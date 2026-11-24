# ADR-0116: compaction keeps the table's codec (M25)

**Status:** accepted, 24 Nov 2026, as built below (the owner: "Accept and close", after M25's exit review,
`docs/m25-exit-review.md`). Proposed the same day with the owner's choices made:
- ZSTD at level 3 when the table sets no codec ("ZSTD at level 3");
- the manifests in the table's `write.avro.compression-codec` ("The table's").

M25 is ADR-0115's item A (the owner: "A: ZSTD written"), with CeeSafe's zstd encoder at levels 1 to 9 ("1 to 9")
released here ("Here, by release.md").

## Context

- **Today** a merged file's pages are SNAPPY (`COMPACTION_PAGE_CODEC`, ADR-0112), whatever the table's codec, and
  the manifests compaction writes are Avro with the null codec.
- **Iceberg's table properties:**
  - `write.parquet.compression-codec`: `zstd`, `snappy`, `gzip`, `lz4`, `brotli` or `uncompressed`. It is `zstd` by
    default since Iceberg 1.4 and in PyIceberg; it was `gzip` before.
  - `write.parquet.compression-level`: the codec's level. When unset, parquet-mr's zstd level is 3, and pyarrow's 1.
  - `write.avro.compression-codec`: the manifests' codec, `gzip` by default (Avro's `deflate`), and
    `write.avro.compression-level`.
- **What CeeSafe gives:** deflate both ways (0.90.0), snappy both ways (0.94.0), the zstd decoder (0.94.4), and, once
  released, the zstd encoder at levels 1 to 9 (ADR 0196 phase 4).

## Decision

1. **The codec a merged file's pages are written in** is the table's `write.parquet.compression-codec`:
   - **`zstd`,** at `write.parquet.compression-level` (taken from 1 to 9; above 9 as 9);
   - **`snappy`, `gzip` and `uncompressed`** as named;
   - **`lz4`, `brotli`, or a name not known:** SNAPPY, as today.
   - **When the table sets none:** the owner's choice, below.
2. **A page that does not shrink** is written uncompressed only where the format allows it: v1 pages name one codec
   for their chunk, so a chunk keeps its codec.
3. **The manifests compaction writes:** the owner's choice, below.
4. **The checks:**
   - **The writer:** each fixture written in ZSTD at levels 1, 3 and 9, read back by itself and by pyarrow
     (`tools/parquet_writer_check.py`).
   - **Real tables:** `tools/compaction_check.py`, on `serve` and through a cluster.
     - PyIceberg's ZSTD tables compact to ZSTD files, read the same.
     - A table set to `snappy` or `gzip` keeps its codec.
     - The merged file's size is compared with pyarrow's ZSTD file of the same rows at the same level.
   - **The page fuzzer's seeds** take the writer's ZSTD files.

## Slices

1. CeeSafe's zstd encoder, released (ADR 0196 phase 4), and the toolchain moved.
2. The codec and level from the table's properties; ZSTD pages written.
3. The manifests' codec, if chosen.
4. The checks.
5. The exit review.

## For the owner to decide

- **The codec when the table sets none:**
  - **ZSTD at level 3 (recommended):** Iceberg's default since 1.4, and PyIceberg's; level 3 is parquet-mr's zstd
    default.
  - **The inputs' codec** (the first input's chunk codec): what the writer that made the files chose.
- **The manifests compaction writes:**
  - **The table's `write.avro.compression-codec` (recommended):** `gzip` (Avro's deflate) by default, as Iceberg's
    writers do; `zstd` and `snappy` too; `uncompressed` as null.
  - **Null, as today:** manifests are small, and every reader takes null.

## Consequences

- **A table's files keep its codec through compaction,** and ZSTD tables' compacted files are about libzstd's size.
- **Compaction's speed** follows the codec: ZSTD at level 3 compresses more slowly than SNAPPY.

## As built (M25, CeeSafe 0.95.1)

- **§1:** `none` is taken as uncompressed too. A level that is not a number, or is 0 or negative, is the codec's
  default: ZSTD's 3, gzip's 6.
- **§2:** v1 pages name their chunk's codec, so every page of a chunk is in that codec even when it does not
  shrink.
- **§3:** `zstandard` is taken as an Avro name beside `zstd`. The level is `write.avro.compression-level`, for
  deflate and zstandard.
- **§4:** the merged ZSTD file is 0.535 of pyarrow's level-3 file of the same rows. The encodings differ, so the
  check's bound is 1.25. The encoder's sizes against libzstd's, 0.999 to 1.003 at each level, are CeeSafe's
  `codec_check`'s.
- **The exit review's Lows,** recorded in `docs/m25-exit-review.md` (B1 to B6).
