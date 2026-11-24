# M26 exit review: the page writer's Lows closed (24 Nov 2026)

**M26's exit (ADR-0117 item B; ADR-0118, proposed):**
- every file compaction writes is right for pyarrow and parquet-java, whatever wrote its inputs: bounds in each
  column's order, paths from the schema, sizes as the format defines them;
- M23's B2 to B6, M24's B1 and M25's B1 and B2 fixed with a test each.

## How it was checked

- **Unit tests (504):**
  - `statisticsInEachOrder`, on a new pyarrow fixture (ORDERS): unsigned integers past the signed range, decimals of
    both signs in FIXED, floats with ±0.0 and NaNs, names holding a `.`;
  - `pathsFromTheSchema`, `sizesCountHeadersAndDictionaries`;
  - `deletedRowsAddNoFile`: a bin whose rows are all deleted adds no file, and its written file is gone;
  - `tableLevelReachesTheFile`: gzip at 1, 6 and 9 from the table's properties writes three different files;
  - `mergeFailureJoins`, async through `compactTable` as `serve` runs it: an input whose pages do not read is
    joined.
  - Each was seen to fail with its fix taken out.
- **`tools/parquet_writer_check.py` (pyarrow, 36 files):** each fixture written in each codec reads as the
  fixture, NaN-aware and with -0.0 apart from 0.0; every flat or struct column's min and max equal its values',
  with the zeros' signs.
- **`tools/parquet_java_check.sh` (parquet-java 1.15.2, Avro 1.12.0, local):** 1,343 checks.
  - Each written file beside its fixture: the same rows; each chunk found by its path; its null count, and its
    bounds by parquet-java's comparator; uncompressed, its total uncompressed size equal to its bytes.
  - The Avro test's manifest in each codec read as the same records (M25's B1).
  - Unsigned integers ordered as signed, put back into the writer, fail it in every codec's file. parquet-java
    reads a zero bound as -0.0 or +0.0 whatever the file says, so the zeros' signs are pyarrow's check's.
- **The smokes:** s3, cluster and maintenance, with the compaction check on `serve` and through a cluster.
- **The review:** an agent read ADR-0118 and the code without my notes. It checked the logical types' Thrift ids,
  the converted types' numbering, each comparison, the float bounds, the sizes, the paths, the snapshot summary
  and manifests with a file left out, and the failure path, and confirmed parquet-java's reading of float
  statistics from its classes. No High or Medium finding.

## Findings

### A. Fixed before closing

1. **Low: a file left out of the commit could keep an equality delete.** The removal check counted every output as
   live data, a 0-row one too. A bin merging inputs of 0 rows, with no deletes of its own, kept its inputs'
   sequence number, so another bin's equality delete in its partition stayed. A missed cleanup, never a wrong read.
   Fixed: a file left out is skipped there.

### B. Recorded, not fixed

1. **A crash between the commit and the deletion of a 0-row file** leaves an object no manifest names. Its key is a
   new UUID, and the unreferenced-file sweep removes it. On a cluster's leader the key is handed to the next gated
   step, as a failed commit's are.
2. **parquet-java's row-group filter does not know NaNs** (not CosmoStore's): bounds without NaNs, as the format asks
   and Arrow writes, can let an `eq(col, NaN)` filter skip a row group holding one. Every writer that leaves NaNs
   out shares it.
3. **The parquet-java check is local,** as the SDK matrix is: CI's check job installs no JDK or Maven.

## Where the code differs from ADR-0118

- **§1:** FIXED_LEN_BYTE_ARRAY's bounds are written now (unsigned bytes, or a DECIMAL's value), where they were left
  out; FLOAT16 gets none.
- **§5:** only a merged file of 0 rows is left out. A joined file's rows are its inputs' stated counts, so it is
  always added.
- **§6:** parquet-java reads rows through its example reader, not parquet-avro's, since Avro's names cannot hold a
  `.`; its bounds are compared with the fixture's, which pyarrow wrote.
