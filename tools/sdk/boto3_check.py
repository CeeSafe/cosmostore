"""boto3 against `cosmostore serve` (M3 SDK matrix). Run by tools/sdk/boto3.sh, which starts the server and sets
AWS_ENDPOINT_URL and the credentials. Prints one line per check; exit status 1 if any fails."""
import hashlib
import io
import os
import sys
import urllib.error
import urllib.request

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config
from botocore.exceptions import ClientError

endpoint = os.environ["AWS_ENDPOINT_URL"]
failed = False


def check(name, got, want):
    global failed
    if got == want:
        print("ok  ", name)
    else:
        print("FAIL", name, "expected", repr(want), "got", repr(got))
        failed = True


def code_of(fn):
    try:
        fn()
    except ClientError as e:
        return e.response["Error"]["Code"]
    return "no error"


def client(style="path", **extra):
    # boto3 presigns with SigV2 for a custom endpoint unless told s3v4; CosmoStore accepts only SigV4 (ADR-0013).
    extra.setdefault("signature_version", "s3v4")
    return boto3.client(
        "s3",
        endpoint_url=endpoint if style == "path" else endpoint.replace("127.0.0.1", "localhost"),
        config=Config(s3={"addressing_style": style}, retries={"max_attempts": 1}, **extra),
    )


s3 = client()
B = "boto3-test"
s3.create_bucket(Bucket=B)
check("head_bucket", s3.head_bucket(Bucket=B)["ResponseMetadata"]["HTTPStatusCode"], 200)
check("create twice", code_of(lambda: s3.create_bucket(Bucket=B)), "BucketAlreadyOwnedByYou")
check("list_buckets", [b["Name"] for b in s3.list_buckets()["Buckets"]], [B])

# Objects, with each checksum algorithm the SDK offers.
body = os.urandom(300000)
r = s3.put_object(Bucket=B, Key="o/plain", Body=body, ContentType="x/y", Metadata={"k": "v"})
check("put ETag", r["ETag"], '"%s"' % hashlib.md5(body).hexdigest())
for algo in ["CRC32", "CRC32C", "SHA256", "CRC64NVME"]:
    key = "o/" + algo.lower()
    s3.put_object(Bucket=B, Key=key, Body=body, ChecksumAlgorithm=algo)
    check("put with " + algo, s3.get_object(Bucket=B, Key=key)["Body"].read() == body, True)
# SHA-1 is taken since ADR-0090 §4, and returned with checksum mode.
s3.put_object(Bucket=B, Key="o/sha1", Body=b"abc", ChecksumAlgorithm="SHA1")
check("SHA1 taken and returned", s3.head_object(Bucket=B, Key="o/sha1", ChecksumMode="ENABLED").get("ChecksumSHA1"),
      "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
got = s3.get_object(Bucket=B, Key="o/plain")
check("get", got["Body"].read() == body, True)
check("content type", got["ContentType"], "x/y")
check("metadata", got["Metadata"], {"k": "v"})
check("range", s3.get_object(Bucket=B, Key="o/plain", Range="bytes=10-19")["Body"].read(), body[10:20])
check("head size", s3.head_object(Bucket=B, Key="o/plain")["ContentLength"], len(body))
check("no such key", code_of(lambda: s3.get_object(Bucket=B, Key="nope")), "NoSuchKey")
check("head missing", code_of(lambda: s3.head_object(Bucket=B, Key="nope")), "404")
check("If-None-Match *", code_of(lambda: s3.put_object(Bucket=B, Key="o/plain", Body=b"x", IfNoneMatch="*")),
      "PreconditionFailed")
check("If-Match", code_of(lambda: s3.get_object(Bucket=B, Key="o/plain", IfMatch='"0"')), "PreconditionFailed")

# Listing with the paginators.
for i in range(25):
    s3.put_object(Bucket=B, Key="l/%02d" % i, Body=b"")
keys = [o["Key"] for p in s3.get_paginator("list_objects_v2").paginate(Bucket=B, Prefix="l/", PaginationConfig={"PageSize": 7})
        for o in p.get("Contents", [])]
check("list_objects_v2 pages", keys, ["l/%02d" % i for i in range(25)])
keys = [o["Key"] for p in s3.get_paginator("list_objects").paginate(Bucket=B, Prefix="l/", PaginationConfig={"PageSize": 4})
        for o in p.get("Contents", [])]
check("list_objects pages", len(keys), 25)
r = s3.list_objects_v2(Bucket=B, Delimiter="/")
check("delimiter", [p["Prefix"] for p in r["CommonPrefixes"]], ["l/", "o/"])

# Managed transfers: multipart upload, download, and copy (UploadPartCopy).
cfg = TransferConfig(multipart_threshold=5 * 1024 * 1024, multipart_chunksize=5 * 1024 * 1024, max_concurrency=4)
big = os.urandom(13 * 1024 * 1024)
s3.upload_fileobj(io.BytesIO(big), B, "m/big", Config=cfg, ExtraArgs={"Metadata": {"origin": "boto3"}})
head = s3.head_object(Bucket=B, Key="m/big")
check("multipart ETag", head["ETag"].endswith('-3"'), True)
check("multipart metadata", head["Metadata"], {"origin": "boto3"})
out = io.BytesIO()
s3.download_fileobj(B, "m/big", out, Config=cfg)
check("download (ranged, concurrent)", out.getvalue() == big, True)
s3.copy({"Bucket": B, "Key": "m/big"}, B, "m/copy", Config=cfg)
check("managed copy", s3.get_object(Bucket=B, Key="m/copy")["Body"].read() == big, True)
check("copy_object", s3.copy_object(Bucket=B, Key="o/copy", CopySource={"Bucket": B, "Key": "o/plain"})["CopyObjectResult"]["ETag"],
      '"%s"' % hashlib.md5(body).hexdigest())

# Multipart by hand.
up = s3.create_multipart_upload(Bucket=B, Key="m/hand")["UploadId"]
p1 = s3.upload_part(Bucket=B, Key="m/hand", UploadId=up, PartNumber=1, Body=big[:5 * 1024 * 1024], ChecksumAlgorithm="CRC32")
p2 = s3.upload_part(Bucket=B, Key="m/hand", UploadId=up, PartNumber=2, Body=b"tail")
check("list_parts", [p["PartNumber"] for p in s3.list_parts(Bucket=B, Key="m/hand", UploadId=up)["Parts"]], [1, 2])
check("list_multipart_uploads", [u["Key"] for u in s3.list_multipart_uploads(Bucket=B).get("Uploads", [])], ["m/hand"])
s3.complete_multipart_upload(Bucket=B, Key="m/hand", UploadId=up, MultipartUpload={"Parts": [
    {"PartNumber": 1, "ETag": p1["ETag"]}, {"PartNumber": 2, "ETag": p2["ETag"]}]})
check("completed", s3.get_object(Bucket=B, Key="m/hand")["Body"].read() == big[:5 * 1024 * 1024] + b"tail", True)
up = s3.create_multipart_upload(Bucket=B, Key="m/aborted")["UploadId"]
s3.upload_part(Bucket=B, Key="m/aborted", UploadId=up, PartNumber=1, Body=b"x")
s3.abort_multipart_upload(Bucket=B, Key="m/aborted", UploadId=up)
check("aborted", code_of(lambda: s3.list_parts(Bucket=B, Key="m/aborted", UploadId=up)), "NoSuchUpload")

# Presigned URLs, both addressing styles.
for style in ["path", "virtual"]:
    c = client(style)
    url = c.generate_presigned_url("get_object", Params={"Bucket": B, "Key": "o/plain"}, ExpiresIn=60)
    check("presigned GET (%s)" % style, urllib.request.urlopen(url).read() == body, True)
    url = c.generate_presigned_url("put_object", Params={"Bucket": B, "Key": "p/" + style}, ExpiresIn=60)
    req = urllib.request.Request(url, data=b"presigned " + style.encode(), method="PUT")
    check("presigned PUT (%s)" % style, urllib.request.urlopen(req).status, 200)
    check("virtual-host get" if style == "virtual" else "path get",
          c.get_object(Bucket=B, Key="p/" + style)["Body"].read(), b"presigned " + style.encode())

url = client(signature_version="s3").generate_presigned_url("get_object", Params={"Bucket": B, "Key": "o/plain"})
try:
    urllib.request.urlopen(url)
    check("SigV2 refused", "accepted", "InvalidRequest")
except urllib.error.HTTPError as e:
    text = e.read().decode()
    check("SigV2 refused", (e.code, "<Code>InvalidRequest</Code>" in text, "AWS4-HMAC-SHA256" in text), (400, True, True))

# POST object with a SigV4 policy (ADR-0018), posted as a browser would: multipart/form-data.
def post_form(url, fields, filename, data, content_type="text/plain"):
    boundary = "----cosmostore" + os.urandom(8).hex()
    body = b""
    for k, v in fields.items():
        body += b"--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (
            boundary.encode(), k.encode(), v.encode())
    body += b"--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n" % (
        boundary.encode(), filename.encode(), content_type.encode())
    body += data + b"\r\n--%s--\r\n" % boundary.encode()
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    try:
        r = urllib.request.urlopen(req)
        return r.status, r.read().decode(errors="replace"), {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace"), {k.lower(): v for k, v in e.headers.items()}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None
urllib.request.install_opener(urllib.request.build_opener(NoRedirect))

conditions = [["starts-with", "$key", "post/"], ["starts-with", "$Content-Type", "text/"],
              ["content-length-range", 1, 1048576], ["starts-with", "$x-amz-meta-note", ""]]
post = s3.generate_presigned_post(B, "post/${filename}", Fields={"Content-Type": "text/plain", "x-amz-meta-note": "hi"},
                                  Conditions=conditions, ExpiresIn=60)
status, text, _ = post_form(post["url"], post["fields"], "hello.txt", b"posted bytes")
check("POST object", status, 204)
got = s3.get_object(Bucket=B, Key="post/hello.txt")
check("POST object stored", (got["Body"].read(), got["ContentType"], got["Metadata"]), (b"posted bytes", "text/plain", {"note": "hi"}))
# A POST form's checksum fields are checked (the M12 exit review's A6): SHA-1 of "abc", then a wrong one.
summed = s3.generate_presigned_post(B, "post/summed", Fields={"x-amz-checksum-sha1": "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="},
                                    Conditions=[{"x-amz-checksum-sha1": "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="}], ExpiresIn=60)
status, _, _ = post_form(summed["url"], summed["fields"], "s", b"abc")
check("a POST form's checksum taken", (status, s3.head_object(Bucket=B, Key="post/summed", ChecksumMode="ENABLED").get("ChecksumSHA1")),
      (204, "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="))
status, text, _ = post_form(summed["url"], summed["fields"], "s", b"abd")
check("a POST form's wrong checksum refused", (status, "BadDigest" in text), (400, True))
created = s3.generate_presigned_post(B, "post/created", Fields={"success_action_status": "201"},
                                     Conditions=[{"success_action_status": "201"}], ExpiresIn=60)
status, text, _ = post_form(created["url"], created["fields"], "x", b"x")
check("POST 201", (status, "<Key>post/created</Key>" in text), (201, True))
redirect = s3.generate_presigned_post(B, "post/r", Fields={"success_action_redirect": "http://example.invalid/done"},
                                      Conditions=[{"success_action_redirect": "http://example.invalid/done"}], ExpiresIn=60)
status, _, headers = post_form(redirect["url"], redirect["fields"], "x", b"x")
check("POST redirect", (status, headers.get("location", "").startswith("http://example.invalid/done?bucket=")), (303, True))
status, text, _ = post_form(post["url"], post["fields"], "big.txt", b"x" * 1048577)
check("POST too large", (status, "EntityTooLarge" in text), (400, True))
extra = dict(post["fields"]); extra["x-amz-meta-other"] = "no"
status, text, _ = post_form(post["url"], extra, "e.txt", b"x")
check("POST field outside the policy", status, 403)
bad = dict(post["fields"]); bad["policy"] = bad["policy"][:-4] + "AAA="
status, text, _ = post_form(post["url"], bad, "b.txt", b"x")
check("POST with a changed policy", status in (400, 403), True)
short = s3.generate_presigned_post(B, "post/${filename}", Fields={"Content-Type": "text/plain", "x-amz-meta-note": "hi"},
                                   Conditions=conditions, ExpiresIn=1)
import time
time.sleep(2)
status, text, _ = post_form(short["url"], short["fields"], "late.txt", b"x")
check("POST with an expired policy", status, 403)
wrong_key = dict(post["fields"]); wrong_key["key"] = "elsewhere/${filename}"
status, _, _ = post_form(post["url"], wrong_key, "w.txt", b"x")
check("POST key outside the policy", status, 403)
# Encryption on a POST (ADR-0046 §5): the form's field, then a bucket's default; a file over one 64 KiB chunk.
sealed = s3.generate_presigned_post(B, "post/sealed", Fields={"x-amz-server-side-encryption": "AES256"},
                                    Conditions=[{"x-amz-server-side-encryption": "AES256"}], ExpiresIn=60)
body = bytes(range(256)) * 600
status, _, headers = post_form(sealed["url"], sealed["fields"], "s.bin", body)
check("POST sealed", (status, headers.get("x-amz-server-side-encryption")), (204, "AES256"))
got = s3.get_object(Bucket=B, Key="post/sealed")
check("POST sealed reads", (got["Body"].read() == body, got["ServerSideEncryption"]), (True, "AES256"))
kms = s3.generate_presigned_post(B, "post/kms", Fields={"x-amz-server-side-encryption": "aws:kms"},
                                 Conditions=[{"x-amz-server-side-encryption": "aws:kms"}], ExpiresIn=60)
status, text, _ = post_form(kms["url"], kms["fields"], "k.bin", b"x")
check("POST SSE-KMS", (status, "NotImplemented" in text), (501, True))
s3.put_bucket_encryption(Bucket=B, ServerSideEncryptionConfiguration={
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]})
plain = s3.generate_presigned_post(B, "post/default", ExpiresIn=60)
status, _, _ = post_form(plain["url"], plain["fields"], "d.bin", b"sealed by the bucket")
check("POST under a default", (status, s3.head_object(Bucket=B, Key="post/default")["ServerSideEncryption"]), (204, "AES256"))
check("POST under a default reads", s3.get_object(Bucket=B, Key="post/default")["Body"].read(), b"sealed by the bucket")
s3.delete_bucket_encryption(Bucket=B)
check("no default after delete", code_of(lambda: s3.get_bucket_encryption(Bucket=B)), "ServerSideEncryptionConfigurationNotFoundError")

