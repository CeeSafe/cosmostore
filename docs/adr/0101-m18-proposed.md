# ADR-0101: M18, what comes after key rotation (proposed)

**Status:** proposed, 20 Nov 2026. The owner: "propose M18". M17 (key rotation without re-sealing, ADR-0100) closed
the same day.

## Context

- **Still refused:** the archive storage classes, GLACIER (Flexible Retrieval) and DEEP_ARCHIVE.
  - **Since when:** M12 took the other classes (ADR-0090 §1) and refused these, as their reads need RestoreObject.
  - **What clients meet:**
    - a PutObject or a lifecycle transition to them is refused;
    - `RestoreObject` answers NotImplemented;
    - so do the tools that tier data and restore it (lifecycle-to-Glacier policies, `aws s3api restore-object`, the
      SDKs' restore helpers).
- **Users and roles come only from files** (M11 to M15):
  - the users file names users, their keys and identity policies;
  - the roles file names roles;
  - both reload without a restart (ADR-0088, ADR-0096).
  - **What is missing:** a client cannot create a user or an access key, or attach a policy, through an API, as
    AWS's IAM API does.
- **Left by M16 (ADR-0098 §5):** compaction does not merge row groups or apply deletes. Both need zstd and snappy in
  CeeSafe, which has neither (G40), and Parquet's encodings.
- **Recorded, not fixed:** M17's B1 to B5 and M16's B1 to B6, all Low.

## Decision (proposed)

1. **M18 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Archive storage classes | **Writes and transitions:** GLACIER and DEEP_ARCHIVE are taken on writes, copies, multipart uploads and lifecycle transitions. **Reads:** an archived version's GET, and a CopyObject from it, are InvalidObjectState until it is restored. HeadObject shows its class and `x-amz-restore`. **RestoreObject** (`Days`, and the tier `Expedited`, `Standard` or `Bulk`) starts a restore. After the tier's time, a model of AWS's that is configurable and in seconds for tests, the version reads for the days asked, and then it is archived again. **Durable:** the restore's state is a metadata-only record, as tags and storage classes are. **On `serve` and a cluster.** The bytes stay where they are. |
   | B | The IAM API, a subset | `CreateUser`, `DeleteUser`, `ListUsers`, `CreateAccessKey`, `DeleteAccessKey`, `ListAccessKeys`, `PutUserPolicy`, `GetUserPolicy`, `DeleteUserPolicy`, `CreateRole`, `DeleteRole`, `PutRolePolicy` and `GetRole`, through `iam` signing. Users and roles are kept in the store, as the catalog's records are, beside the files, which stay the operator's. |
   | C | Compaction that re-encodes | zstd and snappy in plain CeeSafe, Parquet's encodings and nested levels. Compaction then merges row groups and applies deletes. |

2. **The recommendation is A.**
   - **Why:**
     - it has been the next candidate since M15;
     - it is what clients hit most: a lifecycle rule to GLACIER is common, and today it is refused;
     - it completes storage classes, which M12 started.
   - **What it stands on:**
     - M12's storage classes and transitions (ADR-0090);
     - SetTags' metadata-only records (ADR-0017), a new format for a restore's state;
     - lifecycle's pass, which also expires a restore.
   - **What it must decide:** what an archived version's restore time is, by default.
3. **B is real work for a gain mostly in tooling.**
   - **The gain:** clients that create users through IAM, and tests that do.
   - **The cost:** it moves users and roles from files to the store, so two sources of truth have to be reconciled.
4. **C stays the largest,** as ADR-0099 said, and waits for G40.
5. **Not in M18:**
   - a KMS service;
   - SNI and HTTP/2, which are CeeSafe.Web's;
   - S3 Metadata tables and S3 Vectors.

## For the owner to decide

- **Which item is M18:** A (recommended), B or C.
- **For A, the default restore times:**
  - **AWS's, scaled (recommended):**
    - GLACIER: Expedited 1–5 min, Standard 3–5 h, Bulk 5–12 h;
    - DEEP_ARCHIVE: Standard 12 h, Bulk 48 h;
    - each scaled by `--restore-scale` (1 by default; tests use a small fraction).
  - **Immediate by default:** a restore completes at once unless the operator sets times. That is simplest for
    users, but less like S3.

## Consequences

- One design ADR follows the choice, with its slices.
- **For A:** a new SetTags format for a restore's state. An older binary cannot open a store that has one.
