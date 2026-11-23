# M23 exit review: compaction that merges row groups (23 Nov 2026)

**M23's exit (ADR-0111 item A; ADR-0112, proposed with the owner's choices):**
- a bin of Parquet files whose pages all read is rewritten as row groups of the table's target size, not only joined;
- every codec, page version, encoding and type that PyIceberg, pyarrow and Spark write is read; SNAPPY is written;
- structs, lists and maps are merged, with dictionary pages when smaller;
- files of one schema merge whatever their writer, their columns matched by Iceberg field id;
- the merge is swept for faults and crashes, and its page decoder fuzzed;
- real ZSTD and SNAPPY tables compact on `serve` and a cluster, read the same by PyIceberg and pyarrow;
- CeeSafe's snappy and zstd released from here (0.94.0 and 0.94.4), and the toolchain moved to them.

## How it was checked

- **The evidence:**
  - **Unit tests (477 after the review's fixes):**
    - the page reader against 13 pyarrow fixtures, each compared with a Dremel shredding of its rows: none, gzip,
      snappy and zstd; v1 and v2 pages; PLAIN, dictionary, the DELTA encodings and BYTE_STREAM_SPLIT; flat and
      nested, two with Iceberg field ids;
    - the writer: each fixture written again (none, SNAPPY, gzip), read back the same, and pyarrow reading the files
      as their fixtures (`tools/parquet_writer_check.py`);
    - merges: two files into one row group of 46 rows, and two files of one schema whose writers order and name its
      columns otherwise, every value in its column;
    - the crash sweep over a merge, once, sticky, torn and as a crash at every I/O point;
    - Avro's null, snappy and zstandard files of one set of records, read the same;
    - the page fuzzer, 1,500 mutants a run.
  - **The page fuzzer under ASan and UBSan** (`tools/page_fuzz.sh`): 3.6 million mutants in 30 minutes, clean after
    the two fixes below.
  - **`tools/compaction_check.py` on `serve` and through a cluster's node (34 checks):** PyIceberg's ZSTD files
    merged into one SNAPPY row group; a nested SNAPPY table of twelve files merged into one row group, read the same
    by PyIceberg and by pyarrow, with its bounds.
  - **The rest:** the cluster smoke (209), the cluster maintenance smoke, the Terraform check and the five SDKs, on
    0.94.4.
- **Found before the review:**
  - **By the fuzzer, two decoder bugs:**
    - an RLE run's value wider than its bit width was taken: a BOOLEAN decoded as 7, and levels and dictionary
      indexes went the same way;
    - a chunk whose first value continues a row was taken: merged, it would join another file's last row.
  - **By CI:** the cluster maintenance smoke asked through nodes 1 and 2 after killing the shard's leader, which was
    sometimes node 1. It asks through the two nodes still up.
  - **By pyarrow:** its thread pool can deadlock at interpreter exit under load, after the check's reads are done.
    The check scripts exit with `os._exit`.
- **CI's perf gate on the move to 0.94.4 (bc87f88):** large GETs at 32 clients ran 0.74 and 0.77 of the base's
  ops/s in both passes, and failed one pass of the rerun, which passed.
  - **Why it is not the compiler:** 9b879f4's source was built with 0.94.0 and with 0.94.4 (their binaries 32 bytes
    apart) and gated against each other here, 5 rounds of large objects at 32 clients, at a load of 3 to 8. With
    0.94.4, large GETs did 1.07 times the ops/s, at 0.82 times the p99, and large writes were level.
  - **What else changed between them:** 0.94.1 to 0.94.3 are screen readers in the window runtime, which a server
    does not use, and 0.94.4 adds the zstd decoder, which GETs do not call.
- **The review:** an agent read the ADR and the merge's code, with no reading of mine, and confirmed its findings with
  probe tests in a scratch copy. It found no input whose honest rows merge to different rows.

## Findings

### A. Fixed before closing