# Batch delete, then everything.
r = s3.delete_objects(Bucket=B, Delete={"Objects": [{"Key": "l/%02d" % i} for i in range(25)] + [{"Key": "missing"}]})
check("delete_objects", len(r["Deleted"]), 26)
check("bucket not empty", code_of(lambda: s3.delete_bucket(Bucket=B)), "BucketNotEmpty")
boto3.resource("s3", endpoint_url=endpoint).Bucket(B).objects.all().delete()
s3.delete_bucket(Bucket=B)
check("bucket deleted", code_of(lambda: s3.head_bucket(Bucket=B)), "404")
# Versions (ADR-0041): ids on writes, reads by id, a delete marker, the paginator over versions, and the resource's
# object_versions, which is how boto3 empties a bucket with versioning.
V = "boto3-versions"
s3.create_bucket(Bucket=V)
check("versioning never set", s3.get_bucket_versioning(Bucket=V).get("Status"), None)
s3.put_bucket_versioning(Bucket=V, VersioningConfiguration={"Status": "Enabled"})
check("versioning enabled", s3.get_bucket_versioning(Bucket=V).get("Status"), "Enabled")
ids = [s3.put_object(Bucket=V, Key="k", Body=b"version %d" % i)["VersionId"] for i in range(3)]
check("three version ids", (len(set(ids)), all(len(i) == 32 for i in ids)), (3, True))
got = s3.get_object(Bucket=V, Key="k", VersionId=ids[0])
check("get by version id", (got["Body"].read(), got["VersionId"]), (b"version 0", ids[0]))
check("head names the current version", s3.head_object(Bucket=V, Key="k")["VersionId"], ids[2])
check("no such version", code_of(lambda: s3.get_object(Bucket=V, Key="k", VersionId="0" * 31 + "1")), "NoSuchVersion")
part = os.urandom(5 * 1024 * 1024)
up = s3.create_multipart_upload(Bucket=V, Key="mp")["UploadId"]
etag = s3.upload_part(Bucket=V, Key="mp", UploadId=up, PartNumber=1, Body=part)["ETag"]
done = s3.complete_multipart_upload(Bucket=V, Key="mp", UploadId=up,
                                    MultipartUpload={"Parts": [{"PartNumber": 1, "ETag": etag}]})
check("multipart version id", len(done.get("VersionId", "")), 32)
copied = s3.copy_object(Bucket=V, Key="copy", CopySource={"Bucket": V, "Key": "k", "VersionId": ids[1]})
check("copy from a version", (copied["CopySourceVersionId"], s3.get_object(Bucket=V, Key="copy")["Body"].read()),
      (ids[1], b"version 1"))
