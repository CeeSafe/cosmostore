# ADR-0107: M21, what comes after the recorded Lows (proposed)

**Status:** decided, 22 Nov 2026: the owner chose A ("A: IAM for tools"), with Terraform as the bar ("Terraform");
ADR-0108 designs it. Proposed the same day. The owner: "Propose M21". M20 (the recorded Lows, ADR-0106) was closed on 21 Nov
2026. CeeSafe's gaps were then worked down at the owner's word: CeeSafe ADRs 0194 to 0198 were released in 0.85.1,
0.87.0 and 0.90.0, and CosmoStore runs on 0.90.0.

## Context

- **What tools cannot do yet** (ADR-0105's item B): set up IAM as they do on AWS. M19 built users, keys, inline
  policies and roles.
  - **What Terraform's `aws_iam_*` resources need beyond that:**
    - managed policies (`CreatePolicy`, `GetPolicy`, `GetPolicyVersion`, `ListPolicies`, `DeletePolicy`) and their
      attachments (`Attach`/`Detach`/`ListAttached` `UserPolicies` and `RolePolicies`);
    - groups;
    - tags on users and roles;
    - the reads its refresh makes (`GetAccessKeyLastUsed`, `ListInstanceProfilesForRole`, `ListRolePolicies`).
  - **Today** those calls answer InvalidAction, so `terraform apply` of an `aws_iam_user` stops at its first refresh.
- **Table maintenance on a cluster** (M16 B5, decided as an item of its own in M20):
  - a run is one leader write, so it holds its shard's write gate from start to end;
  - a long compaction holds up that shard's other writes, as well as running into the front's 30 s timeout;
  - the fix splits a run into gated writes, each bin's put and then the commit, with the copy between them outside the
    gate;
  - it has not been seen at test sizes.
- **Compaction that re-encodes** (ADR-0105's item C):
  - CeeSafe 0.90.0 has deflate and gzip;
  - snappy and zstd, PyIceberg's and Spark's defaults for Parquet pages, are ADR 0196's phases 2 and 3, accepted and
    not built;
  - this still waits on them.

## Decision (proposed)

1. **M21 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | IAM for tools | **Managed policies:** create, get, version, list, delete; attached to users, groups and roles, and listed. **Groups:** create, get, list, delete; users added and removed; a group's inline and attached policies joined into its users' identity policies. **Tags** on users, roles and policies. **The refresh's reads.** **Done when** Terraform's `aws_iam_user`, `aws_iam_access_key`, `aws_iam_group`, `aws_iam_group_membership`, `aws_iam_role`, `aws_iam_policy` and their attachments apply, plan clean and destroy against CosmoStore, on `serve` and a cluster. |
   | B | Table maintenance on a cluster, as gated writes | **What changes:** a cluster leader's compaction is a run of gated writes: each bin's file put, then the commit, with the bytes copied outside the gate. The other jobs follow it. **Done when** a write to the shard goes through while its compaction copies, and a run longer than the front's timeout completes. |
   | C | Compaction that re-encodes | **What it needs first:** CeeSafe's snappy and zstd (ADR 0196's phases 2 and 3). **Then:** Parquet's encodings, row groups merged, deletes applied. |

2. **The recommendation is A.**
   - **Why:**
     - it is the gap a client meets first: an operator who sets up a store with Terraform cannot today;
     - everything it needs is in place: M19's records, policy evaluation and the sets they merge into;
     - ADR-0105 named it the next milestone after M20.
   - **What it must decide:** whether Terraform is the bar, run here against the store, or the AWS CLI and SDKs alone,
     as M19 was.
3. **B is the next, or a slice of whichever comes next,** when compaction runs on a cluster at real sizes. Its risk is
   a stall, not a wrong answer.
4. **C waits on CeeSafe's codecs,** which are its first half.
5. **Not in M21:**
   - permission boundaries;
   - MFA;
   - SAML and OIDC federation;
   - a KMS service;
   - SNI and HTTP/2;
   - service-linked roles and instance profiles, beyond the empty reads Terraform's refresh makes.

## For the owner to decide

- **Which item is M21:** A (recommended), B or C.
- **For A, the bar:**
  - **Terraform (recommended):** a Terraform configuration of every resource above applies, plans with no change, and
    destroys, against `serve` and a cluster. Terraform and its AWS provider are downloaded into a scratch directory,
    as the SDKs are.
  - **The AWS CLI and the SDKs alone,** as M19: every call made through each, with no Terraform run.

## Consequences

- One design ADR follows the choice, with its slices.
- **For A:** the IAM record grows to hold policies, groups and tags. A record of the new form is refused by a binary
  from before it, which reads it as one it cannot decode, and its sets keep the files' alone.
