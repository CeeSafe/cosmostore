# ADR-0088: Identities, users and their identity policies (M11)

**Status:** proposed, 19 Nov 2026. M11 is item A of ADR-0087 (the owner: "A."). Where users are defined was left
open, so this takes ADR-0087's recommendation: a users file beside the credentials file.

## Context

- **Every key is one account's** (ADR-0050). A key may do what no resource policy denies (ADR-0043, ADR-0084, ADR-0076).
  Roles (ADR-0075) are the only identity policies, and S3 Tables refuses their sessions (ADR-0083 §6).
- **AWS's IAM in one account** (the IAM user guide's policy evaluation logic, *memory*):
  - A request by an IAM user is allowed when an identity policy of the user, or the resource's policy naming that
    user, allows it, and no policy denies it. An explicit Deny anywhere wins; nothing allowing it is an implicit
    deny.
  - The account's root may do anything no resource policy denies.
  - Identity policies have no `Principal`, and their resources are ARNs of any service:
    - `arn:aws:s3:::bucket/key`;
    - `arn:aws:s3express:<region>:<account>:bucket/<name>`;
    - `arn:aws:s3tables:<region>:<account>:bucket/<name>[/table/<id>]`;
    - `arn:aws:iam::<account>:role/<name>`.
  - A resource policy names a user as `arn:aws:iam::<account>:user/<name>`.
  - GetSessionToken's session is its user's. AssumeRole needs `sts:AssumeRole` on the role's ARN (the role's trust
    policy is the other half, *memory*; CosmoStore's roles have none).
- **What CosmoStore has:**
  - The credentials file, reloaded on change into credential sets that keep each key's place (ADR-0050).
  - The identity policy grammar and decision of roles (ADR-0075 §2, `parseIdentityPolicy`, `sessionAllows`).
  - The resource policies' decision (`gateDecision`, `checkTables`).

## Decision (proposed)

1. **The users file** (`serve --users-file`, `node --users-file`): `account <access key>[,<access key>…]` lines name
   the account's keys, and one user a line, `<name> <access key>[,<access key>…] <identity policy JSON>`; `#` for
   comments.
   - **Names:** 1 to 64 of `A-Za-z0-9+=,.@_-`, as IAM's, unique ignoring case; `account` is not one.
   - **Keys:** a key is named once in the file, as the account's or one user's. With a users file, a key it names
     neither way is refused (InvalidAccessKeyId): removing a user's line, or emptying the file, takes its keys away
     rather than giving them the account (fail closed; amended after M11's exit review, A2, by the owner's choice).
     A key the users file names that the credentials file does not have is no one's, so removing a key from the
     credentials file revokes it whatever the users file says (A3). Without a users file every key is the
     account's, as before, so a deployment without one changes nothing.
   - **The policy:** an identity policy, `parseIdentityPolicy`'s grammar widened as §3 says. A user with several of
     AWS's policies writes their statements into one.
   - **Reloads:** it is reloaded with the credentials file, whenever either changes. A file that does not read
     changes nothing and is reported, with its line and the key, as ADR-0050's file is. Each key's
     place in the credential set then carries its user's name and parsed policy.