marker = s3.delete_object(Bucket=V, Key="k")
check("delete marker", (marker.get("DeleteMarker"), len(marker["VersionId"])), (True, 32))
try:
    s3.head_object(Bucket=V, Key="k")
    check("head under a marker", "found", "404")
except ClientError as e:
    headers = e.response["ResponseMetadata"]["HTTPHeaders"]
    check("head under a marker", (e.response["Error"]["Code"], headers.get("x-amz-delete-marker"),
                                  headers.get("x-amz-version-id")), ("404", "true", marker["VersionId"]))
check("get a marker by id", code_of(lambda: s3.get_object(Bucket=V, Key="k", VersionId=marker["VersionId"])),
      "MethodNotAllowed")
listed = [(v["Key"], v["VersionId"], v["IsLatest"]) for page in
          s3.get_paginator("list_object_versions").paginate(Bucket=V, Prefix="k", PaginationConfig={"PageSize": 2})
          for v in page.get("Versions", [])]
check("versions in pages of two", listed, [("k", ids[2], False), ("k", ids[1], False), ("k", ids[0], False)])
markers = s3.list_object_versions(Bucket=V, Prefix="k").get("DeleteMarkers", [])
check("the marker is the latest", [(m["VersionId"], m["IsLatest"]) for m in markers], [(marker["VersionId"], True)])
r = s3.delete_objects(Bucket=V, Delete={"Objects": [{"Key": "k", "VersionId": marker["VersionId"]},
                                                    {"Key": "k", "VersionId": ids[0]}]})
check("delete_objects with versions", sorted((d["VersionId"], d.get("DeleteMarker", False)) for d in r["Deleted"]),
      sorted([(marker["VersionId"], True), (ids[0], False)]))
check("the key is back", s3.get_object(Bucket=V, Key="k")["Body"].read(), b"version 2")
s3.put_bucket_versioning(Bucket=V, VersioningConfiguration={"Status": "Suspended"})
check("a suspended put has no version id", s3.put_object(Bucket=V, Key="k", Body=b"null").get("VersionId"), None)
check("the null version", s3.get_object(Bucket=V, Key="k", VersionId="null")["Body"].read(), b"null")
# Lifecycle rules for versions (ADR-0042) are kept and returned.
s3.put_bucket_lifecycle_configuration(Bucket=V, LifecycleConfiguration={"Rules": [
    {"ID": "old", "Filter": {"Prefix": "k"}, "Status": "Enabled",
     "NoncurrentVersionExpiration": {"NoncurrentDays": 30, "NewerNoncurrentVersions": 2}},
    {"ID": "markers", "Filter": {"Prefix": ""}, "Status": "Enabled", "Expiration": {"ExpiredObjectDeleteMarker": True}}]})
rules = s3.get_bucket_lifecycle_configuration(Bucket=V)["Rules"]
check("lifecycle rules for versions",
      [(r["ID"], r.get("NoncurrentVersionExpiration"), r.get("Expiration")) for r in rules],
      [("old", {"NoncurrentDays": 30, "NewerNoncurrentVersions": 2}, None),
       ("markers", None, {"ExpiredObjectDeleteMarker": True})])
check("noncurrent days of zero", code_of(lambda: s3.put_bucket_lifecycle_configuration(Bucket=V, LifecycleConfiguration={
    "Rules": [{"ID": "z", "Filter": {"Prefix": ""}, "Status": "Enabled",
               "NoncurrentVersionExpiration": {"NoncurrentDays": 0}}]})), "InvalidArgument")
check("bucket with versions not empty", code_of(lambda: s3.delete_bucket(Bucket=V)), "BucketNotEmpty")
boto3.resource("s3", endpoint_url=endpoint).Bucket(V).object_versions.all().delete()
check("no versions left", [k for k in s3.list_object_versions(Bucket=V) if k in ("Versions", "DeleteMarkers")], [])
s3.delete_bucket(Bucket=V)
check("versioned bucket deleted", code_of(lambda: s3.head_bucket(Bucket=V)), "404")

# Bucket policies (ADR-0043): an anonymous client (no signature) reads what a policy allows, and nothing else.
from botocore import UNSIGNED
anonymous = boto3.client("s3", endpoint_url=endpoint, config=Config(signature_version=UNSIGNED, retries={"max_attempts": 1}))
P = "boto3-policy"
s3.create_bucket(Bucket=P)
s3.put_object(Bucket=P, Key="pub/a", Body=b"public")
s3.put_object(Bucket=P, Key="priv/b", Body=b"private")
check("anonymous before a policy", code_of(lambda: anonymous.get_object(Bucket=P, Key="pub/a")), "AccessDenied")
check("no policy", code_of(lambda: s3.get_bucket_policy(Bucket=P)), "NoSuchBucketPolicy")
import json
s3.put_bucket_policy(Bucket=P, Policy=json.dumps({"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::%s/pub/*" % P},
    {"Effect": "Allow", "Principal": "*", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::%s" % P,
     "Condition": {"StringLike": {"s3:prefix": "pub/*"}}},
    {"Effect": "Deny", "Principal": {"AWS": "arn:aws:iam:::user/%s" % os.environ["AWS_ACCESS_KEY_ID"]},
     "Action": "s3:PutObject", "Resource": "arn:aws:s3:::%s/frozen/*" % P}]}))
check("get_bucket_policy", json.loads(s3.get_bucket_policy(Bucket=P)["Policy"])["Statement"][0]["Action"], "s3:GetObject")
check("anonymous read", anonymous.get_object(Bucket=P, Key="pub/a")["Body"].read(), b"public")
check("anonymous read refused", code_of(lambda: anonymous.get_object(Bucket=P, Key="priv/b")), "AccessDenied")
check("anonymous list under the prefix", [o["Key"] for o in anonymous.list_objects_v2(Bucket=P, Prefix="pub/").get("Contents", [])], ["pub/a"])
check("anonymous list elsewhere", code_of(lambda: anonymous.list_objects_v2(Bucket=P, Prefix="priv/")), "AccessDenied")
check("anonymous write", code_of(lambda: anonymous.put_object(Bucket=P, Key="pub/x", Body=b"x")), "AccessDenied")
check("a key denied", code_of(lambda: s3.put_object(Bucket=P, Key="frozen/x", Body=b"x")), "AccessDenied")
check("a key elsewhere", s3.put_object(Bucket=P, Key="open/x", Body=b"x")["ResponseMetadata"]["HTTPStatusCode"], 200)
check("a malformed policy", code_of(lambda: s3.put_bucket_policy(Bucket=P, Policy="{}")), "MalformedPolicy")
# The policy's status and the public-access block (ADR-0044).
def block_of(**on):
    names = ["BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets"]
    return {n: on.get(n, False) for n in names}
check("the status of a public policy", s3.get_bucket_policy_status(Bucket=P)["PolicyStatus"]["IsPublic"], True)
check("no public-access block", code_of(lambda: s3.get_public_access_block(Bucket=P)), "NoSuchPublicAccessBlockConfiguration")
s3.put_public_access_block(Bucket=P, PublicAccessBlockConfiguration=block_of(RestrictPublicBuckets=True))
check("get_public_access_block", s3.get_public_access_block(Bucket=P)["PublicAccessBlockConfiguration"], block_of(RestrictPublicBuckets=True))
check("anonymous read under RestrictPublicBuckets", code_of(lambda: anonymous.get_object(Bucket=P, Key="pub/a")), "AccessDenied")
check("a key under it", s3.get_object(Bucket=P, Key="pub/a")["Body"].read(), b"public")
public_policy = s3.get_bucket_policy(Bucket=P)["Policy"]
s3.put_public_access_block(Bucket=P, PublicAccessBlockConfiguration=block_of(BlockPublicPolicy=True))
check("a public policy under BlockPublicPolicy", code_of(lambda: s3.put_bucket_policy(Bucket=P, Policy=public_policy)), "AccessDenied")
check("the policy it already had", anonymous.get_object(Bucket=P, Key="pub/a")["Body"].read(), b"public")
s3.delete_public_access_block(Bucket=P)
check("the block deleted", code_of(lambda: s3.get_public_access_block(Bucket=P)), "NoSuchPublicAccessBlockConfiguration")
s3.delete_bucket_policy(Bucket=P)
check("the status without a policy", s3.get_bucket_policy_status(Bucket=P)["PolicyStatus"]["IsPublic"], False)
check("anonymous after the delete", code_of(lambda: anonymous.get_object(Bucket=P, Key="pub/a")), "AccessDenied")
boto3.resource("s3", endpoint_url=endpoint).Bucket(P).objects.all().delete()
s3.delete_bucket(Bucket=P)

