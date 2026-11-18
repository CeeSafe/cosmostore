# S3 compatibility

What `cosmostore serve` supports, and which clients are tested against it (ROADMAP M3, whose exit this matrix
passed on 9 Nov 2026). Every client run starts
on a fresh store and ends with fsck. Updated 13 Nov 2026, when every row was run again with versioning in (ADR-0041).

## Clients

| Client | Version | Script | Checks | Result |
|---|---|---|---|---|
| AWS CLI v2 | 2.34.13 | `tools/s3_smoke.sh` | 358 | pass |
| rclone | 1.73.2 | `tools/sdk/rclone.sh` | 20 | pass |
| boto3 (botocore with CRT) | 1.42.97 | `tools/sdk/boto3.sh` | 178 | pass |
| AWS SDK for Go v2 | service/s3 1.114.9, s3control 1.81.0, sts 1.52.0 | `tools/sdk/go.sh` | 55 | pass |
| AWS SDK for JavaScript v3 | client-s3, client-s3-control, client-sts 3.1168.0 | `tools/sdk/js.sh` | 61 | pass |
| AWS SDK for Java v2 (with aws-crt) | 2.57.11 | `tools/sdk/java.sh` | 25 | pass |
| AWS SDK for .NET (with CrtIntegration) | AWSSDK.S3 4.0.104.11, S3Control 4.1.1, SecurityToken 4.1.0.2 | `tools/sdk/dotnet.sh` | 55 | pass |
| Ceph s3-tests (subset) | commit 5b39871 | `tools/s3tests/run.sh` | 377 | pass |

### Client settings to know

- **boto3** presigns with SigV2 for a custom endpoint unless it is told otherwise:
  `Config(signature_version="s3v4")`. CosmoStore accepts SigV4 only, and refuses SigV2 with S3's `InvalidRequest`.
  boto3's CRC32C and CRC64NVME checksums need `pip install "boto3[crt]"`, the Java SDK's need the
  `software.amazon.awssdk.crt:aws-crt` dependency, and the .NET SDK's need `AWSSDK.Extensions.CrtIntegration`.
- **The JavaScript SDK's presigned PUT** signs a CRC32 of an empty body unless the client sets
  `requestChecksumCalculation: "WHEN_REQUIRED"`. S3 then refuses the upload with BadDigest, and so does CosmoStore.
- **Virtual-host addressing** needs `cosmostore serve … <domain>`, so that buckets are `<bucket>.<domain>`.
  Path-style always works.
- **TLS:** `cosmostore serve <dir> 0.0.0.0:9000 <credentials> --tls-cert chain.pem --tls-key key.pem`. Clients
  verify the certificate as usual, for example with `AWS_CA_BUNDLE`, rclone's `--ca-cert` or curl's `--cacert` for
  a private CA. Replace the files to renew: the server reloads them within one upkeep round (`--maintain-seconds`,
  10 by default). Without TLS, requests are still authenticated (SigV4), but their bytes are readable on the
  network.

### s3-tests

The subset is every in-scope test that passes (`tools/s3tests/subset.txt`). At this commit, 496 tests are left once
the out-of-scope markers are excluded (the `versioning` and `delete_marker` markers are in scope since ADR-0041,
`bucket_policy` since ADR-0043). 389 pass. The subset leaves out every
`test_post_object*` test: they all sign with SigV2, so they pass or fail on the SigV2 refusal, not on POST object.
SigV4 POST is tested with boto3 and the JS SDK instead (ADR-0018). That leaves 377 in the subset: the 252 of M3 and
125 more: 33 versioning and delete-marker tests (five of them conditional writes on the current version),
`test_lifecycle_set_noncurrent` (ADR-0042), 10 bucket-policy tests (ADR-0043), 9 on the policy status and the
public-access block (ADR-0044), 20 that ACLs let pass (ADR-0045) the 39 `test_object_lock_*` tests
(ADR-0047), and 13 with CORS (ADR-0049: ten `test_cors_*` and `test_set_cors`, and three raw GETs that needed a
missing key to be a 404 for a requester who may list the bucket). The four `test_cors_presigned_*_v2` tests sign
with SigV2. The tests that watch rules expire objects need RGW's debug clock and
stay out of scope; `src/store/version_tests.cee` checks that with the store's own clock. ADR-0014 accounts for the rest: nearly all need
a second account: the policy and ACL tests that expect the `alt` user to be refused by default, or
granted to, fail, since every key is of one account (ADR-0043, ADR-0045). Other ACL tests compare the owner's id and
display name with their configuration's; the owner here is `cosmostore`. Response checksums and GET `?partNumber` pass since ADR-0015. Of the checksum tests, only
SHA-1 still fails, along with those that need a second account or POST object.

