# ADR-0137: M36, after M34's recorded items (proposed)

**Status:** decided, 26 Nov 2026. The owner chose A, table replication ("A."), with M35's B1 first ("Yes, B1
first"); its design is ADR-0138.

Proposed the same day, after M35 was closed (the owner: "continue").

## Context

- **M35 closed M34's recorded items** (ADR-0136): full list pages, view metadata as Iceberg Java builds it, a table
  bucket's orphaned files swept, and the catalog's hold made explicit and raced.
- **M35's exit review recorded five items** (`docs/m35-exit-review.md`):
  - **B1:** the orphan sweep reads every table, view, staged and pin record, and lists each view's objects, under the
    store's hold on `serve` (the gate and store on a cluster), once a pass per table bucket. All S3 traffic of the
    node, or the shard, waits on it, for a time that grows with the catalog, not with the orphans;
  - **B2:** a swept id's catalog records (its configuration, notes, stale pins) stay until its table bucket goes;
  - **B3:** on a cluster the sweep notes again what it deleted in the same step; notes are looked up linearly;
  - **B4:** slice 2's leniencies against Java's builder, each accepting what Java refuses;
  - **B5:** the review's other missing tests.
- **Remaining from earlier milestones:**
  - S3 Tables' table replication (eight calls), ADR-0133's and ADR-0135's B;
  - Iceberg v3's remaining parts (deletion vectors written by compaction, multi-argument transforms, lineage on
    branches), their C, still waiting for an engine here that writes them.

## Decision (proposed)

1. **M36 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Table replication | S3 Tables' eight replication calls: a table bucket's or table's replicas in another table bucket, read-only, on `serve` and a cluster. **Done when:** a replica reads as its source after each commit, through the CLI and boto3, and PyIceberg reads the replica. |
   | B | M35's recorded items | The sweep's reads off the hold, each id re-checked under it before it goes (B1); a swept id's catalog records removed with it (B2); notes kept as a step sees them (B3); B4 and B5 fixed or kept. **Done when:** the sweep holds the store only for its deletes and their re-checks, measured on a table bucket of 10,000 tables, and each fix has a test. |
   | C | Iceberg v3's remaining parts | Compaction's position deletes written as deletion vectors in a v3 table; multi-argument transforms; lineage on branches. **Done when:** Iceberg Java reads each, in CI. |

2. **The recommendation is A, with B1 first as its slice 0.**
   - **Why A:**
     - replication is the last of S3 Tables' table calls not served here, but for migrations;
     - its pieces are built: table buckets, encryption and policies (M30), clusters as `serve` (M31), maintenance
       per shard, and S3's own bucket replication (its targets and queue, ADR-0077);
     - a replica is read-only, so it adds no writer to the catalog's records, and B2's hold stays what it is.
   - **Why B1 first:** it is the one recorded item whose cost a deployment feels. Every pass stalls the node's S3
     traffic for as long as the catalog takes to read. Replication adds a second reader of every table's metadata
     each commit, so the sweep's hold should be short before it lands. B1 is one slice: the reads as the per-table
     run does them (off the hold), and under the hold only each doomed id's records and pins read again.
   - **B's rest** (B2 to B5) is small and costs nothing while it waits.
   - **C** still waits for an engine that writes those v3 features: PyIceberg 0.12 writes none of them, and the Java
     checks here read them without writing them through an engine.
3. **For A, the questions the design ADR answers:**
   - **What a replica is:** a table in the destination table bucket with the source's metadata and data copied, its
     own id and warehouse, refused every write but replication's; or the source's files referenced in place.
   - **When it is copied:** after each commit of the source (asynchronously, through a queue as S3's replication), or
     by the destination's maintenance pass.
   - **Across a cluster:** source and destination table buckets on different shards.
   - **Encryption:** a replica sealed with the destination's encryption, as S3 Tables does.
   - **Status:** `GetTableReplicationStatus` and what it reports while a copy is behind.

## For the owner to decide

- **Which item is M36:** A with B1 first (recommended), A alone, B or C.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A,** S3 Tables' API is complete here but for migrations.