# ACLs (ADR-0045): canned ACLs and the document, on buckets, objects, versions and multipart uploads.
A = "boto3-acl"
everyone = "http://acs.amazonaws.com/groups/global/AllUsers"
def grants_of(acl):
    return sorted((g["Grantee"].get("ID") or g["Grantee"].get("URI"), g["Permission"]) for g in acl["Grants"])
s3.create_bucket(Bucket=A, ACL="public-read")
check("a bucket made public-read", grants_of(s3.get_bucket_acl(Bucket=A)), [("cosmostore", "FULL_CONTROL"), (everyone, "READ")])
check("the owner", s3.get_bucket_acl(Bucket=A)["Owner"]["ID"], "cosmostore")
s3.put_object(Bucket=A, Key="open", Body=b"open", ACL="public-read")
s3.put_object(Bucket=A, Key="shut", Body=b"shut")
check("anonymous list by the ACL", sorted(o["Key"] for o in anonymous.list_objects_v2(Bucket=A)["Contents"]), ["open", "shut"])
check("anonymous read by the ACL", anonymous.get_object(Bucket=A, Key="open")["Body"].read(), b"open")
check("anonymous read of a private object", code_of(lambda: anonymous.get_object(Bucket=A, Key="shut")), "AccessDenied")
check("anonymous write under public-read", code_of(lambda: anonymous.put_object(Bucket=A, Key="x", Body=b"x")), "AccessDenied")
check("no ACL in the headers", [h for h in s3.head_object(Bucket=A, Key="open")["ResponseMetadata"]["HTTPHeaders"] if "acl" in h], [])
s3.put_object_acl(Bucket=A, Key="open", ACL="private")
check("anonymous read after private", code_of(lambda: anonymous.get_object(Bucket=A, Key="open")), "AccessDenied")
policy = s3.get_object_acl(Bucket=A, Key="shut")
policy = {"Owner": policy["Owner"], "Grants": policy["Grants"] + [{"Grantee": {"Type": "Group", "URI": everyone}, "Permission": "READ"}]}
s3.put_object_acl(Bucket=A, Key="shut", AccessControlPolicy=policy)
check("the document's grants", grants_of(s3.get_object_acl(Bucket=A, Key="shut")), [("cosmostore", "FULL_CONTROL"), (everyone, "READ")])
check("anonymous read by the document", anonymous.get_object(Bucket=A, Key="shut")["Body"].read(), b"shut")
s3.put_bucket_versioning(Bucket=A, VersioningConfiguration={"Status": "Enabled"})
v1 = s3.put_object(Bucket=A, Key="ver", Body=b"one", ACL="public-read")["VersionId"]
v2 = s3.put_object(Bucket=A, Key="ver", Body=b"two")["VersionId"]
check("anonymous read of a public version", anonymous.get_object(Bucket=A, Key="ver", VersionId=v1)["Body"].read(), b"one")
check("anonymous read of the private current", code_of(lambda: anonymous.get_object(Bucket=A, Key="ver")), "AccessDenied")
s3.put_object_acl(Bucket=A, Key="ver", VersionId=v1, ACL="private")
s3.put_object_acl(Bucket=A, Key="ver", ACL="public-read")
check("the version made private", code_of(lambda: anonymous.get_object(Bucket=A, Key="ver", VersionId=v1)), "AccessDenied")
check("the current made public", anonymous.get_object(Bucket=A, Key="ver")["Body"].read(), b"two")
check("the versions stay", [v["VersionId"] for v in s3.list_object_versions(Bucket=A, Prefix="ver")["Versions"]], [v2, v1])
upload = s3.create_multipart_upload(Bucket=A, Key="parts", ACL="public-read")["UploadId"]
etag = s3.upload_part(Bucket=A, Key="parts", UploadId=upload, PartNumber=1, Body=b"part")["ETag"]
s3.complete_multipart_upload(Bucket=A, Key="parts", UploadId=upload, MultipartUpload={"Parts": [{"ETag": etag, "PartNumber": 1}]})
check("anonymous read of a public upload", anonymous.get_object(Bucket=A, Key="parts")["Body"].read(), b"part")
check("a grantee by email", code_of(lambda: s3.put_bucket_acl(Bucket=A, GrantRead="emailAddress=a@example.com")), "UnresolvableGrantByEmailAddress")
check("a grantee there is not", code_of(lambda: s3.put_bucket_acl(Bucket=A, GrantRead="id=stranger")), "InvalidArgument")
s3.put_bucket_acl(Bucket=A, ACL="private")
check("anonymous list after private", code_of(lambda: anonymous.list_objects_v2(Bucket=A)), "AccessDenied")
boto3.resource("s3", endpoint_url=endpoint).Bucket(A).object_versions.all().delete()
s3.delete_bucket(Bucket=A)

# Object lock (ADR-0047): retention and legal hold on versions, the default retention, copies and multipart uploads.
import datetime
L = "boto3-lock"
far = datetime.datetime(2040, 1, 1, tzinfo=datetime.timezone.utc)
s3.create_bucket(Bucket=L, ObjectLockEnabledForBucket=True)
check("versioning under object lock", s3.get_bucket_versioning(Bucket=L)["Status"], "Enabled")
check("the lock configuration", s3.get_object_lock_configuration(Bucket=L)["ObjectLockConfiguration"], {"ObjectLockEnabled": "Enabled"})
kept = s3.put_object(Bucket=L, Key="kept", Body=b"kept", ObjectLockMode="GOVERNANCE", ObjectLockRetainUntilDate=far)["VersionId"]
head = s3.head_object(Bucket=L, Key="kept")
check("the lock in a head", (head["ObjectLockMode"], head["ObjectLockRetainUntilDate"]), ("GOVERNANCE", far))
check("a locked version", code_of(lambda: s3.delete_object(Bucket=L, Key="kept", VersionId=kept)), "AccessDenied")
check("a retention shortened", code_of(lambda: s3.put_object_retention(Bucket=L, Key="kept", VersionId=kept,
      Retention={"Mode": "GOVERNANCE", "RetainUntilDate": datetime.datetime(2030, 1, 1, tzinfo=datetime.timezone.utc)})), "AccessDenied")
longer = datetime.datetime(2041, 1, 1, tzinfo=datetime.timezone.utc)
s3.put_object_retention(Bucket=L, Key="kept", VersionId=kept, Retention={"Mode": "GOVERNANCE", "RetainUntilDate": longer})
check("a retention made longer", s3.get_object_retention(Bucket=L, Key="kept", VersionId=kept)["Retention"], {"Mode": "GOVERNANCE", "RetainUntilDate": longer})
s3.copy_object(Bucket=L, Key="copy", CopySource={"Bucket": L, "Key": "kept"})
check("a copy has no lock", code_of(lambda: s3.get_object_retention(Bucket=L, Key="copy")), "NoSuchObjectLockConfiguration")
s3.put_object_legal_hold(Bucket=L, Key="copy", LegalHold={"Status": "ON"})
check("the hold in a head", s3.head_object(Bucket=L, Key="copy")["ObjectLockLegalHoldStatus"], "ON")
copy_version = s3.head_object(Bucket=L, Key="copy")["VersionId"]
check("a held version, with a bypass", code_of(lambda: s3.delete_object(Bucket=L, Key="copy", VersionId=copy_version, BypassGovernanceRetention=True)), "AccessDenied")
s3.put_object_legal_hold(Bucket=L, Key="copy", LegalHold={"Status": "OFF"})
check("the hold taken off", s3.get_object_legal_hold(Bucket=L, Key="copy")["LegalHold"]["Status"], "OFF")
# A POST form's object lock fields (ADR-0090 §5), as PutObject's headers.
held = s3.generate_presigned_post(L, "posted", Fields={"x-amz-object-lock-legal-hold": "ON"},
                                  Conditions=[{"x-amz-object-lock-legal-hold": "ON"}], ExpiresIn=60)
status, _, _ = post_form(held["url"], held["fields"], "p.txt", b"posted under a hold")
check("a POST form's legal hold", (status, s3.head_object(Bucket=L, Key="posted").get("ObjectLockLegalHoldStatus")), (204, "ON"))
s3.put_object_legal_hold(Bucket=L, Key="posted", LegalHold={"Status": "OFF"})
s3.put_object_lock_configuration(Bucket=L, ObjectLockConfiguration={"ObjectLockEnabled": "Enabled",
    "Rule": {"DefaultRetention": {"Mode": "GOVERNANCE", "Years": 1}}})