- **The Python that runs them needs the AWS CRT** (`pip install "boto3[crt]"`), as the boto3 row does. Without
  it botocore signs some requests differently and the result shifts: two date-header tests of the subset fail
  (`test_object_create_amz_date_and_no_date`, `test_object_create_date_and_amz_date`), and five tests outside it
  pass (two `*_bad_expect_mismatch`, three on expired presigned requests).
- **Versioning tests that do not pass, and why:**
  - `test_delete_marker_nonversioned` expects `x-amz-delete-marker: false` on the 404 of a deleted key in a bucket
    without versioning. S3 sends the field only when it is true.
  - `test_versioning_concurrent_multi_object_delete` creates its bucket a second time and expects success;
    CosmoStore answers BucketAlreadyOwnedByYou.
  - `test_bucket_list_return_data_versioning` creates its bucket a second time too; the two
    `test_versioned_object_acl*` tests compare the owner's display name with their configuration's.

## Operations

| Area | Supported | Not yet |
|---|---|---|
| Auth | SigV4 headers; presigned URLs, with hoisted `x-amz-*` query headers; aws-chunked, signed and unsigned, with trailers; POST object with a SigV4 policy; anonymous requests where a bucket policy allows them (ADR-0043) | SigV2, session tokens, users and accounts (every key is of one account) |
| Buckets | Create, Head, Delete, List (with creation dates and pagination), GetBucketLocation, Put-, Get- and DeleteBucketPolicy (ADR-0043: principals `*` and access keys; Allow, Deny and the `Not` forms; string, IP, numeric, Bool and Null conditions on `aws:SecureTransport`, `aws:SourceIp`, `aws:Referer`, `aws:UserAgent`, `s3:prefix`, `s3:delimiter`, `s3:max-keys`), Put-, Get- and DeleteBucketCors, with preflights answered and the CORS fields on answers to requests that name an origin (ADR-0049), Get- and PutBucketNotificationConfiguration (ADR-0048: queue configurations for webhooks `serve` is given; object created and removed events; prefix and suffix filters), Get- and PutBucketAcl and `x-amz-acl` or `x-amz-grant-*` on CreateBucket (ADR-0045: canned ACLs, grants to the owner, `AllUsers` and `AuthenticatedUsers`), Get- and PutObjectLockConfiguration with a default retention and `x-amz-bucket-object-lock-enabled` on CreateBucket (ADR-0047), GetBucketPolicyStatus and Put-, Get- and DeletePublicAccessBlock (ADR-0044, ADR-0045: all four settings), PutBucketVersioning and GetBucketVersioning (`Enabled`, `Suspended`), ListObjectVersions (versions and delete markers, `key-marker` and `version-id-marker`); bucket tags; lifecycle rules (expiration by days or date, filtered by prefix, tags and size; NoncurrentVersionExpiration with NewerNoncurrentVersions; ExpiredObjectDeleteMarker; AbortIncompleteMultipartUpload) | MFA delete, notifications to topics, functions or EventBridge and the events `:Post`, `:Copy` and beyond created and removed, ACL grants to other accounts or by email, other condition keys and operators (refused when a policy is put); lifecycle transitions |
| Objects | Put, Get, Head, Delete; Range; `?partNumber`; If-Match / If-None-Match / If-(Un)Modified-Since; conditional PUT and Complete (`If-None-Match`, `If-Match`); `response-*`; `versionId` on Get, Head, Delete, GetObjectAttributes and the tagging calls, with `x-amz-version-id` and `x-amz-delete-marker` in responses (ADR-0041); GetObjectAttributes; Get- and PutObjectAcl, and `x-amz-acl` or `x-amz-grant-*` on Put, Copy, CreateMultipartUpload and POST object (ADR-0045); object lock: retention and legal hold on versions (Get- and PutObjectRetention, Get- and PutObjectLegalHold, the `x-amz-object-lock-*` fields on Put, Copy and CreateMultipartUpload, `x-amz-bypass-governance-retention`; ADR-0047) | the object lock fields of a POST form |
| Integrity | Content-MD5; `x-amz-checksum-{crc32,crc32c,crc64nvme,sha256}` checked and stored, CRC64NVME by default; returned with `x-amz-checksum-mode`; multipart COMPOSITE and FULL_OBJECT | SHA-1 checksums |
| Encryption | SSE-KMS (`aws:kms` with a key id or the default key, `--kms-key-file`; ADR-0055), SSE-S3 (`x-amz-server-side-encryption: AES256`, with `serve --sse-key-file`) and SSE-C (the customer key fields, over TLS) on Put, Get, Head, GetObjectAttributes, POST object, CopyObject (the `x-amz-copy-source-server-side-encryption-customer-*` fields too), CreateMultipartUpload, UploadPart, UploadPartCopy and Complete; ranges and `?partNumber`; Get-, Put- and DeleteBucketEncryption with `AES256` or `aws:kms` (ADR-0046); the policy condition keys `s3:x-amz-server-side-encryption`, `...-aws-kms-key-id` and `...-customer-algorithm` | SSE-KMS against a KMS service: its keys are a local file (`serve --kms-key-file`, ADR-0055); an encryption context and `aws:kms:dsse` (NotImplemented); bucket keys (reported off) |
| Metadata | `x-amz-meta-*` (2 KiB), Content-Encoding/-Disposition/-Language, Cache-Control, Expires; object tags (Get/Put/DeleteObjectTagging, `x-amz-tagging`, `x-amz-tagging-directive`, `x-amz-tagging-count`) | |
| Listing | ListObjects v1 and v2: prefix, delimiter, pagination, `encoding-type=url` | |
| Multipart | Create, UploadPart, UploadPartCopy (ranges), Complete (a retry gets its first answer), Abort, ListParts, ListMultipartUploads; uploads older than 7 days are aborted, and lifecycle rules may abort sooner | `delimiter` in ListMultipartUploads |
| Copy and delete | CopyObject (COPY/REPLACE, `x-amz-copy-source-if-*`, If-Match / If-None-Match on the destination, a source `?versionId=`), DeleteObjects (one sync per batch, version ids, delete markers reported) | |
| Addressing | path-style; virtual-host under a configured domain | |
| Network | HTTP/1.1 on any address (`[address:]port`, 127.0.0.1 by default); TLS 1.2/1.3 with `--tls-cert`/`--tls-key`, reloaded when the files change | SNI, HTTP/2 |

