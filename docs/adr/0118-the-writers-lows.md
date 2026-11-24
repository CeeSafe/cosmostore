# ADR-0118: the page writer's Lows closed (M26)

**Status:** proposed, 24 Nov 2026. M26 is ADR-0117's item B (the owner: "B: writer's Lows"), with parquet-java as
the second reader ("parquet-java").

## Context

`src/s3/parquet_writer.cee` writes every file compaction makes. Its recorded Lows:
- **M23's B2, statistics' order.** `compareValues` orders by physical type only:
  - INT32 and INT64 as signed, also when their logical type is unsigned (`INT(8..64, false)`, or converted
    `UINT_8..UINT_64`);
  - BYTE_ARRAY by unsigned bytes, also when it is a DECIMAL, whose order is signed by value;
  - floats by value, so with -0.0 and +0.0 both present either may be the minimum. The format says a zero minimum is
    written as -0.0, and a zero maximum as +0.0.
  - FIXED_LEN_BYTE_ARRAY and INT96 get no min or max.
  - The footer keeps the inputs' `column_orders` (TYPE_DEFINED_ORDER), so readers take min and max as ordered by
    the logical type. pyarrow and parquet-java skip row groups by them.
- **M23's B3, sizes.** A chunk's `total_uncompressed_size` counts its data pages' bodies only. The format counts
  every page's header and body, the dictionary page's too. The row group's `total_byte_size` is the sum.
- **M23's B4, paths.** A chunk's `path_in_schema` is `leaf.path` split on `.`, so a column named `a.b` is written
  as the two names `a` and `b`. parquet-java matches chunks to the schema by that path.
- **M23's B5, dictionaries.** A dictionary of one value is written with index width 0. The format allows it, Arrow
  writes 1, and no other reader has been tried on it.
- **M23's B6:** the fallback to joining has no test of its own.
- **M24's B1:** a bin whose rows are all deleted commits a data file of 0 rows. Iceberg's rewrite commits none.
- **M25's B1:** snappy manifests have no outside reader in the checks.
- **M25's B2:** a level is checked at the codec, not from the table's properties to the file.

## Decision (proposed)

1. **Statistics in each column's own order:**
   - **signed integers,** as today;
   - **unsigned integers** (`INT(…, false)` or `UINT_*`), ordered as unsigned;
   - **DECIMAL** in BYTE_ARRAY or FIXED_LEN_BYTE_ARRAY, by its big-endian two's-complement value;
   - **other BYTE_ARRAY and FIXED_LEN_BYTE_ARRAY** (strings, binary, UUID, ENUM, JSON), by unsigned bytes;
   - **floats** with NaNs left out of min and max, as parquet-java does, so a column of NaNs and values still has
     bounds. A zero minimum is written -0.0, and a zero maximum +0.0.
   - **INT96, INTERVAL, and a logical type not known here:** no min or max, as today.
   - **The order comes from the leaf's logical type,** taken from its schema element by the reader as `unit` is.
2. **Sizes as the format defines them:** each chunk's `total_uncompressed_size` counts every page's header and
   uncompressed body, its dictionary page's too. `total_byte_size` sums it.
3. **Paths from the schema:** a leaf carries its path's names, one an element. `path_in_schema` is written from
   them. `leaf.path`, joined with `.`, stays for messages.
4. **Dictionaries' index width at least 1.**
5. **No 0-row file:** a bin whose rows are all deleted commits its inputs' removal, with no file added.
6. **The checks:**
   - **Unit tests for each:** unsigned and decimal bounds, ±0.0, NaNs, a `.` in a column's name, a one-value
     dictionary, a bin deleted whole, the join fallback, and a level from the table's properties to the file's
     bytes.
   - **parquet-java** (`tools/parquet_java_check.sh`, built with Maven like the SDK matrix's Java check, and run
     locally like `tools/parquet_writer_check.py`):
     - it reads each file the writer's test leaves, row by row through parquet-avro's reader, and compares the
       rows with pyarrow's reading of the fixture;
     - it reads each chunk's statistics through parquet-java's own min and max, and checks them against the
       column's values in its type's order;
     - it reads a snappy manifest the Avro test leaves, through Avro Java (M25's B1).
   - **New fixtures from pyarrow:** unsigned integers, decimals in both physical types, floats with ±0.0 and NaNs,
     and a column named with a `.`.

## Slices

1. Paths from the schema (§3), and dictionaries' width (§4).
2. Statistics in each type's order (§1), with their fixtures.
3. Sizes (§2).
4. No 0-row file (§5), the join fallback's test and the level end to end.
5. The parquet-java check (§6).
6. The exit review.

## Consequences

- **Every file compaction writes is right for pyarrow and parquet-java,** whatever wrote its inputs.
- **M23's B list is closed,** and M24's B1 and M25's B1 and B2 with it.
- **The parquet-java check is a local tool, as the SDK matrix is:** it needs a JDK and Maven, which CI's check job
  does not install.
