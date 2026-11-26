# ADR-0134: Iceberg views and nested namespaces (M34)

**Status:** accepted, 26 Nov 2026 (the owner: "Yes I accept ADR-0134 and close M34"). Proposed the same day, with
the owner's choices made:
- views have actions of their own ("Actions of their own");
- namespaces nest up to 8 levels ("Up to 8 levels");
- S3 Tables' API stays one level, as AWS ("One level, as AWS").

M34 is ADR-0133's item A (the owner: "A: views, nested namespaces").

## Context

- **The Iceberg REST spec's views:**
  - `GET` and `POST /v1/{prefix}/namespaces/{ns}/views`: list, and create (`{name, location?, schema, view-version,
    properties}`);
  - `GET`, `HEAD`, `POST` and `DELETE /v1/{prefix}/namespaces/{ns}/views/{view}`: load, exists, commit (replace) and
    drop;
  - `POST /v1/{prefix}/views/rename`: `{source, destination}`, as a table's;
  - `POST /v1/{prefix}/namespaces/{ns}/register-view`, newer, optional.
  - Each answers a `LoadViewResult`: `{metadata-location, metadata, config}`.
  - **The view metadata:** format version 1, with `view-uuid`, `location`, `current-version-id`, `versions` (each
    with its schema id, its `representations` (SQL per dialect) and its default namespace), `version-log`, `schemas`
    and `properties`.
  - **A commit's updates:** `assign-uuid`, `upgrade-format-version`, `add-schema`, `set-location`, `set-properties`,
    `remove-properties`, `add-view-version` and `set-current-view-version`. Its requirement is `assert-view-uuid`.
  - A catalog lists the view endpoints it serves in `config`'s `endpoints`.
  - A view and a table may not share a name in one namespace.
- **Namespaces in the REST spec** are lists of levels: `["a", "b"]`, `a\x1fb` in a path. S3 Tables' API and this
  catalog take one level today.
- **What CosmoStore has:**
  - **The catalog's records** (`.s3tables/tables/<ns>/<name>`, holding the table's id and metadata location, and
    `.s3tables/namespaces/<ns>`), written conditionally.
  - **Metadata files** in the warehouse under the table's id, sealed by its encryption (ADR-0126).
  - **S3 Tables' authorization** by action and resource (ADR-0084).
  - **The engines' clients in CI:** Iceberg Java 1.10 (`V3Check`) and PyIceberg 0.12, which both have the view calls.

## Decision

1. **Nested namespaces** (slice 1):
   - a namespace is one to N levels (the owner's choice of N), kept as its levels joined by `\x1f` in its record's
     key, as the REST paths name it;
   - a namespace's `parent` lists only its children;
   - a namespace is dropped only when it holds no table, view or child;
   - a nested namespace's tables are tables as any: warehouse, maintenance, policies, encryption.
   - **S3 Tables' own API:** per the owner's choice below.
2. **Views' records and files** (slice 2):
   - a view's record is `.s3tables/views/<ns>/<name>`, with its id (a UUID), its metadata location and its times;
   - its metadata files are in the warehouse under its id (`<view id>/metadata/00000-<uuid>.metadata.json`), versioned
     and sealed by its table bucket's encryption as a table's are;
   - its name may not be a table's in its namespace, nor a table's a view's (AlreadyExists);
   - it is removed with its table bucket, and its files with its drop.
3. **The view calls** (slices 2 and 3):
   - create, load, exists, list (paged as tables are) and drop;
   - commit, with `assert-view-uuid` and the eight updates. A view version is checked, with its schema and
     representations, as Iceberg Java's `ViewMetadata` builder checks it;
   - rename, within its table bucket;
   - `config` lists the view endpoints;
   - `register-view` stays unserved, as `register-table` is (ADR-0124: two catalogs would share files).
4. **Authorization** (slice 3): per the owner's choice below, checked against the table bucket's policy, the
   identity's, and the view's resource `bucket/<name>/view/<id>`.
5. **The checks** (slice 4):
   - **unit tests:** a view's metadata (create, each update, a requirement that does not hold), a name a table
     holds, nested namespaces' keys and listing;
   - **Iceberg Java (`V3Check` phase `views`):** create, load, replace (a new version), list, rename and drop a
     view; tables in a nested namespace;
   - **PyIceberg (`iceberg_check.py`):** `create_view`, `load_view`, `list_views`, `view_exists`, `drop_view`, and a
     nested namespace's tables;
   - **the cluster smoke** through a node, and **CI**.
6. **The exit review** (slice 5).

## For the owner to decide

- **How views are authorized:**
  - **actions of their own (recommended):** `s3tables:CreateView`, `GetView`, `ListViews`, `UpdateView`,
    `RenameView` and `DeleteView`, on `bucket/<name>/view/<id>`. A policy says what it means, and a table's Allow
    does not reach views. AWS's IAM does not know them, so they hold only here;
  - **onto the table actions:** `CreateTable`, `GetTableMetadataLocation`, `ListTables`,
    `UpdateTableMetadataLocation`, `RenameTable` and `DeleteTable`. Policies written for tables then cover views,
    and a table's Allow is a view's.
- **How deep namespaces nest:**
  - **up to 8 levels (recommended):** deep enough for an engine's catalogs, bounded for keys and listings;
  - **up to 16;**
  - **unbounded,** to the key's length.
- **S3 Tables' own API and nested namespaces:**
  - **one level as AWS (recommended):** its ListNamespaces, GetNamespace and table calls name a nested namespace's
    first level only, and refuse a deeper name (BadRequest), as AWS would. Nested namespaces are the Iceberg
    catalog's;
  - **all levels, joined by `.`:** its calls take and answer `a.b`, which AWS's would refuse.

## Consequences

- **The catalog goes beyond S3 Tables:** views and nested namespaces, listed in its `config`.
- **A view is a catalog object with its own records, files and policies,** removed with its table bucket.
