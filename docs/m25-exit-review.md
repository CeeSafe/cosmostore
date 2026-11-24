# M25 exit review: ZSTD written, the table's codec kept (24 Nov 2026)

**M25's exit (ADR-0115 item A; ADR-0116, proposed with the owner's choices):**
- a ZSTD table compacts to ZSTD files at its level, of about libzstd's size, read the same by PyIceberg and pyarrow;
- a table set to another codec keeps it, and its manifests are in its `write.avro.compression-codec`;
- CeeSafe's zstd encoder released first (ADR 0196 phase 4).

## How it was checked

- **CeeSafe 0.95.1, released from here** (the owner: "Push and tag v0.95.1"; its release workflow green):
  - `Zstd.compress` and `ZstdEncoder` at levels 1 to 9, with libzstd's parameters;
  - libzstd 1.5.7 (and 1.5.5 on Linux) read all 4,080 frames of `codec_check`;
  - sizes at levels 1 to 9 are 0.999 to 1.003 of libzstd's;
  - its fuzzer (ASan and UBSan, on macOS and Linux), and its allocation sweep (376 of 376 points).
  - The contract suite's `slices tsan` timing step failed at load 94 and passed when run alone.
- **Unit tests (498 after the review's fixes):**
  - a manifest written in each Avro codec (null, deflate, snappy, zstandard) and read back;
  - the codec and level from the table's properties, for every name and level case below (`codecsFromProperties`);
  - a page at ZSTD levels 1, 3 and 9 and gzip 1 and 9 is the codec's own output at that level
    (`levelsReachTheCodec`).
- **The writer:** each fixture in ZSTD at levels 1, 3 and 9, read back by itself and by pyarrow, with each file's
  codec checked (30 files, `tools/parquet_writer_check.py`).
- **The page fuzzer:** its seeds include the writer's ZSTD files.
- **`tools/compaction_check.py`** (100 checks, on `serve` and through a cluster's node):
  - PyIceberg's default table compacts to ZSTD;
  - a table set to `zstd` at level 3 with `zstd` manifests compacts to ZSTD, read the same by PyIceberg and pyarrow,
    its metrics as PyIceberg's, its manifests zstandard;
  - a gzip table with null manifests keeps both;
  - the merged ZSTD file is 0.535 of pyarrow's level-3 file of the same 20,000 rows (87,881 bytes against 164,342).
    The writers' encodings differ, so the bound is loose (1.25); the codec's own sizes are CeeSafe's `codec_check`'s.
- **The smokes:** s3, cluster (209 checks), maintenance, on 0.95.1.
- **The review:** an agent read ADR-0116 and the code without my notes, and checked PyIceberg 0.12.0's sources
  where it could. It found no High finding: the Avro codec names, snappy's CRC, the commit's use of the codec for
  every manifest and the manifest list, and the fallbacks on bad input were read as right.

## Findings

### A. Fixed before closing

1. **Medium: the codec and level choice had no unit test.** Only four property combinations were checked, through
   `compaction_check.py`.
   - **Now covered:** names in any case; `uncompressed` and `none`; `lz4`, `brotli` and unknown names as SNAPPY;
     `zstandard` and `bzip2` for Avro; levels 15 and 22 as 9, and `0`, `-1`, `abc`, empty and ` 3` as the
     default (`codecsFromProperties`).
2. **Medium: nothing showed that the level reaches the codec.** A dropped level would have passed every test.
   - **Now covered:** a page's bytes at each level are the codec's own at that level, and levels 1 and 9 differ for
     it (`levelsReachTheCodec`).
   - The plumbing from the plan to the page writer is still checked only through the size bound (B2).
3. **Low: the writer check's codec oracle** took any file suffix it did not know as ZSTD. It now names each suffix,
   so an unknown one fails.

### B. Recorded, not fixed

1. **Snappy manifests are read back only by CosmoStore's own reader.** PyIceberg needs python-snappy for them,
   which the check's environment lacks. Their format (raw snappy, then the big-endian CRC-32) was read as Avro's.
2. **A level is checked at the codec, not end to end.** A level lost between the table's properties and the page
   writer would show only as a larger file.
3. **Level 0 for gzip and deflate** is the default, 6, where zlib's 0 stores. The files stay valid; that setting is
   not followed.
4. **ZSTD's negative levels** are taken as 3, and levels above 9 as 9 (ADR-0115's choice), without a log line.
5. **A table that sets no codec gets ZSTD,** including tables Iceberg Java made before 1.4, whose files are gzip.
   This is the owner's choice; old parquet-mr builds without zstd cannot read such files.
6. **M23's B3, again:** a chunk's `total_uncompressed_size` leaves out its dictionary page and its page headers, and
   the row group's `total_byte_size` sums it. pyarrow ignores it. Real compression makes it differ more from the
   written size.

## Where the code differs from ADR-0116

- **§1:** `none` is taken as uncompressed too, and `zstandard` as an Avro name beside `zstd`.
- **§2:** a v1 page names its chunk's codec, so every page of a chunk is written in that codec even when it does
  not shrink, as the ADR allows.
