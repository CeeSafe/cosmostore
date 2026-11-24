# ADR-0119: M27, after the writer's Lows (proposed)

**Status:** decided, 24 Nov 2026. The owner chose:
- B, with C's CI step first ("B + CI step");
- position deletes rewritten within compaction's run ("In compaction's run").

Proposed the same day (the owner: "continue", after M26 was closed the same day).

## Context

- **Compaction (M23 to M26)** merges row groups, applies v2 deletes, keeps the table's codec, and writes files right
  for pyarrow and parquet-java.
- **v3 tables cannot exist here.** The catalog creates tables at format version 2 and refuses
  `upgrade-format-version` to anything else (`src/s3/iceberg.cee`). The earlier proposals (ADR-0115's B, ADR-0117's
  A) took v3's deletion vectors as the next step; they come after v3 tables themselves:
  - **row lineage:** `next-row-id` in the metadata, `first-row-id` and `added-rows` in each snapshot, and each data
    file's `first_row_id`, which a commit assigns; a rewrite must keep each row's `_row_id` and
    `_last_updated_sequence_number`, written into the file;
  - **deletion vectors:** Puffin files of roaring bitmaps, at most one a data file;
  - **new types** (variant, geometry, nanosecond timestamps) and default values, which a v3 reader must refuse or
    take.
- **v2 position deletes stay longer than they apply.**
  - **Compaction removes one** only when no live file of its partition is at or below its sequence number
    (M24's B3), because the commit does not keep the paths it names.
  - **Dangling ones are never rewritten away:** Spark leaves them after its rewrites, and our own compaction leaves
    them when another file of the partition stays. Every scan plan reads them.
  - **Iceberg Java's `RewritePositionDeleteFiles`** drops the dangling entries and merges the rest. It is a separate
    action from data compaction, and S3 Tables runs none.
- **The operational Lows:**
  - **M26's B3:** the parquet-java check is local only.
  - **M22's B2:** an ask is lost if the shard's leader changes before the loop takes it (the day's pass runs it
    within the hour).
  - **M22's B3:** one loop serves every shard a node leads, so a long compaction delays the other shards' passes.
  - **M21's:** IAM bounds and paths, each recorded with its reason.

## Decision (proposed)

1. **M27 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Iceberg v3 tables | The catalog creates and upgrades v3 tables, with row lineage assigned at each commit; v3's new types refused where not read; compaction keeps each row's lineage and applies deletion vectors (Puffin, roaring bitmaps). **Done when:** Iceberg Java 1.10 and PyIceberg make v3 tables here, Spark writes deletion vectors, and compaction leaves the same rows with the same `_row_id`s, read by Java. |
   | B | Position deletes rewritten | Compaction keeps a position delete's paths in its plan; dangling entries dropped, delete files with none left removed exactly, the rest of a partition's merged into one (Iceberg's `RewritePositionDeleteFiles`). **Done when:** a table with Spark's dangling position deletes compacts to none, and a partition's many small delete files to one, read the same by PyIceberg and Java. |
   | C | The operational Lows | The parquet-java check in CI (a JDK and Maven in the check job); asks kept across a leader change (in the shard's replicated state); a loop per shard, or a time slice, so one table does not hold the others. **Done when:** each is fixed with a test, or decided to stay. |

2. **The recommendation is B, with C's CI step as its first slice.**
   - **Why B:**
     - it cleans up what our own compaction leaves: today a partition compacted with position deletes keeps them
       while any older file stays;
     - Spark's merge-on-read tables, the common v2 writer of position deletes, gain the most;
     - it builds what A's deletion vectors need: a delete's paths kept, and exact removal.
   - **Why not A first:** v3 is large (row lineage touches every commit the catalog takes), and its writers are
     few: PyIceberg 0.12 writes no v3 deletes, and Iceberg Java needs 1.8 or later. A is the milestone after B.
   - **The CI step** is small, and makes M26's check guard every push.
   - **M22's B2 and B3** stay as recorded: the day's pass bounds the first, and the second has not been seen to
     matter.
3. **Not in M27:** v3 tables (item A, next), equality delete rewriting, and sort or z-order compaction.

## For the owner to decide

- **Which item is M27:** B with C's CI step (recommended), A, or C.
- **For B, where position deletes are rewritten:**
  - **within compaction's run (recommended):** the same job, after the data bins, in the same commit, so a
    partition's data and deletes are rewritten together;
  - **a separate job,** as Iceberg Java's action is: its own status, and a commit of its own.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For B, a table's position delete files stop growing** with each compaction, and scan plans read fewer files.
- **v3 tables remain refused** until item A.
