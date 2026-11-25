# ADR-0127: M31, after S3 Tables' configuration (proposed)

**Status:** decided, 25 Nov 2026. The owner chose A, clusters as `serve` ("A: clusters as serve").

Proposed the same day, after M30 was closed (the owner: "continue").

## Context

- **S3 Tables' configuration is done** (M30, ADR-0126): tags, storage class and encryption, every file of a KMS
  table sealed, and tag conditions in policies. It is checked by the CLI, boto3, the SDK matrix, Terraform, and
  Iceberg Java on a KMS table in CI.
- **Clusters lag `serve`:**
  - **M30's two cluster bugs:** M30 found two bugs only a cluster had (a bucket's config written in the request that
    made it, and an encrypted table's first metadata file written in the clear). Both had one cause: a shard does not
    see its own request's writes (ADR-0058). They were fixed around that cause, not at it.
  - **M30's B1:** on a cluster, a table bucket's tags, storage class and encryption are set after its create.
  - **M22's B2:** an ask for a maintenance run is lost if its shard's leader changes before the loop takes it.
  - **M22's B3:** one loop serves every shard a node leads, so a long compaction delays the other shards' passes.
- **S3 Tables' API, what is left** (botocore 1.44.9):
  - **record expiration:** three calls. AWS documents it for its own managed tables only (S3 Storage Lens, SageMaker
    Catalog), "not available for S3 tables that you create", and its settings name no column. CosmoStore has no such
    tables.
  - **metrics and logging:** five calls, stored settings;
  - **replication:** eight calls;
  - **migrations:** six calls.
- **Beyond S3 Tables:** Iceberg views and nested namespaces, which S3 Tables does not have. Iceberg v3's remaining
  parts: deletion vectors written, encryption keys, multi-argument transforms, lineage on branches.

## Decision (proposed)

1. **M31 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Clusters as `serve` | A request's own writes seen within it on a shard where a call needs it, so a configured CreateTableBucket is taken in one request (M30's B1). A maintenance ask kept in the shard's replicated state (M22's B2). Each shard's maintenance its own loop (M22's B3). **Done when:** the cluster smoke runs `iceberg_check.py`'s configured creates as `serve` does; a leader killed after an ask still runs it; a long compaction on one shard does not hold up another's pass; the store change swept for faults and crashes. |
   | B | S3 Tables' remaining small calls | Metrics and logging configurations stored and answered. Record expiration answered as AWS answers it for a table one makes. Replication and migrations stay NotImplemented. **Done when:** the CLI and the SDK matrix see AWS's answers for each call. |
   | C | Iceberg views and nested namespaces | The REST catalog's view endpoints (create, load, replace, rename, drop, list) and namespaces nested past one level. They go beyond S3 Tables, for engines that use views. **Done when:** Iceberg Java and PyIceberg make, read and replace a view, and a nested namespace holds tables. |
   | D | Table replication | A table bucket's or table's replication to another table bucket, here or through another endpoint, the replica read-only (ADR-0125's C). **Done when:** a replica reads the same as its source after each commit. |

2. **The recommendation is A.**
   - **Why:**
     - each of M30's two High findings was cluster-only, with one cause: a shard does not see its own request's
       writes. A store that can, where a call asks, removes that class of bug, not one instance;
     - it takes away the one limit the owner accepted in M30;
     - M22's B2 and B3 have been recorded for two milestones.
   - **B** is cheap parity that few tools call, and could ride along with A.
   - **C** goes beyond S3 Tables. It is worth doing when engines that use views are asked for.
   - **D** is large, and few deployments run one table bucket on two endpoints' storage.
3. **For A, the work:**
   - **The store** (a durability change, ADR-0001's ordering kept, a fault sweep):
     - a shard's request reads what it has staged, as `serve` does, for the records it writes (a bucket made, then
       a record in it);
     - or a bucket and its first records staged and applied together, if reading one's staged writes is too wide.
       The design ADR chooses.
   - **CreateTableBucket** takes its settings in one request on a cluster.
   - **Maintenance asks** kept in the shard's replicated state, taken by its leader after a change.
   - **A loop per shard** a node leads.
   - **The checks:** the cluster smoke with `iceberg_check.py`'s configured creates; the maintenance smoke with a
     leader killed after an ask; a fault and crash sweep of the store change.

## For the owner to decide

- **Which item is M31:** A (recommended), B, C or D.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A,** a cluster takes the calls `serve` takes in one request, and its maintenance keeps its asks.
