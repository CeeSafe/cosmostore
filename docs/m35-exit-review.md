# M35 exit review: M34's recorded items (26 Nov 2026)

**M35 closed, 26 Nov 2026** (the owner: "Yes"), with ADR-0136 accepted and B1 to B5 recorded below.

**M35's exit (ADR-0135 item A; ADR-0136, with the owner's choices):** M34's B1 to B4 each closed or kept with its
reason, and M34's review's missing tests written.

| M34 item | Outcome |
|---|---|
| B1, view metadata against Iceberg Java's builder | **Closed** (slice 2): reuse, expiry, the log's time, the summary. Its remaining leniencies are A's L5 below. |
| B2, checks before writes race | **Kept** (the owner's "B2: keep + check", slice 4): each call runs whole under the store's hold, or its shard's gate. The review found the one place a check was made in an earlier call (A's M1), now fixed. |
| B3, a view's orphan files | **Closed** (slice 3, the owner's "Every orphaned id"): ids no record names, for tables and views, and a view's earlier metadata files. |
| B4, short list pages | **Closed** (slice 1). |

## How it was checked

- **Unit tests:**
  - `namespacePagesSkipNested` (slice 1; fails on the code before it);
  - `viewMetadataAsJavaBuilds`, `viewUpdatesEachAlone`, `viewsInAnEncryptedTableBucket` (slice 2, with M34's
    missing tests);
  - `orphansSwept` (slice 3);
  - `stagedCommitAfterAViewAtItsName`, `writePathsStayUnderTheirId` (this review's M1, M2).
  - Mutation-checked: schema reuse, version expiry, the sweep's pin, staged, current-file and known-references
    guards, M1's view check, and M2's write-path check.
- **PyIceberg** (`iceberg_check.py`, 68, on `serve` and through a cluster's node): a view and a table raced at one
  name, and a child namespace raced with its parent's drop, 20 times each (slice 4).
- **Iceberg Java** (`V3Check` phase `views`), plain and on a KMS table: one schema kept across replaces, versions past
  a history of 2 expired.
- **The smokes:** the S3 smoke, the cluster smoke, the cluster S3 smoke (214) and the cluster maintenance smoke.
  After the review's fixes: 559 unit tests, the S3 smoke (PyIceberg 68), the Java check and the cluster S3 smoke
  (214). CI is green for slices 1 to 4 (`bd6e63d`, `8bc205f`).

## The review

An independent agent, reading only, given the diff `0deb2b4..8bc205f`, ADR-0136 and the rules, and asked to verify
or refute B2's claim on its own. **It found no High**, and no way the sweep deletes a file a live table or view needs
under the catalog's own rules.

### A. Found and fixed

1. **Medium (M1): a staged create's commit did not look for a view at its name.** The check was its stage's, an
   earlier call, so a view made between stage and commit left a table and a view at one name. The commit now makes
   the check again (`icebergCommitCreate`), as Iceberg Java's catalogs do. B2's comment at the hold now says that it
   covers one call, and that a check made in an earlier call is made again at the write.
2. **Medium (M2): a table's `write.*.path` could name another id of the warehouse.** Its engine's files there were
   referenced only through the pin its own unreferenced run writes. With that run failing, the sweep could have
   deleted them. Now both:
   - a table's metadata written by the catalog with a `write.data.path`, `write.metadata.path`,
     `write.object-storage.path` or `write.folder-storage.path` in its warehouse but under another id is refused
     (400), at the create and by a commit;
   - the sweep deletes no id until every table with metadata has had its own unreferenced run succeed. This covers
     metadata an engine writes itself through S3 Tables' API, which the catalog does not read.
3. **Medium (M3), in part: the sweep under the store's hold.** Past its budget, or while ids are held, it no longer
   lists an id's objects. The rest is B1 below.
4. **Low (L1): the hold's comment overstated it.** A drop's purge after the answer lets go between pages, on a prefix
   no record names; the comment now says so.
5. **Low (L2), in part:** a key the store did not delete keeps its note, still due.
6. **Low (L5c): expiry keeps the larger of the versions a commit added and the history size,** as Java's builder
   does.

### B. Recorded, not fixed

1. **The sweep's reads are under the hold (M3's rest).** It reads every table, view, staged and pin record, and lists
   each view's objects, under the store on `serve` and the gate and store on a cluster, once a pass for each table
   bucket. That costs as much as the catalog is large, not the orphans: the table runs' reads are off the hold, these
   are not yet. Moving them off needs a re-check under the hold of each id about to go.
2. **A swept id's catalog records stay (L2's rest):** its configuration, its unreferenced notes and stale pins under
   `.s3tables/`. They are small, and go with the table bucket. A staged create never committed keeps its id, as its
   reservation is live.
3. **On a cluster, a step does not see its own writes (L3):** the sweep notes again a key it deleted in the same step;
   the note goes on the next pass. Notes are looked up one by one, linear in a view's old files.
4. **Slice 2's leniencies against Java's builder (L5 a, b, d, e):**
   - a reused schema or version is the last added, where Java's `-1` is then refused;
   - a version is compared with its `schema-id -1` resolved, where Java compares it as sent;
   - several `set-current-view-version` in one commit log each (before M35 too), where Java logs one;
   - `default-catalog` null and absent are not the same.
   Each accepts what Java would refuse; none makes metadata Java does not read.
5. **The review's other missing tests:** a rename in the race check; an old staged reservation's id swept; the
   budget carried across passes; a pin whose table was dropped; a view whose location is outside its id; a cluster's
   sweep across a change of leader; `listNamespaces` with more than a page of nested namespaces between two
   top-level ones; a rollback's log time.
