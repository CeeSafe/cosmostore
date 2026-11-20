# ADR-0104: The IAM API, a subset (M19)

**Status:** proposed, 20 Nov 2026. M19 is item A of ADR-0103 (the owner: "A: IAM API"). Users and roles from the
files and from the API live side by side, each name once (the owner's choice).

## Context

- **What the server knows of who signs** (M11 to M15):
  - **Credential sets** (ADR-0050): each access key in a stable place, with its user's name, id and identity policy
    (ADR-0088). They are built from the credentials file and the users file.
  - **Role sets** (ADR-0096): each role in a stable place, built from the roles file.
  - **Reloading:** both are rebuilt when their files change. A request reads them without a lock, and a set is
    replaced whole.
- **What STS already does** (ADR-0075): a form-encoded `POST /` with its own signing service, `sts`, and XML
  answers. IAM's Query protocol is the same shape, signed for `iam`, with IAM's XML namespace.

## Decision (proposed)

1. **The calls,** through a `POST /` signed for `iam` (as STS is for `sts`), `Version=2010-05-08`:
   - **Users:** `CreateUser`, `GetUser`, `ListUsers`, `DeleteUser`. A user has a name, an id (`AIDA…`, made at
     create), an ARN (`arn:aws:iam::000000000000:user/<name>`) and a creation date.
   - **Access keys:** `CreateAccessKey` (its secret answered once), `ListAccessKeys`, `UpdateAccessKey`
     (`Active`/`Inactive`), `DeleteAccessKey`. A user holds two keys at most, as on AWS.
   - **Inline user policies:** `PutUserPolicy`, `GetUserPolicy`, `ListUserPolicies`, `DeleteUserPolicy`.
     - **How they are joined:** a user's identity policy is its policies' statements joined. A policy is checked
       as the users file's are (ADR-0088), and a name holds one.
   - **Roles:** `CreateRole` (with its trust policy), `GetRole`, `ListRoles`, `DeleteRole`; `PutRolePolicy`,
     `GetRolePolicy`, `DeleteRolePolicy` (one inline policy a role).
   - **Errors:** IAM's XML, with its codes: `EntityAlreadyExists`, `NoSuchEntity`, `LimitExceeded`,
     `MalformedPolicyDocument`, `DeleteConflict`, `ValidationError`.
2. **Who may call:**
   - the account's keys;
   - a user whose identity policy allows the call's `iam:<Action>` on its resource (the user's or role's ARN);
   - never a session (STS's): IAM answers it `AccessDenied`, as AWS does without MFA.
3. **Where kept:**
   - **The records:** users, keys, user policies and roles made by the API are records in a hidden bucket,
     `_cosmostore-iam`, as the catalog's are (ADR-0083). Each write is a conditional write of one record, so two
     callers cannot both make a name.
   - **Secrets:** kept as the credentials file keeps them: in the clear, in the store, as durable as any object.
   - **On a cluster:** the bucket lives on a shard, written through its log like any other.
4. **Live at once:**
   - **How a set is built:** the credential and role sets are built from the files and the records together. An API
     user's key goes after the files' keys and keeps its place, as a file's does.
   - **When (amended in slice 2):** within an upkeep round, as a file's change is.
     - **`serve`:** its upkeep (`--maintain-seconds`, 10 s by default) reads the records' generation and rebuilds
       when it changed.
     - **A node:** its reload task does the same every 2 s (ADR-0092).
     - **Why not before the call answers:** the rebuild's state is the upkeep's, so sharing it with request handlers
       would take a rework of the upkeep's loops. AWS's IAM is itself eventually consistent: its documentation has
       changes take seconds to be seen everywhere.
5. **A name once** (the owner's choice):
   - **The files stay the operator's.** The API cannot read their secrets, nor change or delete a file's user, key
     or role. It answers `NoSuchEntity` for those writes, and it lists them as their names only.
   - **Creating a name the files hold** is `EntityAlreadyExists`.
   - **A file that later names an API user's or role's name:** that file entry is skipped and reported, once a
     reload.
6. **Deleting:** as on AWS, a user with keys or policies is `DeleteConflict`, and so is a role with a policy. Delete
   them first. A deleted user's keys are revoked in the next set (their places kept).
7. **Trust policies:**
   - **What is kept:** `CreateRole`'s `AssumeRolePolicyDocument`, answered by `GetRole`.
   - **What is enforced:** for a role made by the API, `AssumeRole` also needs its trust policy to allow the caller,
     as an `AWS` principal (the account, or the user's ARN).
   - **The roles file's roles:** they keep ADR-0088 §4's rule (the caller's identity policy alone).

## Slices

1. The records, and sets built from the files and the records, on `serve`.
2. The users, keys and user policies calls.
3. The roles calls, and trust policies at `AssumeRole`.
4. A cluster: the records through a shard, and every node's sets.
5. The CLI and SDK checks (`aws iam`, boto3, Go, Java, JS, .NET), and the exit review.

## Consequences

- **The store:** a new hidden bucket and its records, so an older binary that opens the store sees the bucket as a
  bucket. It cannot use its users, but it does not fail on them.
- **Secrets at rest:** as the files' secrets are. Encrypting them is not in M19.
