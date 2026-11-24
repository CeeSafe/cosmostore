# ADR-0121: M28, after position deletes rewritten (proposed)

**Status:** decided, 24 Nov 2026. The owner chose:
- A, with B as its first slice ("A with B first");
- deletion vectors applied by compaction, none written ("Apply, write none").

Proposed the same day (the owner: "continue", after M27 was closed the same day).

## Context

- **Compaction (M23 to M27)** merges row groups, applies v2 deletes, keeps the table's codec, writes files right for
  pyarrow and parquet-java, and rewrites position deletes.
- **v3 tables cannot exist here:** the catalog creates format version 2 and refuses `upgrade-format-version` to 3.
  A v3 table needs:
  - **row lineage:** the metadata's `next-row-id`, each snapshot's `first-row-id` and `added-rows`, assigned when
    the catalog takes the commit; each data file's `first_row_id` in its manifest; a rewrite keeping each row's
    `_row_id` and `_last_updated_sequence_number`, written into the file;
  - **deletion vectors:** Puffin files of roaring bitmaps, at most one a data file, which replace position delete
    files in v3;
  - **v3's types and defaults** (variant, geometry, nanosecond timestamps, `unknown`; `initial-default` and
    `write-default`), which the catalog stores and compaction must read or refuse.
- **M27's B1, the rewrite's cost:** a table with any position delete file reads every partition's delete files at
  every run, even when nothing would change.
- **The cluster's Lows (M22's B2 and B3):** an ask is lost if the shard's leader changes before the loop takes it,
  and one loop serves every shard a node leads.
- **The other Lows on record:** M21's IAM bounds and paths; M24's B2 and B4; M25's B3 to B5; M26's B1 and B2;
  M27's B2 and B3. Each has its reason.

## Decision (proposed)

1. **M28 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Iceberg v3 tables | The catalog creates and upgrades v3 tables and assigns row lineage at each commit; v3's types and defaults stored; compaction keeps each row's lineage, and reads and applies deletion vectors (refusing a v3 table's partition it cannot, never wrongly). **Done when:** PyIceberg and Iceberg Java make v3 tables here, append and delete, and compaction leaves the same rows with the same `_row_id`s. |
   | B | The rewrite's cost | A partition read only when its rewrite could change something: two or more delete files, or one whose `file_path` bounds name files not all live. **Done when:** a run over a table of many partitions each with one live delete file reads none of them, with a test that counts the reads. |
   | C | The cluster's Lows | An ask kept in the shard's replicated state across a leader change; each shard's maintenance passes in turn by time, not table by table. **Done when:** each is fixed with a test, or decided to stay. |

2. **The recommendation is A, with B as its first slice.**
   - **Why A:**
     - it is the one Iceberg feature a client can ask for and be refused: `upgrade-format-version` to 3, or a
       create with `format-version` 3;
     - Iceberg Java 1.8 and later write v3, and its deletion vectors replace position deletes there;
     - M27's kept-row rule and exact removal carry over to deletion vectors.
   - **Why B first:** it is small, and A's deletion vectors would read Puffin files at every run the same way.
   - **C** stays as recorded: the day's pass bounds a lost ask, and one loop has not been seen to matter.
3. **The work, for A:**
   - **the catalog:** v3 metadata validated and written; `next-row-id`, `first-row-id` and `added-rows` assigned
     on commit; the new types and defaults stored and returned;
   - **compaction:** v3 files' lineage columns read and written; deletion vectors read from Puffin (its footer,
     and the roaring bitmap's portable format) and applied; a merged file's `first_row_id` null with lineage
     materialized, as the spec asks of a rewrite;
   - **the checks:** PyIceberg's and Iceberg Java's v3 tables, with Java's deletion vectors, compacted.
4. **Not in M28:** encryption keys, multi-argument transforms, and row lineage on branches other than `main`.

## For the owner to decide

- **Which item is M28:** A with B first (recommended), A alone, B, or C.
- **For A, how deletion vectors are written by compaction:**
  - **applied, none written (recommended):** compaction applies a partition's deletion vectors as it merges, as
    M24 applies position deletes, and writes none;
  - **also rewritten:** a data file kept by the run keeps a deletion vector rewritten into a new Puffin file, as
    M27 rewrites position deletes.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A, the catalog takes v3 tables,** and compaction keeps each row's lineage.
- **For B, a run reads only the delete files whose rewrite could change something.**
