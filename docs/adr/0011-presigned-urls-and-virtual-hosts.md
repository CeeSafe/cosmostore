# ADR-0011: Presigned URLs, virtual-host addressing, bucket creation dates

**Status:** accepted for M3 slice 4 (`src/s3/request.cee`, `src/s3/serve.cee`), 8 Nov 2026

## Context

- **Presigned URLs.** Browsers, curl and `aws s3 presign` use them: SigV4 carried in the query instead of an
  Authorization header.
- **Virtual-host addressing.** SDKs default to `<bucket>.<endpoint host>` for most bucket names. Path-style is a
  setting, and some clients deprecate it.
- **Bucket creation dates.** ListBuckets has reported 1970 (ADR-0008, limits), although `BucketCreate` records and
  checkpoints always kept the time.

## Decision

### Query authentication

1. **The parameters.** A request without an Authorization header, whose query has `X-Amz-Algorithm`, is
   authenticated from the query.
   - Required: `X-Amz-Algorithm` (`AWS4-HMAC-SHA256`), `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires` (1 to
     604,800 s), `X-Amz-SignedHeaders` and `X-Amz-Signature`. A missing or invalid one is
     `AuthorizationQueryParametersError` (400).
   - `X-Amz-Security-Token` is `InvalidToken`, because the store has no temporary credentials.
2. **One check for both forms.**
   - The query's credential, signed headers and signature go through the Authorization header's parser.
   - Both forms then share `verify`: the credential lookup, the date in the scope, the canonical request and the
     signature comparison.
   - For query auth, the canonical query is the raw query without `X-Amz-Signature`.
3. **Time.** A URL is refused (AccessDenied) after `X-Amz-Date + X-Amz-Expires`, or when `X-Amz-Date` is more than 15
   minutes in the future. Header auth keeps its 15-minute skew in both directions.
4. **The payload** is `UNSIGNED-PAYLOAD`, unless the request also sends `x-amz-content-sha256`. A presigned PUT then
   takes the same body path as any PUT: `Content-MD5` and `x-amz-checksum-*` are still checked.
5. **`X-Amz-*` parameters** are ignored by the operations' parameter checks (`onlyParams`), as `x-id` is.

### Virtual-host addressing

6. **The domain.** `cosmostore serve <dir> <port> <credentials-file> [domain]` takes an optional domain.
   - A Host of `<bucket>.<domain>`, with any port and compared case-insensitively, names the bucket, and the whole
     path is the key.
   - Any other Host, including the bare domain, is path-style. Without a domain, only path-style is served.
   - Bucket names with dots work, because the domain is matched as a suffix.
7. **The signature is unchanged.** SigV4 signs the path as sent and the Host header, so virtual-host requests need
   nothing new.

### Bucket creation dates

8. **ListBuckets** reports each bucket's creation time, from `ObjectStore.listBucketInfo`. The time comes from its
   `BucketCreate` record or the checkpoint.

## Rejected

- **Inferring the domain from Host headers.** A bucket named like a host label would change how every other
  request is read. The operator names the domain.
- **A presigned-URL cache or replay protection.** S3 has neither: a URL is valid until it expires.

## Tests

- **Unit:**
  - AWS's published presigned-URL example (GET `/test.txt`, 86,400 s) gives the documented signature exactly;
  - `virtualBucket` with ports, mixed case, dotted names, near misses, and no domain.
- **End to end** (`tools/s3_smoke.sh`, with the server's domain `localhost`):
  - `aws s3 presign` with curl, and a URL with a changed key (403);
  - a presigned PUT, from `tools/s3_raw.py presign`, through curl;
  - an expired URL, and one without its signature;
  - virtual-host PUT, GET, `s3 cp` both ways and listing, through the CLI with `addressing_style = virtual`;
  - ListBuckets' creation date is today.

## Not yet

- POST policy (browser form uploads).
- Presigned URLs for chunked uploads (`STREAMING-*` in the query).
