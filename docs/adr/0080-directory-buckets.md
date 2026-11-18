# ADR-0080: Directory buckets (M8)

**Status:** accepted, 18 Nov 2026 (the owner: "accept ADR-0079 and ADR-0080"); proposed the same day as M8's one item (ADR-0079; the owner chose directory buckets
only, with S3's limits enforced).

## Context

- **AWS's documentation** (the S3 user guide's "differences for directory buckets", "directory bucket naming rules"
  and "API operations for directory buckets"; the API reference's CreateBucket, CreateSession, ListDirectoryBuckets
  and ListObjectsV2; read 18 Nov 2026):
  - **Names:** `<base>--<zone-id>--x-s3`, 3 to 63 characters in all, lowercase letters, digits and `-`, beginning and
    ending with a letter or digit, unique in their zone; not beginning `xn--`, `sthree-` or `amzn-s3-demo-`.
  - **CreateBucket:** a `CreateBucketConfiguration` with `Location` (`Type` AvailabilityZone or LocalZone, `Name` the
    zone id) and `Bucket` (`DataRedundancy` SingleAvailabilityZone or SingleLocalZone, `Type` Directory);
    `LocationConstraint`, `x-amz-acl`, `x-amz-grant-*`, `x-amz-bucket-object-lock-enabled` and
    `x-amz-object-ownership` are not taken (always bucket owner enforced). The answer has `x-amz-bucket-arn`.
  - **CreateSession:** `GET /?session` on the bucket, with `x-amz-create-session-mode` ReadWrite or ReadOnly (unset:
    ReadWrite if allowed, else ReadOnly) and optional encryption headers (AES256 or aws:kms, and a KMS key and context);
    the answer is `CreateSessionResult` > `Credentials` > `AccessKeyId`, `Expiration`, `SecretAccessKey`,
    `SessionToken`, credentials that expire after 5 minutes and cannot be extended. Later requests are signed with
    them and send the token in `x-amz-s3session-token`. A ReadOnly session can only GetObject, HeadObject,
    ListObjectsV2, GetObjectAttributes, ListParts and ListMultipartUploads. CopyObject and HeadBucket do not need a
    session. The policy action is `s3express:CreateSession`.
  - **ListDirectoryBuckets:** `GET /` with `continuation-token` and `max-directory-buckets` (0 to 1,000); the answer
    is `ListAllMyDirectoryBucketsResult` > `Buckets` > `Bucket` (`BucketArn`, `BucketRegion`, `CreationDate`, `Name`),
    then `ContinuationToken`.
  - **Not for directory buckets:** versioning, object lock, MFA delete, ACLs, object tags, replication, server access
    logs, website hosting, event notifications, Requester Pays, Transfer Acceleration, S3 Select, SSE-C and DSSE-KMS,
    MD5 checksums (Content-MD5), ListObjects v1, ListObjectVersions, CORS, and lifecycle transitions.
  - **Taken:** bucket policies, default encryption, lifecycle expiration, inventory, access points; and the object
    calls PutObject, GetObject, HeadObject, DeleteObject(s), CopyObject, GetObjectAttributes, RenameObject,
    ListObjectsV2, HeadBucket and the multipart calls.
  - **Behaviour:** ListObjectsV2 is not in key order, its prefix must end in the delimiter and the delimiter can only
    be `/`, `StartAfter` is not taken, and `CommonPrefixes` include the prefixes of uploads in progress. Deleting an
    object deletes the empty "directories" above it. A multipart upload's parts must be consecutive from 1 (else 400),
    and ETags are not MD5s.
  - **Not stated there:** the error for an expired session token, the errors for a wrong `CreateBucketConfiguration`,
    and the error AWS gives for a call that is not taken.
- **What an SDK sends to a custom endpoint, checked 18 Nov 2026** (boto3 1.42.97 against a stub that answers
  CreateSession):
  - **Every call on a `--x-s3` bucket, CreateBucket included, first takes a session:** `GET /<bucket>?session`, then the
    call path-style, signed for the service `s3express` with the session's key and its token in
    `x-amz-s3session-token`. This holds for CreateBucket (the bucket does not exist yet), PutBucketPolicy, HeadBucket
    and DeleteBucket too. On AWS these go to a regional endpoint without a session; through a custom endpoint they
    arrive here with one.
  - **CopyObject** is signed for `s3express` with the long-term key and no session.
  - **ListDirectoryBuckets** is `GET /` signed for `s3express` with the long-term key: the same request as
    ListBuckets except the service in the signature's scope.
- **What CosmoStore has:** STS's sealed session tokens and their check in the signature (ADR-0075 §1, `request.cee`
  `verify`), which a CreateSession token can be a kind of; buckets and their `BucketConfig` records; policies
  (ADR-0043) and access points (ADR-0076).

## Decision (proposed)

1. **The zone.** `serve --zone-id <id>` (and on a cluster, `node --zone-id`, the same on every node) names the one zone
   this server's directory buckets are in, e.g. `local-az1`: 1 to 20 of a-z, 0-9 and `-`. Without one, a directory
   configuration is NotImplemented. The region in ARNs is the one requests are signed for.