check("the default retention", s3.get_object_lock_configuration(Bucket=L)["ObjectLockConfiguration"]["Rule"]["DefaultRetention"], {"Mode": "GOVERNANCE", "Years": 1})
upload = s3.create_multipart_upload(Bucket=L, Key="parts")["UploadId"]
etag = s3.upload_part(Bucket=L, Key="parts", UploadId=upload, PartNumber=1, Body=b"part")["ETag"]
parts = s3.complete_multipart_upload(Bucket=L, Key="parts", UploadId=upload, MultipartUpload={"Parts": [{"ETag": etag, "PartNumber": 1}]})["VersionId"]
check("an upload's default retention", s3.get_object_retention(Bucket=L, Key="parts")["Retention"]["Mode"], "GOVERNANCE")
errors = s3.delete_objects(Bucket=L, Delete={"Objects": [{"Key": "parts", "VersionId": parts}, {"Key": "copy", "VersionId": copy_version}]})
check("delete_objects, one locked", ([e["Code"] for e in errors.get("Errors", [])], [d["Key"] for d in errors.get("Deleted", [])]), (["AccessDenied"], ["copy"]))
check("versioning suspended under object lock", code_of(lambda: s3.put_bucket_versioning(Bucket=L, VersioningConfiguration={"Status": "Suspended"})), "InvalidBucketState")
s3.create_bucket(Bucket=L + "-off")
check("a lock in a bucket without object lock", code_of(lambda: s3.put_object(Bucket=L + "-off", Key="held", Body=b"x", ObjectLockLegalHoldStatus="ON")), "InvalidRequest")
check("object lock without versioning", code_of(lambda: s3.put_object_lock_configuration(Bucket=L + "-off", ObjectLockConfiguration={"ObjectLockEnabled": "Enabled"})), "InvalidBucketState")
s3.delete_bucket(Bucket=L + "-off")
for kind in ("Versions", "DeleteMarkers"):
    for v in s3.list_object_versions(Bucket=L).get(kind, []):
        s3.delete_object(Bucket=L, Key=v["Key"], VersionId=v["VersionId"], BypassGovernanceRetention=True)
s3.delete_bucket(Bucket=L)
check("the lock bucket deleted", code_of(lambda: s3.head_bucket(Bucket=L)), "404")

# Event notifications (ADR-0048): the configuration only; tools/s3_smoke.sh has a webhook to deliver to.
N = "boto3-notify"
s3.create_bucket(Bucket=N)
check("no notification rules", [k for k in s3.get_bucket_notification_configuration(Bucket=N) if k.endswith("Configurations")], [])
check("a target serve was not given", code_of(lambda: s3.put_bucket_notification_configuration(Bucket=N, NotificationConfiguration={
    "QueueConfigurations": [{"QueueArn": "arn:cosmostore:sqs::nowhere:webhook", "Events": ["s3:ObjectCreated:*"]}]})), "InvalidArgument")
check("a topic", code_of(lambda: s3.put_bucket_notification_configuration(Bucket=N, NotificationConfiguration={
    "TopicConfigurations": [{"TopicArn": "arn:aws:sns:us-east-1:1:t", "Events": ["s3:ObjectCreated:*"]}]})), "NotImplemented")
s3.put_bucket_notification_configuration(Bucket=N, NotificationConfiguration={})
check("rules taken off where there were none", s3.get_bucket_notification_configuration(Bucket=N).get("QueueConfigurations"), None)
s3.delete_bucket(Bucket=N)

# CORS (ADR-0049): the rules; tools/s3_smoke.sh sends the preflights.
C = "boto3-cors"
s3.create_bucket(Bucket=C)
check("no CORS rules", code_of(lambda: s3.get_bucket_cors(Bucket=C)), "NoSuchCORSConfiguration")
cors_rules = [{"ID": "site", "AllowedOrigins": ["https://*.example", "http://localhost:3000"], "AllowedMethods": ["GET", "PUT"],
               "AllowedHeaders": ["*"], "ExposeHeaders": ["ETag"], "MaxAgeSeconds": 300},
              {"AllowedOrigins": ["*"], "AllowedMethods": ["HEAD"]}]
s3.put_bucket_cors(Bucket=C, CORSConfiguration={"CORSRules": cors_rules})
check("get_bucket_cors", s3.get_bucket_cors(Bucket=C)["CORSRules"], cors_rules)
check("a pattern with two wildcards", code_of(lambda: s3.put_bucket_cors(Bucket=C, CORSConfiguration={"CORSRules": [
    {"AllowedOrigins": ["https://*.a.*"], "AllowedMethods": ["GET"]}]})), "InvalidRequest")
s3.delete_bucket_cors(Bucket=C)
check("the CORS rules deleted", code_of(lambda: s3.get_bucket_cors(Bucket=C)), "NoSuchCORSConfiguration")
s3.delete_bucket(Bucket=C)

# M7 (ADR-0072 to ADR-0077) through boto3: each item's configuration calls, and what each does. common.sh starts
# serve with access logs every 2 s, a 3 s inventory day, websites under web.localhost and a role "reader" of sdk-m7.
import json
import time


def until(fn, seconds=15):
    end = time.time() + seconds
    while time.time() < end:
        got = fn()
        if got:
            return got
        time.sleep(0.25)
    return None


def keys_under(bucket, prefix):
    return [o["Key"] for o in s3.list_objects_v2(Bucket=bucket, Prefix=prefix).get("Contents", [])]


M7, LOGS = "sdk-m7", "sdk-m7-logs"
s3.create_bucket(Bucket=M7)
s3.create_bucket(Bucket=LOGS)
s3.put_object(Bucket=M7, Key="index.html", Body=b"the index", ContentType="text/html")
s3.put_object(Bucket=M7, Key="error.html", Body=b"the error page", ContentType="text/html")

# Access logs (ADR-0072).
logging_on = {"TargetBucket": LOGS, "TargetPrefix": "access/"}
s3.put_bucket_logging(Bucket=M7, BucketLoggingStatus={"LoggingEnabled": logging_on})
check("get_bucket_logging", s3.get_bucket_logging(Bucket=M7).get("LoggingEnabled"), logging_on)
check("logging to a bucket that is not there", code_of(lambda: s3.put_bucket_logging(Bucket=M7, BucketLoggingStatus={
    "LoggingEnabled": {"TargetBucket": "sdk-nowhere", "TargetPrefix": "x/"}})), "InvalidTargetBucketForLogging")
s3.put_object(Bucket=M7, Key="logged.txt", Body=b"logged")


def logged_put():
    for k in keys_under(LOGS, "access/"):
        if b"REST.PUT.OBJECT logged.txt" in s3.get_object(Bucket=LOGS, Key=k)["Body"].read():
            return True
    return False


check("the PUT's line in a log object", until(logged_put), True)
s3.put_bucket_logging(Bucket=M7, BucketLoggingStatus={})
check("logging off", s3.get_bucket_logging(Bucket=M7).get("LoggingEnabled"), None)

# Website hosting (ADR-0073): the configuration, then the site through <bucket>.web.localhost, with a policy that
# lets anyone read.
site = {"IndexDocument": {"Suffix": "index.html"}, "ErrorDocument": {"Key": "error.html"}}
s3.put_bucket_website(Bucket=M7, WebsiteConfiguration=site)
got = s3.get_bucket_website(Bucket=M7)
check("get_bucket_website", {k: got.get(k) for k in site}, site)
s3.put_bucket_policy(Bucket=M7, Policy=json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": "*",
    "Action": "s3:GetObject", "Resource": "arn:aws:s3:::%s/*" % M7}]}))


def site_get(path):
    req = urllib.request.Request(endpoint + path, headers={"Host": "%s.web.localhost:%s" % (M7, endpoint.rsplit(":", 1)[1])})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


check("the site's index", site_get("/"), (200, b"the index"))
check("the site's error document", site_get("/no-such-page"), (404, b"the error page"))
s3.delete_bucket_website(Bucket=M7)
check("the website deleted", code_of(lambda: s3.get_bucket_website(Bucket=M7)), "NoSuchWebsiteConfiguration")
s3.delete_bucket_policy(Bucket=M7)

# Inventory (ADR-0074): a daily CSV report into the logs bucket; a day is 3 s here.
inventory = {"Id": "daily", "IsEnabled": True, "IncludedObjectVersions": "Current", "Schedule": {"Frequency": "Daily"},
             "Destination": {"S3BucketDestination": {"Bucket": "arn:aws:s3:::" + LOGS, "Format": "CSV", "Prefix": "inv"}}}
s3.put_bucket_inventory_configuration(Bucket=M7, Id="daily", InventoryConfiguration=inventory)
got = s3.get_bucket_inventory_configuration(Bucket=M7, Id="daily")["InventoryConfiguration"]
check("get_bucket_inventory_configuration", (got["Id"], got["IsEnabled"], got["Schedule"], got["Destination"]),
      ("daily", True, {"Frequency": "Daily"}, inventory["Destination"]))
check("list_bucket_inventory_configurations",
      [c["Id"] for c in s3.list_bucket_inventory_configurations(Bucket=M7)["InventoryConfigurationList"]], ["daily"])
