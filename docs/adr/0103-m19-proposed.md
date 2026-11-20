# ADR-0103: M19, what comes after archive storage classes (proposed)

**Status:** proposed, 20 Nov 2026. The owner: "propose M19". M18 (archive storage classes, ADR-0102) closed the same
day.

## Context

- **Users and roles come only from files** (M11 to M15):
  - the users file names the account's keys, the users with their ids, keys and identity policies;
  - the roles file names roles and their policies;
  - both reload without a restart (ADR-0088, ADR-0096);
  - STS issues sessions for roles (ADR-0075).
  - **What a client cannot do:** create a user, an access key or a role, or attach a policy, through an API. Tools
    that manage IAM (the AWS CLI's `iam`, Terraform's `aws_iam_*`, SDK test fixtures) cannot set CosmoStore up.
- **Recorded Lows, M15 to M18:** about twenty, in the four exit reviews. Most are small; a few touch security:
  - a KMS key named in a request can be sealed under between a node's count and its take (M17 B4);
  - some key bytes are not wiped (M17 B2);
  - an archived GET checks conditions before its class (M18 B2).
- **Left by M16:** compaction that re-encodes waits on codecs in CeeSafe (G40).

## Decision (proposed)

1. **M19 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | The IAM API, a subset | **Calls**, through `iam` signing (Query protocol, XML answers): `CreateUser`, `GetUser`, `ListUsers` and `DeleteUser`; `CreateAccessKey`, `ListAccessKeys`, `UpdateAccessKey` and `DeleteAccessKey`; `PutUserPolicy`, `GetUserPolicy`, `ListUserPolicies` and `DeleteUserPolicy`; `CreateRole`, `GetRole`, `ListRoles`, `DeleteRole`, `PutRolePolicy`, `GetRolePolicy` and `DeleteRolePolicy`. **Where kept:** users, keys and roles made so are kept in the store, durable and on a cluster through a shard's log. **What they do:** they are decided as the files' are, and live at once. **Who may call:** the account (its keys), or a user whose identity policy allows `iam:*` actions. **Clients:** the AWS CLI's `iam` and the SDKs manage a user end to end, and its key then works on S3. |
   | B | The recorded Lows | **Each Low** of M15 to M18's exit reviews is fixed, or decided to stay with why. **First, the security ones:** the KMS race, key bytes, and condition order. |
   | C | Compaction that re-encodes | zstd and snappy in plain CeeSafe, and Parquet's encodings. Compaction then merges row groups and applies deletes. |

2. **The recommendation is A.**
   - **Why:**
     - it is the most-asked gap for real clients: setting a store up by IAM calls, as on AWS, is what tools and tests
       do;
     - every M11 to M15 piece it needs is there: users, ids, identity policies, roles and their sessions, all decided
       already.
   - **What it must decide:** how the store's users and the files' live together.
3. **B is worth its own milestone** after A. Its items are small, each with a fix known.
4. **C waits for G40,** as before.
5. **Not in M19:**
   - groups;
   - managed policies (ARN-attached);
   - permission boundaries;
   - MFA;
   - SAML and OIDC federation;
   - a KMS service;
   - SNI and HTTP/2.

## For the owner to decide

- **Which item is M19:** A (recommended), B or C.
- **For A, the store's users beside the files':**
  - **Both, a name once (recommended):**
    - the files stay the operator's, and the API's users and roles are kept in the store;
    - a name in both is refused when the API creates it, and a file that names an API user's name is reported and
      that file entry skipped;
    - the API cannot change or delete a file's user or role.
  - **The store only:** the files are read once, as a seed, and from then on IAM calls manage everyone.

## Consequences

- One design ADR follows the choice, with its slices.
- **For A:** new catalog records for users, keys and roles, so an older binary cannot open a store that has them.
