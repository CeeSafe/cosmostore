# M29 exit review: engines' catalog calls (25 Nov 2026)

**M29's exit (ADR-0123 item A; ADR-0124):**
- Iceberg Java's create, replace and create-or-replace transactions work here: an engine's `CREATE TABLE AS SELECT`
  and `CREATE OR REPLACE TABLE … AS SELECT`;
- each other catalog call Java's client makes is done, or refused by design with its reason;
- on `serve` and through a cluster, in CI.

## How it was checked

- **`tools/iceberg_java_check.sh`** (Iceberg Java 1.10.0, in CI; 47 checks):
  - CTAS, RTAS (a wider schema, its rows replaced, its history kept), and create-or-replace both ways;
  - PyIceberg's create transaction;
  - **`calls`, 22 catalog calls:**
    - namespaces: create, exists, load, list, drop (refused with a table in it);
    - tables: create, exists, list, append, schema, spec and order updates, properties, tags, branches, expire
      snapshots, rename, drop with purge;
    - setting namespace properties and registering a table, refused by design;
  - M28's v3 checks.
- **`tools/iceberg_check.py`** (on `serve` and through a cluster's node, in the smokes): PyIceberg's create
  transaction.
- **Unit tests (523):**
  - `icebergStagedCreates`: a staged create writes no table; a create commit at a location not staged, or staged for
    another name, refused; a schema with an id twice, or a spec of a column not there, refused; a non-create commit
    to a table not there answered 404; the right one makes the table once;
  - `compactionReadsOnlyItsOwnFiles`.
- **The smokes:** s3, cluster and maintenance, and `compaction_check.py`.
- **The review:** an agent read ADR-0124 and the code without my notes. It found no High. Its findings come from
  reading.

## Findings

### A. Fixed before closing

1. **Medium: reservations were unbounded,** one record per staged create, never expiring. They are now kept by
   namespace and table name: a name holds one at most, and a later staged create of it replaces it. They are then
   bounded as tables are.
2. **Medium: a create commit skipped a create's own checks.** A schema with a field id twice, or a spec or order of
   a column not there, could make a table a plain create refuses. The created metadata is now checked as a create's:
   every schema a struct of ids once each, and each spec's and order's sources the current schema's columns. A
   `format-version` property is not stored.
3. **Medium (an old gap, now open to a CreateTable-only caller): compaction read files of other tables of its table
   bucket.** A table whose snapshots named another table's manifests would have been compacted from that table's
   rows, into a warehouse its caller can read.
   - **Fixed:** compaction reads only files under its own table's id: data files, manifest lists, manifests and
     delete files.
   - **Test:** `compactionReadsOnlyItsOwnFiles`, which fails with the check taken out.
4. **Low: authorization and the create path came from two reads.** A POST to a table not there now goes straight to
   the create, from the request it was authorized for.
5. **Low: a commit to a table not there answered 403** to a caller without CreateTable. It is now 404 unless it is a
   create.
6. **Low: a reservation could outlive its table.** A table's drop removes its name's reservation.

### B. Recorded, not fixed

1. **A staged create never committed** leaves its reservation, and any data files its client wrote at an id no table
   has. Neither is read, and the per-table unreferenced-file sweep does not reach them.
2. **`assign-uuid` takes the client's uuid,** so two tables could share a table-uuid. Iceberg's catalogs do the same.
3. **The unreferenced-file sweep** still reads other tables' files that a table's metadata names, to know what it
   references. It deletes only within its own table's id.

## Where the code differs from ADR-0124

- **§1:** a reservation is kept by namespace and name (`.s3tables/staged/<namespace>/<name>`), holding the id.
- **§2:**
  - a create commit is checked as a create;
  - a commit to a table not there that is not a create is 404;
  - a table's drop removes its name's reservation.
- **Compaction** reads only its own table's files (A3).
