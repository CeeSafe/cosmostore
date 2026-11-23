# ADR-0112: compaction that merges row groups (M23)

**Status:** accepted, 23 Nov 2026, as amended by its As built and exit-review sections (the owner: "Accept and
close"). Proposed the same day with the owner's choices made:
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

## As built (slices 1 to 6)

- **The codecs (slices 1 and 2), released from here (CeeSafe's `docs/release.md`):**
  - **0.94.0:** lib/std's `Snappy` (ADR 0196 phase 2).
  - **0.94.4:** lib/std's `Zstd` decoder (phase 3). It was prepared as 0.94.1, then 0.94.2 and 0.94.3, each taken
    meanwhile by another session's releases. The owner asked for patch versions as 1.0.0 nears.
  - **The toolchain:** CI's `v0.94.4`, and `ceesafe.toml`'s `>=0.94.4`.
  - **Avro too:** its snappy blocks (a raw block and a big-endian CRC-32) and zstandard blocks are read, as well as
    deflate, with fixtures of each (`tools/avro_codec_fixtures.py`).
- **The reader (slice 3), as §1:**
  - **Coverage:** every codec (none, SNAPPY, GZIP, ZSTD), page version, encoding and physical type of §1. INT96 is
    refused.
  - **The corpus:** 13 pyarrow fixtures in the repo (`tools/parquet_page_fixtures.py`), each compared with a Dremel
    shredding of its rows written in the generator, not with pyarrow's reading. They are flat and nested (a struct,
    a list and a map), with nulls, two with Iceberg field ids.
  - **Beyond §5's refusals:** a hybrid run's value wider than its bit width, and a chunk whose first value continues
    a row. The fuzzer found both.
- **The writer (slice 4):**
  - **Pages:** v1 data pages of up to 20,000 levels, each starting at a row; levels in the RLE hybrid (runs of 8 or
    more as RLE).
  - **Dictionary:** a dictionary page when it is smaller than PLAIN and has at most 65,535 entries.
  - **Statistics:** each chunk's null count, and its min and max where the type's order is known here.
  - **The footer:** the first input's schema, field ids and key-value metadata are kept; `created_by` is
    CosmoStore's.
- **The rewrite (slice 5), narrower than §2 in three places:**
  - **The row group's size** is measured by the decoded values' bytes (values and definition levels), not by the
    encoded chunks. The encoded groups come out smaller than the target.
  - **Memory, narrower than §2:** each input is read whole, one at a time, beside one row group's decoded values. A
    bin's memory is bounded by its largest input and the target, not by the target alone.
  - **The manifest entry:** its counts and bounds are combined from the inputs' entries, as joining did, not taken
    from the new statistics.
- **Grouping (slice 5):**
  - **Files whose pages all read** are grouped by partition and by their columns' keys, sorted. A key is each
    element's repetition and Iceberg field id (its name without one), then the leaf's types, length, scale and
    precision. They are not grouped by the footer's shape.
  - **What that gives:** files of other writers, with columns in another order or under other names, merge. Each
    input's columns are matched to the first's by key.
  - **Others** are grouped by shape and joined as before.
  - **A merge that fails while copying** (an input that no longer decodes) leaves its bin for the next run.
- **The checks (slice 6):**
  - **The crash sweep:** compaction's sweep (ADR-0110 §6) is run again, once, sticky, torn and as a crash, over two
    files that can only be merged (one schema, from writers whose shapes differ).
  - **The fuzzer:** `src/s3/parquet_fuzz_tests.cee` runs 1,500 mutants in every test run; `tools/page_fuzz.sh` runs
    it under ASan and UBSan.
    - **Its invariants:** every chunk a mutant decodes has levels and values that agree, and reads back the same
      after the writer writes it.
    - **Its finds:** two bugs, fixed. After the fixes, 3.6 million mutants in 30 minutes, clean.
  - **Real tables:** in `tools/compaction_check.py`, on `serve` and through a cluster's node:
    - PyIceberg's ZSTD files merge into one SNAPPY row group, the same rows;
    - a nested SNAPPY table of twelve files (a struct, a list and a map) merges into one row group, read the same by
      PyIceberg and pyarrow, with its bounds.

## Amended by the exit review (`docs/m23-exit-review.md`)

- **§5, hostile pages:** a bit-packed run unpacks only the values still needed; a DELTA block is at most 65,536
  values; a page holds at most 4 M levels and a chunk 32 M, checked as each page is read. Each chunk's rows must be
  its row group's.
- **§1, the writer:** pages are also cut at about 1 MB of values, and the footer keeps the first input's column
  orders. v1 levels BIT_PACKED are refused where a column has levels.
- **§2, the row group:** a ceiling of 256 MB on the table's size, and a row group written at 16 M levels in a column,
  so that a merged file is one the next merge reads. What a merge holds counts both levels and byte arrays' ends.
- **§4, a merge that fails** is joined as before when its files can be joined (`copiedBin`), on `serve` and a
  cluster; it no longer keeps its bin from compacting.
- **§4, the manifest entry:** a merged file's `column_sizes` are left out, as its columns are encoded again.
