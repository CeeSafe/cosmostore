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

1. **The users file** (`serve --users-file`, `node --users-file`): one user a line, `<name> <access key>[,<access
   key>…] <identity policy JSON>`, `#` for comments.
   - **Names:** 1 to 64 of `A-Za-z0-9+=,.@_-`, as IAM's.
   - **Keys:** each named key must be in the credentials file and belong to one user only. A key no user names is
     the account's, as every key is now. So a deployment without a users file changes nothing.
   - **The policy:** an identity policy, `parseIdentityPolicy`'s grammar widened as §3 says. A user with several of
     AWS's policies writes their statements into one.
   - **Reloads:** it is reloaded with the credentials file, whenever either changes. A file that does not read, or
     names a key the credentials do not have, changes nothing and is reported, as ADR-0050's file is. Each key's
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
3. **Identity policy grammar** (roles' and users'):
   - **Actions:** `s3:`, `s3express:`, `s3tables:`, `sts:`.
   - **Resources:** `*`, or the ARNs of §Context, with any region and account, matched by service and the part
     after its prefix (`s3:bucket/key`, `s3express:bucket/name`, `s3tables:bucket/name/table/id`, `iam:role/name`).
   - Another service's action or ARN is MalformedPolicy, and a role whose policy does not parse stops `serve` at
     start, as now.
   - **Principals:** resource policies take `arn:aws:iam::<account>:user/<name>` beside the key ARNs they take now.
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
