# M11 exit review: identities (19 Nov 2026)

**M11's exit (ROADMAP, M11; ADR-0088, proposed):** a key restricted to one bucket's reads is refused everything else,
through every SDK, on `serve` and on a cluster. A user's request is decided as IAM decides within one account.

## How it was checked

- **The evidence:**
  - **Unit tests:** 377: `usersFileAndKeys`, `identityPoliciesOfEveryService`, `resourcePoliciesNameUsers`,
    `tablesDecideUsersAndRoles`.
  - **The S3 smoke's users server:** 20 checks over S3, S3 Tables, STS and a reload.
  - **The cluster smoke:** 140, with a user through every node.
  - **The SDK matrix:** a restricted user in boto3, Go, JavaScript, Java and .NET.
- **Two reviews by readers who had not written the code:**
  - **Security:** every call site of the decision, with attacks run against a server. Six findings were reproduced.
  - **Conformance:** with IAM's evaluation and grammar, using the AWS CLI's botocore models where they name
    actions. Points from memory are marked *memory*.

## The item

| Done when | Evidence | Verdict |
|---|---|---|
| A restricted key is refused everything else | smokes, every SDK | **does not hold: A1, A2** |
| IAM's decision within one account | unit tests, smokes | holds for direct calls; **A3–A6, B1–B4** |
| On `serve` and a cluster | both smokes | holds |

## Findings

### A. A user reaching past its policy

1. **High: a user writes into any bucket through its own bucket's replication** (reproduced).
   - **Where:** PutBucketReplication checks only that the destination exists and is versioned
     (`replication.cee:209`).
   - **The attack:** a user refused PutObject on `victim` sets replication from its own bucket to `victim`, and its
     objects (and delete markers) appear there.
   - **The same, from reading:** an inventory destination (`inventory.cee:195`) and a logging target
     (`access_log.cee:114`) let a user have the server write where it may not.
2. **High: deleting a user's line makes its keys the account's** (both reviews; reproduced).
   - A key no user names is the account's (ADR-0088 §1). So removing a user, emptying the users file, or starting
     without `--users-file` gives its keys, and their live GetSessionToken sessions, every right of the account.
   - The natural way to remove a user escalates it.