check("an account id is not done, not dropped", code_of(lambda: s3.put_bucket_inventory_configuration(Bucket=M7, Id="acct",
    InventoryConfiguration=dict(inventory, Id="acct", Destination={"S3BucketDestination": dict(
        inventory["Destination"]["S3BucketDestination"], AccountId="111122223333")}))), "NotImplemented")
manifest = until(lambda: [k for k in keys_under(LOGS, "inv/") if k.endswith("manifest.json")], 20)
check("a report's manifest", bool(manifest), True)
if manifest:
    files = json.loads(s3.get_object(Bucket=LOGS, Key=manifest[0])["Body"].read())["files"]
    import csv
    import gzip
    rows = list(csv.reader(io.TextIOWrapper(gzip.GzipFile(fileobj=io.BytesIO(
        s3.get_object(Bucket=LOGS, Key=files[0]["key"])["Body"].read())))))
    check("its CSV has every object", sorted(r[1] for r in rows), ["error.html", "index.html", "logged.txt"])
s3.delete_bucket_inventory_configuration(Bucket=M7, Id="daily")
check("the inventory deleted", code_of(lambda: s3.get_bucket_inventory_configuration(Bucket=M7, Id="daily")),
      "NoSuchConfiguration")

# STS (ADR-0075): a session token, and the role "reader", sign S3 requests through boto3.
sts = boto3.client("sts", endpoint_url=endpoint)


def as_creds(c):
    return boto3.client("s3", endpoint_url=endpoint, aws_access_key_id=c["AccessKeyId"], aws_secret_access_key=c["SecretAccessKey"],
                        aws_session_token=c["SessionToken"], config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1},
                                                                           signature_version="s3v4"))


session = sts.get_session_token(DurationSeconds=900)["Credentials"]
check("get_session_token gives an ASIA key", session["AccessKeyId"][:4], "ASIA")
check("the session reads", as_creds(session).get_object(Bucket=M7, Key="logged.txt")["Body"].read(), b"logged")
role = sts.assume_role(RoleArn="arn:aws:iam::000000000000:role/reader", RoleSessionName="boto3")["Credentials"]
reader = as_creds(role)
check("the role reads", reader.get_object(Bucket=M7, Key="logged.txt")["Body"].read(), b"logged")
check("the role does not write", code_of(lambda: reader.put_object(Bucket=M7, Key="no", Body=b"no")), "AccessDenied")
check("nor read another bucket", code_of(lambda: reader.list_objects_v2(Bucket=LOGS)), "AccessDenied")
check("policy ARNs are not done, not dropped", code_of(lambda: sts.assume_role(RoleArn="arn:aws:iam::000000000000:role/reader",
    RoleSessionName="arns", PolicyArns=[{"arn": "arn:aws:iam::aws:policy/ReadOnlyAccess"}])), "NotImplemented")

# Access Points (ADR-0076): S3 Control through boto3, then requests by alias and by ARN. S3 Control puts the
# account in the host, so both go to localhost (`<account>.localhost`, `<name>-<account>.localhost`).
ACCOUNT = "000000000000"
ctl = boto3.client("s3control", endpoint_url=endpoint.replace("127.0.0.1", "localhost"))
made = ctl.create_access_point(AccountId=ACCOUNT, Name="sdk-ap", Bucket=M7)
alias = made.get("Alias", "")
check("create_access_point gives an alias", alias[-8:], "-s3alias")
got = ctl.get_access_point(AccountId=ACCOUNT, Name="sdk-ap")
check("get_access_point", (got["Bucket"], got["NetworkOrigin"]), (M7, "Internet"))
check("list_access_points", [a["Name"] for a in ctl.list_access_points(AccountId=ACCOUNT, Bucket=M7)["AccessPointList"]], ["sdk-ap"])
check("a name twice", code_of(lambda: ctl.create_access_point(AccountId=ACCOUNT, Name="sdk-ap", Bucket=M7)),
      "AccessPointAlreadyOwnedByYou")
s3.put_object(Bucket=alias, Key="ap/door.txt", Body=b"through a door")
check("a write by its alias lands in its bucket", s3.get_object(Bucket=M7, Key="ap/door.txt")["Body"].read(), b"through a door")
arn = "arn:aws:s3:us-east-1:%s:accesspoint/sdk-ap" % ACCOUNT
check("a read by its ARN", client("virtual").get_object(Bucket=arn, Key="ap/door.txt")["Body"].read(), b"through a door")
ctl.delete_access_point(AccountId=ACCOUNT, Name="sdk-ap")
check("the access point deleted", code_of(lambda: ctl.get_access_point(AccountId=ACCOUNT, Name="sdk-ap")), "NoSuchAccessPoint")

# Replication (ADR-0077): a new version copied to another bucket with its version id and ETag.
RS, RD = "sdk-rsrc", "sdk-rdst"
for b in (RS, RD):
    s3.create_bucket(Bucket=b)
    s3.put_bucket_versioning(Bucket=b, VersioningConfiguration={"Status": "Enabled"})
rule = {"ID": "all", "Priority": 1, "Status": "Enabled", "Filter": {"Prefix": ""},
        "DeleteMarkerReplication": {"Status": "Enabled"}, "Destination": {"Bucket": "arn:aws:s3:::" + RD}}
check("one priority twice", code_of(lambda: s3.put_bucket_replication(Bucket=RS, ReplicationConfiguration={
    "Role": "arn:aws:iam::%s:role/r" % ACCOUNT, "Rules": [rule, dict(rule, ID="again")]})), "InvalidArgument")
s3.put_bucket_replication(Bucket=RS, ReplicationConfiguration={"Role": "arn:aws:iam::%s:role/r" % ACCOUNT, "Rules": [rule]})
check("get_bucket_replication", s3.get_bucket_replication(Bucket=RS)["ReplicationConfiguration"]["Rules"][0]["Destination"]["Bucket"],
      "arn:aws:s3:::" + RD)
put = s3.put_object(Bucket=RS, Key="r/one.txt", Body=b"replicate me")
check("replicated", until(lambda: s3.head_object(Bucket=RS, Key="r/one.txt").get("ReplicationStatus") == "COMPLETED"), True)
replica = s3.head_object(Bucket=RD, Key="r/one.txt")
check("the replica keeps its version id and ETag", (replica["VersionId"], replica["ETag"]), (put["VersionId"], put["ETag"]))
check("and is a replica", replica.get("ReplicationStatus"), "REPLICA")
s3.delete_bucket_replication(Bucket=RS)
check("the replication deleted", code_of(lambda: s3.get_bucket_replication(Bucket=RS)), "ReplicationConfigurationNotFoundError")

# Directory buckets (ADR-0080): boto3 takes a session (CreateSession) before each bucket's calls; then the same with
# sessions off, which signs every call for s3express with the long-term key.
DIR = "sdk--local-az1--x-s3"
dir_config = {"Location": {"Type": "AvailabilityZone", "Name": "local-az1"},
              "Bucket": {"DataRedundancy": "SingleAvailabilityZone", "Type": "Directory"}}
