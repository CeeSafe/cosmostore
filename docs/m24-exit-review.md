# M24 exit review: compaction that applies deletes (24 Nov 2026)

**M24's exit (ADR-0113 item A; ADR-0114, proposed with the owner's choices):**
- a partition with position and equality delete files is compacted with its deletes applied, and the delete files
  that then apply to nothing live are removed;
- a merge reads its inputs a row group at a time (M23's B1);
- a merged file's manifest counts and bounds come from the rows it holds, under the table's metrics mode;
- the merge with deletes is swept for faults and crashes, and real tables with each kind of delete compact on `serve`
  and a cluster.

## How it was checked

- **Unit tests (495 after the review's fixes):**
  - which deletes apply, by sequence number and partition;
  - both delete readers on pyarrow's files, an equality delete matching rows by value and by null;
  - rows dropped whole over flat and nested columns;
  - metrics: modes, truncation, decimals, floats, time units;
  - a merge of a file of three row groups, read one at a time;
  - a merge that applies a position and an equality delete, each id counted.
- **The crash sweep with deletes:** once, sticky, torn and as a crash at every I/O point. Every state left must be
  one of these, by file paths and rows:
  - before;
  - either file compacted alone with its deletes applied;
  - after.
- **`tools/compaction_check.py` (80 checks on `serve` and through a cluster's node):**
  - **Metrics:** each merged file's against PyIceberg's own from its footer, under the table's properties.
  - **A position delete:** applied, and its file removed.
  - **An equality delete:** applied to its id's older rows and not to a row of that id appended after it, and its
    file removed.
- **The page fuzzer** in every test run, and under ASan and UBSan.
- **Found before the review:**
  - **Planning:** a fault in the plan can leave one file out, and the other then compacts alone with its deletes
    applied. The sweep's first check did not allow that state, which is right, and now names it.
  - **PyIceberg** plans no scan of a table with equality deletes (apache/iceberg#6568). That table's files are listed
    from its manifests and its rows before compaction stated.
- **The review:** an agent read ADR-0114 and the code with no reading of mine. Its findings came from reading, without
  probe tests; each fixed one has a test now.

## Findings

### A. Fixed before closing

1. **High: an equality delete written under an unpartitioned spec could be removed while it still applied to another
   spec's older files**, bringing deleted rows back.
   - **Why:** Iceberg treats such a delete as global, but the removal check matched data files by spec and partition
     only.
   - **Fixed:** no delete file is removed while a live data file of another spec remains.
   - **Test:** `compactionKeepsDeletesWithAnotherSpec`.
2. **High: a delete file within the 64 MB limit could decode to billions of values,** an OOM that any writer to the
   table could cause.
   - **Fixed:**
     - a delete file's rows are bounded at 8 M, as its manifest states them and again as it decodes (each chunk's
       stated count checked before it is decoded);
     - a bin's deletes are bounded at 16 M rows together.
   - **Test:** `deleteRowsBounded`.
3. **Medium: reading position deletes was quadratic in the paths they name.** Paths are found through a hash map now.
4. **Medium: timestamps were read without their unit.** A millisecond column's bounds were 1,000 times too small, so
   pruning could skip its rows, and its equality keys never matched.
   - **Fixed:** a leaf carries its time unit, from its logical or converted type. A time or timestamp has an Iceberg
     value only in Iceberg's unit (microseconds, or nanoseconds for `_ns`). Otherwise it has no bound, and a bin
     whose equality delete needs it is not merged.
   - **Test:** `timestampsInIcebergsUnit`.
5. **Low: equality keys of NaNs differed by payload.** Every NaN is one key now, as Java's comparison has them equal
   (`nanKeysAreOne`).
6. **Low: metrics modes were matched with case.** They are matched without case, as Java's are.
7. **Low: an unused list in the plan,** left from before M24, is gone.
8. **The reviewer's suspicion S1: partitions were matched by the JSON text of their values.**
   - **The risk:** a delete file whose partition text differed from its data files' would not be applied to them.
     They would be rewritten under new paths and a newer sequence number, and the deleted rows would come back. The
     same risk existed before M24, when such files would have been joined.
   - **Fixed in two ways:**
     - a partition key is its spec and its values in their order, without their names, so writers that name a field
       otherwise (as Avro's names are made) still match;
     - a delete file is removed only when a committed bin applied it, not whenever it applies to nothing live.
   - **Tried and dropped:** leaving the table as it is when a delete's partition is no live data file's. Dangling
     deletes are common (Spark leaves position deletes after their files are rewritten), so it would stop compaction
     of every such table.

### B. Recorded, not fixed

1. **A bin whose rows are all deleted commits a data file of 0 rows,** where Iceberg's rewrite writes none. It is
   valid, and the next compaction merges it away.
2. **Some partitions stay as they are at every run, never wrongly:**
   - an equality delete on a field dropped from the current schema;
   - a float column promoted to double, whose Iceberg value is not made here;
   - a timestamp column in milliseconds under an equality delete.
3. **Position delete files are removed conservatively:** one stays while any live data file of its partition is at or
   below its sequence number, whether or not it names that file. Exact removal needs the paths it names, which the
   commit does not keep.
4. **Partition values are matched as the Avro reader gives them:** a writer that wrote one value under another
   physical type (a decimal as fixed in one manifest and bytes in another) would still not match. No writer known
   here does so within one table.

## Where the code differs from ADR-0114

These are in its As built section, amended here:
- **§2:** a struct's fields keep their bounds, as Iceberg Java's writers do; PyIceberg keeps none for nested fields.
- **§3:** delete files are bounded in rows as well as bytes. A delete file is removed only when a committed bin
  applied it, and none while another spec's data is live.
- **§5:** position delete files are removed by partition and sequence number, conservatively (B3).
