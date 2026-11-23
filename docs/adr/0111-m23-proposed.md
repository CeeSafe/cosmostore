# ADR-0111: M23, what comes after cluster maintenance (proposed)

**Status:** decided, 23 Nov 2026. The owner chose:
- A, compaction that merges row groups ("A: merge row groups");
- SNAPPY as the codec compaction writes ("SNAPPY");
- the CeeSafe releases made here by `docs/release.md` ("Here, by release.md").

Proposed the same day (the owner: "propose M23"). M22 (cluster table maintenance as gated steps,
ADR-0110) was closed on 23 Nov 2026.

## Context

- **Compaction that re-encodes** (ADR-0105's and ADR-0107's C, the one feature item left on record):
  - **Today's compaction joins small Parquet files whole** (ADR-0098): it copies their column chunks under a new
    footer. So:
    - a compacted file keeps every input's row groups, and readers still open many small row groups;
    - a partition with a delete file is not compacted at all;
    - files whose footers do not join (another schema or writer shape) are left alone.
  - **What merging needs:** decoding and encoding Parquet pages (PLAIN, RLE/bit-packed hybrid, dictionary; data page
    v1 and v2), and the codecs those pages use:
    - PyIceberg's and Iceberg's default is ZSTD;
    - Spark's is SNAPPY.
  - **CeeSafe has deflate and gzip** (0.90.0). Its snappy and zstd are ADR 0196's phases 2 (snappy, both ways) and 3
    (the zstd decoder), accepted and not built. A zstd encoder is its phase 4.
  - **CeeSafe main is at 0.93.6** (other sessions' releases). Each codec is a CeeSafe release, made by its
    `docs/release.md`, and tagged on the owner's word.
- **The recorded Lows:**
  - **M21's:** B3, tag keys' case; B4, the whole IAM record decoded per call; B5, a failed users file's report.
  - **M22's:**
    - B1, the sweep single-node, with no removal after it;
    - B2, an ask lost to a change of leader;
    - B3, one maintenance loop for every shard;
    - B4, the user quota counting the API's users only;
    - B5, `//` in a path.
  - All are small, and none fails open.

## Decision (proposed)

1. **M23 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Compaction that merges row groups | **First, in CeeSafe:** snappy (ADR 0196 phase 2) and the zstd decoder (phase 3), each released. **Then here:** Parquet's pages decoded and encoded (PLAIN, RLE/bit-packed, dictionary; page v1 and v2; SNAPPY, ZSTD, GZIP, none); a bin's rows written as row groups of the target size; the footer, statistics and Iceberg field ids kept. **Done when:** PyIceberg's (ZSTD) and Spark-style (SNAPPY) tables of many small files compact to files of few row groups that read the same rows, with PyIceberg's and pyarrow's readers. |
   | B | Compaction that applies deletes | **Needs A.** A partition's position and equality delete files applied while it is rewritten, and the deletes then dropped from the snapshot. **Done when:** a table with deletes compacts to files without the deleted rows, and the deletes are gone. |
   | C | The recorded Lows | M21's B3 to B5 and M22's B1 to B5, each fixed or decided to stay with a reason. |

2. **The recommendation is A.**
   - **Why:**
     - it is the feature gap left: compaction today reduces file counts but not row groups, and leaves files it
       cannot join;
     - its first half, the codecs, also lets the store read snappy Avro manifests, which Spark's writers can make.
   - **B follows it** as M24, as it needs A's page decoding.
   - **C** can be the last slices of either, or a milestone of its own.
3. **The work, for A:**
   - two CeeSafe releases, each with its fuzzing, oracle checks and fault sweep as ADR 0196 sets them;
   - CosmoStore's Parquet page codec, swept by a corpus of pyarrow-written files of every encoding and codec;
   - the compaction's rewrite path, with the same crash sweep M22 built.
4. **Not in M23:**
   - sort and z-order compaction strategies;
   - a zstd encoder (ADR 0196 phase 4);
   - Parquet's bloom filters and page indexes in what compaction writes. They are left out, as readers do without
     them.

## For the owner to decide

- **Which item is M23:** A (recommended), B or C.
- **For A, the codec compaction writes,** until CeeSafe has a zstd encoder:
  - **SNAPPY (recommended):** every Parquet reader reads it, and it is fast. A ZSTD table's compacted files are SNAPPY
    until phase 4.
  - **Uncompressed:** larger files, no change of codec.
  - **Wait for zstd's encoder (phase 4) in M23 too:** a third CeeSafe release before the rewrite ships.
- **The CeeSafe releases:** made here by `docs/release.md`, each tag on the owner's word, as 0.85.1, 0.87.0 and 0.90.0
  were (recommended); or by another session.

## Consequences

- **One design ADR follows the choice,** with its slices. For A, two CeeSafe ADR-0196 phases are built first.
- **For A, compaction rewrites rows,** where today it copies bytes. Its correctness is the rows read back the same,
  checked by PyIceberg and pyarrow, beside the crash sweep.