2. **CreateBucket of a directory bucket:** the name has the form above with this server's zone id, the configuration
   says `AvailabilityZone`, this zone, `SingleAvailabilityZone` and `Directory` (another zone, LocalZone or
   SingleLocalZone: InvalidArgument; a name of another form with a directory configuration, or a `--x-s3` name
   without one: InvalidBucketName), and none of the headers S3 does not take (InvalidArgument). The bucket is an
   ordinary bucket whose BucketCreate record carries the zone id after its time (a record without one is a
   general-purpose bucket's), so a directory bucket is never seen without its zone; checkpoint format 25 keeps the
   zone with the bucket. An ordinary bucket cannot become one or stop being one. The answer
   adds `x-amz-bucket-arn` (`arn:aws:s3express:<region>:<account>:bucket/<name>`; the account is
   `x-amz-account-id`'s, else `000000000000`).
3. **CreateSession** (`GET /<bucket>?session`, path-style or under the domain): signed for `s3express` by a long-term
   key or a `GetSessionToken` session (not by another CreateSession session, not by an assumed role: as STS's
   tokens, ADR-0075 §3). The mode is ReadWrite or ReadOnly (unset: ReadWrite); a bucket's policy decides
   `s3express:CreateSession` for it. The bucket must exist, or be a name of this zone's form that does not exist yet
   (an SDK asks for a session before CreateBucket, and keeps using it on the bucket it made: so such a session is
   an ordinary session of that bucket, and the requests it signs are authorized as the key's are); another name is
   NoSuchBucket, a general-purpose bucket InvalidRequest. CreateSession needs `--sts-key-file` (NotImplemented
   without). Encryption headers must be the bucket's default
   encryption, or InvalidArgument; SSE-C's are refused. The token is sealed as STS's are (ADR-0075's keys, AES-256-GCM) but with
   its own version byte and additional data, so neither kind of token opens as the other; it holds the key that made
   it, the bucket, the mode and its expiry (5 minutes), and the answer is `CreateSessionResult`.
4. **A request with `x-amz-s3session-token`:** signed for `s3express` with the session's key; the token opens, has not
   expired (ExpiredToken, as STS's) and names this request's bucket (else AccessDenied); a ReadOnly session may make
   only the six calls above (else AccessDenied). The requester is the key that made the session (for policies, the
   audit line and access logs), narrowed by the mode. A request to a directory bucket signed for `s3`, or for `s3express` without
   a session token, is taken from a long-term key (CopyObject, ListDirectoryBuckets, and SDKs with sessions turned
   off). `x-amz-security-token` and `x-amz-s3session-token` together: InvalidRequest. An ordinary bucket refuses
   `s3express` signatures and session tokens (AuthorizationHeaderMalformed, AccessDenied).
5. **ListDirectoryBuckets:** `GET /` signed for `s3express`: this server's directory buckets in name order,
   `max-directory-buckets` at a time with an opaque `ContinuationToken` (the last name, encoded). ListBuckets (signed
   for `s3`) leaves directory buckets out, as S3 does.
6. **What a directory bucket refuses:** every call that section of the documentation does not take, with
   NotImplemented, so a client sees the difference and nothing is ignored (where AWS's error is known, its own:
   checked with each call in the slices); and on the calls it takes, `Content-MD5`, SSE-C headers, `x-amz-acl`,
   tags (`x-amz-tagging`), object lock headers, `x-amz-request-payer`, `StartAfter` and a delimiter other than `/`
   (InvalidArgument, or NotImplemented where it is a feature), as S3's pages say.
7. **Behaviour kept from S3:**
   - **ETags** of a directory bucket's objects are not MD5s: 32 hex characters drawn at write time (a multipart
     object's too, without the `-N`), stored as other ETags are; a client checks nothing against MD5 here.
   - **Multipart:** parts consecutive from 1 at completion, else InvalidPartOrder.
   - **ListObjectsV2:** a prefix that is not empty ends in `/`, the delimiter is `/` or none; the order is the key
     order (S3 promises no order, so key order is a valid one, and a client that relies on none works); in-progress
     uploads' prefixes appear in `CommonPrefixes`.
   - **Directories** are not stored: a key's prefixes exist while a key or an upload under them does, so deleting
     the last object under one deletes it, as S3 says.
   - **No versioning:** a directory bucket is never versioned; each write replaces the key.
8. **On a cluster:** the `Directory` record goes with the bucket's other records on its shard, ListDirectoryBuckets
   merges the shards as ListBuckets does (ADR-0060), and the front passes `x-amz-s3session-token` through; the token
   opens on any node because the STS keys are the same on every node (ADR-0078 §2).

## Consequences

- The store gains a field of the BucketCreate record and checkpoint format 25; its fault sweep covers a directory bucket made,
  written and deleted. The S3 layer gains the `s3express` service in signatures and a second kind of session token.
- Tests: the unit tests of names, configurations, tokens and refusals; the S3 smoke and the cluster smoke make a
  directory bucket and use it through the AWS CLI (`s3api` with sessions, `s3 cp --recursive`); every SDK of the
  matrix does the same, with sessions on and off.
- `docs/compatibility.md` gains a directory bucket matrix.

## Slices

1. Names, the zone, CreateBucket and its record, ListDirectoryBuckets, and `s3express` signatures from long-term
   keys (sessions off). Checked through boto3 with `AWS_S3_DISABLE_EXPRESS_SESSION_AUTH`: the AWS CLI (2.34) has
   no way to turn sessions off, so its checks, and the smokes', come with slice 2.
2. CreateSession and session tokens, ReadOnly sessions, the cluster: the AWS CLI with sessions in the S3 smoke and
   the cluster smoke (a session made through one node used through another).
3. The refusals and S3's behaviours (§6, §7), then the SDK matrix.

## Rejected

- **A store of its own for directory buckets** (S3 Express's single zone and low latency): the data path is the same
  as any bucket's here; what differs is the API.
- **Taking session tokens without a bucket** (a CreateSession token good for any bucket): AWS's are a bucket's, and a
  token here must not open more than it would there.
- **Listings in a random order** to look like S3's: no order is promised, and key order costs nothing.
