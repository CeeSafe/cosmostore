# ADR-0114: compaction that applies deletes (M24)

**Status:** proposed, 23 Nov 2026, with the owner's choices made:
- partitions whose deletes cannot all be applied here are left as today ("Left as today");
- the table's metrics mode ("The table's");
- a single data file with deletes rewritten alone ("Rewritten alone").

M24 is ADR-0113's item A (the owner: "A: apply deletes"), with the manifest's counts and bounds taken from the rows
written ("From rows written") and M23's B1 as the first slice ("First slice").

## Context

- **Today** (ADR-0098 §2), a partition with a live delete file is not compacted, and when a delete file's spec is not
  a data file's, that spec is not compacted at all. Merge-on-read tables, which fragment the most, are the ones left.
- **Iceberg's deletes (format v2):**
  - **A position delete file** holds rows `(file_path, pos)`: the data file's path and a row's position in it, from 0.
    It applies to a data file of the same partition whose data sequence number is at most the delete's.
  - **An equality delete file** holds rows of some columns (`equality_ids`): every row of the data file whose values
    in those columns equal one of them is deleted, nulls equal to nulls. It applies to a data file of the same
    partition whose data sequence number is below the delete's; one written under an unpartitioned spec applies to
    every partition (a global delete).
  - **After a rewrite,** Iceberg's own (`RewriteDataFiles`) gives the new files the starting snapshot's sequence
    number, so no delete committed before the rewrite applies to them, and none committed after is lost.
- **What M23 gives:** every input's rows decoded, column by column with their levels, and a writer; merges matched by
  field id; the crash sweep and the fuzzer.

## Decision (proposed)

1. **Inputs a row group at a time** (M23's B1). A merge reads each input's row groups by range, from the footer the
   plan already holds, and never a whole file. A merge's memory is one input row group and one output row group.
2. **The manifest's counts and bounds from the rows written,** for every merged file, with or without deletes:
   - **Counts:** value, null and NaN counts per field id, from the values written.
   - **Bounds:** lower and upper bounds per field id in Iceberg's single-value form, by the field's Iceberg type in
     the table's schema. Strings and binary are truncated as the table's metrics mode says
     (`write.metadata.metrics.default`, `truncate(16)` by default, and its per-column settings), the upper bound
     incremented at its last kept character.
   - **Only where Iceberg keeps them:** none for fields inside lists and maps, and no bound where a NaN is the only
     value, as Iceberg's writers do.
   - **Column sizes** are the chunks' compressed sizes.
3. **Which deletes apply** (the plan):
   - **Read:** every live delete file of a candidate partition, by the page reader. Position deletes as `file_path`
     and `pos`; equality deletes as their `equality_ids` columns, which must be primitive fields outside lists and
     maps.
   - **Applied by Iceberg's rules** (above), by partition and data sequence number, to each input file.
   - **A partition is compacted with its deletes** only when every delete file that may apply to it is read and of
     its spec; one that is not (another spec, a global delete, a delete that does not decode, a deletion vector)
     leaves the partition as today.
   - **A data file with deletes is rewritten alone** when it has no bin-mate, since dropping its deletes is worth a
     rewrite.
4. **The merge drops rows:** a position delete's rows by their position in their file; an equality delete's by the
   values of its columns in each row. Rows are dropped whole, with all their levels in every column (lists and maps
   included).
5. **The commit:**
   - **The new files** take the table's sequence number at the plan (the starting one), when their bin applied a
     delete; otherwise the largest of their inputs', as today.
   - **A delete file is removed** (DELETED in its manifest) when nothing live is left that it may apply to. A
     position delete has no live file left among the paths it names; an equality delete has no live data file left
     in its partition with a lower data sequence number.
   - **One snapshot, as today:** a `replace`, with the conditional swap, its summary counting the removed delete
     files and deletes.
6. **The checks:**
   - **The crash sweep** over a table with a position and an equality delete: before (its files and deletes) or after
     (merged, the deletes gone), never rows lost or brought back.
   - **Unit tests:** which deletes apply (sequence numbers equal, below and above; other partitions; other specs);
     rows dropped in flat and nested columns; bounds and truncation of every Iceberg type.
   - **Real tables:** `tools/compaction_check.py` on `serve` and through a cluster: tables with position deletes and
     with equality deletes (written with PyIceberg's manifest writers, as today's check does), read the same by
     PyIceberg before and after, with fewer files and no delete files.

## Slices

1. Inputs read a row group at a time (§1).
2. Counts and bounds from the rows written (§2).
3. Delete files read, and which apply (§3), in the plan.
4. Rows dropped while merging (§4).
5. The commit: sequence numbers and delete files removed (§5), on `serve` and a cluster.
6. The checks (§6).
7. The exit review.

## For the owner to decide

- **Partitions whose deletes cannot all be applied here** (another spec's, a global equality delete):
  - **Left as today (recommended):** never wrong, and these are rare (a spec change with deletes before it).
  - **Applied too:** global and other-spec deletes read and matched by partition values; more rules, more tests.
- **The metrics mode:**
  - **The table's (recommended):** `write.metadata.metrics.default` and per-column `write.metadata.metrics.column.*`
    (`none`, `counts`, `truncate(n)`, `full`), as Iceberg's writers honour them.
  - **Always `truncate(16)`:** simpler; a table that asks for no bounds gets them anyway.
- **A single data file with deletes:**
  - **Rewritten alone (recommended):** its deletes are dropped, and reads stop applying them.
  - **Only in bins of two or more,** as today's rule for bins.

## Consequences

- **Compaction drops rows,** where it has only moved them. Its correctness is the table's rows, with deletes applied,
  read the same by PyIceberg before and after, and no delete lost that still applies to a live file.
- **Merged files' manifest entries become exact,** where they were the inputs' combined.
- **A merge's memory is bounded by two row groups,** where it was an input's whole file.
