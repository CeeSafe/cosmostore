# ADR-0008: The S3 HTTP layer

**Status:** accepted for M3 slice 1 (`cosmostore serve`, `src/s3/`), 7 Nov 2026

## Context

M3 puts the store behind the S3 API, for stock AWS CLI v2 and SDK clients. Three constraints from the toolchain
shape this ADR:
- **The HTTP stack.** CeeSafe.Web (`~/dev/CeeSafe.Web`, `web_server` 0.3.1) gives:
  - HTTP/1.1 and h2c serving, with routing and keep-alive;
  - streaming bodies with backpressure, and `Expect: 100-continue` on the first body read;
  - the raw request target, which SigV4 needs;
  - application state shared as `ctx.state()`.
- **No blocking in async code.** In an async fn, file I/O is N0295 (type-system.md §40.1). Every store call must run
  on a worker thread through `Async.blocking`, whose closure may borrow a `Send` value mutably.
- **The store is single-writer** (`borrow mut this` for mutations).

## Decision

### Serving and concurrency

1. **`cosmostore serve <dir> <port> <credentials-file>`** serves path-style requests (`/bucket/key`) on
   `127.0.0.1:<port>` over HTTP/1.1. The bind address and virtual-host addressing come later in M3.
2. **One `AsyncMutex<ObjectStore>`.** A handler takes the lock, makes its store calls inside `Async.blocking`, and
   drops the lock before it touches the network. Waiting tasks park; they do not block the event loop.
3. **Bodies move without the lock.**
   - **PUT:** the handler takes an `ObjectWriter` under the lock and releases it. It then reads the body in pieces
     of at most 1 MiB. Each piece is written to the writer on a worker thread (`Async.blocking`), while other
     requests use the store. Only `putFinished` (one journal commit) takes the lock again. A body that fails
     validation is discarded (`discardFinished`) and never committed.
   - **GET:** `openReader` runs under the lock, and its extents are pinned (ADR-0007). The bytes are then streamed
     on worker threads without the lock. A client that disconnects drops the reader, which releases the pins.
4. **Commits are serialized.** Each PUT is one journal commit with its own sync, so concurrent PUTs do not share a
   group commit yet. Batching them across requests is M4 work (perf hardening). It needs the store to commit from
   one place, for example a commit task.

### Authentication

5. **SigV4 header auth only** (`Authorization: AWS4-HMAC-SHA256 ...`), against a static credentials file. The file
   has one `access-key secret-key` pair per line; `#` starts a comment.
   - **Refusals:** an anonymous request gets `AccessDenied`, and a bad signature gets `SignatureDoesNotMatch`.
     `x-amz-date` (or `Date`) more than 15 minutes from the server clock gets `RequestTimeTooSkewed`.
   - **The signature check:**
     - the canonical request uses the raw path, with each segment URI-encoded as S3 does, which leaves it as sent;
     - the query is sorted, the signed headers have their values trimmed, and the payload hash is
       `x-amz-content-sha256`;
     - the region is the client's (any), and the service must be `s3`.
   - Presigned URLs (query auth) and POST policy come later in M3.
6. **What `x-amz-content-sha256` covers**, as S3 defines it:
   - **A hex SHA-256:** the server hashes the body while it streams and refuses the PUT before its commit on a
     mismatch (`XAmzContentSHA256Mismatch`).
   - **`UNSIGNED-PAYLOAD`:** the body is not hashed.
   - **`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`:** the body is aws-chunked. Each chunk's signature chains from the seed
     signature and is verified as the chunk arrives.
   - **`STREAMING-UNSIGNED-PAYLOAD-TRAILER`:** the body is aws-chunked without signatures. A trailing
     `x-amz-checksum-*` closes it.
   - The `...-PAYLOAD-TRAILER` signed form also verifies the trailer's signature.
   - For aws-chunked bodies, `x-amz-decoded-content-length` gives the object's size, and a mismatch is
     `IncompleteBody`.
7. **Integrity checks, all before commit:**
   - `Content-MD5` is checked against the body, and a mismatch is `BadDigest`;
   - one `x-amz-checksum-{crc32,crc32c,crc64nvme,sha256}` value, from a header or the trailer, is checked
     (`BadDigest`). A SHA-1 checksum is `NotImplemented`.
   - The store keeps MD5 only. So GET returns no `x-amz-checksum-*` yet. Clients validate a response checksum only
     when one is present.

### The S3 surface in slice 1

8. **Operations:**
   - **Service and bucket:** ListBuckets, CreateBucket, HeadBucket, DeleteBucket, GetBucketLocation.
   - **Objects:** PutObject, GetObject (one `Range`, `If-Match`/`If-None-Match`/`If-(Un)Modified-Since`),
     HeadObject, DeleteObject.
   - **Listing:** ListObjects v1 and v2, with prefix, delimiter, max-keys, marker / start-after /
     continuation-token, and `encoding-type=url`.
   - **Anything else** is `NotImplemented` (501) in S3's XML.
