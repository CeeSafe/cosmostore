# ADR-0076: Access Points (M7 item 5)

**Status:** accepted, 16 Nov 2026 (the owner: "Yes, accept ADR-0071 to 0077"); proposed the same day for M7 item 5 (ADR-0071), under the owner's standing go-ahead.

## Context

- S3 Access Points are named ways into a bucket, each with its own policy and public-access block, so that a bucket
  shared by many applications gets a policy per application instead of one long bucket policy. They are made with S3
  Control (`/v20180820/accesspoint/<name>`, with `x-amz-account-id`), and a request names one by its alias (a
  bucket-like name ending `-s3alias`) or its ARN, which SDKs turn into the host `<name>-<account>.<endpoint>`.

## Decision

1. **S3 Control on the S3 port:** `CreateAccessPoint` (a bucket that exists; `VpcConfiguration` is NotImplemented,
   network origin Internet; a `PublicAccessBlockConfiguration`, all four settings on when it is left out, as AWS
   does), `GetAccessPoint`, `ListAccessPoints` (all, or a bucket's), `DeleteAccessPoint`, and
   `Put/Get/DeleteAccessPointPolicy`. A request with `x-amz-account-id` and a path under `/v20180820/` is one,
   path-style or under `<account>.<domain>`. Names are 3 to 50 of a-z, 0-9 and `-`, one per server
   (`AccessPointAlreadyOwnedByYou`); the look-up and the write hold the store's lock together. Any 12-digit account
   id is taken and given back in ARNs (`arn:aws:s3:us-east-1:<account>:accesspoint/<name>`). Long-term keys and
   their `GetSessionToken` sessions only; not on a cluster yet (NotImplemented).
2. **Stored** as a `BucketConfig` of kind 15 on the access point's bucket (checkpoint format 22): name, alias
   (`<name, up to 30>-<20 of a-z 2-7>-s3alias`), block, creation time, policy. Deleting the bucket deletes them.
3. **A request through one:** a bucket name that is an alias, or `<name>-<12 digits>` (from the ARN's host), and
   that some access point has, is that access point's bucket, before anything else reads the request; while no
   bucket has access points nothing is looked up. Through an access point a request may do what it may to objects,
   and of the bucket itself only list it (objects, versions, uploads), head it, find its location and delete objects
   in a batch: InvalidRequest for the rest. **Its policy** has a bucket policy's grammar, its resources the access
   point's ARN and `…/object/<key pattern>` (any region and account), read as the bucket's and its objects'. A Deny in
   it refuses; an anonymous request needs its Allow, which a public policy under `RestrictPublicBuckets` does not
   give, and then the bucket's as well (policy, or ACLs unless the access point's `IgnorePublicAcls`); a key's
   request is otherwise as without the access point. `BlockPublicPolicy` refuses a public access point policy. The
   check is in `gateDecision` and ahead of the keys' fast path, as a role session's (ADR-0075 §3), so copies,
   DeleteObjects and governance bypass meet it too.
4. **Not done:** a copy's source named by an alias (NoSuchBucket), `GetAccessPointPolicyStatus`, Object Lambda and
   multi-Region access points, `ListAccessPoints` paging (every one in one answer).

## Consequences

- `accessPointsStoredAndFound`, `accessPointPolicies`; the S3 smoke drives `aws s3control` (create, get, list, the
  name twice, a missing bucket, put/get/delete policy, a public policy under the block, delete) and reads, writes and
  lists by alias and by ARN, with the access point's Deny refusing a write through it but not to the bucket, no
  bucket configuration and no anonymous reads through it, and the alias gone with the access point.
