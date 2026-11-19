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

## The fixes (19 Nov 2026)

The owner chose (a): the users file names the account's keys.

| Finding | Fix | Test |
|---|---|---|
| A1 | a user's or session's replication destination needs `s3:ReplicateObject` (`s3:ReplicateDelete` with delete markers), an inventory's or logs' target `s3:PutObject`, when put | S3 smoke: replication and logging into `other` refused |
| A2 | `account <key>[,…]` lines; with a users file, a key named neither way is refused (InvalidAccessKeyId) | `usersFileAndKeys`; S3 smoke: a removed user's key refused |
| A3 | a key the credentials file lacks is no one's, so its removal revokes it; errors name the key | `usersFileAndKeys` |
| A4 | ACL, tags, retention and legal hold on writes (PUT, copy, multipart, POST form) need their own actions; CreateBucket's ACL and object lock too | S3 smoke: an ACL without `s3:PutObjectAcl` refused |
| A5 | `arn:aws:s3express:…` ARNs are `s3express:`, matching directory buckets only | `exitReviewRulesOfM11` |
| A6 | through an access point, a user needs the access point (identity on `s3ap:` or its policy) and the bucket to allow; a Deny on either refuses | (by reading; no access point in the users smoke) |
| B1 | a directory bucket's calls are S3 Express's: management `s3express:<call>`, data `s3express:CreateSession`; S3 Control on its access points `s3express:`, `s3expressap:<name>` | `exitReviewRulesOfM11` |
| B2 | a user principal must be of account `000000000000` and in the users file when the policy is put | `exitReviewRulesOfM11` |
| B5 | HeadBucket on a warehouse needs `s3tables:GetTableBucket` | S3 smoke: the intern's probe refused |
| B6 | a key revoked mid-request is refused, not the account's; user names unique ignoring case; a key named twice in one line | `usersFileAndKeys` |

**Also:**
- The cluster's own replication picks an account key, never a user's.
- B3 (a key principal matching that key's user's role sessions) and B4 (no-resource calls matching ARN wildcards) stay open. Both are Low, and B3 predates M11.

**Checked after the fixes:**
- 378 unit tests;
- the S3 smoke (all passed);
- the cluster smoke (138, none failed);
- the SDK matrix (five SDKs).

**Upgrade note:** a deployment already using `--users-file` must add an `account` line naming its account keys, or they are refused.

## A second reading of the fixes (19 Nov 2026)

A fresh reviewer read the fixes and probed a server built from them. It found A2, A3, A5, B1, B2 and B5 sound, and A4 and A6 sound for users.

| # | Finding | Fix | Test |
|---|---|---|---|
| 1 | Medium (reproduced): a destination was checked on the literal `<bucket>/*`, so a Deny on a narrower prefix (`bkt/secret/*`) did not apply, and the rule's prefix was not checked | the destination is checked on its prefix (`<prefix>*`), and any Deny of the requester's policies or the bucket's that could reach a key under the prefix refuses, its conditions taken to hold | `destinationsSeeEveryDenyUnderTheirPrefix` |
| 2 | Medium: another endpoint's destination skipped the check, so a user could write there with the operator's keys | users and sessions may not name one (AccessDenied) | (by reading) |
| 3 | Medium-Low (reproduced): role sessions through an access point did not read the access point's ARN | a role's session's policies must allow the access point too | (by reading) |
| 4 | Low-Medium: replication into a table warehouse on a cluster | refused for every requester (InvalidRequest), as inventory and logging already were | (by reading) |
| 5 | Low (reproduced): CopyObject's default directive copied tags without the tagging actions | `s3:GetObjectTagging` on the source and `s3:PutObjectTagging` on the target when tags are copied | (by reading) |
| 6 | Low: a key revoked mid-request was still the account's in S3 Tables, S3 Control and the stats check | `userOfRequester` returns a revoked place too (no user, no policy), and S3 Tables refuses it | (by reading) |
| 7 | Low: a stored policy naming another account's user would read as malformed after the upgrade | the account is checked when a policy is put; a stored one reads, and names no user here | `exitReviewRulesOfM11` |

**Still open, with B3 and B4:** grants follow a user's name, so a user removed and made again with that name has
them again.

**Upgrade notes:**
- A deployment with a users file needs an `account` line naming its account keys.
- Replication, inventory and logging configurations that users set before these fixes were not checked: re-put
  them, or check them, after upgrading.
