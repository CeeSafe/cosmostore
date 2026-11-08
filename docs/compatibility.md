# S3 compatibility

What `cosmostore serve` supports, and which clients are tested against it (ROADMAP M3). Every client run starts
on a fresh store and ends with fsck. Updated 8 Nov 2026.

## Clients

| Client | Version | Script | Checks | Result |
|---|---|---|---|---|
| AWS CLI v2 | 2.34.13 | `tools/s3_smoke.sh` | 103 | pass |
| rclone | 1.73.2 | `tools/sdk/rclone.sh` | 20 | pass |
| boto3 (botocore with CRT) | 1.42.97 | `tools/sdk/boto3.sh` | 43 | pass |
| AWS SDK for Go v2 | service/s3 1.114.9 | `tools/sdk/go.sh` | 22 | pass |
| AWS SDK for JavaScript v3 | client-s3 3.1164.0 | `tools/sdk/js.sh` | 25 | pass |
| AWS SDK for Java v2 | — | — | — | not run yet |
| AWS SDK for .NET | — | — | — | not run yet |
| Ceph s3-tests (subset) | commit 5b39871 | `tools/s3tests/run.sh` | 235 | pass |

### Client settings to know

- **boto3** presigns with SigV2 for a custom endpoint unless it is told otherwise:
  `Config(signature_version="s3v4")`. CosmoStore accepts SigV4 only, and refuses SigV2 with S3's `InvalidRequest`.
  boto3's CRC32C and CRC64NVME checksums need `pip install "boto3[crt]"`.
- **The JavaScript SDK's presigned PUT** signs a CRC32 of an empty body unless the client sets
  `requestChecksumCalculation: "WHEN_REQUIRED"`. S3 then refuses the upload with BadDigest, and so does CosmoStore.
- **Virtual-host addressing** needs `cosmostore serve … <domain>`, so that buckets are `<bucket>.<domain>`.
  Path-style always works.

### s3-tests

The subset is every in-scope test that passes (`tools/s3tests/subset.txt`). At this commit, 440 tests are left once
the out-of-scope markers are excluded. 235 pass. ADR-0014 accounts for the other 205: nearly all test ACLs, object
lock, versioning, POST object, CORS or policies. Response checksums and GET `?partNumber` pass since ADR-0015. Of
the checksum tests, only SHA-1 still fails, along with those that need ACLs, versioning or POST object.

## Operations

| Area | Supported | Not yet |
|---|---|---|
| Auth | SigV4 headers; presigned URLs, with hoisted `x-amz-*` query headers; aws-chunked, signed and unsigned, with trailers | SigV2, POST policy, session tokens |
| Buckets | Create, Head, Delete, List (with creation dates and pagination), GetBucketLocation, GetBucketVersioning (always unversioned), ListObjectVersions (one `null` version per object) | versioning, policies, ACLs, CORS, lifecycle |
| Objects | Put, Get, Head, Delete; Range; `?partNumber`; If-Match / If-None-Match / If-(Un)Modified-Since; conditional PUT and Complete (`If-None-Match`, `If-Match`); `response-*`; `versionId=null`; GetObjectAttributes | object lock |
| Integrity | Content-MD5; `x-amz-checksum-{crc32,crc32c,crc64nvme,sha256}` checked and stored, CRC64NVME by default; returned with `x-amz-checksum-mode`; multipart COMPOSITE and FULL_OBJECT | SHA-1 checksums |
| Metadata | `x-amz-meta-*` (2 KiB), Content-Encoding/-Disposition/-Language, Cache-Control, Expires | tagging (GetObjectTagging returns an empty set) |
| Listing | ListObjects v1 and v2: prefix, delimiter, pagination, `encoding-type=url` | |
| Multipart | Create, UploadPart, UploadPartCopy (ranges), Complete (a retry gets its first answer), Abort, ListParts, ListMultipartUploads | `delimiter` in ListMultipartUploads; expiring abandoned uploads |
| Copy and delete | CopyObject (COPY/REPLACE, `x-amz-copy-source-if-*`), DeleteObjects (one sync per batch) | destination conditions on CopyObject |
| Addressing | path-style; virtual-host under a configured domain | |
| Network | HTTP/1.1 on 127.0.0.1 | other addresses, TLS |

Anything else gets S3's `NotImplemented` (501) XML error. Design notes: ADR-0008 to ADR-0015 in `docs/adr/`.
