# M28 exit review: Iceberg v3 tables (25 Nov 2026)

**M28's exit (ADR-0121 item A with B first; ADR-0122, proposed):**
- the catalog makes, upgrades and takes v3 tables, their row lineage assigned at each commit;
- compaction keeps each row's lineage and applies deletion vectors;
- PyIceberg and Iceberg Java make v3 tables here, and compaction leaves the same rows with the same `_row_id`s;
- before that, M27's B1: a partition's position deletes are read only when a rewrite could change them.

## How it was checked

- **Unit tests (521):**
  - **The catalog:** create, upgrade, a snapshot's lineage, a stale `first-row-id` as a conflict
    (`icebergV3Tables`), and a create's `null` members (`icebergCreateTakesNullsAsAbsent`).
  - **Compaction's lineage:** `v3CompactionKeepsRowIds` (with and without deletes; footers' column orders one a
    leaf) and `v3CompactionOfV2Manifests` (an upgraded table's v2 manifests).
  - **Deletion vectors:** `v3CompactionAppliesDeletionVectors`; the reader's `deletionVectorFormats`,
    `deletionVectorsInPuffin`, `deletionVectorsBroken` (every byte changed, every length cut) and
    `portableBitmapsMutated`.
  - **No join of a v3 table:** `v3MergeFailureDoesNotJoin`, async.
  - **The rewrite's cost:** `rewriteReadsOnlyWhatCouldChange`.
  - Each new rule was seen to fail its test with the rule taken out.
- **`tools/iceberg_java_check.sh`** (Iceberg Java 1.10.0 and PyIceberg 0.12, in CI; 20 checks):
  - Java upgrades a v2 table to v3;
  - it makes a v3 table, appends three files, and commits a deletion vector written by its own writer;
  - PyIceberg reads it;
  - compaction merges it, keeping every live row's `_row_id`;
  - PyIceberg and Java read the same rows; still v3, a replace, `next-row-id` advanced.
- **The smokes:** s3, cluster and maintenance, and `compaction_check.py`.
- **The review:** an agent read ADR-0122 and the code without my notes, given the inheritance rules taken from
  Iceberg Java's source. Its findings come from reading.

## Findings

### A. Fixed before closing

1. **Found by the Java check, a bug:** Iceberg Java's create sends `"write-order": null`, which the catalog stored as
   the sort order, so Java could not load the table. A create's `null` members are taken as absent.
2. **Found by the Java check, a bug:** a merged v3 file's footer kept its inputs' `column_orders`, one fewer than its
   leaves for each lineage column. pyarrow refused it. The orders are one a leaf now, and the test checks the count.
3. **High: a v3 table's bin could be joined,** its rows then taking new row ids. This happened with files whose
   pages are not read here (LZ4 or Brotli), or a merge that failed. A v3 table's bin is never joined now
   (`v3MergeFailureDoesNotJoin`).
4. **Medium: deletion vectors were given to every bin of their partition,** and each decoded up to a delete file's
   bound before the bin's was checked. A few bytes of run container state millions of positions.
   - **Fixed:** a vector goes only to the bin holding the file it names.
   - **Fixed:** each delete set is read within what is left of the bin's bound.
5. **Medium: a deletion vector was removed when its file was, applied or not.** It is removed now only when the bin
   holding its file applied it.
6. **Low: an upgraded table was never compacted.** Its v2 manifests have no `first_row_id` field.
   - **Fixed:** they inherit their manifest's id; a rewritten one is given the field, and `format-version` 3, so
     that its entries' explicit ids are read (`v3CompactionOfV2Manifests`).

### B. Recorded, not fixed

1. **`next-row-id`** advances to `first-row-id + added-rows`; Java and PyIceberg add to `next-row-id`. The two are
   the same when the client sends `first-row-id` equal to `next-row-id`, as both do, and ours never gives an id
   twice. A stale one is a 409, where Java's builder throws, so clients retry.
2. **PyIceberg 0.12 cannot append to a v3 table.** Iceberg Java is the checks' v3 writer.
3. **Not done (ADR-0122's consequences):** encryption keys, multi-argument transforms, lineage on branches other than
   `main`, and writing deletion vectors.

## Where the code differs from ADR-0122

- **§2:** a create's `null` members are absent (A1).
- **§3:**
  - a v3 table's bin is never joined (A3);
  - an upgraded table's v2 manifests are compacted, a rewritten one made v3's (A6);
  - the merged file's column orders are one a leaf (A2).
- **§4:** a deletion vector goes to the one bin holding its file, read within the bin's bound, and is removed only
  when that bin applied it (A4, A5).
