# S3 compatibility

What `cosmostore serve` supports, and which clients are tested against it (ROADMAP M3, whose exit this matrix
passed on 9 Nov 2026). Every client run starts
on a fresh store and ends with fsck. Updated 8 Nov 2026.

## Clients

| Client | Version | Script | Checks | Result |
|---|---|---|---|---|
| AWS CLI v2 | 2.34.13 | `tools/s3_smoke.sh` | 122 | pass |
| rclone | 1.73.2 | `tools/sdk/rclone.sh` | 20 | pass |
| boto3 (botocore with CRT) | 1.42.97 | `tools/sdk/boto3.sh` | 52 | pass |
| AWS SDK for Go v2 | service/s3 1.114.9 | `tools/sdk/go.sh` | 22 | pass |
| AWS SDK for JavaScript v3 | client-s3 3.1164.0 | `tools/sdk/js.sh` | 28 | pass |
| AWS SDK for Java v2 (with aws-crt) | 2.57.11 | `tools/sdk/java.sh` | 25 | pass |
| AWS SDK for .NET (with CrtIntegration) | AWSSDK.S3 4.0.104.11 | `tools/sdk/dotnet.sh` | 22 | pass |
| Ceph s3-tests (subset) | commit 5b39871 | `tools/s3tests/run.sh` | 252 | pass |

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

The subset is every in-scope test that passes (`tools/s3tests/subset.txt`). At this commit, 440 tests are left once
the out-of-scope markers are excluded (469 since tagging and lifecycle configuration are in). 264 pass. The subset
leaves out every
`test_post_object*` test: they all sign with SigV2, so they pass or fail on the SigV2 refusal, not on POST object.
SigV4 POST is tested with boto3 and the JS SDK instead (ADR-0018). That leaves 252. ADR-0014 accounts for the rest:
nearly all test ACLs, object lock, versioning, CORS or policies. Response checksums and GET `?partNumber` pass since ADR-0015. Of
the checksum tests, only SHA-1 still fails, along with those that need ACLs, versioning or POST object.

## Operations

| Area | Supported | Not yet |
|---|---|---|
| Auth | SigV4 headers; presigned URLs, with hoisted `x-amz-*` query headers; aws-chunked, signed and unsigned, with trailers; POST object with a SigV4 policy | SigV2, session tokens |
| Buckets | Create, Head, Delete, List (with creation dates and pagination), GetBucketLocation, GetBucketVersioning (always unversioned), ListObjectVersions (one `null` version per object); bucket tags; lifecycle rules (expiration by days or date, filtered by prefix, tags and size; AbortIncompleteMultipartUpload) | versioning, policies, ACLs, CORS; lifecycle transitions and noncurrent versions |
| Objects | Put, Get, Head, Delete; Range; `?partNumber`; If-Match / If-None-Match / If-(Un)Modified-Since; conditional PUT and Complete (`If-None-Match`, `If-Match`); `response-*`; `versionId=null`; GetObjectAttributes | object lock |
| Integrity | Content-MD5; `x-amz-checksum-{crc32,crc32c,crc64nvme,sha256}` checked and stored, CRC64NVME by default; returned with `x-amz-checksum-mode`; multipart COMPOSITE and FULL_OBJECT | SHA-1 checksums |
| Metadata | `x-amz-meta-*` (2 KiB), Content-Encoding/-Disposition/-Language, Cache-Control, Expires; object tags (Get/Put/DeleteObjectTagging, `x-amz-tagging`, `x-amz-tagging-directive`, `x-amz-tagging-count`) | |
| Listing | ListObjects v1 and v2: prefix, delimiter, pagination, `encoding-type=url` | |
| Multipart | Create, UploadPart, UploadPartCopy (ranges), Complete (a retry gets its first answer), Abort, ListParts, ListMultipartUploads; uploads older than 7 days are aborted, and lifecycle rules may abort sooner | `delimiter` in ListMultipartUploads |
| Copy and delete | CopyObject (COPY/REPLACE, `x-amz-copy-source-if-*`, If-Match / If-None-Match on the destination), DeleteObjects (one sync per batch) | |
| Addressing | path-style; virtual-host under a configured domain | |
| Network | HTTP/1.1 on any address (`[address:]port`, 127.0.0.1 by default); TLS 1.2/1.3 with `--tls-cert`/`--tls-key`, reloaded when the files change | SNI, HTTP/2 |

Anything else gets S3's `NotImplemented` (501) XML error. Design notes: ADR-0008 to ADR-0020 in `docs/adr/`.
