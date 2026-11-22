# M21 exit review: IAM for tools (22 Nov 2026)

**M21's exit (ADR-0107 item A; ADR-0108, proposed with the owner's choices):** Terraform's `aws_iam_*` resources apply,
plan with no change and destroy against CosmoStore, on `serve` and a cluster. Behind them are:
- managed policies, their versions and attachments;
- groups;
- tags and paths;
- `UpdateRole` and `UpdateAssumeRolePolicy`;
- the reads Terraform's refresh makes;
- STS's `GetCallerIdentity`.

## How it was checked

- **The evidence:**
  - **Unit tests (440):**
    - the record's form 2 and form 1 read back;
    - identity policies joined from groups and managed policies;
    - AWS's four policies;
    - managed policies' versions, limits and attachments;
    - groups' members, limits and deletes;
    - tags merged and removed;
    - role updates;
    - and, for the review's fixes, joined policies past their size, trust policies naming users with paths, and AWS's
      policies as resources.
  - **The S3 smoke:** the AWS CLI's checks of each new call. Among them:
    - a user allowed what its attached policy's default version allows, and no more;
    - a group member listing by its group's inline policy, and writing by an attached `AmazonS3FullAccess` until it
      is detached;
    - a policy on a user's ARN with its path;
    - `GetCallerIdentity` as the account, a user and a session;
    - and, for the review's fixes, AssumeRole's paths and CreateUser at a Path a policy denies.
  - **`tools/terraform_check.sh` (Terraform 1.9.8, AWS provider 5.80.0):** on `serve` and through one node of a
    three-node cluster:
    1. apply;
    2. a plan with no change;
    3. the key used on S3 as its policies allow;
    4. destroy, with nothing left.
  - **The cluster smoke (206).**
  - **The SDK matrix:** boto3, JS, Java and .NET make the new calls; Go is the Terraform provider's SDK.
- **Runs found bugs before the review:**
  - **Slice 4's smoke:**
    - TagPolicy, UntagPolicy and UpdateAssumeRolePolicy were refused by M19's PolicyName check;
    - UpdateRole's answer had no result element, so the CLI failed after the change was made.
  - **Slice 2's unit tests:** an older test still expected a group's ARN in a policy to be refused.
- **A review by a reader who had not written the code:**
  - **Found:** one High, one Medium-High, two Mediums, one Low-Medium and five Lows.
  - **Reproduced live:** findings 1 to 5, against a built binary.
  - **Read only:** the rest.

## Findings

### A. Fixed before closing

1. **High: one user's joined policy past a policy's size froze the credential set for every user, unsaid.**
   - **Why:** only PutUserPolicy checked the joined policy. Attaching a policy, AddUserToGroup, PutGroupPolicy and
     making a version the default did not. At the reload, `applyUsers` failed the whole set. With no users file, the
     failure was answered as Unchanged, with no line logged, every round.
   - **Reproduced:** four policies of about 5.9 KB attached to one user. Another user's policy and key, deleted, still
     wrote eight seconds later, and a new key stayed unknown.
   - **Fixed, two ways:**
     - **The change is refused.** `applyIamCall` refuses, with LimitExceeded, any change after which a user's or
       role's joined policy that was a policy before is not one. A change that leaves such a record as it was is
       taken, so it can be put right.
     - **The reload fails closed.** A user or role whose policies still do not join is allowed nothing, and said so
       on stderr. The rest of the set is taken.
   - **Tests:** `joinedPoliciesPastTheirSizeAreRefused` covers both.
2. **Medium-High: AssumeRole ignored the role's path.**
   - **What happened:** a RoleArn with any path assumed the role, and the call was decided on `iam:role/<name>`. A
     Deny of `role/svc/*` did not stop it, and an Allow on the real ARN `role/svc/dep` (what Terraform writes)
     answered AccessDenied.
   - **Fixed:** the role set carries each role's path, and a roles file's is `/`. The RoleArn's path must be the
     role's, and the call is decided on `iam:role<path><name>`.
   - **Tests:** the S3 smoke assumes a role by its path. Another path is refused, and so is a policy on the ARN
     without the path.
