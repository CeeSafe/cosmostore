# S3 compatibility

What `cosmostore serve` supports, and which clients are tested against it (ROADMAP M3, whose exit this matrix
passed on 9 Nov 2026). Every client run starts
on a fresh store and ends with fsck. Updated 13 Nov 2026, when every row was run again with versioning in (ADR-0041).

## Clients

| Client | Version | Script | Checks | Result |
|---|---|---|---|---|
| AWS CLI v2 | 2.34.13 | `tools/s3_smoke.sh` | 203 | pass |
| rclone | 1.73.2 | `tools/sdk/rclone.sh` | 20 | pass |
| boto3 (botocore with CRT) | 1.42.97 | `tools/sdk/boto3.sh` | 95 | pass |
| AWS SDK for Go v2 | service/s3 1.114.9 | `tools/sdk/go.sh` | 22 | pass |
| AWS SDK for JavaScript v3 | client-s3 3.1168.0 | `tools/sdk/js.sh` | 28 | pass |
| AWS SDK for Java v2 (with aws-crt) | 2.57.11 | `tools/sdk/java.sh` | 25 | pass |
| AWS SDK for .NET (with CrtIntegration) | AWSSDK.S3 4.0.104.11 | `tools/sdk/dotnet.sh` | 22 | pass |
| Ceph s3-tests (subset) | commit 5b39871 | `tools/s3tests/run.sh` | 305 | pass |

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
`bucket_policy` since ADR-0043). 317 pass. The subset leaves out every
`test_post_object*` test: they all sign with SigV2, so they pass or fail on the SigV2 refusal, not on POST object.
SigV4 POST is tested with boto3 and the JS SDK instead (ADR-0018). That leaves 305 in the subset: the 252 of M3 and
53 more: 33 versioning and delete-marker tests (five of them conditional writes on the current version),
`test_lifecycle_set_noncurrent` (ADR-0042), 10 bucket-policy tests (ADR-0043) and 9 on the policy status and the
public-access block (ADR-0044). The tests that watch rules expire objects need RGW's debug clock and
stay out of scope; `src/store/version_tests.cee` checks that with the store's own clock. ADR-0014 accounts for the rest: nearly all test ACLs, object
lock, CORS, or a second account: the policy tests that expect the `alt` user to be refused by default fail, since
every key is of one account (ADR-0043). Response checksums and GET `?partNumber` pass since ADR-0015. Of the checksum tests, only
SHA-1 still fails, along with those that need ACLs or POST object.

- **The Python that runs them needs the AWS CRT** (`pip install "boto3[crt]"`), as the boto3 row does. Without
  it botocore signs some requests differently and the result shifts: two date-header tests of the subset fail
  (`test_object_create_amz_date_and_no_date`, `test_object_create_date_and_amz_date`), and five tests outside it
  pass (two `*_bad_expect_mismatch`, three on expired presigned requests).
- **Versioning tests that do not pass, and why:**
  - `test_delete_marker_nonversioned` expects `x-amz-delete-marker: false` on the 404 of a deleted key in a bucket
    without versioning. S3 sends the field only when it is true.
  - `test_versioning_concurrent_multi_object_delete` creates its bucket a second time and expects success;
    CosmoStore answers BucketAlreadyOwnedByYou.
  - `test_bucket_list_return_data_versioning` and the two `test_versioned_object_acl*` tests need ACLs; the object
    lock tests need Object Lock.

## Operations

| Area | Supported | Not yet |
|---|---|---|
| Auth | SigV4 headers; presigned URLs, with hoisted `x-amz-*` query headers; aws-chunked, signed and unsigned, with trailers; POST object with a SigV4 policy; anonymous requests where a bucket policy allows them (ADR-0043) | SigV2, session tokens, users and accounts (every key is of one account) |
| Buckets | Create, Head, Delete, List (with creation dates and pagination), GetBucketLocation, Put-, Get- and DeleteBucketPolicy (ADR-0043: principals `*` and access keys; Allow, Deny and the `Not` forms; string, IP, numeric, Bool and Null conditions on `aws:SecureTransport`, `aws:SourceIp`, `aws:Referer`, `aws:UserAgent`, `s3:prefix`, `s3:delimiter`, `s3:max-keys`), GetBucketPolicyStatus and Put-, Get- and DeletePublicAccessBlock (ADR-0044: `BlockPublicPolicy` and `RestrictPublicBuckets`; the two ACL settings are stored and do nothing yet), PutBucketVersioning and GetBucketVersioning (`Enabled`, `Suspended`), ListObjectVersions (versions and delete markers, `key-marker` and `version-id-marker`); bucket tags; lifecycle rules (expiration by days or date, filtered by prefix, tags and size; NoncurrentVersionExpiration with NewerNoncurrentVersions; ExpiredObjectDeleteMarker; AbortIncompleteMultipartUpload) | MFA delete, ACLs, CORS, other condition keys and operators (refused when a policy is put); lifecycle transitions |
| Objects | Put, Get, Head, Delete; Range; `?partNumber`; If-Match / If-None-Match / If-(Un)Modified-Since; conditional PUT and Complete (`If-None-Match`, `If-Match`); `response-*`; `versionId` on Get, Head, Delete, GetObjectAttributes and the tagging calls, with `x-amz-version-id` and `x-amz-delete-marker` in responses (ADR-0041); GetObjectAttributes | object lock |
| Integrity | Content-MD5; `x-amz-checksum-{crc32,crc32c,crc64nvme,sha256}` checked and stored, CRC64NVME by default; returned with `x-amz-checksum-mode`; multipart COMPOSITE and FULL_OBJECT | SHA-1 checksums |
| Metadata | `x-amz-meta-*` (2 KiB), Content-Encoding/-Disposition/-Language, Cache-Control, Expires; object tags (Get/Put/DeleteObjectTagging, `x-amz-tagging`, `x-amz-tagging-directive`, `x-amz-tagging-count`) | |
| Listing | ListObjects v1 and v2: prefix, delimiter, pagination, `encoding-type=url` | |
| Multipart | Create, UploadPart, UploadPartCopy (ranges), Complete (a retry gets its first answer), Abort, ListParts, ListMultipartUploads; uploads older than 7 days are aborted, and lifecycle rules may abort sooner | `delimiter` in ListMultipartUploads |
| Copy and delete | CopyObject (COPY/REPLACE, `x-amz-copy-source-if-*`, If-Match / If-None-Match on the destination, a source `?versionId=`), DeleteObjects (one sync per batch, version ids, delete markers reported) | |
| Addressing | path-style; virtual-host under a configured domain | |
| Network | HTTP/1.1 on any address (`[address:]port`, 127.0.0.1 by default); TLS 1.2/1.3 with `--tls-cert`/`--tls-key`, reloaded when the files change | SNI, HTTP/2 |

Anything else gets S3's `NotImplemented` (501) XML error. Design notes: ADR-0008 to ADR-0020 and ADR-0041 to ADR-0044 in `docs/adr/`.

Versioning (ADR-0041) is checked by `tools/s3_smoke.sh` with the AWS CLI (34 checks), `tools/sdk/boto3.sh` (20
checks) and the s3-tests subset; the lifecycle rules for versions (ADR-0042) by two checks in each of the first two. Bucket policies (ADR-0043) are
checked by the smoke script (28 checks, anonymous requests through curl), boto3 with an unsigned client (12) and
the subset; the policy status and the public-access block (ADR-0044) by 16 checks of the smoke script, 9 of boto3
and the subset. The rclone, Go, JavaScript, Java and .NET scripts pass as before; they do not
exercise versioning.
