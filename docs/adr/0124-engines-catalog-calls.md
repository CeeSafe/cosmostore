# ADR-0124: engines' catalog calls (M29)

**Status:** proposed, 25 Nov 2026, built in slices 1 and 2 below. M29 is ADR-0123's item A (the owner: "A:
engines' calls").

## Context

- **Staged creates are refused** (`stage-create: true` answered 400 since M9). Iceberg Java's create, replace and
  create-or-replace transactions start with one. They are how Spark and Trino run `CREATE TABLE AS SELECT` and
  `CREATE OR REPLACE TABLE … AS SELECT`, and how PyIceberg's `create_table_transaction` works.
- **The REST flow** (Iceberg Java's `RESTSessionCatalog`):
  - a staged create answers with the new table's metadata, written nowhere;
  - the client writes its data files at that metadata's location;
  - one commit then creates the table: the requirement `assert-create`, and every update that builds it from empty
    metadata (`assign-uuid`, `upgrade-format-version`, `add-schema`, `add-spec`, `add-sort-order`, `set-location`,
    `set-properties`, `add-snapshot`, `set-snapshot-ref`);
  - a replace commits against the existing table, with `assert-table-uuid`.
- **What else Java's client calls** was not known. The way to find out is to run its catalog API here, as M28's
  check found two bugs at its first run.

## Decision

1. **A staged create** answers with the table's metadata (as a create's, at a new id's warehouse), with no
   `metadata-location`. It writes one record, the id's reservation (`.s3tables/staged/<id>`, naming the namespace
   and table).
2. **A commit to a table not there** whose only requirement is `assert-create` creates it:
   - it is authorized as `s3tables:CreateTable`;
   - its `set-location` must be the warehouse of an id reserved by a staged create of this namespace and name, so
     that a client cannot make a table at another table's warehouse;
   - its updates are applied to empty metadata, and the result made whole: version 2 or 3 (2 when none is set), the
     location the warehouse, a current schema, the unpartitioned spec and unsorted order when none was added, and a
     uuid;
   - the table's record is written if absent (409 when another create won), and the reservation removed.
3. **Each other call Java's client makes** is run by the Java check (`calls`). Each is done, or refused by design
   with its reason.

## Slices

1. Staged creates and their commits (§1, §2), with Java's CTAS, RTAS and create-or-replace, and PyIceberg's create
   transaction.
2. The calls (§3).
3. The exit review.

## As built (slices 1 and 2)

- **Java's check (`tools/iceberg_java_check.sh`, in CI), 47 checks:**
  - `ctas`: a create transaction with an append makes the table with its 7 rows;
  - `rtas`: a replace transaction with a wider schema replaces its rows and keeps its history;
  - create-or-replace, both ways;
  - PyIceberg's create transaction.
- **`calls`: 22 catalog calls.** These are done:
  - namespaces: create (with `owner`), exists, load, list, drop (refused while a table is in it);
  - tables: create, exists, list, append, schema, spec and sort order updates, properties, tags and branches,
    expire snapshots, rename, drop with purge.
- **Refused by design, as S3 Tables does** (Java's client sees no such endpoint in the catalog's config):
  - **setting or removing a namespace's properties:** a namespace keeps only its `owner`, set at its create;
  - **registering a table from a metadata file:** two tables would share a warehouse, and one's drop would purge the
    other's files.
- **Found:** nothing beyond staged creates. A null-pointer error at first was the check's own (Iceberg Java's request
  builder asks the property map for a null key, which `Map.of`'s maps refuse).
- **Unit test:** `icebergStagedCreates`:
  - a staged create writes no table;
  - a create commit at a location no staged create gave, or staged for another table, is refused;
  - the right one makes the table once.

## Consequences

- **Engines' `CREATE TABLE AS SELECT` and `CREATE OR REPLACE TABLE`** work here, by Iceberg Java's and PyIceberg's
  transactions.
- **A staged create never committed** leaves its reservation record, and any data files its client wrote, at an id
  no table has. Neither is read; the unreferenced-file sweep runs per table, so it does not reach them.
