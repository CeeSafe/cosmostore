# M8 exit review: directory buckets (18 Nov 2026)

**M8's exit (ADR-0079 §1, item 1; the owner chose directory buckets only, with S3's limits enforced):**
CreateBucket with a directory configuration, CreateSession, requests signed for `s3express` with a session token,
`ListDirectoryBuckets`, and S3's differences for them, exercised by the AWS CLI and every SDK of the matrix; what a
directory bucket does not take refused, never silently ignored. ADR-0080 is the design; its three slices are built.

## How it was checked

- **ADR-0080's "done when" against the evidence:** the unit tests (333, no leaks; `src/s3/directory_tests.cee`,
  `src/store/directory_tests.cee` with the fault sweep `directoryFaults{Once,Sticky,Torn,Crash}`), the S3 smoke's and
  the cluster smoke's directory sections (106 cluster checks in all), and the SDK matrix (boto3 201, Go 73,
  JavaScript 77, Java 74, .NET 63 checks). CI runs the unit tests and the three smokes, and passed on every M8 commit.
- **Two reviews of the code by readers who had not written it:** one of every call and parameter a directory bucket
  takes or refuses, against AWS's directory-bucket pages; one of CreateSession's tokens and where a session reaches,
  for security. The reviewers could not fetch AWS's pages and say which points of AWS's behaviour are from memory
  (marked *memory* below); those are checked against the documentation before they are fixed.

## The item

| Done when (ADR-0079) | `serve` | Cluster (ADR-0080 §8) | Verdict |
|---|---|---|---|
| CreateBucket with a directory configuration | unit tests, S3 smoke, every SDK | smoke: made through one node, listed through another | holds |
| CreateSession, session tokens | `expressTokensAreTheirOwn`, `expressSessionsReachTheirBucketAndMode`; S3 smoke (AWS CLI, classic and CRT) | smoke: a session made through one node used through another | holds; **findings B1–B3** |
| Requests signed for `s3express` | unit tests; every SDK, sessions on and off (.NET off only, Go lists with them off: §9) | smoke | holds; B8 |
| ListDirectoryBuckets | S3 smoke, SDKs, paging | merged across shards | holds; B2 |
| S3's differences (§6, §7) | `directoryBucketsRefuseWhatS3Does`, `directoryEtagsAreNotMd5s`; smokes | smoke | **does not hold: A1**, A2–A9 |

## Findings

### A. What a directory bucket takes and refuses (the "never silently ignored" rule)

