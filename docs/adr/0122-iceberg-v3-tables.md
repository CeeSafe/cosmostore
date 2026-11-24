# ADR-0122: Iceberg v3 tables (M28)

**Status:** proposed, 24 Nov 2026. M28 is ADR-0121's item A with B as its first slice (the owner: "A with B first"),
deletion vectors applied by compaction and none written ("Apply, write none").

## Context

- **The catalog** creates tables at format version 2, whatever the request's `format-version` property, and refuses
  `upgrade-format-version` to anything but 2 (`src/s3/iceberg.cee`).
- **What v3 asks** (the table spec's v3 parts, read for this ADR):
  - **Row lineage:**
    - the metadata's `next-row-id`;
    - each snapshot's `first-row-id` and `added-rows`;
    - each manifest's `first_row_id` (manifest list field 520) and each data file's (field 142);
    - each row's `_row_id` (field id 2147483540) and `_last_updated_sequence_number` (2147483539).
    - **A commit:** the client sends `first-row-id` and `added-rows`. Iceberg Java's metadata builder refuses a v3
      snapshot without `first-row-id`, refuses one below `next-row-id` as a retryable conflict, and adds `added-rows`
      to `next-row-id`. PyIceberg 0.12 does the same.
    - **A writer** gives each data manifest without a `first_row_id` one, from the snapshot's `first-row-id` on.
      A data file inherits its manifest's, plus the rows of the files before it in that manifest whose own is null.
      ADDED entries are written null.
    - **A rewrite** copies each row's `_row_id` and `_last_updated_sequence_number` into the new file. A reader
      takes a null `_row_id` as the file's `first_row_id` plus the row's position, and a null
      `_last_updated_sequence_number` as the file's data sequence number.
    - **An upgrade from v2** sets `next-row-id` to 0. Older snapshots stay without lineage, and the first snapshot
      after it gives every data manifest a `first_row_id`.
  - **Deletion vectors:**
    - a delete file entry (content 1) of format `puffin`, with `referenced_data_file` (143), `content_offset` (144)
      and `content_size_in_bytes` (145);
    - at most one a data file in a snapshot;
    - it applies to its file when the file's data sequence number is at or below its own, in the same spec and
      partition.
    - **The blob** (`deletion-vector-v1`) is a 4-byte big-endian length, the magic `D1 D3 39 64`, the vector, and
      a CRC-32 of magic and vector, big-endian.
    - **The vector** is an 8-byte little-endian count of 32-bit roaring bitmaps, each a 4-byte little-endian key
      (a position's high 32 bits) and the bitmap in roaring's portable format.
    - **Position delete files** are deprecated in v3: none may be added; those from v2 stay valid.
  - **New types** (`unknown`, `timestamp_ns`, `timestamptz_ns`, `variant`, `geometry`, `geography`) and field
    defaults (`initial-default`, `write-default`); `encryption-keys` and multi-argument transforms.
- **PyIceberg 0.12** reads v3 metadata, writes `first-row-id` and `added-rows` on a v3 table's snapshots, and reads
  deletion vectors (with pyroaring). It writes no deletion vectors, and refuses to upgrade a table past v2 itself.
- **M27's B1:** a table with any position delete file reads every partition's delete files at every run.

## Decision (proposed)

1. **Slice 1, the rewrite's cost (ADR-0121's B):** a partition's position delete files are read only when a rewrite
   could change something:
   - it has two or more;
   - or its one file's `file_path` bounds name a file not live, or are unequal (it may name several).
   - A test counts the files read.
2. **The catalog:**
   - **creates** a v3 table when the request's `format-version` property is 3 (2 by default; 1 and above 3 refused),
     the property itself not stored, as Iceberg's catalogs do;
   - **upgrades** 2 to 3, setting `next-row-id` to 0;
   - **for a v3 table's added snapshot:** refuses one without `first-row-id` or `added-rows`, or with `first-row-id`
     below `next-row-id` (a conflict, as a stale commit is); then adds `added-rows` to `next-row-id`;
   - **stores** v3's types and defaults as given, returned as stored.
3. **Compaction of a v3 table:**
   - **an input** must have a `first_row_id`, its own or its manifest's. A partition with a file without one stays as
     it is (a v2 table's files after an upgrade, until a client's snapshot gives them one);
   - **a merged file** holds `_row_id` and `_last_updated_sequence_number` for every row: an input's own where its
     file has them, else its `first_row_id` plus the row's position and its data sequence number;
   - **the commit,** as a v3 writer's:
     - the snapshot's `first-row-id` is the table's `next-row-id`;
     - the added data manifest's `first_row_id` is assigned from it, and its rows advance `next-row-id`;
     - the rewritten manifests write each entry's `first_row_id` explicitly, and keep their manifest's.
   - **v3's types:**
     - a `variant`, `geometry` or `geography` column is merged as its Parquet columns, with no bounds;
     - `timestamp_ns` takes its bounds in nanoseconds (ADR-0114 already does);
     - `unknown` is never in a file.
   - **M27's rewrite of position deletes** writes none in a v3 table: it only removes a partition's position delete
     files when no row is kept.
4. **Deletion vectors:**
   - read from their Puffin file at the entry's offset and size: the length, magic and CRC checked; the roaring
     bitmaps read (array, bitmap and run containers), bounded as a delete file's rows are;
   - applied by a bin as M24 applies position deletes, to the one file each names;
   - removed by the commit when the file they name is removed;
   - a partition with a vector that does not read stays as it is.
   - The roaring reader joins the page fuzzer's targets.
5. **The checks** (`tools/compaction_check.py`, on `serve` and through a cluster):
   - PyIceberg makes a v3 table here, and appends to it;
   - the upgrade of a v2 table, by the REST update, as Iceberg Java sends it;
   - deletion vectors written by the check (pyroaring, the Puffin framing) and committed with PyIceberg's manifest
     writers, read by PyIceberg before;
   - compaction then leaves the same rows, each `_row_id` as a reader computed it before, and the vectors removed.
   - Iceberg Java's reading of the result is a check of its own (slice 6).

## Slices

1. The rewrite's cost (§1).
2. The catalog's v3 tables (§2).
3. Compaction's lineage (§3).
4. Deletion vectors read and applied (§4).
5. The checks (§5).
6. Iceberg Java (iceberg-core's REST client, with the Maven tools of the parquet-java check): a v3 table made and
   appended to, a deletion vector written by its own writer, compacted here, and read with its `_row_id`s.
7. The exit review.

## Consequences

- **A client can make, upgrade and write v3 tables here,** and compaction keeps their lineage.
- **A v3 table's deletion vectors** are applied as its files are compacted.
- **Not done:** encryption keys, multi-argument transforms, and lineage on branches other than `main`.
