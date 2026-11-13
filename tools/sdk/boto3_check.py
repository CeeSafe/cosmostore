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

check("wrong secret", code_of(lambda: boto3.client("s3", endpoint_url=endpoint, aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
                                                       aws_secret_access_key="wrong").list_buckets()),
      "SignatureDoesNotMatch")
sys.exit(1 if failed else 0)
