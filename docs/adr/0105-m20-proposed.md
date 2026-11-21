# ADR-0105: M20, what comes after the IAM API (proposed)

**Status:** decided, 21 Nov 2026: the owner chose A ("A: the recorded Lows"), every Low fixed or decided to stay,
the security ones first; ADR-0106 designs it. Proposed the same day. The owner: "propose M20". M19 (the IAM API subset, ADR-0104) was accepted and
closed the same day, its close written once CI passes on its last commits.

## Context

- **Recorded Lows:** 26 across M15 to M19's exit reviews, five a milestone. ADR-0103 §3 kept them for their own
  milestone, after the IAM API. A few touch security:
  - **M17 B4:** a KMS key named in a request can still be sealed under, between a node's count and its take.
  - **M17 B2 and M15 B2:** not every copy of a key's bytes is wiped, and old secrets stay in memory for the
    process's life.
  - **M18 B2:** an archived GET checks its conditions and range before its class, so it answers 304 or 416 where it
    should refuse with 403.
  - **M19 B1:** a role deleted and made again under its name lets the old role's sessions act with the new role's
    policy.
  - **M19 B2:** CreateUser can take the name of a users file's user that has no key.
- **IAM beyond M19's subset:** tools that set up IAM need more than inline policies.
  - **What Terraform's `aws_iam_*` calls:** managed policies (`CreatePolicy`, `AttachUserPolicy`,
    `AttachRolePolicy`, `ListAttached*`), groups, and tags on users and roles. Its reads also call
    `GetAccessKeyLastUsed` and `ListInstanceProfilesForRole`.
  - **Today:** those calls answer InvalidAction.
- **Compaction that re-encodes:** this still waits on G40, as CeeSafe's libraries have no zstd or snappy. Writing
  them in plain CeeSafe is allowed (CosmoStore carries its own inflate), but zstd alone is a large piece.

## Decision (proposed)

1. **M20 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | The recorded Lows | **Each Low** of M15 to M19's exit reviews is fixed, or decided to stay with a reason. **The security ones come first:** the KMS race, wiping key bytes, the archived GET's order, role ids in sessions, and the files' names held. |
   | B | IAM for tools | **Managed policies:** `CreatePolicy`, `GetPolicy`, `GetPolicyVersion`, `ListPolicies`, `DeletePolicy`; `Attach`/`Detach`/`ListAttached` `UserPolicies` and `RolePolicies`. **Groups:** `CreateGroup`, `AddUserToGroup` and their reads, with group inline and managed policies. **Tags:** on users and roles. **The reads Terraform makes.** **Done when** Terraform's `aws_iam_user`, `aws_iam_access_key`, `aws_iam_role`, `aws_iam_policy` and their attachments apply and destroy cleanly. |
   | C | Compaction that re-encodes | **Codecs:** zstd and snappy decoders and encoders, in plain CeeSafe. **Then:** Parquet's encodings. **Compaction then:** merges row groups and applies deletes. |

2. **The recommendation is A.**
   - **Why:**
     - its security Lows are real if small, and each has a known fix;
     - five milestones' worth are now waiting;
     - fixing them before building more keeps the next reviews short.
   - **What it must decide:** whether every Low is in M20, or the security ones plus those whose fix is under a day,
     with the rest decided to stay.
3. **B is the natural next milestone after A.** M19 built everything it needs: the records, policy decisions,
   and the merge into the sets.
4. **C still waits for G40,** unless the owner wants the codecs written here.
5. **Not in M20:**
   - permission boundaries;
   - MFA;
   - SAML and OIDC federation;
   - a KMS service;
   - SNI and HTTP/2.

## For the owner to decide

- **Which item is M20:** A (recommended), B or C.
- **For A, its reach:**
  - **Security first, then the rest (recommended):** each of the 26 is fixed or decided to stay. The six above come
    first, each in its own slice.
  - **The security ones only:** the six; the rest stay recorded.

## Consequences

- One design ADR follows the choice, with its slices.
- **For A:** an API role's sessions name its id (`AROA…`) as users' grants do, so a session from before a role was
  made again is refused. Sessions issued before the change that do not name an id stay valid until they expire.
