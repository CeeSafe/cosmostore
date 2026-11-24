# ADR-0120: position deletes rewritten within compaction (M27)

**Status:** accepted, 24 Nov 2026, as built below (the owner: "Accept and close", after M27's exit review,
`docs/m27-exit-review.md`). Proposed the same day: M27 is ADR-0119's item B with C's CI step first (the owner:
"B + CI step"), the rewrite made within compaction's run ("In compaction's run").

## Context

- **Today (ADR-0114 §5, M24's B3):** a position delete file is removed only when a committed bin applied it and no
  live data file of its partition is at or below its sequence number. Its rows are never rewritten:
  - **dangling rows** (naming a file no longer live) stay, as Spark leaves them after its own rewrites;
  - **a partition's many small delete files** stay many, and each scan plan reads each;
  - **a delete file one live file still needs** stays whole, with rows for the files compaction removed.
- **Iceberg's rule:** a position delete row `(file_path, pos)` applies to the data file of that path when the data
  file's data sequence number is at or below the delete file's. A path is written once, so the file a row names
  existed when the delete was written: its sequence number is at or below the delete's.
- **Iceberg Java's `RewritePositionDeleteFiles`** reads a partition's position delete files, drops the rows naming
  files no longer live, and writes the rest as new files sorted by path and position. It is its own action; S3
  Tables runs neither it nor anything like it.
- **What compaction has:** each position delete file is read whole for a bin (`readPositionDeletesWithin`, bounded
  at 8 M rows), its spec and partition key and sequence number, and the plan's live data files.

## Decision

1. **The CI step (slice 1):** CI's check job installs a JDK and Maven 3.9.9 (from archive.apache.org, its SHA-512
   checked) and runs `tools/parquet_java_check.sh` after the tests (M26's B3).
2. **Which partitions are rewritten:** within a compaction run, after its data bins are planned, each partition
   (spec and partition key) whose position delete files hold a row that dangles, or that has two or more position
   delete files. A partition is left as it is when:
   - one of its delete files carries more than `file_path` and `pos` (the optional `row` column), or a field id
     not Iceberg's two;
   - its delete files hold more than 8 M rows together;
   - a delete file does not read.
3. **A row is kept** when the file it names is live after this commit (not an input this run removes), and that
   file's data sequence number is at or below the row's delete file's (a row that never applied is dropped).
4. **What is written:** a partition's kept rows as one Parquet position delete file, sorted by path, then position,
   duplicates dropped:
   - its schema and footer the first input delete file's, its codec the table's (ADR-0116);
   - its manifest entry's metrics from its rows: counts, and `file_path` and `pos` bounds (Iceberg reads a
     delete file whose `file_path` bounds are equal as naming that one file);
   - **its data sequence number:** the largest of the files it replaces. Each kept row names a file at or below
     its own delete's number, so at or below the largest, and no row comes to apply to a file it did not.
   - **none** when no row is kept: the partition's delete files are removed, with nothing added.
5. **The commit:** the same `replace` snapshot as the data bins:
   - the replaced delete files DELETED in their manifests;
   - the new ones ADDED in a delete manifest (`content` 1) per spec, written in the table's Avro codec;
   - the summary's `added-delete-files`, `removed-delete-files`, `added-position-deletes`,
     `removed-position-deletes`, and the totals, as Iceberg's rewrite writes them.
   - **ADR-0114 §5's removal stays** for a delete file of a partition this run does not rewrite.
6. **Faults:** the run's crash sweep covers a run that rewrites deletes: every state it leaves is before or after,
   by each data and delete file's rows.

## Slices

1. The parquet-java check in CI (§1).
2. The plan: partitions chosen, rows kept (§2, §3), with unit tests.
3. The position delete file written, and the commit (§4, §5).
4. The fault and crash sweep (§6).
5. `tools/compaction_check.py`:
   - a table of dangling position deletes compacts to none;
   - a partition's five small delete files compact to one;
   - PyIceberg reads the same rows, and parquet-java reads the new file.
6. The exit review.

## Consequences

- **A table's position delete files stop accumulating** across compactions, and scan plans read one a partition.
- **v3's deletion vectors (ADR-0119's A)** can reuse the kept-row rule and exact removal.
- **Compaction reads every position delete file of a partition it rewrites,** within the bound of §2.

## As built (M27)

- **§2:** a partition is also left as it is when a row names a file of another partition, since readers scope a
  delete file by partition, or by path when its `file_path` bounds are equal (the exit review's L2).
- **§5:**
  - one added delete manifest per source manifest, not per spec, so each entry is written with the Avro schema it
    was read with (the exit review's M1; compaction's added data manifest likewise);
  - the summary's sizes count delete files (L3).
- **§6:** the new file is read in the checks by PyIceberg's scan. parquet-java reads the writer it shares with
  compaction's data files, in CI.
- **The exit review's Lows** are recorded in `docs/m27-exit-review.md` (B1 to B3).
