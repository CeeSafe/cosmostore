# ADR-0014: The Ceph s3-tests subset, and what it changed

**Status:** accepted for M3 slice 7 (`tools/s3tests/`), 8 Nov 2026

## Context

M3's exit asks for "the relevant subset of Ceph s3-tests". s3-tests (github.com/ceph/s3-tests) checks S3 behaviour
with boto3, test by test, across far more of S3 than CosmoStore implements. Its pytest markers name most of the
features, which makes a subset possible.

## Decision

1. **The scope.** Every test in `test_s3.py` and `test_headers.py` runs, except those marked with a feature outside
   M3. The excluded features:
   - SigV2;
   - bucket policies, encryption and logging;
   - IAM, STS and tenants;
   - lifecycle and object lock;
   - versioning and delete markers;
   - tagging (until ADR-0017 built it), websites, Select, SNS and storage classes;
   - `fails_on_aws`, which is RGW-only behaviour.
2. **The subset is what passes,** pinned by name in `tools/s3tests/subset.txt`: 218 tests at s3-tests commit
   `5b39871`; 238 since ADR-0018 left out the POST tests, which all sign with SigV2. `tools/s3tests/run.sh` runs it against a fresh server and fails if any of them fails, the server logs
   an internal error, or fsck finds a problem afterwards. `run.sh all` reruns the whole in-scope set, to review the
   subset.
   - s3-tests is not vendored. The runner takes a checkout (`S3TESTS_DIR`) and a Python with its requirements
     (`S3TESTS_PYTHON`).
3. **Failures that stay out**, 221 of the 440 in-scope tests at this commit. 198 test features that M3 does not
   have, though their markers do not say so:

   | Cause | Tests |
   |---|---|
   | ACLs and anonymous access | 53 |
   | object lock | 39 |
   | versioning | 35 |
   | POST object (POST policy) | 26 |
   | CORS | 14 |
   | bucket policies | 12 |
   | public access block | 6 |
   | multiple owners | 5 |
   | lifecycle and similar | 1 |
   | client-side: the CRT signer refuses a zero or negative expiry, and botocore hooks run before signing | 7 |

   The rest are M3 work, or decided:
   - **response checksums and GetObjectAttributes** (15 tests), on M3's list;
   - **GET `?partNumber`** (3 tests): a multipart version does not keep its part boundaries yet;
   - **`Transfer-Encoding: chunked` without a length:** refused with MissingContentLength, as S3 does;
   - **non-ASCII metadata:** stored as sent, not RFC 2047-decoded (ADR-0012);
   - **re-creating your own bucket:** `BucketAlreadyOwnedByYou`, not the 200 of S3's legacy us-east-1;
   - **a Complete that names part 1 twice:** InvalidPartOrder. The test expects it to succeed, and I could not
     confirm that S3 accepts it;
   - **the key `"\xae\x8a-"`:** S3 refuses it as unparseable, and it is valid UTF-8 here.

### What it changed (all as S3 does)

4. **ListObjectVersions in an unversioned bucket** lists every object as its one version, `null`, the latest. A
   `versionId=null` on GET, HEAD and DELETE names that version, and any other id is InvalidArgument. s3-tests'
   cleanup lists versions, so no test ran before this.
5. **Listing:**
   - `max-keys=0` is not truncated;
   - an empty continuation token is no token, and it is echoed back;
   - `StartAfter` is echoed back even with a continuation token;
   - v2's `fetch-owner` (and every v1 listing) gives Owners;
   - v1 does not URL-encode its top-level Prefix;
   - ListBuckets takes `max-buckets`, `continuation-token` and `prefix`.
6. **A 304 carries the ETag and Last-Modified.**
7. **Content-Encoding** keeps `", "` between the codings left after `aws-chunked` is removed.
8. **Copy ranges:** a range past the source is InvalidRange, and a malformed one is InvalidArgument.
9. **Presigned URLs** whose `X-Amz-Expires` is zero, negative or over a week get AccessDenied (403). One that is not
   a number gets AuthorizationQueryParametersError.
10. **A retried CompleteMultipartUpload gets its first answer,** as long as its object is still the key's current
    version.
    - `StoreState.completions` remembers the last 1,024 completions, rebuilt from the journal by `applyRecord`. It
      is never checkpointed, so a retry after a checkpoint and a restart gets NoSuchUpload, as one would after S3's
      own window.
    - No record or checkpoint format changes.
11. **Conditional writes:**
    - CompleteMultipartUpload takes If-Match and If-None-Match, checked atomically with the commit
      (`completeUploadIf`);
    - PutObject's If-None-Match takes ETags, not only `*`;
    - If-Match on a key with no object is 404 NoSuchKey, as AWS documents. Both share `resolveCondition`.

## Tests

- **Store:** a retried completion returns the first answer and writes nothing. If-None-Match `*` and If-Match on
  completion are tested, and so is a retry once the object is replaced.
- **Unit:** the copy-range errors.
- **End to end:** the s3-tests subset (218), the smoke test (96), and the SDK matrix (ADR-0013), all on this build.