3. **Medium: CreateUser and CreateRole were decided without their Path.**
   - **What happened:** a Deny on `user/admin/*` did not stop `create-user --path /admin/`.
   - **Fixed:** a user or role not there yet is decided at the Path given.
   - **Tests:** the S3 smoke refuses a user denied `user/admin/*` and lets it make one at `/ok/`.
4. **Medium: a role whose policies did not join left the role set unsaid.**
   - **Fixed with finding 1:** the role is kept, allowed nothing, and said on stderr.
5. **Low-Medium: a trust policy could not name a user with a path.**
   - **What happened:** a trust policy naming `user/tf/dave` refused dave, while one naming `user/dave` let in a dave
     at any path.
   - **Fixed:** the credential set carries each user's path, and a trust policy names the user by its ARN with it.
   - **Tests:** `trustPoliciesNameUsersWithTheirPaths`, and the S3 smoke's assume by a trust naming
     `user/staff/tg`.
6. **Low: GetCallerIdentity on a cluster showed `/` for a user with a path.**
   - **Why:** STS is shard 0's, and that shard may not hold the IAM record.
   - **Fixed:** the path is read from the credential set, as in finding 5.
7. **Low: the record's encoded bytes, with every key's secret, were not wiped after a write.**
   - **Fixed:** they are wiped.
8. **Low: AWS's managed policies could be named in a policy only by `*`.**
   - **Why:** the request side was `iam:foreign/<name>`, while the ARN parses to `iam:foreign/policy/<name>`.
   - **Fixed:** the two now agree.
9. **Low: protocol details.**
   - **Fixed:**
     - `v01` was taken as `v1`;
     - ListUsers and ListRoles ignored `PathPrefix`.
   - **Not fixed:** tag keys (B3).
10. **Low: the record had no bound** on groups or managed policies.
    - **Fixed:** AWS's default quotas are enforced: 300 groups and 1,500 managed policies.
    - **Not bounded:** users, roles and inline policies' total sizes (B2).

### B. Recorded, not fixed

1. **A bucket policy cannot name a user by an ARN with a path.** Such a policy is refused as NotImplemented when it
   is put, so it fails closed. A user at `/` is named as before.
2. **The record's other bounds.** These are:
   - users and roles, which are M19's;
   - the total size of a user's or group's inline policies (AWS: 2,048 and 5,120 characters).

   Each change still rewrites the whole record, and each round joins every user's policies. At AWS's quotas, the
   record stays a few megabytes at most.
3. **Tag keys:** neither unique ignoring case nor checked for IAM's characters. A tool that sends what AWS takes is
   answered as AWS would answer it.
4. **The IAM calls decode the whole record,** every key's secret with it, to decide a resource. This is M19's
   pattern, which M21 extends; finding 7 wipes what is written.
5. **The reload's report.** A users file that fails, unchanged since it last failed, is still answered as Unchanged.
   Since finding 1, nothing of the API's fails the set.

## Where the code differs from ADR-0108

- **§2 ("takes effect within an upkeep round"):** true since finding 1's fix. A change that would make a joined
  policy no policy is refused.
- **§3 ("a policy may name a user or role by an ARN with its path"):** true for identity policies, trust policies,
  AssumeRole and the create calls (findings 2, 3 and 5). Bucket policies are not covered (B1).
- **§6:**
  - **The provider:** the script checks Terraform's SHA-256, and relies on `terraform init` to check the provider's
    signature.
  - **"Nothing left":** it counts the users, groups, roles and the account's policies, which must all be 0, rather
    than reading the record.
- **Not in ADR-0108, added by the review:** the 300-group and 1,500-policy quotas.
