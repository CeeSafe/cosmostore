# ADR-0113: M24, what comes after merging row groups (proposed)

**Status:** decided, 23 Nov 2026. The owner chose:
- A, compaction that applies deletes ("A: apply deletes");
- the counts and bounds from the rows written ("From rows written");
- M23's B1 as A's first slice ("First slice").

Proposed the same day (the owner: "continue", after M23 was closed). M23 (compaction that merges row groups,
ADR-0112) was closed the same day.

## Context

- **Compaction and deletes** (ADR-0111's item B, which it put after A: "B follows it as M24"):
  - **Today:** a partition with a live delete file is not compacted at all (ADR-0098 §2), so merge-on-read tables,
    whose updates and deletes are delete files, never compact where they change.
    - **Spark and Iceberg Java** write merge-on-read deletes: position deletes (a data file's path and row
      position), and, from Flink and others, equality deletes (rows matching some columns' values).
    - **PyIceberg** reads both, and writes copy-on-write deletes itself; the compaction check commits a position
      delete with PyIceberg's manifest writers.
  - **What M23 gives it:** every value of a data file, decoded row by row, and a writer. Applying deletes is dropping
    rows while merging.
  - **What it needs besides:** reading the delete files (Parquet: `file_path` and `pos`, or the equality columns),
    deciding which data files each applies to (partition, sequence numbers, a position delete's file paths), and
    what the commit does with delete files that no longer apply to any live file.
- **ZSTD stays ZSTD only with an encoder:** compacted files of a ZSTD table are SNAPPY until CeeSafe's zstd encoder
  (ADR 0196 phase 4), a release of its own made here as 0.94.0 and 0.94.4 were.
- **The recorded Lows:**
  - **M23's:**
    - B1, a merge's inputs read whole, not a row group at a time;
    - B2, statistics' order for types outside Iceberg's;
    - B3, `total_uncompressed_size`;
    - B4, column names with `.`;
    - B5, width-0 dictionaries;
    - B6, no test of the join fallback itself.
  - **M22's B1 to B4, and M21's B3 to B5** (ADR-0111's list), all small, none failing open.

## Decision (proposed)

1. **M24 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Compaction that applies deletes | A partition's position and equality delete files are read and applied while its files are merged; delete files that then apply to no live file are dropped from the snapshot. **Done when:** a merge-on-read table with position and equality deletes compacts to files without the deleted rows, read the same by PyIceberg and pyarrow before and after, and its delete files are gone; on `serve` and a cluster, with the crash sweep. |
   | B | ZSTD written (CeeSafe's zstd encoder, ADR 0196 phase 4) | A CeeSafe release with lib/std's zstd encoder, its oracle checks, fuzzing and fault sweep; compaction then writes a table's own codec (`write.parquet.compression-codec`, ZSTD by default). **Done when:** a ZSTD table compacts to ZSTD files read the same, and libzstd reads every frame the encoder writes. |
   | C | The recorded Lows | M23's B1 (inputs read a row group at a time, so a merge's memory is the row group's) first; then M21's to M23's other B items, each fixed or decided to stay with a reason. |

2. **The recommendation is A.**
   - **Why:**
     - it is the feature gap M23 leaves: tables that change by deletes are the ones that fragment most, and they are
       the ones compaction skips;
     - it is built on M23's reader and writer, which are fresh and reviewed.
   - **B** is a CeeSafe milestone more than a CosmoStore one: SNAPPY files read everywhere, so it changes sizes, not
     what works.
   - **C's B1** could be A's first slice instead, since applying deletes reads every input anyway.
3. **The work, for A:**
   - delete files read: position deletes (`file_path`, `pos`), and equality deletes by their `equality_ids`;
   - which deletes apply to which data file, by Iceberg's rules: the same partition (or an unpartitioned spec), and a
     data sequence number below the delete's (equality) or at most the delete's (position);
   - rows dropped while merging, with the manifest's counts and bounds from what is written, not from the inputs;
   - the commit: the data files replaced, and delete files that apply to no live file any more removed, in one
     snapshot, with the conditional swap as today;
   - the crash sweep over it, and real tables from Spark-style writers (position deletes) and an equality-delete
     writer.
4. **Not in M24:**
   - deletion vectors (Iceberg v3's Puffin deletes);
   - sort and z-order strategies;
   - rewriting delete files themselves (Iceberg's rewrite-position-delete-files).

## For the owner to decide

- **Which item is M24:** A (recommended), B or C.
- **For A, a bound's choice:** the manifest's counts and bounds of a file with deleted rows
  - **from the rows written (recommended):** exact, computed by the writer while it writes;
  - **the inputs' combined, as M23 does:** looser after deletes (a bound may name a deleted value), still correct for
    pruning.
- **For A, M23's B1 first:** reading inputs a row group at a time as A's first slice (recommended), or after.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A, compaction drops rows,** where it has only moved them. Its correctness is the table's rows read the same
  by PyIceberg and pyarrow, with the deletes applied, before and after; and no delete lost that still applies.
