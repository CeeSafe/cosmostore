# ADR-0112: compaction that merges row groups (M23)

**Status:** proposed, 23 Nov 2026, with the owner's choices made:
- lists and maps in M23 ("In M23");
- dictionary pages when smaller ("Yes, when smaller");
- small fixtures in the repo ("Small fixtures in repo").

M23 is ADR-0111's item A (the owner: "A: merge row groups"). The owner also chose SNAPPY as the codec compaction
writes ("SNAPPY") and the CeeSafe releases made here ("Here, by release.md").

## Context

- **Today's compaction (ADR-0098)** joins a bin's Parquet files whole. It copies their column chunks, in order, under
  a new footer (`parquet.cee`'s `joinParquet`), and never reads a page.
  - **A compacted file keeps every input's row groups:** ten one-row files make a file of ten one-row groups.
  - **Files whose footers differ** (`shape`: schema, writer, column orders) do not join, and stay small.
- **CosmoStore reads Parquet's footer only:** `thrift.cee` is Thrift's compact protocol, and `parquet.cee` the
  footer's chunks, rows and offsets. No page is decoded anywhere.
- **What the pages hold, as PyIceberg (pyarrow) and Spark write them:**
  - **Codecs:** ZSTD (PyIceberg's and Iceberg's default), SNAPPY (Spark's), GZIP, uncompressed.
  - **Page types:** a dictionary page, then data pages, v1 (pyarrow's default) or v2.
  - **Encodings:**
    - PLAIN;
    - RLE_DICTIONARY (PLAIN_DICTIONARY in older writers);
    - RLE/bit-packed hybrid for levels and booleans;
    - and, rarely from these writers, the DELTA encodings and BYTE_STREAM_SPLIT.
- **The codecs** come from CeeSafe: snappy (ADR 0196 phase 2) and the zstd decoder (phase 3), built and released
  from here first. Deflate and gzip are 0.90.0's.

## Decision (proposed)

1. **A page codec,** `src/s3/parquet_pages.cee`.
   - **Reads:** a column chunk's dictionary and data pages (v1 and v2), each decompressed with lib/std's codec, into
     values with their definition and repetition levels.
   - **Writes:** values back as data pages.
   - **Encodings read:** PLAIN, RLE_DICTIONARY and PLAIN_DICTIONARY, the RLE/bit-packed hybrid,
     DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY and BYTE_STREAM_SPLIT.
   - **What it writes:** data pages v1 under SNAPPY, a dictionary page when it is smaller than PLAIN (the owner's to
     decide, below), and the RLE hybrid for levels.
   - **Physical types:** BOOLEAN, INT32, INT64, FLOAT, DOUBLE, BYTE_ARRAY and FIXED_LEN_BYTE_ARRAY. INT96 is not
     Iceberg's and is refused.
   - **Refused:** a page whose codec, encoding or type is not one of these is not decoded, and its file is joined as
     today. Not knowing is not compacting (ADR-0098's rule).
2. **What is merged:**
   - **The bin:** its files of one Iceberg schema and partition, as today. Their columns are matched by Iceberg field
     id, not by position. They need not share a writer's shape any more, only the schema.
   - **Each column's values,** decoded file after file, are written as row groups of the target row group size:
     - Iceberg's `write.parquet.row-group-size-bytes`, 128 MB by default;
     - the table's own setting when it has one;
     - measured by the encoded column chunks.
   - **Statistics** are computed for each new chunk: min, max, null count and distinct count off. The Iceberg field ids
     and the logical types are kept in the schema.
   - **Not written:** page indexes and bloom filters (ADR-0111 §4).
   - **Memory:** at most one row group of every column is held while it is written, so a bin's memory is bounded by
     the target row group size and its columns' count.
3. **Nested columns:**
   - **Structs** with optional fields are read and written with their definition levels.
   - **Lists and maps** (repetition levels) are the owner's to decide, below.
4. **Compaction:**
   - **It merges when it can:** a bin whose files' pages all decode is rewritten, and otherwise joined as today.
   - **The manifest entry:** row count and sizes as today, and the bounds from the new statistics.
   - **What stays as it is:** the gated steps (ADR-0110), the commit, and the job's status.
5. **The checks:**
   - **A corpus:** files pyarrow writes, of every codec, page version, encoding and type above, with nulls and
     nested structs, committed as fixtures. Each is decoded and its values compared with pyarrow's reading,
     re-encoded, and read back by pyarrow.
   - **Hostile pages are refused, not trusted:**
     - lengths past the page;
     - a dictionary index past the dictionary;
     - a bit width over 32;
     - a decompressed size over the page header's;
     - levels past the schema's depth.
   - **The fuzzer:** the page decoder fuzzed, as ADR 0196's codecs are.
   - **The crash sweep:** M22's compaction sweep over the rewrite.
   - **Real tables:** PyIceberg's ZSTD table and a SNAPPY table of many small files compacted on `serve` and a
     cluster, then read by PyIceberg and pyarrow to the same rows, with few row groups.

## Slices

1. CeeSafe's snappy (ADR 0196 phase 2), released, and the toolchain moved.
2. CeeSafe's zstd decoder (phase 3), released, and the toolchain moved.
3. The page reader: codecs, encodings, levels, types, and its corpus.
4. The page writer: PLAIN, the dictionary, SNAPPY, the statistics; read back by pyarrow.
5. The rewrite in compaction: field-id matching, the target row group size, and joining as before where a page does
   not decode.
6. The checks on `serve` and a cluster, the crash sweep, and the fuzzer.
7. The exit review.

## For the owner to decide

- **Lists and maps (repetition levels):**
  - **In M23 (recommended):** PyIceberg and Spark tables often have them. A bin with one would otherwise stay joined,
    as today.
  - **Later:** structs only now, and a bin with a list or map joined as today.
- **Dictionary pages in what compaction writes:**
  - **Yes, when smaller (recommended):** as pyarrow does. Low-cardinality columns are much smaller.
  - **PLAIN only:** simpler, and larger files.
- **The corpus's size:**
  - **Small fixtures in the repo (recommended):** a few KB each, as hex like today's.
  - **Generated at test time by pyarrow:** larger, with tests that need Python.

## Consequences

- **Compaction rewrites values,** where it copied bytes. Its correctness is the rows read back the same, checked by
  pyarrow and PyIceberg, beside the sweep and the fuzzer.
- **A ZSTD table's compacted files are SNAPPY** until CeeSafe has a zstd encoder (ADR 0196 phase 4). Readers take
  either, as a file names its codec per chunk.
- **Files written by other writers** with encodings outside §1 keep today's behaviour.
