# ADR-0098: Compaction for S3 Tables (M16)

**Status:** proposed, 20 Nov 2026. M16 is item C of ADR-0097 (the owner: "C: Tables compaction").

## Context

- **What S3 Tables does:** its `icebergCompaction` job, on by default, rewrites a table's small data files into
  files near `targetFileSizeMB` (64 to 512), with the `auto`, `binpack`, `sort` or `z-order` strategy.
- **What CosmoStore does today:** it stores the configuration, and the job always shows `disabled` (ADR-0086 §1).
- **What the maintenance pass already has** (ADR-0086, `src/s3/table_maintenance.cee`):
  - **Snapshot management:** it reads and swaps table metadata with the catalog's conditional write
    (`swapMetadata`).
  - **Unreferenced file removal:** it reads manifest lists and manifests (`avro.cee`, null and deflate blocks), and
    deletes what nothing references.
  - **What it lacks:** it writes no Avro, and reads no Parquet.
- **What the files are:** Iceberg's data files are Parquet. Its writers (PyIceberg, Spark) compress pages with zstd
  by default.
  - **What CeeSafe lacks:** `lib/std` has no zstd or snappy (CEESAFE_GAPS G40).
  - **What CosmoStore has:** an inflate (`src/s3/inflate.cee`).

## Decision (proposed)

1. **Binpack by copying row groups (recommended).**
   - **What it does:** a compacted file is its inputs' row groups, copied byte for byte in order, then a new
     footer.
   - **The footer:** Thrift compact `FileMetaData`, with each column chunk's offsets moved and the page indexes'
     offsets dropped.
   - **What it needs:** no page is decompressed or decoded, so any codec and any type, nested ones included, is
     carried as written.
   - **What it does not do:** it lowers the number of files, not of row groups. Readers (PyIceberg, Spark, Trino)
     take a file of many row groups.
   - **The alternative, re-encoding:** decode every page and write new ones. That merges row groups too, but needs
     zstd and snappy, every Parquet encoding, and nested levels, in plain CeeSafe. It is several times the work, for
     a gain readers barely see.
2. **What is compacted:**
   - **Which files:** data files under 75% of `targetFileSizeMB`.
   - **How they are grouped:** by partition spec, partition value and Parquet schema (the same columns, field ids
     and physical types).
   - **How bins are made:** in path order, each bin up to `targetFileSizeMB`; a bin of one file is left.
   - **`auto` and `binpack`** run this. **`sort` and `z-order`** are not done: the job's status says so, as
     `Failed` with a message.
   - **Partitions with delete files are left as they are** (format v2). Position deletes name a file and a row
     position, which a rewrite moves, and equality deletes depend on sequence numbers that a rewrite must carry.
     Neither is rewritten, so their partitions are skipped.
3. **The commit:** one `replace` snapshot, as Iceberg's RewriteFiles makes.
   - **The manifests:** a new manifest lists the compacted files as ADDED. The manifests that held the inputs are
     rewritten with those entries DELETED, and the others are carried as they are. Both are written as Avro, with
     the null codec.
   - **The new files' metrics:**
     - **Counts:** record, value and null counts are summed from the inputs' manifest entries.
     - **Bounds:** lower and upper bounds are the least and greatest of the inputs', for the types whose
       serialized order is known; for others they are left out.
   - **The swap:** through `swapMetadata`, against the metadata the run started from. If a client committed
     meanwhile, the run is abandoned, and its written files are deleted at once.
   - **Data sequence numbers:** a compacted file takes the largest of its inputs'. Skipped partitions with deletes
     make this safe (§2).
4. **Where it runs:** in the maintenance pass, once per table per day (`--tables-day-seconds` for tests), on
   `serve` and on a cluster's shard leaders, as snapshot management does.
   - **The job's status:** `Successful` with the files and bytes rewritten, or `Failed` with a reason.
   - **How much it reads:** the inputs are read through the store, at most a bin at a time.
5. **Not in M16:**
   - `sort` and `z-order`;
   - rewriting delete files, or partitions that have them;
   - merging row groups (re-encoding);
   - compaction asked by a client (Spark's `rewrite_data_files` still works, as it commits through the catalog).

## Slices

1. Thrift compact protocol and Parquet's `FileMetaData`: read, re-offset and write. Tests on files written by
   PyIceberg and by pyarrow (zstd, snappy, uncompressed, nested columns).
2. The Avro writer, for manifests and manifest lists, read back by `avro.cee` and by PyIceberg.
3. The plan (which files, which bins) and the commit (the `replace` snapshot, its metrics), on `serve`, with
   PyIceberg reading the same rows after compaction.
4. A cluster's shard leaders, and the job's status.
5. The exit review.

## For the owner to decide

- **The approach:**
  - **Copy row groups (recommended):** fewer files, no codecs.
  - **Re-encode:** fewer row groups too; it needs zstd and snappy in CeeSafe, several times the work.
- **Partitions with delete files:**
  - **Skip them (recommended):** nothing a delete applies to is rewritten.
  - **Apply the deletes while rewriting:** this needs the re-encode approach.

## Consequences

- **The journal:** no new record. Compaction writes objects and commits through the catalog's conditional write.
- **The job's configuration** keeps the client's status: `enabled` (the default) or `disabled` now mean what they
  say, where today the job is always `disabled` (ADR-0086 §1 amended).
- **Space:** a run writes its bins before the swap. A table then holds both until unreferenced file removal deletes
  the inputs (`unreferencedDays + nonCurrentDays`).