9. **A conditional PUT is checked under the lock.**
   - `If-None-Match: *` maps to `PutCondition.IfAbsent`.
   - For `If-Match: "<etag>"`, the handler reads the current version's MD5 and generation under the lock. If the ETag
     matches, it writes with `IfGeneration(generation)`. Nothing can come between the two, so this is a true CAS.
10. **ETag:** the quoted hex MD5 of the object. A multipart object's is the MD5 of its part MD5s, then `-N`
    (ADR-0009).
11. **Errors:** S3's XML error body (`Code`, `Message`, `Resource`, `RequestId`) with S3's status for each code.
    `StoreError` maps to these codes:
    - `NoSuchBucket` and `NoSuchKey` give 404;
    - `BucketAlreadyOwnedByYou` gives 409 (there is one owner), and so does `BucketNotEmpty`;
    - `PreconditionFailed` gives 412;
    - `EntityTooLarge` gives 400;
    - `InsufficientStorage` gives 507 (MinIO's `XMinioStorageFull` semantics, as S3 has none);
    - `InvalidBucketName` gives 400;
    - `KeyTooLongError` gives 400;
    - a journal failure gives 503 `ServiceUnavailable`;
    - `DataCorrupt` gives 500 `InternalError`, and is logged.
12. **Listing** needs each key's ETag and last-modified time. `ListPage` gains `md5s` and `mtimes`, filled from the
    index.

## Rejected

- **A store thread with a command channel.** It serializes the same way as the mutex. It also needs every command,
  and every reply carrying a borrowed body, to be owned and `Send`. The mutex plus `Async.blocking` reaches the same
  single writer with less code. A commit task may still come in M4, to batch commits.
- **Reading a whole PUT body into memory.** Objects reach 5 GiB.
- **Hand-written C for SHA-256 or HMAC.** lib/std has `Sha256` and `HmacSha256` (CeeSafe ADR 0075). CRC-32/IEEE,
  the AWS CLI's default checksum, is not in lib/std. It is a table-driven CeeSafe function in `src/s3/crc32.cee`
  until it is (CEESAFE_GAPS G26).

## Tests

- **Unit:**
  - SigV4 against AWS's published examples (the `GET /test.txt` example of the S3 SigV4 documentation, the chunked
    upload example with its seed and chunk signatures);
  - the aws-chunked decoder, with all framings split at every byte;
  - XML escaping and URL encoding;
  - CRC-32 test vectors.
- **End to end** (`tools/s3_smoke.sh`): the AWS CLI v2 against `cosmostore serve`. It covers bucket create, list and
  delete; put and get of small, extent-sized and chunked-checksum objects; ranges; conditional PUT; listing with a
  delimiter and pagination; and the expected errors.

## As built (7 Nov 2026)

`src/s3/`: `server.cee` (dispatch, buckets, listing), `objects.cee` (PUT, GET/HEAD), `request.cee` (fields, path,
query, SigV4), `sigv4.cee`, `chunked.cee`, `encode.cee`, `crc32.cee`, `errors.cee`, `serve.cee`. CeeSafe.Web is a
path dependency (`../../CeeSafe.Web/packages`, `web_server` 0.3.1).

- **Drops that do no I/O.** The compiler (N0295) refused async code that could drop an `ObjectWriter` (whose drop
  unlinked files) or a reader pin (whose drop locked a `Mutex`). Both now queue or count instead (ADR-0007
  amendment). So no request path can stall the event loop on the disk.
- **Logging.** 5xx responses are logged to standard error from async code (`AsyncConsole.writeError`).
- **Measured** (macOS laptop, loopback): `aws s3 cp` of a 3 MB object at about 500 MB/s both ways (one client).
  16 parallel PUTs and then 16 parallel GETs were all byte-exact.
- **Tests:**
  - 7 unit tests (`src/s3/s3_unit_tests.cee`): AWS's GET-object and chunked-upload signatures match exactly, and the
    signed and unsigned aws-chunked bodies decode when split at every byte.
  - `tools/s3_smoke.sh`: 42 checks with AWS CLI 2.34 and `tools/s3_raw.py` (signed chunked PUTs, a changed chunk,
    GETs dropped half way), then fsck.

### Limits of slice 1 (the rest of M3)

- **No multipart:** `aws s3 cp` of a file over 8 MB (the CLI's multipart threshold) fails with `NotImplemented`.
  Done in slice 2 (ADR-0009).
- **Not yet built:** CopyObject, DeleteObjects, presigned URLs, POST policy, and virtual-host addressing.
- **Not stored:**
  - `x-amz-meta-*` user metadata;
  - the response checksum;
  - a bucket's creation date (ListBuckets says 1970).
- **One address:** only 127.0.0.1 is served, without TLS.
- **No shared group commit:** PUTs are serialized on the store's lock, each with its own commit.