2. **The decision for a user's request** (a key the users file names, or that key's GetSessionToken session):
   - **The policies:**
     - An explicit Deny in the user's identity policy, or the resource's policy (a bucket's, an access point's, a
       table bucket's or table's), refuses.
     - Otherwise an Allow in either allows: the resource policy's by the user's ARN, its key, or `*`.
     - Otherwise the request is refused (AccessDenied, ForbiddenException).
   - **Calls with no resource policy** are decided by the identity policy alone: ListBuckets, CreateBucket,
     ListDirectoryBuckets, CreateTableBucket, ListTableBuckets, S3 Control's account calls, and STS.
   - **The policy calls** are never refused to the account's keys (ADR-0043 §4). A user needs an Allow for them, as
     on AWS.
   - **Account-only:** the admin API and the stats endpoint (ADR-0054, ADR-0021) refuse users.
   - **A role's session** is decided as today, by its role's and session's policies with the resource's. With this,
     S3 Tables takes it too (ADR-0083 §6 is lifted).
   - **Through an access point** (amended after M11's exit review, A6), each side must allow, as on AWS: the access
     point, by the user's identity policy on the access point's ARN or the access point's policy; and the bucket, by
     the identity policy on the bucket's ARN or the bucket's policy. A Deny on either ARN, or in either policy,
     refuses.
   - **Fields that are calls of their own** (A4): a write's ACL needs `s3:PutObjectAcl`, its tags
     `s3:PutObjectTagging`, its retention `s3:PutObjectRetention` and its legal hold `s3:PutObjectLegalHold`; a bucket
     made with an ACL `s3:PutBucketAcl`, with object lock `s3:PutBucketObjectLockConfiguration` and
     `s3:PutBucketVersioning`. For every requester, as on AWS.
   - **Where the server writes for a configuration** (A1): a user's or a session's replication destination needs
     `s3:ReplicateObject` (and `s3:ReplicateDelete` with delete markers), and an inventory's or the logs' target
     `s3:PutObject`, on the destination's objects, when the configuration is put. The account's keys may name any
     bucket. A policy changed later is not read again at delivery: what a configuration may do is decided once.
   - **A table bucket's warehouse:** its data is decided as `s3tables:GetTableData`/`PutTableData`, and HeadBucket
     as `s3tables:GetTableBucket` (B5).
3. **Identity policy grammar** (roles' and users'):
   - **Actions:** `s3:`, `s3express:`, `s3tables:`, `sts:`.
   - **Resources:** `*`, or the ARNs of §Context, with any region and account, matched by service and the part
     after its prefix (`s3:bucket/key`, `s3ap:name[/object/key]`, `s3express:bucket`, `s3expressap:name`,
     `s3tables:bucket/name/table/id`, `iam:role/name`).
   - **Directory buckets are S3 Express's** (amended after M11's exit review, A5 and B1): an
     `arn:aws:s3express:…:bucket/…` ARN matches directory buckets only, and `arn:aws:s3:::…` general purpose buckets
     only. A directory bucket's management calls are `s3express:<call>` (CreateBucket, DeleteBucket, its policy,
     encryption and lifecycle calls), and its objects and listings are granted by `s3express:CreateSession` on the
     bucket, as AWS grants them through the session. A directory bucket's access point is `s3expressap:<name>`,
     and S3 Control's calls on it `s3express:`.
   - Another service's action or ARN is MalformedPolicy, and a role whose policy does not parse stops `serve` at
     start, as now.
   - **Principals:** resource policies take `arn:aws:iam::000000000000:user/<name>` beside the key ARNs they take
     now. Another account's user is MalformedPolicy, and so is a user the users file does not have when the policy
     is put (B2). A grant follows the name: a user removed and made again with that name has it again (AWS keys
     principals by a unique id; CosmoStore's users have none).
4. **STS:**
   - **GetSessionToken** by a user: the session is the user's, decided by the user's identity policy.
   - **AssumeRole** by a user needs an identity Allow of `sts:AssumeRole` on `arn:aws:iam::<account>:role/<name>`.
     The account's keys may assume any role, as now.
5. **On a cluster:** every node takes the same users file, as the credentials file, read at start (a node does not
   reload its credentials yet). A shard decides each request as
   `serve` does. The front's merged calls (ListBuckets, ListTableBuckets, ListDirectoryBuckets) are decided on the
   shards that answer them.

## Slices

1. The users file and its reload; resolving a key to its user; the identity policy grammar; the decision on S3
   (service, buckets, objects, S3 Control, directory buckets); principals by user; admin and stats refused.
2. S3 Tables (users and roles' sessions); STS (GetSessionToken, AssumeRole by users).
3. On a cluster.
4. The SDK matrix (a restricted user's key, refused and allowed, in every SDK) and the exit review.

## Consequences

- No new journal record: users are a file, as keys are.
- A request by an account key costs what it costs now. A user's request reads its parsed identity policy, and the
  resource's policy when one exists.
- `docs/compatibility.md`'s "users and accounts" becomes users, one account.

## Rejected

- **The IAM API** (CreateUser, AttachUserPolicy, CreateAccessKey): a service of its own, its users stored in the
  store and replicated. The file is the source of truth, as keys are.
- **Users in the credentials file** (a new line format): it would change ADR-0050's file under every deployment.
  A second file leaves it as it is.
- **Policies as separate documents attached by name** (AWS's managed policies): one inline policy a user is enough
  for one account's needs, and avoids a second namespace.
