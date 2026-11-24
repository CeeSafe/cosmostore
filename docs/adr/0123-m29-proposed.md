# ADR-0123: M29, after Iceberg v3 tables (proposed)

**Status:** proposed, 25 Nov 2026 (the owner: "continue", after M28 was closed the same day).

## Context

- **M23 to M28 finished compaction and v3:**
  - compaction merges, applies every kind of delete, keeps the table's codec and each row's lineage, and writes files
    right for pyarrow and parquet-java;
  - Iceberg Java 1.10 makes and writes v3 tables here, and reads them back after compaction (in CI).
- **What the catalog still refuses** (recorded since M9, ADR-0083):
  - **Staged creates** (`stage-create: true`): Iceberg Java's `createTransaction` and `replaceTransaction`. These are
    how Spark and Trino run `CREATE TABLE AS SELECT` and `CREATE OR REPLACE TABLE`, and Iceberg Java's
    `buildTable(...).createOrReplaceTransaction()`.
  - **Views** (the REST catalog's view endpoints), nested namespaces, and credential vending.
  - **S3 Tables' own API:** tags, encryption other than the server's, replication, storage classes, metrics, and
    record expiration.
- **The Iceberg Java check** (M28) runs a real engine's catalog client against `serve` and a cluster. It found two
  bugs at its first run that PyIceberg never met.
- **The cluster's Lows (M22's B2 and B3):**
  - an ask is lost if the shard's leader changes before the loop takes it;
  - one loop serves every shard a node leads.

## Decision (proposed)

1. **M29 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Engines' catalog calls | Staged creates (create and replace transactions, committed with `assert-create` or `assert-table-uuid`), and each other REST call Iceberg Java's `RESTCatalog` makes that is refused today, found by running its catalog API. **Done when:** Iceberg Java's `createTransaction`, `replaceTransaction` and `createOrReplaceTransaction` work here (CTAS's and RTAS's way), with each other call it makes, on `serve` and a cluster, in CI. |
   | B | S3 Tables' tags and encryption | `TagResource`, `UntagResource` and `ListTagsForResource` on table buckets and tables; a table bucket's and table's encryption configuration (SSE-KMS by this server's KMS keys, ADR-0071). **Done when:** the AWS CLI and boto3 set, read and remove both, and a KMS-encrypted table's files are sealed with its key. |
   | C | The cluster's Lows | An ask kept in the shard's replicated state; each shard's maintenance passes by time. **Done when:** each is fixed with a test, or decided to stay. |

2. **The recommendation is A.**
   - **Why:**
     - an engine's `CREATE TABLE AS SELECT` is refused here today, and it is the common way to make a table from a
       query;
     - the Java check finds what an engine's client sends, as it did at its first run;
     - A is a catalog change, without a new on-disk format.
   - **B** is parity with S3 Tables' own API, which few tools call.
   - **C** stays as recorded.
3. **The work, for A:**
   - **The REST calls:** `stage-create` answers with the table's metadata, written nowhere. The commit that creates
     the table carries `assert-create` and its updates.
   - **A replace transaction:** commits against the existing table, keeping its history, as Iceberg's
     `replaceTransaction` does.
   - **A list of every REST call the Java client makes** (its `RESTCatalog` and `RESTSessionCatalog`), each done or
     refused with the reason.
   - **The checks:** the Java check's CTAS and RTAS ways, and each call found.
4. **Not in M29:** views, nested namespaces, credential vending, and multi-table transactions.

## For the owner to decide

- **Which item is M29:** A (recommended), B or C.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A, engines make tables from queries here.**
