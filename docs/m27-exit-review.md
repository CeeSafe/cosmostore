# M27 exit review: position deletes rewritten within compaction (24 Nov 2026)

**M27's exit (ADR-0119 item B with C's CI step; ADR-0120, proposed):**
- a table's dangling position deletes compact to none, and a partition's many small delete files to one, read the
  same by PyIceberg;
- the parquet-java check in CI.

## How it was checked

- **CI (slice 1):** the check job runs pyarrow's writer check and parquet-java's after the tests. The first run in CI
  passed 1,343 checks over 36 files.
- **Unit tests (510):**
  - `positionDeletesRewritten`: a partition's two position delete files become one, naming only the live file the run
    does not rewrite, its rows sorted and once each, at the larger sequence number (2);
  - `crossPartitionRowsLeaveTheRewrite`: rows naming a file of another partition leave the partition as it is;
  - `compactionKeepsDeletesWithAnotherSpec`: its position delete, naming only the merged files, is rewritten away.
- **The crash sweep (`rewriteDeletesFaults{Once,Sticky,Torn,Crash}`):** a fault or a crash at every I/O point. Every
  state is one named, and every original file still live keeps each of its deleted positions in a live position
  delete file.
  - It found a state the first list missed: the bins failed and the rewrite committed.
  - A keep rule that drops every row fails it, and the L2 test fails without its fix.
- **`tools/compaction_check.py` (109 checks, on `serve` and through a cluster):**
  - a partition whose only delete names a file gone from the table: the delete file removed;
  - five small position delete files on a large file that stays: one file of its five rows, sorted, the dangling row
    dropped;
  - PyIceberg reads the same rows; the summary counts 1 added and 6 removed.
- **The smokes:** s3, cluster and maintenance.
- **The review:** an agent read ADR-0120 and the code without my notes. It checked PyIceberg 0.12's delete index and
  sequence inheritance in its sources, and found no High.

## Findings

### A. Fixed before closing

1. **Medium: a rewritten delete file could be committed with a null partition.**
   - **Why:** each spec's added manifest was written with the Avro schema of its first entry's source manifest. Avro
     values are written by field name, so an entry read from a manifest whose writer named the partition field
     otherwise was written with that field null.
   - **The effect:** readers index a position delete by spec and partition, so its rows would stop applying.
   - **Fixed:** one added manifest per source manifest, each entry written with the schema it was read with.
     Compaction's added data manifest had the same pattern since M16, and is fixed the same way.
   - **Not tested:** no writer at hand names a partition field otherwise within one table. The grouping is by
     construction.
2. **Low: a kept row's file was not checked to be in the rewrite's partition.**
   - **Why:** readers scope a delete file by its partition, or by path when its `file_path` bounds are equal. Merging
     or dropping rows could move a file from one to the other, so that a row starts or stops applying.
   - **Fixed:** a partition whose rows name a file of another partition is left as it is
     (`crossPartitionRowsLeaveTheRewrite`). The tests' live file was under another spec, and is now in the
     partition's own spec, named ORC so that the run does not rewrite it.
3. **Low: the summary's sizes left out delete files.** `added-files-size`, `removed-files-size` and
   `total-files-size` now count them, as Iceberg's summary does: the rewritten files added, and the delete files
   removed, M24's included.

### B. Recorded, not fixed

1. **Cost:** a table with any position delete file reads every partition's delete files whole at every run, and
   builds a map of its live data paths, even when nothing would change. The bounds are 8 M rows a partition and
   16 M a run, the latter by the manifests' stated counts. Memory peaks at about 150 MB with long paths.
2. **The new file's footer** is the first input's, its key-value metadata included (`ARROW:schema`). This is harmless
   for the two required columns read here.
3. **M24's related case, not M27's:** a bin removes an input that a path-scoped delete of another partition names,
   without applying it, since bins match deletes by partition. Writers do not make such deletes.

## Where the code differs from ADR-0120

- **§2:** a partition is also left as it is when a row names a file of another partition (A2).
- **§5:** one added delete manifest per source manifest, not per spec (A1). The summary's sizes count delete files
  (A3).
- **§6's parquet-java read of the new file** is covered by the writer it shares with compaction's data files, which
  CI's parquet-java check reads, and by PyIceberg's scan in `compaction_check.py`.