1. **High: DeleteObjects is refused.** `delete` is not among the parameters a directory bucket takes
   (`src/s3/directory.cee:389`), so `POST /<bucket>?delete` is NotImplemented. S3 and ADR-0080 take it; every SDK's
   batch delete fails. No test sends it (the CLI's `s3 rm --recursive` deletes one key at a time).
2. **A copy into a directory bucket keeps the source's tags** (`copy.cee:511`): a tagged object copied from a
   general-purpose bucket is stored with them; GET then says `x-amz-tagging-count`, and lifecycle tag filters can
   match it. A directory bucket holds no tags.
3. **Inventory shows the real MD5 as the ETag** (with `-N`) and the class `STANDARD` (`inventory.cee:311`): against
   §7, which shows the same ETag on every read and listing, and leaks the MD5 it hides.
4. **The storage class reads `STANDARD`** in ListObjectsV2, GetObjectAttributes, ListParts, ListMultipartUploads and
   inventory; S3 says `EXPRESS_ONEZONE`, the only class a PUT here may name.
5. **Lifecycle rules a directory bucket does not take are kept** (`bucket_config.cee:168`): tag filters,
   NoncurrentVersionExpiration, ExpiredObjectDeleteMarker never act on a bucket never versioned or tagged.
   Transitions are refused for every bucket already. S3 takes expiration and AbortIncompleteMultipartUpload, by
   prefix and size (*memory*).
6. **Encryption differs from §3:** PutBucketEncryption with `aws:kms` is taken, after which a PUT naming `aws:kms` is
   refused while one naming nothing is sealed with KMS; CreateSession takes and answers only `AES256`, whatever the
   bucket's default, and says `AES256` when objects are stored without encryption (no default set). S3 encrypts
   every directory bucket's objects, SSE-S3 or SSE-KMS (*memory*).
7. **`versionId=null` is NotImplemented** on GET, HEAD, DELETE and GetObjectAttributes; S3 takes `null` only
   (*memory*).
8. **An empty `x-amz-tagging` is NotImplemented**; S3 refuses only a tag set that is not empty (*memory*).
9. **RenameObject** is in ADR-0080's "taken" list and not built (NotImplemented): built, or listed as not done.

Smaller: a ReadOnly session is refused HeadBucket (the ADR's six calls do not include it, but an SDK sends it with
its session); HeadBucket gives no `x-amz-bucket-location-type`/`-name`; an access point can be made on a directory
bucket with no check of its name form (requests through it are refused correctly); `inDirectoryBucket` decides
ETags by the name alone, so a `--x-s3` general-purpose bucket made before M8 would show directory ETags.

Checked and right: the bucket and object sub-resources refused (versioning, ACLs, tags, CORS, website, logging,
notifications, replication, Requester Pays, acceleration, object lock, versions, ownership controls, public access
block, analytics, metrics, intelligent tiering, location, ListObjects v1, retention, legal hold, select, restore,
torrent, browser POST); the headers refused (ACL and grants, tagging directive, object lock, request payer, website
redirect, SSE-C on both sides of a copy, Content-MD5, another storage class); ListObjectsV2's and
ListMultipartUploads' prefix and delimiter rules and `start-after`; consecutive parts at completion; the directory
ETag on GET and HEAD, conditions on GET, PUT and a copy's source, the copy's and the completion's results, listings
and GetObjectAttributes, with parts' ETags their MD5s.

### B. Sessions (ADR-0080 §3, §4)

1. **High: a session reaches S3 Control.** The access point calls (`/v20180820/…`, `server.cee:476`) are served
   before the session check (`:537`), as the session's key with no bucket or mode check: a ReadOnly session for
   bucket A can create, delete or set the policy of an access point on any bucket the key that made it could. Fix:
   a request with `x-amz-s3session-token` is refused there.
2. **Medium: requests with no bucket skip the session check** (`server.cee:513`): a session for A lists every bucket
   (ListBuckets, ListDirectoryBuckets); §4 says a token names the request's bucket, else AccessDenied.
3. **Medium: a copy's source is not held to the session's bucket** (`checkExpressSession` compares `req.bucket`
   only; `copy.cee:452` authorizes the source as the key that made it): a ReadWrite session for A copies B's object
   into A and reads it. SDKs sign CopyObject without a session (ADR-0080's context), so refusing a session's copy
   from another bucket costs no client.
4. **Medium: policies cannot name `s3express:` actions.** `actionPattern` (`policy.cee:210`) takes `*` or `s3:…`,
   so an AWS-style directory bucket policy granting or denying `s3express:CreateSession` is MalformedPolicy, and only
   `"*"` decides CreateSession (§3); a role's `s3express:ListAllMyDirectoryBuckets` likewise.
5. **Low: CreateSession for a name not made yet is not authorized by any policy** (none exists yet); if another key
   makes the bucket within 5 minutes, the session reaches it. Each call is still authorized as the key's, so only a
   Deny written on CreateSession alone is passed by.
6. **Low: the audit and access log lines name the session's temporary key id** (`server.cee:490`), not the key that
   made it (§4); a session's requests cannot be traced to their key.
7. **Low: an unsigned request with a bad or expired `x-amz-s3session-token` goes on as anonymous** instead of being
   refused (`request.cee:355`). Nothing is gained; S3 refuses it.
8. **Low: a general-purpose bucket can be made with an `s3express` signature** (`expressReaches` takes
   NoSuchBucket); §4 says an ordinary bucket refuses them.
9. **Low: path-style `/b//x` is key `x`, a virtual host's `//x` is `/x`** on a directory bucket (`request.cee:262`).
   The signature and policies see the same key, so not a security matter: one rule for both.

Checked and sound: STS and CreateSession tokens do not open as each other (version byte and additional data, which
binds the key id); both tokens at once is InvalidRequest; the signature is checked with the token's sealed secret
and its key id compared in constant time; a session key without its token matches no key; an ordinary bucket's
request with a token fails the bucket compare; expiry by the server's clock; a removed or disabled key ends its
sessions at once; access point aliases and ARNs are resolved before the compare; DeleteObjects' keys stay in the
request's bucket; malformed tokens (short, bad base64, wrong version or mode, a long id) are refused before parsing,
the plaintext authenticated first; the `content-length: 0` rule of SigV4 admits no body (HTTP/1.1 only, a body
needs a length or `transfer-encoding`, and the cluster front frames what it buffered again); the cluster front
passes the token through and drops a client's `x-cosmo-*` fields.

### C. What CI does not run

The SDK matrix (as for M7: run by hand, `tools/sdk/`). No chaos run takes a directory bucket: its data path is any
bucket's, and its one new record (the zone in BucketCreate) has its fault sweep and checkpoint format 25 test.

## The findings, closed (the owner: "continue and fix them all")

| Finding | What closed it | Evidence |
|---|---|---|
| A1 DeleteObjects refused | `delete` among a directory bucket's calls | `directoryBucketsRefuseWhatS3Does`; S3 smoke and cluster smoke: `delete-objects` |
| A2 a copy keeps the source's tags | A copy that would give a directory bucket tags is NotImplemented (S3's CopyObject says so); `x-amz-tagging-directive` and an empty `x-amz-tagging` taken | unit test; S3 smoke: a tagged object copied, then with `REPLACE` |
| A3 inventory's MD5 ETags | Inventory shows the directory ETag | `directoryEtag` in `inventoryRow` |
| A4 `STANDARD` | `EXPRESS_ONEZONE` in listings, GetObjectAttributes, ListParts, uploads and inventory | `directoryEncryptionIsTheBuckets`; both smokes |
| A5 lifecycle rules not taken | Tag filters, NoncurrentVersionExpiration, ExpiredObjectDeleteMarker NotImplemented (checked against AWS's pages: expiration and aborts, by prefix and size) | `putBucketLifecycle` |
| A6 encryption | Objects always sealed (the default, else SSE-S3 with the server's keys); a request names only the bucket's; CreateSession answers it; KMS context NotImplemented | `directoryEncryptionIsTheBuckets`; S3 smoke (three checks) |
| A7 `versionId=null` | Taken; another id InvalidArgument (AWS's pages: "only the null value") | unit test; S3 smoke |
| A8 an empty `x-amz-tagging` | Taken | unit test |
| A9 RenameObject | ADR-0081 (accepted: "Take on with ADR-0081"): a Rename record, conditions, client tokens | `renameMovesAnObject`, `renameAndCompaction`, `renameClientTokens`, `renameFaults{Once,Sticky,Torn,Crash}`, `renameSourcesInEveryForm`; S3 smoke (12 checks), cluster smoke, boto3 |
| Smaller | HeadBucket in a ReadOnly session; HeadBucket's zone headers; CreateAccessPoint on a directory bucket NotImplemented. `inDirectoryBucket` by name stays: a general-purpose `--x-s3` bucket can be made only before M8 | unit test; S3 smoke |
| B1 sessions reach S3 Control | A request with a session token is AccessDenied there | both smokes |
| B2 bucket-less calls | Likewise for ListBuckets and ListDirectoryBuckets | both smokes |
| B3 a copy's source | Held to the session's bucket (CopyObject, UploadPartCopy) | `expressSessionsReachTheirBucketAndMode`; S3 smoke |
| B4 `s3express:` in policies | Actions `s3express:…` and resources `arn:aws:s3express:<region>:<account>:bucket/<name>`, in bucket and role policies | `directoryBucketPolicies`; S3 smoke |
| B5 CreateSession before the bucket | The bucket's policy decides `s3express:CreateSession` on each use of a session | S3 smoke: a Deny stops a session made before it |
| B6 the log's requester | The key that made the session | `server.cee` |
| B7 a token without a signature | AccessDenied | S3 smoke |
| B8 a bucket made with `s3express` | A CreateBucket signed so must name a directory bucket | S3 smoke |
| B9 `//key` | Path-style and virtual-host both drop one `/` | ADR-0080 §9 |

**After the fixes:** 335 tests, the S3 and TLS smokes, the cluster smoke (110), and the SDK matrix (boto3, Go,
JavaScript, Java, .NET) all pass.

## Verdict

**M8 should not close yet.** A1 breaks a call every SDK uses, B1 and B3 let a session reach past its bucket and
mode, and A2 to A8 break the "never silently ignored" rule or S3's answer. The recommendation is to fix them all,
each with a test (A5 to A8 checked against AWS's pages first), A9 either built or listed as not done, then run the
smokes and the SDK matrix again. Closing M8 is the owner's decision.

**After the fixes:** every finding is closed with its test, A9 by ADR-0081 (RenameObject, built the same day). M8's
"done when" holds; M8 can close on the owner's word.
