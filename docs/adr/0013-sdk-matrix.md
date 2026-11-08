# ADR-0013: The SDK matrix, and what it changed

**Status:** accepted for M3 slice 6 (`tools/sdk/`, `docs/compatibility.md`), 8 Nov 2026

## Context

M3's exit asks for an SDK matrix and an s3-tests subset that pass. The smoke test (`tools/s3_smoke.sh`) drives the
AWS CLI, which is one client. Each SDK signs, checksums, presigns and parses in its own way, so each finds its own
gaps.

## Decision

1. **One script per client** in `tools/sdk/`. Each starts a fresh `cosmostore serve` (`common.sh`), runs the client,
   checks that the client's deletes left no extents, and runs fsck on the store.
   - `rclone.sh`: copy, check (hashes and bytes), modification times, sync with deletes, server-side copy and move,
     multipart (5 MiB chunks), and purge.
   - `boto3.sh` (`boto3_check.py`):
     - objects with every checksum algorithm, conditions, ranges and metadata;
     - both list paginators;
     - managed upload, download and copy (multipart and UploadPartCopy), and multipart by hand;
     - presigned GET and PUT in both addressing styles;
     - batch delete and auth errors.
   - `go.sh` (`go/main.go`, AWS SDK for Go v2): checksums, typed errors (`NoSuchKey`, `NotFound`), paginators, the
     transfer manager both ways, copy, the presign client, virtual hosts, and batch delete.
   - `js.sh` (`js/check.mjs`, AWS SDK for JavaScript v3): the same, with `lib-storage`'s Upload and
     `s3-request-presigner`.
   - The SDKs are not vendored. The scripts take an installed boto3 (`BOTO3_PYTHON`), Go modules (downloaded on first
     run), or a directory with the JS SDK installed (`JS_SDK_DIR`).
2. **Presigned URLs carry headers in their query.** Presigners hoist some `x-amz-*` headers into the signed query:
   the JS SDK sends `x-amz-checksum-crc32`, `x-amz-sdk-checksum-algorithm` and `x-amz-checksum-mode` there.
   - For a presigned request only, each such parameter is read as the header it names, unless the request also
     sends that header.
   - The operations' parameter checks ignore them.
   - `X-Amz-Content-Sha256` in the query is the payload hash.
   - For header auth, query parameters are never headers, because they would be unsigned.
   - So a hoisted checksum is checked like a header one. The JS presigner signs the CRC32 of an empty body when it is
     not given one, so S3 refuses the real upload with BadDigest, and CosmoStore does too. The SDK's documented fix
     is `requestChecksumCalculation: "WHEN_REQUIRED"`, and `js.sh` checks both cases.
3. **SigV2 is refused with S3's own message.** `Authorization: AWS …` and `AWSAccessKeyId` query auth get
   `InvalidRequest`: "The authorization mechanism you have provided is not supported. Please use
   AWS4-HMAC-SHA256."
   - boto3 presigns with SigV2 for a custom endpoint unless the client sets `signature_version='s3v4'`, so the
     clear message matters there.
   - SigV2 itself is not built: it is deprecated, and its HMAC-SHA1 needs a SHA-1 that lib/std lacks (CEESAFE_GAPS
     G26).
4. **Two read-only answers clients ask for:**
   - GetBucketVersioning returns an empty configuration (never enabled). rclone reads it before a purge.
   - GetObjectTagging returns an empty set (ADR-0010).

## Result (8 Nov 2026)

| Client | Checks |
|---|---|
| rclone 1.73.2 | 20 |
| boto3 1.42.97 | 43 |
| AWS SDK for Go v2 (service/s3 1.114.9) | 22 |
| AWS SDK for JavaScript v3 (client-s3 3.1164.0) | 25 |

All pass, each followed by a clean fsck, as does `tools/s3_smoke.sh` (96 checks). The matrix is published in
`docs/compatibility.md`.

## Not yet

- **The Java SDK v2:** run since slice 14, `tools/sdk/java.sh` (25 checks). Maven ran from the scratchpad, and its
  tarball was checked against Apache's SHA-512. The checks cover checksums, typed errors, paginators, the async
  multipart client (upload, download and copy), the presigner, virtual hosts, tags and batch delete.
- **The .NET SDK:** no .NET SDK is installed.
- **The Ceph s3-tests subset.**
- **Response checksums:** the Go SDK notes "Response has no supported checksum", and every client accepts that.
