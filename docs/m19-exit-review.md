# M19 exit review: the IAM API subset (21 Nov 2026)

**M19's exit (ADR-0103 item A; ADR-0104, proposed):** users, access keys, inline user policies and roles with trust
policies made through the IAM API, on `serve` and a cluster. Their keys and roles work on S3 and STS within an upkeep
round, through the AWS CLI and every SDK of the matrix.

## How it was checked

- **The evidence:**
  - **Unit tests (421):**
    - the record's codec;
    - the merge of the files and the records into the credential and role sets, with a name once;
    - users without policies allowed nothing;
    - each call's change to the record, and its refusals;
    - trust policies: who they let assume a role, and what they hold that fails closed.
  - **The S3 smoke:**
    - **Users:** a user, key and policy made; the key working within a round and no further; made inactive; its
      deletes.
    - **Roles:** a role made, given a policy and assumed; one whose trust names someone else, refused; the trust
      policies a role may not be made with.
    - **The hidden bucket:** each path to it refused (listing, copy and part copy sources, a log's target, an
      inventory's destination, an access point's bucket).
    - **Authorization:** a list on oneself refused, and a bad policy name refused.
  - **The cluster smoke (193):**
    - a user made through node 1 and listed through node 2;
    - its key working through every node, and no further than its policy;
    - the user deleted through node 3, and its key refused after;
    - `/cluster/iam` answering a signed ask, and refusing an unsigned one and one under another secret.
  - **The SDK matrix:** boto3, Go, Java, JS and .NET each make a user, key, policy and role, use the key and the
    role, delete them all, and see the key refused (14 checks each).
- **A review by a reader who had not written the code:** one High, two Mediums and several Lows, most reproduced
  against `serve`.

## Findings

### A. Fixed before closing

1. **High: a copy read the hidden bucket, and with it every API user's secret.**
   - **How:** `copy-object --copy-source _cosmostore-iam/state`, or `upload-part-copy`, by any user allowed `s3:*`,
     wrote the record to a bucket of theirs.
   - **The effect:** signing as any API user, including one allowed `iam:*`, and so making any user or policy.
   - **Why:** the guard looked only at the request's own bucket, and a copy's source is a header.
   - **Fixed:** a hidden bucket is never a copy's source, a log's target, an inventory's or replica's destination,
     or an access point's bucket (ADR-0104 §3, amended).
2. **Medium: trust policies' Condition and NotPrincipal were ignored, and wildcard Denies missed.**
   - **The effect:** a role was assumed by callers its policy did not name (reproduced), and a Deny of
     `sts:Assume*` denied nothing.
   - **Fixed:** `CreateRole` refuses what is not decided, and a stored policy with it allows nobody (§7, amended).
3. **Medium: a node's ask of a peer's `/cluster/iam` was refused.**
   - **Why:** nodes sign such asks as the operator, and that endpoint did not take the operator's signature.
   - **The effect:** a node without a replica of the records' shard never took API users' keys. One that lost its
     replica would have kept deleted keys live.
   - **Why the smoke missed it:** its three nodes each hold a replica.
   - **Fixed:** the endpoint takes it, and the cluster smoke now asks it directly.
   - **Also fixed:** a node never takes records older than ones it has seen (§4, amended).
4. **Low: authorization was on the name as given, not the record's.**
   - **The effect:** a policy on `user/BOB` allowed acting on `bob`, and ListUsers allowed on oneself listed every
     user.
   - **Fixed:** the record's name, and `*` for lists (§2, amended).
5. **Low, smaller fixes:**
   - an empty or ill-formed PolicyName was taken;
   - a presigned IAM request on a cluster went to shard 0, not the records' shard;
   - the files' entries skipped for an API name were not logged, as §5 says they are;
   - the hidden bucket could be a log's target, an inventory's destination or an access point's bucket (objects
     could land in it, but never as its record).
6. **During the milestone:**
   - **The cluster's first IAM write failed** (slice 4). The first call made the bucket and wrote the record in one
     request, and a leader's writes apply only when they commit, so the write did not see the bucket. The shard's
     leader now makes the bucket (§3, amended).
   - **The new boto3 checks found a deleted user still listed:** until the next round, its entry in the live set
     was taken for a users file's user. A credential now records whether it is the API's.

### B. Recorded, not fixed

1. **Low: roles are matched by name.** Deleting a role and making one of the same name lets the old role's sessions
   act with the new role's policy. The roles file already behaves so (ADR-0096).
2. **Low: the files' users without a live key can be shadowed.** CreateUser can take the name of a users file's
   user that has no key, and that entry is then skipped (now logged).
3. **Low: a deleted user's key keeps working until the next round** (up to `--maintain-seconds`, 2 s on a node), as
   §4 chose. AWS's IAM is itself eventually consistent.
4. **Low, compatibility:**
   - ListRoles and GetRole do not show the roles file's roles, while ListUsers shows the users file's users;
   - ListAccessKeys with the account's key and no UserName answers NoSuchEntity, where AWS lists the root's keys;
   - ServiceFailure is sent as a Sender error (AWS: Receiver);
   - the account part of an IAM ARN is not checked.
5. **Not done:** groups, managed policies, permission boundaries, MFA, login profiles, tags on users and roles, and
   the access keys' last-used data.

## Decisions for the owner

**Taken, 21 Nov 2026** (the owner: "Accept and close"): ADR-0104 accepted as amended, and M19 closed once CI passed on
its last commits (a7de6aa, 4507f70).

- **Accept ADR-0104,** with its amendments:
  - §2: authorization is on the record's name, and `*` for lists;
  - §3: the shard's leader makes the bucket, and the bucket is no client's in any role;
  - §4: nodes read their replica or a peer's `/cluster/iam`, and never older records;
  - §7: trust policies hold only what is decided.
- **Close M19.**
