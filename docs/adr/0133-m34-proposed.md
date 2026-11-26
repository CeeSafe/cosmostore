# ADR-0133: M34, after hardening (proposed)

**Status:** proposed, 26 Nov 2026, after M33 was closed the same day (the owner: "continue").

## Context

- **S3 Tables' API is done** but for replication (eight calls) and migrations (six). Its recorded Lows are closed
  (M33).
- **The Iceberg REST catalog here** has:
  - namespaces of one level, as S3 Tables has;
  - tables: create, staged create, load, commit, rename and drop;
  - no views. A view call is NotImplemented, and the catalog's `config` lists no view endpoints.
- **Engines use views:**
  - Iceberg Java's `RESTCatalog` is a `ViewCatalog`;
  - PyIceberg 0.12 has `create_view`, `load_view`, `list_views`, `view_exists`, `drop_view` and `register_view`;
  - Spark and Trino make views through their catalogs.
- **S3 Tables itself has neither views nor nested namespaces,** so these go beyond it. Its clients do not use them;
  engines on the Iceberg REST catalog do.
- **Remaining after M33:**
  - table replication;
  - Iceberg v3's remaining parts;
  - M33's five recorded Lows.

## Decision (proposed)

1. **M34 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Iceberg views and nested namespaces | The REST catalog's view endpoints (list, create, load, replace by commit, rename, drop, exists), their metadata files written as tables' are (versioned, sealed by their table bucket's encryption), authorized by S3 Tables' policies (actions to be named in the design ADR), and namespaces nested past one level where the catalog's clients name them so. **Done when:** Iceberg Java and PyIceberg make, read, replace, rename and drop a view, and make tables in a nested namespace, in CI, on `serve` and a cluster. |
   | B | Table replication | S3 Tables' eight replication calls: a table bucket's or table's replicas in another table bucket, read-only. **Done when:** a replica reads as its source after each commit, through the CLI and boto3. |
   | C | Iceberg v3's remaining parts | Compaction's position deletes written as deletion vectors in a v3 table; multi-argument transforms; lineage on branches. **Done when:** Iceberg Java reads each, in CI. |
   | D | M33's recorded Lows | Its B1 to B5, each fixed or kept. |

2. **The recommendation is A.**
   - **Why:**
     - views are what engines ask a REST catalog for after tables;
     - both clients in CI have the calls, so the checks are the engines' own;
     - the table code it builds on (metadata files, commits, sealing, policies) is hardened now.
   - **B** is large, and few deployments run two table buckets as source and replica.
   - **C** waits for an engine that writes those v3 features.
   - **D** is small, and can ride along with A where it touches the same code.
3. **For A, the questions the design ADR answers:**
   - **Authorization:** S3 Tables has no view actions. The design names CosmoStore's (e.g. `s3tables:CreateView`)
     or maps views onto the table actions, for the owner to choose.
   - **Nested namespaces:** how deep, and how they are kept beside S3 Tables' one-level namespaces, which its own API
     must keep answering as AWS does.
   - **What a view's records hold, and how they are removed with their table bucket.**

## For the owner to decide

- **Which item is M34:** A (recommended), B, C or D.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A,** the catalog goes beyond S3 Tables for the first time, and says so in its `config`.
