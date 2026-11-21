# ADR-0108: IAM for tools: managed policies, groups, tags, and Terraform (M21)

**Status:** proposed, 22 Nov 2026, with the owner's choices made: AWS's four managed policies that matter here ("The
four that matter"), and the Terraform check run locally ("Locally"). M21 is item A of ADR-0107 (the owner: "A: IAM for
tools"), with Terraform as the bar (the owner: "Terraform").

## Context

- **M19** (ADR-0104) gave the IAM API users, access keys, inline user policies, and roles with trust policies and inline
  policies.
  - **Where they live:** in one JSON record of the hidden bucket `_cosmostore-iam`, merged with the files into the
    credential and role sets each upkeep round, on `serve` and a cluster.
- **What a tool needs beyond that:** Terraform's `aws_iam_*` resources need managed policies and their attachments,
  groups, tags and paths. Their refresh reads more besides. `terraform apply` of a lone `aws_iam_user` stops today:
  - the provider asks STS's `GetCallerIdentity` first;
  - its refresh calls `ListUserTags`, and both answer InvalidAction.
- **The rule M19 set stays:** a name once, and the files are the operator's. The API neither makes nor changes what
  they hold.

## Decision (proposed)

1. **The record grows** (its JSON's `version` goes from 1 to 2):
   - **Managed policies:** a name, an id (`ANPA…`), a path, a description, tags, and up to five versions (`v1`…), one
     of them the default. Their ARN is `arn:aws:iam::000000000000:policy<path><name>`.
   - **Groups:** a name, an id (`AGPA…`), a path, their members (user names), inline policies, and attached managed
     policies.
   - **Users and roles:** a path, tags and attached managed policies. Roles also have a description.
   - **Limits:** AWS's. 10 managed policies attached to a user, group or role; 5 versions of a policy; 50 tags on a
     user, role or policy; 10 groups for a user.
2. **What a user or role may do.**
   - **A user's identity policy** joins:
     - its inline policies;
     - its attached policies' default versions;
     - each of its groups' inline and attached policies.
   - **A role's policy** joins its inline policies and its attached policies' default versions.
   - **One evaluation:** the joined statements are decided as M19's are (ADR-0088's evaluation); nothing new.
   - **A version made the default** takes effect within an upkeep round, as any IAM change does (ADR-0104 §4).
3. **The calls added.**
   - **Managed policies:** `CreatePolicy`, `GetPolicy`, `ListPolicies`, `DeletePolicy`, `CreatePolicyVersion`,
     `GetPolicyVersion`, `ListPolicyVersions`, `DeletePolicyVersion`, `SetDefaultPolicyVersion`,
     `ListEntitiesForPolicy`.
     - **Refused, as AWS does:** deleting a policy that is attached, or has versions besides its default
       (DeleteConflict); a sixth version (LimitExceeded).
   - **Attachments:** `Attach`, `Detach` and `ListAttached` of `UserPolicies`, `GroupPolicies` and `RolePolicies`.
   - **Groups:**
     - `CreateGroup`, `GetGroup` (with its users), `ListGroups`, `DeleteGroup` (DeleteConflict while it has
       members or policies);
     - `AddUserToGroup`, `RemoveUserFromGroup`, `ListGroupsForUser`;
     - `PutGroupPolicy`, `GetGroupPolicy`, `ListGroupPolicies`, `DeleteGroupPolicy`.
   - **Tags:** `TagUser`, `UntagUser`, `ListUserTags`, and the same for roles and policies. The `Tags` of
     `CreateUser`, `CreateRole` and `CreatePolicy` are kept.
   - **Changes:** `UpdateRole` (its description and maximum session) and `UpdateAssumeRolePolicy`.
   - **Paths:** kept and shown in every answer and ARN. A policy may name a user or role by an ARN with its path.
   - **The reads Terraform's refresh and destroy make, answered as AWS answers them for what CosmoStore has none of:**
     - `GetAccessKeyLastUsed`: no use recorded, the region and service `N/A`;
     - `ListInstanceProfilesForRole`: none;
     - `GetLoginProfile`: NoSuchEntity;
     - `ListMFADevices`, `ListSSHPublicKeys`, `ListServiceSpecificCredentials`, `ListSigningCertificates`: none.
   - **STS's `GetCallerIdentity`:** the caller's account (`000000000000`), its ARN (the root's, a user's, or an assumed
     role's session) and its user id.
   - **Who may call:** as ADR-0104 §2. Each call's `iam:<Action>` is decided on its resource: the user's, group's,
     role's or policy's ARN, or `*` for a list.
4. **AWS's own managed policies** (`arn:aws:iam::aws:policy/…`) are the owner's to decide, below.
   - **Recommended:** the four that mean something to this store, each a fixed document: `AdministratorAccess`,
     `AmazonS3FullAccess`, `AmazonS3ReadOnlyAccess` and `IAMReadOnlyAccess`. Any other is NoSuchEntity.
5. **The files stay as they are.** Groups, managed policies and tags are the API's only. A file's user can be added to
   no group, since the API does not change what the files hold.
6. **The check:** `tools/terraform_check.sh`.
   - **The tools:** Terraform and its AWS provider, pinned versions checked against HashiCorp's SHA-256 sums,
     downloaded into a scratch directory, as the SDKs are.
   - **The configuration:** every resource below, against `serve`, then against a cluster through one node.
     - **The resources:** `aws_iam_user`, `aws_iam_access_key`, `aws_iam_group`, `aws_iam_group_membership`,
       `aws_iam_user_group_membership`, `aws_iam_policy`, `aws_iam_user_policy_attachment`,
       `aws_iam_group_policy_attachment`, `aws_iam_role`, `aws_iam_role_policy`, `aws_iam_role_policy_attachment`
       and `aws_iam_user_policy`, with tags and a path.
     - **The steps:** `apply`; a `plan` that shows no change (`-detailed-exitcode` 0); the access key used on S3 within
       a round; `destroy`, after which the IAM record is empty.
   - **It runs locally,** as the SDK matrix does: CI needs no network for it.

## Slices

1. The record's version 2, and the identity policies joined from groups and managed policies, on `serve`.
2. Managed policies, their versions and attachments.
3. Groups and their memberships and policies.
4. Tags, paths, `UpdateRole`, `UpdateAssumeRolePolicy`, the refresh's reads, and `GetCallerIdentity`.
5. `tools/terraform_check.sh` against `serve`, then a cluster. The CLI's and SDKs' checks of the new calls.
6. The exit review.

## For the owner to decide

- **AWS's own managed policies:**
  - **The four that mean something here (recommended):** `AdministratorAccess`, `AmazonS3FullAccess`,
    `AmazonS3ReadOnlyAccess` and `IAMReadOnlyAccess`, each a fixed document. A configuration that attaches one
    applies.
  - **None:** every `arn:aws:iam::aws:policy/…` is NoSuchEntity, and a configuration must make its own.
- **The Terraform check:**
  - **Locally, as the SDK matrix (recommended):** `tools/terraform_check.sh`, run before each slice is committed and
    at the exit review.
  - **In CI too:** a job that downloads Terraform and the provider on every push.

## Consequences

- **Older binaries:** the IAM record's version 2 is refused by a binary from before it, which keeps the files' sets
  alone. A store moved back to an older binary loses the API's users and roles until it is moved forward again.
- **Size:** the record grows with groups and policies. At AWS's limits, a thousand users with a policy each stays well
  under a megabyte. The record is read whole each round, as in M19.
