# ADR-0117: M26, after ZSTD written (proposed)

**Status:** proposed, 24 Nov 2026 (the owner: "continue", after M25 was closed the same day).

## Context

- **M23 to M25 made compaction a real Iceberg rewrite:** it merges row groups, applies v2 deletes and keeps the
  table's codec. What remains is in two groups.
- **Iceberg v3's deletes (ADR-0115's B, deferred):**
  - **Deletion vectors:** v3 puts position deletes in Puffin files, as one roaring bitmap per data file. CosmoStore
    reads no Puffin today, so a v3 table's partition with a deletion vector is left as it is, never wrongly.
  - **Position delete files are removed conservatively** (M24's B3): one stays while any live file of its partition
    is at or below its sequence number. Dangling ones are never rewritten away.
  - **Use:** PyIceberg 0.12 writes no deletion vectors. Iceberg Java 1.8+ with Spark writes them for v3 tables, and
    few tables are v3 yet.
- **The recorded Lows, by what they risk:**
  - **A reader could be misled:**
    - **M23's B2:** statistics for types outside Iceberg's are written in the wrong order: unsigned INT32 and INT64
      as signed, BYTE_ARRAY decimals as unsigned bytes, and -0.0 against +0.0. pyarrow trusts these to skip row
      groups, so it could skip rows it should read. Iceberg's writers make none of these types, but other writers
      do.
    - **M23's B3:** `total_uncompressed_size` leaves out the page headers and the dictionary page. Real compression
      (M25) now makes it differ more from what readers size buffers by.
    - **M23's B4:** `path_in_schema` is split on `.`, so a column named with a `.` gets a wrong path. Iceberg's
      writers rename such columns, other writers' files may not.
    - **M23's B5:** a dictionary of one value is written with index width 0. The format allows it, but no reader has
      been tried on such a file.
  - **Untested:**
    - **M23's B6:** the fallback to joining has no test of its own.
    - **M25's B1:** snappy manifests have no outside reader in the checks.
    - **M25's B2:** a level is checked at the codec, not end to end.
  - **Small, and right as they are:**
    - **M24's B1:** a 0-row file is committed when every row of a bin is deleted.
    - **M24's B2 and B4, M25's B3 to B5:** partitions left as they are, values matched as the reader gives them, and
      levels taken as documented.
    - **M21's and M22's B items:** IAM bounds and paths, the maintenance loop's asks and sweep.

## Decision (proposed)

1. **M26 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Iceberg v3's deletes | Puffin read, with deletion vectors (roaring bitmaps) applied as M24 applies position deletes; dangling position delete files dropped and the rest rewritten; exact removal of position deletes. **Done when:** a v3 table written by Iceberg Java with deletion vectors compacts with them applied, read the same by Java and pyarrow, and a v2 table's dangling deletes are gone. |
   | B | The writer's Lows | M23's B2 to B6 fixed: statistics in each type's own order (or left out where unsure), `total_uncompressed_size` as the format defines it, column paths from the schema rather than split names, width-1 dictionaries, and a test of the join fallback. Then M24's B1 (no 0-row file) and M25's B1 and B2 (an outside snappy reader, the level end to end). **Done when:** each is fixed with a test, or decided to stay with a reason, and the writer's files are read the same by pyarrow and by parquet-java's `parquet-cli`. |
   | C | Both, B first | B as one milestone's first slices, then A. |

2. **The recommendation is B.**
   - **Why:**
     - B2 and B4 can make a reader return wrong rows from a file compaction wrote, for files from writers other than
       Iceberg's. That is the only open risk of wrong answers in compaction.
     - B is small (about a slice per item) and closes M23's list, where A is a milestone of its own.
     - A waits on use: PyIceberg writes no deletion vectors, and v3 tables are few.
   - **M21's and M22's Lows** stay as they are: none risks wrong data, and each has its reason recorded.
3. **The work, for B:**
   - **Statistics:** each column's order from its logical type (unsigned integers, decimals by value, floats with
     -0.0 below +0.0), and none where the type's order is not known here.
   - **Sizes:** each chunk's `total_uncompressed_size` with its headers and dictionary page, and the row group's
     `total_byte_size` from it.
   - **Paths:** the schema's own names, walked from the root, not split on `.`.
   - **Dictionaries:** an index width of at least 1.
   - **Tests:** the join fallback through the async runner; a 0-row bin; parquet-java's reader (`parquet-cli`, run
     in the checks like the SDK matrix's Maven tools) on the writer's files; a snappy manifest read by fastavro or
     Avro Java.
4. **Not in M26:** Iceberg v3's other types (variant, geometry, nanosecond timestamps' writing), row lineage, and
   sorting or z-ordering in compaction.

## For the owner to decide

- **Which item is M26:** B, the writer's Lows (recommended); A, v3's deletes; or C, both with B first.
- **For B, the second reader:**
  - **parquet-java through `parquet-cli` (recommended):** Spark's and Iceberg Java's reader, run with the Maven
    tools the SDK matrix already downloads.
  - **pyarrow only, as today.**

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For B, every file compaction writes is right for any reader,** not only Iceberg's, and M23's list is closed.
- **For A, v3 tables compact,** and dangling position deletes stop growing a table's metadata.