for sessions in (True, False):
    d = client() if sessions else boto3.client(
        "s3", endpoint_url=endpoint, config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1},
                                                    signature_version="s3v4", s3_disable_express_session_auth=True))
    how = " (sessions)" if sessions else " (sessions off)"
    made = d.create_bucket(Bucket=DIR, CreateBucketConfiguration=dir_config)
    check("create a directory bucket" + how, made["ResponseMetadata"]["HTTPHeaders"].get("x-amz-bucket-arn", "").endswith(":bucket/" + DIR), True)
    check("list_directory_buckets" + how, [b["Name"] for b in d.list_directory_buckets()["Buckets"]], [DIR])
    check("not in list_buckets" + how, DIR in [b["Name"] for b in d.list_buckets()["Buckets"]], False)
    put = d.put_object(Bucket=DIR, Key="a/b.txt", Body=b"in a directory")
    check("an ETag that is not the MD5" + how, put["ETag"] != '"%s"' % hashlib.md5(b"in a directory").hexdigest(), True)
    check("get" + how, d.get_object(Bucket=DIR, Key="a/b.txt")["Body"].read(), b"in a directory")
    check("If-Match with it" + how, d.get_object(Bucket=DIR, Key="a/b.txt", IfMatch=put["ETag"])["ETag"], put["ETag"])
    check("listed" + how, [o["Key"] for o in d.list_objects_v2(Bucket=DIR, Prefix="a/")["Contents"]], ["a/b.txt"])
    d.upload_fileobj(io.BytesIO(os.urandom(12 << 20)), DIR, "big/m.bin", Config=TransferConfig(multipart_threshold=5 << 20, multipart_chunksize=5 << 20))
    check("a multipart ETag without -N" + how, "-" in d.head_object(Bucket=DIR, Key="big/m.bin")["ETag"], False)
    check("no versioning" + how, code_of(lambda: d.put_bucket_versioning(Bucket=DIR, VersioningConfiguration={"Status": "Enabled"})), "NotImplemented")
    check("a prefix ends in /" + how, code_of(lambda: d.list_objects_v2(Bucket=DIR, Prefix="a")), "InvalidArgument")
    # RenameObject (ADR-0081): the multipart object moves, its ETag kept; the batch delete; versionId null.
    big_etag = d.head_object(Bucket=DIR, Key="big/m.bin")["ETag"]
    d.rename_object(Bucket=DIR, Key="big/renamed.bin", RenameSource=DIR + "/big/m.bin", ClientToken="sdk-rename-" + str(sessions))
    check("rename_object" + how, d.head_object(Bucket=DIR, Key="big/renamed.bin")["ETag"], big_etag)
    check("the source gone" + how, code_of(lambda: d.head_object(Bucket=DIR, Key="big/m.bin")), "404")
    check("rename onto an existing key, If-None-Match *" + how,
          code_of(lambda: d.rename_object(Bucket=DIR, Key="a/b.txt", RenameSource="/big/renamed.bin", DestinationIfNoneMatch="*")),
          "PreconditionFailed")
    check("versionId null" + how, d.head_object(Bucket=DIR, Key="a/b.txt", VersionId="null")["ContentLength"], 14)
    check("the storage class" + how, d.list_objects_v2(Bucket=DIR, Prefix="a/")["Contents"][0]["StorageClass"], "EXPRESS_ONEZONE")
    deleted = d.delete_objects(Bucket=DIR, Delete={"Objects": [{"Key": "a/b.txt"}, {"Key": "big/renamed.bin"}]})
    check("delete_objects" + how, sorted(o["Key"] for o in deleted.get("Deleted", [])), ["a/b.txt", "big/renamed.bin"])
    for k in ("a/b.txt", "big/m.bin"):
        d.delete_object(Bucket=DIR, Key=k)
    d.delete_bucket(Bucket=DIR)
    check("deleted" + how, d.list_directory_buckets()["Buckets"], [])

# A directory bucket's access point (ADR-0082): its scope, requests through it with its sessions, its listing.
APB, AP = "sdk3--local-az1--x-s3", "sdkdoor--local-az1--xa-s3"
d = client()
d.create_bucket(Bucket=APB, CreateBucketConfiguration=dir_config)
made = ctl.create_access_point(AccountId=ACCOUNT, Name=AP, Bucket=APB,
                               Scope={"Prefixes": ["pub/"], "Permissions": ["GetObject", "PutObject", "ListBucket"]})
check("directory access point: its alias is its name", made["Alias"], AP)
check("directory access point: its ARN", made["AccessPointArn"], "arn:aws:s3express:us-east-1:%s:accesspoint/%s" % (ACCOUNT, AP))
check("get_access_point_scope", ctl.get_access_point_scope(AccountId=ACCOUNT, Name=AP)["Scope"]["Permissions"],
      ["GetObject", "PutObject", "ListBucket"])
check("list_access_points_for_directory_buckets",
      [p["Name"] for p in ctl.list_access_points_for_directory_buckets(AccountId=ACCOUNT, DirectoryBucket=APB)["AccessPointList"]], [AP])
d.put_object(Bucket=AP, Key="pub/a.txt", Body=b"through")
check("a GET through it", d.get_object(Bucket=AP, Key="pub/a.txt")["Body"].read(), b"through")
check("listed through it", [o["Key"] for o in d.list_objects_v2(Bucket=AP, Prefix="pub/")["Contents"]], ["pub/a.txt"])
check("a key outside its scope", code_of(lambda: d.put_object(Bucket=AP, Key="other/a.txt", Body=b"x")), "AccessDenied")
check("a permission outside its scope", code_of(lambda: d.delete_object(Bucket=AP, Key="pub/a.txt")), "AccessDenied")
ctl.delete_access_point_scope(AccountId=ACCOUNT, Name=AP)
d.delete_object(Bucket=AP, Key="pub/a.txt")
ctl.delete_access_point(AccountId=ACCOUNT, Name=AP)
check("deleted", ctl.list_access_points_for_directory_buckets(AccountId=ACCOUNT)["AccessPointList"], [])
d.delete_bucket(Bucket=APB)

# S3 Tables (ADR-0083): table buckets, namespaces and tables, and the metadata location's compare-and-set.
tables = boto3.client("s3tables", endpoint_url=endpoint, config=Config(retries={"max_attempts": 1}))
tarn = tables.create_table_bucket(name="sdk-tables")["arn"]
check("create_table_bucket", tarn, "arn:aws:s3tables:us-east-1:%s:bucket/sdk-tables" % ACCOUNT)
check("list_table_buckets", [b["name"] for b in tables.list_table_buckets()["tableBuckets"]], ["sdk-tables"])
tables.create_namespace(tableBucketARN=tarn, namespace=["sales"])
made = tables.create_table(tableBucketARN=tarn, namespace="sales", name="orders", format="ICEBERG")
got = tables.get_table(tableArn=made["tableARN"])
check("get_table by its ARN", (got["name"], got["namespace"], got["versionToken"]), ("orders", ["sales"], made["versionToken"]))
wh = got["warehouseLocation"]
wbucket, wprefix = wh[5:].split("/", 1)
client().put_object(Bucket=wbucket, Key=wprefix + "/metadata/00001-x.metadata.json", Body=b"{}")
moved = tables.update_table_metadata_location(tableBucketARN=tarn, namespace="sales", name="orders",
                                              versionToken=got["versionToken"], metadataLocation=wh + "/metadata/00001-x.metadata.json")
check("update_table_metadata_location", tables.get_table_metadata_location(tableBucketARN=tarn, namespace="sales", name="orders")["metadataLocation"],
      wh + "/metadata/00001-x.metadata.json")
check("a stale versionToken", code_of(lambda: tables.update_table_metadata_location(tableBucketARN=tarn, namespace="sales", name="orders",
      versionToken=got["versionToken"], metadataLocation=wh + "/metadata/00002-y.metadata.json")), "ConflictException")
check("its token moved on", moved["versionToken"] != got["versionToken"], True)
tables.rename_table(tableBucketARN=tarn, namespace="sales", name="orders", newName="orders2", versionToken=moved["versionToken"])
check("rename_table", [t["name"] for t in tables.list_tables(tableBucketARN=tarn)["tables"]], ["orders2"])
tables.delete_table(tableBucketARN=tarn, namespace="sales", name="orders2")
check("the table's files gone with it", client().list_objects_v2(Bucket=wbucket, Prefix=wprefix + "/")["KeyCount"], 0)
tables.delete_namespace(tableBucketARN=tarn, namespace="sales")
tables.delete_table_bucket(tableBucketARN=tarn)
check("delete_table_bucket", tables.list_table_buckets()["tableBuckets"], [])

session = client().create_session(Bucket="sdk2--local-az1--x-s3", SessionMode="ReadOnly")
check("create_session", session["Credentials"]["AccessKeyId"][:4], "ASIA")

check("wrong secret", code_of(lambda: boto3.client("s3", endpoint_url=endpoint, aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
                                                       aws_secret_access_key="wrong").list_buckets()),
      "SignatureDoesNotMatch")

# Users (ADR-0088): a user's key reads what its identity policy allows, and nothing else.
client().create_bucket(Bucket="sdk-py-users")
client().put_object(Bucket="sdk-py-users", Key="a", Body=b"read me")
user = boto3.client("s3", endpoint_url=endpoint, aws_access_key_id="AKIASDKUSER000000001",
                    aws_secret_access_key="sdkuser/secret/0123456789abcdefgh",
                    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}, retries={"max_attempts": 1}))
