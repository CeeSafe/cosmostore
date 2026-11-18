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
check("SHA1 not implemented", code_of(lambda: s3.put_object(Bucket=B, Key="o/sha1", Body=b"x", ChecksumAlgorithm="SHA1")),
      "NotImplemented")
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
    for k in ("a/b.txt", "big/m.bin"):
        d.delete_object(Bucket=DIR, Key=k)
    d.delete_bucket(Bucket=DIR)
    check("deleted" + how, d.list_directory_buckets()["Buckets"], [])
session = client().create_session(Bucket="sdk2--local-az1--x-s3", SessionMode="ReadOnly")
check("create_session", session["Credentials"]["AccessKeyId"][:4], "ASIA")

check("wrong secret", code_of(lambda: boto3.client("s3", endpoint_url=endpoint, aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
                                                       aws_secret_access_key="wrong").list_buckets()),
      "SignatureDoesNotMatch")
sys.exit(1 if failed else 0)
