# ADR-0115: M25, what comes after applying deletes (proposed)

**Status:** decided, 24 Nov 2026. The owner chose:
- A, ZSTD written ("A: ZSTD written");
- levels 1 to 9 ("1 to 9");
- the CeeSafe release made here ("Here, by release.md").

Proposed the same day (the owner: "continue", after M24 was closed). M24 (compaction that applies deletes,
ADR-0114) was closed the same day.

## Context

- **A ZSTD table's compacted files are SNAPPY** (ADR-0112's consequence):
  - **The decoder:** CeeSafe has zstd's decoder (0.94.4, ADR 0196 phase 3), but no encoder.
  - **PyIceberg's default codec** is ZSTD (`write.parquet.compression-codec`). Iceberg Java's has been ZSTD since 1.4.
  - **What compaction does to them:**
    - it changes the codec the table chose;
    - its files come out larger, typically 20 to 40% more than ZSTD at level 3 on columnar pages.
  - **ADR 0196 phase 4** is the encoder, accepted and not built. It would be a CeeSafe release made here, as 0.94.0
    and 0.94.4 were.
- **Iceberg v3's deletes:**
  - **Deletion vectors:** v3 replaces position delete files with Puffin blobs of roaring bitmaps, one per data file.
    Today a v3 table's deletion vector leaves its partition as it is.
  - **Exact position-delete removal (M24's B3):** that, and the rewriting of position delete files, both want a
    delete's paths kept by the commit.
- **The recorded Lows:**
  - **M24's:**
    - B1, a 0-row file when every row of a bin is deleted;
    - B2, partitions that stay as they are;
    - B3, conservative position-delete removal;
    - B4, partition values as the Avro reader gives them.
  - **M23's:**
    - B2, statistics of types outside Iceberg's;
    - B3, `total_uncompressed_size`;
    - B4, names with `.`;
    - B5, width-0 dictionaries;
    - B6, no test of the join fallback.
  - **M22's B1 to B4 and M21's B3 to B5.**
  - All are small, and none fails open.

## Decision (proposed)

1. **M25 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | ZSTD written | **First, in CeeSafe:** lib/std's zstd encoder (ADR 0196 phase 4), released, with its oracle checks (libzstd reads every frame it writes, and its sizes are compared), its fuzzer and its fault sweep. **Then here:** compaction writes the table's own codec (`write.parquet.compression-codec`: zstd at its level, snappy, gzip or uncompressed), and Avro manifests in zstandard when the table asks. **Done when:** a ZSTD table compacts to ZSTD files of about libzstd's size at the same level, read the same by PyIceberg and pyarrow. |
   | B | Iceberg v3's deletes | Deletion vectors (Puffin, roaring bitmaps) read and applied as M24 applies position deletes; position delete files rewritten (dangling ones dropped, the rest merged); exact removal of position deletes. **Done when:** a v3 table with deletion vectors compacts with them applied, and a v2 table's dangling position deletes are gone. |
   | C | The recorded Lows | M21's to M24's B items, each fixed or decided to stay with a reason. |

2. **The recommendation is A.**
   - **Why:**
     - it is what a user of PyIceberg or Iceberg Java sees: their table's codec, changed by compaction, and larger
       files;
     - it finishes ADR 0196, whose decoders are built.
   - **B** waits on v3's use. PyIceberg writes no deletion vectors yet, and few engines do.
   - **C** can be A's last slices, or a milestone of its own.
3. **The work, for A:**
   - **The CeeSafe release:**
     - the encoder: block splitting, literals with Huffman, sequences with FSE, and a match finder at a few levels;
     - libzstd as the oracle, the fuzzer and the fault sweep, as for the decoder.
   - **Here:**
     - the codec chosen from the table's properties;
     - Parquet's ZSTD pages written;
     - the writer's checks and the compaction smoke on ZSTD.
4. **Not in M25:**
   - zstd dictionaries;
   - long-distance matching;
   - levels above 19, which libzstd reaches with a different strategy.

## For the owner to decide

- **Which item is M25:** A (recommended), B or C.
- **For A, the levels the encoder takes:**
  - **1 to 9, and 19 mapped to 9 (recommended):** they cover PyIceberg's and Iceberg Java's defaults (1 and 3) and the
    common choices. Higher levels' search strategies are the most code.
  - **1 to 19:** libzstd's full range below the "ultra" levels.
- **For A, the CeeSafe release:** made here by its `docs/release.md`, tagged on the owner's word, as 0.94.0 and
  0.94.4 were (recommended).

## Consequences

- **One design ADR follows the choice,** with its slices. For A, ADR 0196 phase 4 is built in CeeSafe first.
- **For A, compaction keeps a table's codec,** where it changed ZSTD to SNAPPY.