check("a user reads", user.get_object(Bucket="sdk-py-users", Key="a")["Body"].read(), b"read me")
check("a user writes nothing", code_of(lambda: user.put_object(Bucket="sdk-py-users", Key="b", Body=b"x")), "AccessDenied")
check("nor lists every bucket", code_of(lambda: user.list_buckets()), "AccessDenied")
client().delete_object(Bucket="sdk-py-users", Key="a")
client().delete_bucket(Bucket="sdk-py-users")
# The long tail (ADR-0090): storage classes recorded, or refused.
client().create_bucket(Bucket="sdk-py-tail")
client().put_object(Bucket="sdk-py-tail", Key="ia", Body=b"x", StorageClass="STANDARD_IA")
check("a storage class recorded", client().head_object(Bucket="sdk-py-tail", Key="ia").get("StorageClass"), "STANDARD_IA")
# An archive class (ADR-0102): taken; its read InvalidObjectState until restored.
client().put_object(Bucket="sdk-py-tail", Key="g", Body=b"x", StorageClass="GLACIER")
check("an archive class taken", client().head_object(Bucket="sdk-py-tail", Key="g").get("StorageClass"), "GLACIER")
check("its read refused, not restored", code_of(lambda: client().get_object(Bucket="sdk-py-tail", Key="g")), "InvalidObjectState")
# RestoreObject (an hour is a second here: Standard's 4 hours take 4 s).
client().restore_object(Bucket="sdk-py-tail", Key="g", RestoreRequest={"Days": 1, "GlacierJobParameters": {"Tier": "Standard"}})
check("restoring", client().head_object(Bucket="sdk-py-tail", Key="g").get("Restore"), 'ongoing-request="true"')
time.sleep(5)
check("restored, read", client().get_object(Bucket="sdk-py-tail", Key="g")["Body"].read(), b"x")
client().delete_object(Bucket="sdk-py-tail", Key="g")
client().delete_object(Bucket="sdk-py-tail", Key="ia")
client().delete_bucket(Bucket="sdk-py-tail")

# The IAM API (ADR-0104): a user, its key and policy made through boto3; the key signs within an upkeep round (10 s
# here); a role made with a trust policy and assumed; everything deleted, and the key refused after.
iam = boto3.client("iam", endpoint_url=endpoint, region_name="us-east-1")
check("iam create_user", iam.create_user(UserName="py-dev")["User"]["UserName"], "py-dev")
check("iam a name twice", code_of(lambda: iam.create_user(UserName="py-dev")), "EntityAlreadyExists")
made = iam.create_access_key(UserName="py-dev")["AccessKey"]
check("iam create_access_key", (made["AccessKeyId"][:4], len(made["SecretAccessKey"]) >= 40), ("AKIA", True))
check("iam its secret listed nowhere", "SecretAccessKey" in iam.list_access_keys(UserName="py-dev")["AccessKeyMetadata"][0], False)
iam.put_user_policy(UserName="py-dev", PolicyName="reads", PolicyDocument=json.dumps({"Version": "2012-10-17",
    "Statement": {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::%s/*" % M7}}))
check("iam get_user_policy", iam.get_user_policy(UserName="py-dev", PolicyName="reads")["PolicyDocument"]["Statement"]["Action"],
      "s3:GetObject")
dev = boto3.client("s3", endpoint_url=endpoint, aws_access_key_id=made["AccessKeyId"], aws_secret_access_key=made["SecretAccessKey"],
                   config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1}, signature_version="s3v4"))


def dev_reads():
    try:
        return dev.get_object(Bucket=M7, Key="logged.txt")["Body"].read()
    except ClientError:
        return None


check("iam its key reads within a round", until(dev_reads, 25), b"logged")
check("iam and no more", code_of(lambda: dev.put_object(Bucket=M7, Key="no", Body=b"no")), "AccessDenied")
trust = {"Version": "2012-10-17", "Statement": {"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::000000000000:root"},
                                                "Action": "sts:AssumeRole"}}
check("iam create_role", iam.create_role(RoleName="py-role", AssumeRolePolicyDocument=json.dumps(trust))["Role"]["Arn"],
      "arn:aws:iam::000000000000:role/py-role")
check("iam its trust read back", iam.get_role(RoleName="py-role")["Role"]["AssumeRolePolicyDocument"]["Statement"]["Principal"]["AWS"],
      "arn:aws:iam::000000000000:root")
iam.put_role_policy(RoleName="py-role", PolicyName="reads", PolicyDocument=json.dumps({"Version": "2012-10-17",
    "Statement": {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::%s/*" % M7}}))


def assumed():
    try:
        return sts.assume_role(RoleArn="arn:aws:iam::000000000000:role/py-role", RoleSessionName="py")["Credentials"]
    except ClientError:
        return None


creds = until(assumed, 25)
check("iam the role assumed", (creds or {}).get("AccessKeyId", "")[:4], "ASIA")
if creds:
    check("iam its session reads", as_creds(creds).get_object(Bucket=M7, Key="logged.txt")["Body"].read(), b"logged")
# M21 (ADR-0108 §3): a managed policy versioned and attached, a group with a path and a policy, tags, UpdateRole, and
# GetCallerIdentity as the user; then all of it undone.
writes = json.dumps({"Version": "2012-10-17", "Statement": {"Effect": "Allow", "Action": "s3:PutObject",
                                                             "Resource": "arn:aws:s3:::%s/py-m21" % M7}})
pol = iam.create_policy(PolicyName="py-writes", Path="/py/", PolicyDocument=writes, Tags=[{"Key": "a", "Value": "b"}])["Policy"]
check("iam create_policy", (pol["Arn"], pol["DefaultVersionId"]), ("arn:aws:iam::000000000000:policy/py/py-writes", "v1"))
iam.create_policy_version(PolicyArn=pol["Arn"], PolicyDocument=writes, SetAsDefault=True)
check("iam its versions", [v["VersionId"] for v in iam.list_policy_versions(PolicyArn=pol["Arn"])["Versions"]], ["v1", "v2"])
iam.attach_user_policy(UserName="py-dev", PolicyArn=pol["Arn"])
check("iam attached", [a["PolicyName"] for a in iam.list_attached_user_policies(UserName="py-dev")["AttachedPolicies"]], ["py-writes"])
check("iam the policy's tags", iam.list_policy_tags(PolicyArn=pol["Arn"])["Tags"], [{"Key": "a", "Value": "b"}])
check("iam create_group", iam.create_group(GroupName="py-group", Path="/py/")["Group"]["Arn"], "arn:aws:iam::000000000000:group/py/py-group")
iam.add_user_to_group(GroupName="py-group", UserName="py-dev")
iam.put_group_policy(GroupName="py-group", PolicyName="lists", PolicyDocument=json.dumps({"Version": "2012-10-17",
    "Statement": {"Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::%s" % M7}}))
check("iam its members", [u["UserName"] for u in iam.get_group(GroupName="py-group")["Users"]], ["py-dev"])
iam.tag_user(UserName="py-dev", Tags=[{"Key": "team", "Value": "py"}])
check("iam the user's tags", iam.list_user_tags(UserName="py-dev")["Tags"], [{"Key": "team", "Value": "py"}])
check("iam GetCallerIdentity as the user", boto3.client("sts", endpoint_url=endpoint, region_name="us-east-1",
      aws_access_key_id=made["AccessKeyId"], aws_secret_access_key=made["SecretAccessKey"]).get_caller_identity()["Arn"],
      "arn:aws:iam::000000000000:user/py-dev")


def dev_writes():
    try:
        dev.put_object(Bucket=M7, Key="py-m21", Body=b"m21")
        return True
    except ClientError:
        return False


def dev_lists():
    try:
        dev.list_objects_v2(Bucket=M7, MaxKeys=1)
        return True
    except ClientError:
        return False


check("iam writes by the attached policy", until(dev_writes, 25), True)
check("iam lists by the group's", until(dev_lists, 25), True)
client().delete_object(Bucket=M7, Key="py-m21")
iam.update_role(RoleName="py-role", Description="py", MaxSessionDuration=7200)
check("iam update_role", iam.get_role(RoleName="py-role")["Role"]["MaxSessionDuration"], 7200)
iam.detach_user_policy(UserName="py-dev", PolicyArn=pol["Arn"])
iam.delete_policy_version(PolicyArn=pol["Arn"], VersionId="v1")
iam.delete_policy(PolicyArn=pol["Arn"])
iam.remove_user_from_group(GroupName="py-group", UserName="py-dev")
iam.delete_group_policy(GroupName="py-group", PolicyName="lists")
iam.delete_group(GroupName="py-group")
check("iam the group gone", code_of(lambda: iam.get_group(GroupName="py-group")), "NoSuchEntity")
check("iam a user with keys not deleted", code_of(lambda: iam.delete_user(UserName="py-dev")), "DeleteConflict")
iam.delete_access_key(UserName="py-dev", AccessKeyId=made["AccessKeyId"])
iam.delete_user_policy(UserName="py-dev", PolicyName="reads")
iam.delete_user(UserName="py-dev")
iam.delete_role_policy(RoleName="py-role", PolicyName="reads")
iam.delete_role(RoleName="py-role")
check("iam the user gone", code_of(lambda: iam.get_user(UserName="py-dev")), "NoSuchEntity")
check("iam its key refused within a round", until(lambda: code_of(lambda: dev.get_object(Bucket=M7, Key="logged.txt")) == "InvalidAccessKeyId", 25), True)
sys.exit(1 if failed else 0)
