# ADR-0136: M34's recorded items (M35)

**Status:** accepted, 26 Nov 2026 (the owner: "Yes", to accepting ADR-0136 and closing M35). Proposed the same day,
with the owner's choices made:
- B2 is kept, with the hold made explicit and checked ("B2: keep + check");
- B3's sweep reaches every orphaned id ("Every orphaned id").

M35 is ADR-0135's item A (the owner: "A.").

## Context

M34's exit review (`docs/m34-exit-review.md`) recorded B1 to B4 and three missing tests. Read again against the code:

- **B2, checks before writes, does not race where the catalog runs.**
  - On `serve`, a catalog call (S3 Tables' API and the Iceberg REST catalog alike) runs whole in one
    `Async.blocking`, holding the store's one `AsyncMutex` (`src/s3/tables.cee`, `routeTablesKeyed`'s caller). A
    view's create reads the table's record and writes its own under that one hold, as a namespace's create reads its
    parent's and a drop lists its children.
  - On a cluster, the call goes to its table bucket's shard (`src/cluster/tables_cluster.cee`). Its leader runs it
    behind the shard's gate, one write at a time (`leadWrite`, ADR-0060 §5), and then as `serve` runs it. A deposed
    leader's writes are not committed.
  - So a view and a table cannot both be made at one name, nor a namespace under a parent being dropped, today. The
    review read each write as conditional on its own key only, which it is, but missed the hold around the call.
  - What would open the race: narrowing that hold (e.g. a lock per table bucket that lets a long compaction step
    interleave), or a catalog write made outside the route. Nothing says so where the hold is taken.
- **B3, orphan files.** A view's metadata file is written before its record. A crash between them, or a drop's
  purge cut short (the purge runs after the answer, outside the hold), leaves files under an id no record names.
  - Tables have the same two gaps: a create or staged commit that crashes after its first metadata file, and a
    purge cut short.
  - Both are bounded only by DeleteTableBucket today. The unreferenced-file removal (ADR-0086 §3,
    `src/s3/table_unreferenced.cee`) runs per table and reads only that table's prefix.
  - Views have no metadata log in the spec, so a view's earlier metadata files are referenced by nothing once a commit
    replaces them. They are never removed while the view lives.
- **B4, short list pages.** S3 Tables' ListNamespaces and ListTables read `max + 1` keys, then skip the nested
  namespaces' (and their tables') among them. A page can come back short, or empty with a continuation token. AWS's
  clients follow the token, so nothing breaks, but AWS answers a full page or the last one.
- **B1, view metadata against Iceberg Java's `ViewMetadata.Builder`** (Iceberg 1.10):
  - an `add-schema` equal to a schema it holds reuses that schema's id; an `add-view-version` equal to a version it
    holds (all but its id and `timestamp-ms`) reuses that version;
  - versions beyond `version.history.num-entries` (default 10) are expired, the current one always kept, and the
    version log keeps only entries for kept versions;
  - the version log's entry takes the version's `timestamp-ms`;
  - a version's `summary` is checked as Java checks it.
- **The missing tests:** each view update on its own (`assign-uuid` mismatched, `remove-properties`, `add-schema`
  with -1), a commit whose `assert-view-uuid` does not hold (CommitFailed), and a view in an encrypted table bucket.

## Decision

1. **List pages are full** (slice 1, B4):
   - ListNamespaces and ListTables keep reading after skipped keys until the page holds `max` entries or the
     namespace's keys end;
   - the token is the last shown entry's key, so a page never repeats or skips one;
   - a unit test with more nested namespaces than a page, and with tables in them.
2. **View metadata as Iceberg Java's builder makes it** (slice 2, B1), with the missing tests:
   - schemas and versions reused when equal, as above;
   - versions expired past `version.history.num-entries`, its value read from the view's properties, 10 when absent,
     at least 1;
   - the log's entry at the version's time, and a version's `summary` checked;
   - each update's test, the CommitFailed test, and a view created, replaced and loaded in a KMS table bucket;
   - Iceberg Java's view replace in `V3Check` asserts the schema id reused, and a replace past the history size
     expires the oldest.
3. **Orphan files swept** (slice 3, B3): every orphaned id in a table bucket's warehouse, and a view's earlier
   metadata files, as the owner chose below.
4. **B2 kept** (slice 4), as the owner chose below: the comment where the hold is taken, and the parallel check on
   `serve` and a cluster.
5. **The exit review** (slice 5).

## For the owner to decide

- **B2, the catalog's checks before its writes:**
  - **kept, with the hold made explicit (recommended):** a comment where the hold is taken, saying the catalog's
    checks rely on it; and a check that makes a view and a table at one name in parallel (and a namespace under a
    parent being dropped), many times, on `serve` and through a cluster's nodes, and expects exactly one to be made
    each time. If the hold is ever narrowed, that check fails;
  - **closed as well by records:** one record per name across tables and views (a reservation written first, `IfAbsent`),
    and a namespace's create written conditional on its parent's generation. It defends against a future narrowing,
    at the cost of a second record per table and view, kept in step on renames and drops, and a migration for the
    tables already made.
- **B3, what the sweep reaches:**
  - **every id in a table bucket's warehouse (recommended):** the unreferenced-file removal, when its table bucket has
    it enabled, also lists the warehouse's top-level ids. An id that no table, view or staged create's record names
    is removed once it has stayed so for `unreferencedDays + nonCurrentDays`, as unreferenced files are. A view's
    metadata files other than its current one are removed on the same terms. This closes tables' two gaps as well as
    views';
  - **views only:** a view's id with no record, and its earlier metadata files. Tables' gaps stay as they are.

## Consequences

- **M34's B1 to B4 are each closed or kept with their reason,** and the review's missing tests written.
- **With the recommended B3,** a crash or a cut-short purge no longer leaves objects until DeleteTableBucket, for
  tables and views both. An id is noted when first found with no record, as files are, so a create in flight is never
  removed.
