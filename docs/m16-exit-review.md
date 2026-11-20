# M16 exit review: compaction for S3 Tables (20 Nov 2026)

**M16's exit (ADR-0097 item C; ADR-0098, proposed):** the maintenance pass compacts a PyIceberg table's small files
on `serve` and on a cluster, and PyIceberg reads the same rows after. The design: binpack by copying row groups, and
partitions with delete files skipped (the owner's choices).

## How it was checked

- **The evidence:**
  - **Unit tests:**
    - footers written back to their bytes;
    - files joined, nested ones included, and read by pyarrow;
    - hostile footers refused;
    - Avro files written back and read the same, named union branches included;
    - dropped tables leave no job status.
  - **`tools/compaction_check.py`** (24 checks), in the S3 smoke and through a cluster's node 3:
    - six one-row files become one;
    - a partitioned table, with data under two specs, is compacted per spec and partition;
    - `sort` is refused;
    - a partition with a position delete is left as it is, and the delete still applies.
  - **The S3 smoke** with its PyIceberg, maintenance and compaction checks; **the cluster smoke**; **the SDK
    matrix**.
- **A review by a reader who had not written the code:** two crashes reproduced, the other findings read.

## Findings

### A. Fixed before closing

1. **High: a hostile footer crashed the server** (reproduced: SIGSEGV).
   - **Why:** the Thrift reader checked its depth limit only in structs, so lists nested in lists recursed without
     bound.
   - **Who could do it:** anyone who can write a table can commit such a file. Compaction, on by default, reads
     every small file's footer, so the server crashed again on each scheduled run.
   - **Fixed:** collections check the depth too (`hostileParquetFootersAreRefused`).
2. **High: with two partition specs, compacted files could be filed under the wrong spec.**
   - **Why:** every joined file went into one new manifest, written by the first bin's manifest's schema and spec.
   - **The effect:** a later spec's file was filed as the first spec's with its partition values null, so a filter
     on them pruned its rows away, silently.
   - **Fixed:** one added manifest per spec, each from a manifest of that spec. `compaction_check.py` now compacts
     data under two specs and checks each file's spec and the filtered rows.
3. **Medium: a hostile footer's numbers overflowed** (reproduced: a panic).
   - **Where:** row counts summed, and a page offset moved.
   - **Fixed:** checked arithmetic, and negative row counts refused. The commit's counts and summary totals, which
     come from writers' manifests and summaries, are checked too: a count that would overflow is left out, and a
     row count refuses the commit.
4. **Medium: an input replaced between the plan and the copy was checked by its size only.**
   - **The effect:** an overwrite of the same size would join chunks that are not its footer's.
   - **Fixed:** the version's generation is compared, and its SSE checked again.
5. **Low: some failures left the run's files behind.**
   - **What was left:** an error in the commit skipped deleting the manifests and manifest list already written.
   - **Fixed:** they are deleted on every failed commit.
6. **Low: `distinct_counts` was copied from the first input.** It is now left out, as split offsets and sort order
   are.
7. **Low: a union branch naming an earlier type (a reused `fixed`) did not match.**
   - **The effect:** such a table's commit failed on every run.
   - **Fixed:** named types are resolved (`avroUnionsResolveNamedTypes`).

### B. Recorded, not fixed

1. **Low: a run that loses the store's lock mid-way leaves the files it already put.**
   - **When:** the store is closing, so the server is stopping.
   - **What reclaims them:** unreferenced file removal, after its age.
2. **Low: a joined file's footer keeps the first input's key-value metadata** (`ARROW:schema` among it). The inputs
   share their schema, writer and column orders, so it describes them all.
3. **Low: page indexes and bloom filters are dropped** (ADR-0098 §1). A reader then skips by row-group statistics
   only.
4. **Low: files join only with the same writer** (`created_by`). Files of two PyIceberg versions are not joined
   together, by design: a reader may work around a writer's quirks by its name.
5. **Low: on a cluster, compaction runs inside a maintenance-run request through the front,** under its timeout. A
   bin of 512 MB on slow disks could outlast it, and the run then fails and is tried again the next day. Not seen at
   test sizes.
6. **Low: footers are read under the store's lock.** That is a few KB per candidate, up to 10,000 candidates a run.

## Decisions for the owner

- **Accept ADR-0098** (its §3 now says one added manifest per spec): **taken, 20 Nov 2026** (the owner: "I accept
  the amended ADR-0098").
- **Close M16:** **taken, 20 Nov 2026** (the owner: "yes, close M16").