3. **Medium: a revocation is blocked while the users file still names the key** (both reviews; reproduced).
   - Removing a key from the credentials file fails the whole reload ("a user names a key the credentials file does
     not have", line 0, no key named), so the key stays live.
   - It defeats ADR-0050's revocation.
4. **Medium: ACL, tagging and object lock headers on a write need only `s3:PutObject`** (reproduced).
   - `x-amz-acl: public-read` and `x-amz-tagging` succeed though the user's policy denies `s3:PutObjectAcl` and
     `s3:PutObjectTagging`.
   - **From reading:** `x-amz-object-lock-mode: COMPLIANCE` passes a Deny on `s3:PutObjectRetention`, and CreateBucket
     with `x-amz-acl` needs only `s3:CreateBucket`.
   - AWS authorizes each header's own action (*memory*).
5. **Medium: an `s3express` ARN grants general-purpose buckets** (reproduced). `identityResourcePattern` maps
   `arn:aws:s3express:…:bucket/*` to `s3:*`, the namespace of every bucket. So a policy written for directory buckets
   reads `victim`.
6. **Medium: access points** (both reviews).
   - **Deny ignored:** an identity Deny on an access point ARN (`s3ap:…/object/…`) is never applied to object calls,
     which are decided on `s3:<bucket>/<key>` only.
   - **Allow ignored:** an access point policy's Allow for a user counts for nothing, against ADR-0088 §2.
   - **A bucket Allow alone is enough:** a bucket policy's Allow lets a user in through an access point. AWS wants
     the access point and the bucket each to allow (*memory*).

### B. Conformance

1. **Medium: directory buckets use `s3:` actions for users.**
   - CreateBucket of a directory bucket is decided as `s3:CreateBucket`; AWS's is `s3express:CreateBucket` (botocore).
   - A session's data calls need `s3:GetObject` and the like on `s3:<dir>/<key>`. AWS grants them through
     `s3express:CreateSession` alone (botocore).
   - S3 Control on a directory bucket's access point is named `s3:*`, and AWS's `arn:aws:s3express:…:accesspoint/`
     form is refused (*memory*).
2. **Medium: resource policies may name users that do not exist, of any account.**
   - `arn:aws:iam::999999999999:user/alice` and `…::*:user/alice` both match the local alice.
   - A misspelled user in a Deny denies no one, where AWS answers MalformedPolicy (*memory*).
   - Grants follow a name, so they pass to a later user of the same name (AWS keys principals by unique id).
3. **Low: a bucket policy naming a key also applies to role sessions its user assumed** (`who.key` is the parent's).
4. **Low: identity-only calls with no resource type** (ListTableBuckets, ListAllMyBuckets) match ARN wildcards such
   as `arn:aws:s3tables:*:*:bucket/*`; AWS matches `"*"` (*memory*).
5. **Low: HeadBucket on any table warehouse** answers 200 to a user or role, by `gateDecision`'s warehouse bypass;
   a probe for table buckets. It should need `s3tables:GetTableBucket`.
6. **Low: smaller.**
   - A role's path is dropped from the ARN checked (a refusal, not a grant).
   - A user's GetSessionToken session cannot AssumeRole (before M11).
   - **The users file:**
     - user names are case-sensitive (IAM's are not, *memory*);
     - a key named twice in one line reads "two users";
     - errors say "line 0" and name no key.
   - `userOfRequester` reads the current set at each call, so a key revoked between authentication and
     authorization falls to the account's fast path for that request.
7. **Info:** identity `NotAction`/`NotResource` and `*` now reach `sts:`, `s3tables:` and `iam:role/`, so roles'
   policies written before M11 now reach S3 Tables. That is AWS's semantics, worth an upgrade note.

Checked and right (both reviews):
- **The evaluation:**
  - every S3 route's decision, and DeleteObjects per key, the copy source, versions, tagging, ACLs, retention, legal
    hold and governance bypass;
  - POST forms, presigned URLs, CreateSession and express tokens;
  - a user always gets a decision, never the account's fast paths;
  - Deny wins; Allow in identity or resource.
- **Account-only, services and STS:**
  - policy calls need an Allow;
  - stats and admin refused;
  - S3 Control by identity;
  - `sts:AssumeRole` checked before the role's lookup;
  - a session cannot call STS.
- **S3 Tables:** every route, Iceberg and maintenance-run included. Roles are AND-ed with their session policy, and
  the warehouse's data is checked as GetTableData and PutTableData.
- **The grammar:**
  - only four services;
  - Principal refused in identity policies;
  - unknown condition keys refused;
  - actions case-insensitive, resources case-sensitive.
- **Principals:** keys and users are matched in separate lists, so neither is confused with the other.
- **The users file:** a bad reload keeps the old users, and either file's change reloads both.
- **The cluster:** shards decide merged lists.

## Verdict

**M11 should not close yet.**
- **A1** lets a restricted user write any bucket.
- **A2** turns removing a user into giving it the account.
- **A3 to A6** are other ways past a policy or a revocation.

**The recommendation:**
- **Fix A and B,** each with a test.
- **A2 and A3 need a rule of the owner's**, since ADR-0088 §1 made a key no user names the account's:
  - **(a) Account keys named:** the users file names the account's keys (an `account` line), and any key neither
    names is refused (fail closed); or
  - **(b) Refuse such a reload:** a reload that leaves a user's key unnamed is refused, and a key removed from the
    credentials file is revoked even when a user names it (that user loses the key).

  (a) is the safer, and (b) changes nothing for deployments without users.

Closing M11 and accepting ADR-0088 are the owner's decisions.
