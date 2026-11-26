# M34 exit review: Iceberg views and nested namespaces (26 Nov 2026)

**M34 closed, 26 Nov 2026** (the owner: "Yes I accept ADR-0134 and close M34"), with ADR-0134 accepted and B1 to B4
recorded below.

**M34's exit (ADR-0133 item A; ADR-0134, with the owner's choices):** Iceberg Java and PyIceberg make, read, replace,
rename and drop a view, and make tables in a nested namespace, in CI, on `serve` and on a cluster.

## How it was checked

- **Unit tests:**
  - `nestedNamespaces`: keys, listing by parent, the depth limit, and drops;
  - `icebergViewsLifecycle`: create, list, load, commit (a new version made current), a requirement that does not
    hold, a table refused at a view's name, a namespace with a view kept, rename and drop;
  - `viewsAuthorizedOnTheirOwn`: a Deny on `bucket/<name>/view/*` refuses views and not tables, a table's Deny does
    not reach a view, and a user's Allow of tables is not one of views;
  - `nestedNamespacesAtTheEdges`: a nested table renamed within its namespace and out of it, and S3 Tables' own API
    refusing `a%1Fb`;
  - `viewCommitEdges`: no updates write no file, the current version made current again logs nothing, and a view's
    location stays its warehouse.
- **PyIceberg** (`iceberg_check.py`, on `serve` and through a cluster's node):
  - `create_view`, `view_exists`, `list_views`, `load_view` and `drop_view`;
  - a table refused at a view's name;
  - a nested namespace listed under its parent;
  - a table in it appended, read and renamed;
  - its parent not dropped while it has a child.
- **Iceberg Java** (`V3Check` phase `views`, in CI), plain and on a KMS table:
  - its view builder's create, replace (a second version, current), list, rename and drop;
  - a nested namespace's table.
- **The smokes and CI:** 552 unit tests, the S3 smoke, the cluster smoke (214, PyIceberg 66 through a node) and the Java check. CI is green for slices 1 to 4 (`ceaa0b3`, `cbaa901`); the review fixes' run
  follows this commit.
- **The review:** one agent read ADR-0134 and the diff without my notes. Its findings come from reading.
  - It found no High.
  - The two Mediums are fixed, and each fix is mutation-checked: the test fails with the fix taken out.

## Findings

### A. Fixed before closing

1. **Medium: a table in a nested namespace could not be renamed.**
   - The catalog's rename called S3 Tables' `renameTable`, which takes a namespace of one level. Every rename in a
     nested namespace was BadRequest, a rename of the name alone included.
   - **Fixed:** `renameTableIn` takes 1 to 8 levels when the catalog asks.
   - **Tests:** `nestedNamespacesAtTheEdges`, and PyIceberg's rename.
2. **Medium: S3 Tables' own API reached nested namespaces,** against the owner's "One level, as AWS". A `%1F` in a
   path reached GetNamespace, DeleteNamespace, the table calls, maintenance, and GetTable by name. GetTable by ARN
   found a nested table too.
   - **Fixed:** these routes refuse a nested namespace (BadRequest), and GetTable by ARN does not find one
     (NotFound).
   - **Test:** `nestedNamespacesAtTheEdges`.
3. **Low (L1): a namespace's existence was told before authorization.** The view calls now check their action first,
   as the table calls do.
4. **Low (L2, in part): commits that changed nothing.**
   - A commit with no updates now writes no metadata file.
   - Making the current version current again adds no entry to the version log.
5. **Low (L3): `set-location` took any location.** A view's location is now its warehouse, as at its create.
6. **Low (L6): a property key that is not UTF-8** became `""`. It is now refused.

### B. Recorded, not fixed

- **B1 (L2, the rest): view metadata is not yet Iceberg Java's `ViewMetadata.Builder` in every detail.**
  - An identical schema or version is added again, not reused.
  - Old versions are not expired (`version.history.num-entries`).
  - The log's entry is stamped with the commit's time, not the version's `timestamp-ms`.
  - A version's `summary` is not checked.
  - Engines read the result: Java's replace and PyIceberg's load pass.
- **B2 (L4): checks before writes race.**
  - A view and a table made at one name at once may both be written.
  - A child namespace made while its parent is dropped is left without a parent.
  - Each write is conditional on its own key. Closing these needs one record across both kinds (a name's
    reservation), or a namespace's generation checked by its children.
- **B3 (L5): a view's orphan files.** A crash between a commit's file and its record, or a commit racing a drop, can
  leave a file under a view's id. No sweep lists view ids: the unreferenced-file sweep is per table.
- **B4: listing pages skip nested namespaces after taking a page.** S3 Tables' ListNamespaces and ListTables can then
  answer a short or empty page, with a continuation token.
- **The review's other missing tests:**
  - each update on its own (`assign-uuid` mismatched, `remove-properties`, `add-schema` with -1);
  - a concurrent commit's CommitFailed;
  - a view in an encrypted table bucket. Java's KMS run makes and replaces one; a unit test does not.