Anything else gets S3's `NotImplemented` (501) XML error. Design notes: ADR-0008 to ADR-0020 and ADR-0041 to ADR-0054 in `docs/adr/`.

Versioning (ADR-0041) is checked by `tools/s3_smoke.sh` with the AWS CLI (34 checks), `tools/sdk/boto3.sh` (20
checks) and the s3-tests subset; the lifecycle rules for versions (ADR-0042) by two checks in each of the first two. Bucket policies (ADR-0043) are
checked by the smoke script (28 checks, anonymous requests through curl), boto3 with an unsigned client (12) and
the subset; the policy status and the public-access block (ADR-0044) by 16 checks of the smoke script, 9 of boto3
and the subset; ACLs (ADR-0045) by 40 checks of the smoke script, 19 of boto3 and the subset; object lock (ADR-0047) by 26 and 17
and the subset; event notifications (ADR-0048) by 15 checks of the smoke script, with a webhook of its own
(`tools/webhook.py`) and a kill of the server while an event waits, and 4 of boto3; CORS (ADR-0049) by 20 checks of the smoke script, which sends the preflights with curl, 4 of boto3
and the subset. The rclone, Go, JavaScript, Java and .NET scripts pass as before; they do not
exercise versioning.

M7's calls (ADR-0072 to ADR-0077) are checked by the smoke script with the AWS CLI and, since 18 Nov 2026, by 33
checks of boto3 (`s3`, `s3control` and `sts` clients): access logs delivered into a target bucket, a website's index
and error document through `<bucket>.web.localhost`, an inventory's manifest and CSV, a session token and an assumed
role signing S3 requests, an access point by alias and by ARN, and a replica keeping its source's version id and
ETag; and what is refused rather than dropped (an inventory's `AccountId`, STS `PolicyArns`, a replication priority
given twice). The Go, JavaScript and .NET SDKs run the same 33 (`tools/sdk/go/m7.go`, `tools/sdk/js/check.mjs`, `tools/sdk/dotnet/Program.cs`; .NET gives a configuration that is not there as an empty one, where the others give its error), and found two defects the CLI and boto3 had
let pass: S3 Control's errors were S3's `<Error>` form, which its s3control client reads as UnknownError (now
`<ErrorResponse><Error>`, ADR-0076 §1), and a replication rule with its `Status` after `DeleteMarkerReplication`,
as Go writes it, was MalformedXML (ADR-0077 §1).