1. **High: a few kilobytes of hostile pages could make the decoder allocate gigabytes.** A client that can write a
   table's files could take `serve` down for every tenant.
   - **The paths:**
     - a bit-packed run of width 0 stated groups without end and was unpacked whole;
     - DELTA_BINARY_PACKED's block size was checked only as a multiple of 128;
     - a page's levels, and a chunk's, were bounded only by 64 M each, at 8 bytes a level while decoded.
   - **Fixed:**
     - only the values still needed are unpacked;
     - a DELTA block is at most 65,536 values;
     - a page holds at most 4 M levels, and a chunk 32 M, checked as each page is read.
   - **The merge stays within them:** its row groups are written at 16 M levels in a column at most.
2. **Medium: the writer made pages its own reader refused, and a bin whose merge failed was skipped at every run.**
   - **The pages:** they were cut every 20,000 levels only, so wide values made one page over the reader's 64 MB.
   - **Fixed:** pages are also cut at about 1 MB of values.
   - **A failed merge:** a file whose footer reads but whose pages do not, such as v1 levels BIT_PACKED, kept its bin
     from compacting at every run.
   - **Fixed:**
     - a bin whose merge fails is joined as before when its files can be joined (`copiedBin`, on `serve` and a
       cluster);
     - v1 levels BIT_PACKED are refused where a column has levels.
3. **Medium: memory was not bounded by one row group, as §2 said.**
   - **Fixed:**
     - the target row group size has a ceiling of 256 MB;
     - what a merge holds counts both levels and byte arrays' ends.
   - **Not fixed (B1):** each input is read whole.
4. **Medium: a merged file's `column_sizes` were its inputs' sums,** though its columns are encoded again.
   - **Fixed:** a merged file's entry has none.
   - **Unchanged:** its value, null and NaN counts and its bounds describe the same values, and stay.
5. **Low: rows were not checked against chunks.** A chunk whose rows differ from its row group's count makes the merge
   fail, and the bin is then joined or left.
6. **Low: the footer had no column orders,** so parquet-mr would not trust its min and max. They are the first input's.

### B. Recorded, not fixed

1. **Each input is read whole,** one at a time, beside a row group's decoded values. The inputs are small files by
   construction (under the target file size), but a bin's memory is bounded by its largest input and the row group,
   not the row group alone. Reading row group by row group from the store is the next step if it matters.
2. **Statistics' order for types outside Iceberg's:**
   - INT32 and INT64 marked unsigned are ordered as signed;
   - BYTE_ARRAY decimals are ordered as unsigned bytes;
   - with both -0.0 and +0.0, the minimum may be +0.0.
   - Iceberg writes none of these (its decimals are FIXED, whose statistics are left out), but pyarrow trusts them
     to skip row groups.
3. **`total_uncompressed_size` leaves out the page headers and the dictionary page,** against the format's
   definition. Readers use it for buffers, not to read.
4. **`path_in_schema` is split on `.`,** so a column whose name holds a `.` gets a wrong path. Iceberg's writers
   rename such columns in their files.
5. **A dictionary of one value is written with index width 0,** where Arrow writes 1. The format allows it (a width
   of 0 holds the one index), but no reader has been tried on such a file.

6. **The fallback to joining (finding 2) has no test of its own.** It runs on `serve` and a cluster through the same
   prepare and copy as every bin, and its one new step is clearing the bin's merge flag; a test needs an input whose
   footer reads and whose pages do not, through the async runner.

## Where the code differs from ADR-0112

These are in its As built section, amended here:
- **§2, the row group's size:** measured by the decoded values, with a ceiling of 256 MB, and written at 16 M levels
  in a column too.
- **§2, memory:** each input is read whole (B1).
- **§2, grouping:** by the columns' keys (field id, or name, and types), not by the footer's shape.
- **§4, the manifest entry:** its counts and bounds are combined from the inputs' entries, as joining did; its column
  sizes are left out.
- **§4, a merge that fails** is joined when its files can be.
