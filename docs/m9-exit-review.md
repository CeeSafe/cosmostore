# M9 exit review: S3 Tables and the Iceberg REST catalog (19 Nov 2026)

**M9's exit (ROADMAP, M9):** PyIceberg can create a table, append to it and read it back, on `serve` and on a
cluster. The S3 Tables API is signed for `s3tables`, each table bucket is a hidden bucket, and its catalog is
objects with conditional writes. What is not done is refused, never silently ignored. ADR-0083 (proposed) is the
design, and its four slices are built.

## How it was checked

- **ADR-0083's "done when" against the evidence:**
  - **CI on `e5bb167`:** the unit tests (351, no leaks), the S3 and TLS smokes, the cluster smoke (130 checks), and
    PyIceberg's 16 checks (`tools/iceberg_check.py`), on `serve` and through cluster node 2. All passed.
  - **The SDK matrix, run by hand in slice 4:** the S3 Tables API checked with boto3, the AWS CLI, Go, JavaScript,
    Java and .NET.
- **Two reviews of the code by readers who had not written it:**
  - One of conformance: every call and update against the ADR, AWS's S3 Tables API and the Iceberg REST spec. It
    could not fetch AWS's or Iceberg's pages, so its points about their behaviour are from memory (*memory* below).
    Those are checked against the documentation before they are fixed.
  - One of security, which reproduced its confirmed findings against a running server.
  - The findings the reviews called confirmed were read again in the code for this review.

## The item

| Done when | `serve` | Cluster (ADR-0083 §7) | Verdict |
|---|---|---|---|
| PyIceberg: create, append, read back | `iceberg_check.py` (16) | the same 16 through node 2 | holds; C1–C5 |
| The S3 Tables API | `tableNamesAndArns`, `tableWarehouseCalls`; S3 smoke (22); every SDK | smoke: two shards, merged listing, swaps through other nodes | holds; C6–C10 |
| The catalog as objects, conditional writes | unit tests; stale tokens refused in every SDK | smoke: a stale token refused | holds; B8 |
| The hidden bucket refuses S3's reach to the catalog | `tableWarehouseCalls`; S3 smoke | smoke | **does not hold: B1**, B2, B3 |
| Not done is refused, never ignored | NotImplemented sub-resources | | **does not hold in parts:** C6 |

## Findings

### B. Security

1. **High: a browser form POST writes catalog records (confirmed).** `isPostObject` is served
   (`server.cee:425`) before the warehouse refusal (`server.cee:571`), so a key holder can POST
   `.s3tables/tables/<ns>/<name>` into a table bucket's hidden bucket. The record is forged and its `id` chosen.
   - **Proven:** a forged record with `"id":".s3tables"`, then DeleteTable, purged the prefix `.s3tables/` and
     wiped the whole catalog. A forged `id` can also purge another table's warehouse, a forged `metadataLocation`
     points anywhere, and a record that is not JSON breaks the calls that read it.
   - **Fix:** refuse form uploads on `--table-s3` buckets, as on directory buckets. Also, purge only an id of the
     UUID form.
2. **Medium: access-log and inventory delivery write into the catalog (confirmed for logging).** A logging
   target (`access_log.cee:116`) or an inventory destination (`inventory.cee:196`) may be a `--table-s3` bucket,
   with a prefix under `.s3tables/`. Delivery writes with the store directly.
   - **Proven:** one delivery under `.s3tables/namespaces/`, and ListNamespaces is 500 and DeleteTableBucket 409
     for good. No call can delete the record.
   - **Fix:** refuse such buckets as targets and destinations (and on a cluster, where the target is not seen),
     and refuse delivery keys under `.s3tables/`.
3. **Medium: a copy's source reads the catalog from outside (confirmed).** The refusal checks
   `x-amz-copy-source` only when the destination is a warehouse. CopyObject or UploadPartCopy into an ordinary
   bucket, from `<x>--table-s3/.s3tables/…`, copies a record. An AssumeRole session, which S3 Tables refuses,
   can do it too.
   - **Fix:** refuse a source under `.s3tables/` in a warehouse-shaped bucket, whatever the destination.
4. **Medium: a commit stalls the server.** `set-properties` goes through `jsonSet`, a linear scan
   (`json.cee:288`), so n properties cost O(n²) under the store's lock.
   - **Measured:** 250k properties (about 4 MB, under the 8 MiB body cap): an unrelated GET timed out at 30 s.
     Later loads and commits parse the bloated file again.
   - **Fix:** limit properties and updates per commit; set them through a map or a sorted pass; a lower body cap
     (B5).
5. **Medium: 8 MiB is read before authentication** (`tables.cee:1162`, to hash the body). Each unauthenticated
   connection can hold 8 MiB; STS holds 64 KiB.
   - **Fix:** check the key and date before reading, and a lower cap.
6. **Medium (design): no policy restricts S3 Tables.** No `s3tables:*` action is authorized. Table bucket
   policies are NotImplemented, and the hidden bucket takes no policy. So every long-term key, Deny statements
   elsewhere or not, may create, delete and purge every table bucket and reach every warehouse.
   - **What is refused:** anonymous requests, AssumeRole sessions and directory-bucket sessions, as ADR-0083 §6
     says.
   - **Fix:** say so in ADR-0083 and `docs/compatibility.md` now. Decide later whether `s3tables:*` actions
     are authorized against a policy (a design question for the owner).
7. **Low: `set-location` has no `/` boundary** (`iceberg.cee:584`). `s3://<hidden>/<id>X…` passes, and files
   written there escape the purge of `<id>/`. No other table is reachable, since ids are fixed-length UUIDs.
   - **Fix:** the location must be the warehouse itself or begin `<warehouse>/`, as `metadataLocationOk` has it.
8. **Low: races and routing on a cluster.**
   - Two RenameTables to one name can overwrite each other's record, leaving one table's warehouse orphaned. The
     destination is checked in applied state, then moved with no condition.
     **Fix:** a rename whose destination must be absent.
   - The front prefers GetTable's `tableBucketARN` (`tables_cluster.cee:84`), and the shard `tableArn`
     (`tables.cee:782`). A pair that disagrees gives only NotFound. One order for both.
   - A request presigned for `s3tables` takes S3's route on the front. `serve` refuses such requests anyway.
9. **Low: a general-purpose bucket `foo--table-s3` made before M9** becomes table bucket `foo`: hidden, its
   bucket calls refused, and its `.s3tables/` keys read as records. Note it for upgrades, or refuse to start with
   one (as `--x-s3` for M8).

### C. Conformance

1. **Medium: `remove-snapshots` leaves refs, `current-snapshot-id` and `snapshot-log` entries pointing at removed
   snapshots** (`iceberg.cee:547`). The written metadata names a snapshot it no longer has, which Java's reader
   refuses (*memory*). Cascade as Java's builder does, or refuse with 400.
2. **Medium: `last-updated-ms` moves only with snapshots** (`iceberg.cee:504`, `:853`). A schema, property or spec
   commit keeps the old time, and the metadata log's entries repeat it.
3. **Medium: Iceberg calls can answer in S3 Tables' error shape (confirmed in the code).** An error the Iceberg
   handlers do not map themselves goes out as `{"message"}` with `x-amzn-ErrorType` (`tables.cee:1192`): Internal,
   Forbidden, Conflict, some NotFound. Iceberg clients cannot read it. ADR-0083 §1 gives the catalog its own shape.
4. **Medium: create keeps the client's field ids unchecked** (`iceberg.cee:295`). The reviewer says the spec's
   server assigns fresh column, partition-field (from 1000) and sort-order ids (*memory*).
   - **What gets through:** duplicate column ids; spec fields without `field-id` (optional in the REST spec), which
     makes invalid v2 metadata; and a sorted order with id 0.
   - PyIceberg sends fresh ids, so the checks pass.
5. **Medium: a `.metadata.json.gz` location is taken** (`tables.cee:1007`, as the ADR says) **but cannot be
   loaded**: the catalog parses the gzip bytes as JSON and answers 500. Refuse it, or read it.
6. **Low: values silently ignored**, against the "never silently ignored" rule.
   - CreateNamespace's `owner` is not kept and `properties` reads `{}`.
   - `set-properties` and `remove-properties` do nothing on metadata without `properties` (an engine's file swapped
     in).
   - add-schema's `last-column-id`.
   - A commit's `identifier` is not checked against its path.
   - CreateTable's `partitionSpec.specId` and unknown schema field members are dropped, and a field whose `type`
     is not a string is written as `""`.
7. **Low: `-1` in set-current-schema, set-default-spec and set-default-sort-order** means the last in the list;
   the spec has the last added in this commit (*memory*).
8. **Low: add-snapshot** takes a v2 snapshot without `sequence-number`, and reads `"parent-snapshot-id": null` as
   a parent.
9. **Low: names and fields.**
   - Namespace and table names may end with `_`; AWS wants a letter or digit at both ends (*memory*).
   - `namespaceId` is missing from GetTable and the table summary (*memory*).
   - RenameTable to itself is 409, not 400 (*memory*).
   - Iceberg's rename into a missing namespace says NoSuchTable where the spec says NoSuchNamespace.
10. **Low: the JSON model.**
    - Leading zeros (`0123`) are taken and written back, which is invalid JSON.
    - With a duplicate key, `jsonMember` reads the last copy and `jsonSet` the first.
    - Strings are not checked as UTF-8.
    - `-9223372036854775808` is refused.
11. **Low: leftovers.**
    - A commit with no updates still writes a file.
    - An orphan metadata file remains when CreateTable loses its record's race.
    - DeleteTable answers 500 when the purge fails after the record is gone.

Checked and right (both reviews):
- **Routing and signing:**
  - Routing by the signature's service, decided before access points.
  - The scope's service enforced in `verify`, so a request verified for one service is never run as another.
  - The computed body hash overrides a sent one.
  - The canonical path's second encoding.
  - ARNs restricted to `[a-z0-9-]`, so `%2F` and `..` cannot escape.
- **The hidden bucket against S3's calls:**
  - GET, PUT, DELETE and multipart on `.s3tables/` keys refused, also as `%2E`.
  - DeleteObjects filtered per key.
  - Listings that could reach the catalog refused, and bucket calls refused.
  - CreateBucket of `--table-s3` names refused, and ListBuckets hides them.
  - Access points resolved before the refusal.
- **Paging, tokens and deletes:**
  - The 1–1000 page limits and tokens.
  - versionToken as the generation, with If-Match.
  - The order of deletes, and the leftovers' 409.
- **Iceberg metadata:**
  - Every v2 field required on create.
  - The metadata log (capped at 100).
  - Each requirement's comparison, and the sequence numbers and snapshot log of add-snapshot and set-snapshot-ref.
  - The status codes and 409 types.
  - `/config`.
- **The cluster:**
  - The front finds every documented call's table bucket.
  - `x-cosmo-*` headers stripped.
  - ListTableBuckets' merge.
  - A losing commit removes only its own file.
- **The JSON parser:** depth capped at 64, integer overflow checked, no crash or leak on hostile input.

### D. What CI does not run

The SDK matrix (as for M7 and M8: run by hand, `tools/sdk/`). No chaos run takes a table bucket: its data and its
catalog are objects, which the store's fault sweeps cover, and M9 adds no journal record or checkpoint format.

## The findings, closed (the owner: "Fill all findings")

The reviewers' *memory* points were checked, as AWS's and Iceberg's pages could not be fetched here, against:
- botocore's `s3tables` service model (the AWS CLI's, 2.34.13), for AWS's shapes, names and patterns;
- PyIceberg 0.12.0's `update_table_metadata`, which follows Java's `TableMetadata` builder.

| Finding | What closed it | Evidence |
|---|---|---|
| B1 a form POST forges records | No form upload into a `--table-s3` bucket (AccessDenied); a purge empties only a prefix of a UUID's form | S3 smoke: "no form upload into a warehouse"; `tableIdsAndCatalogKeys` |
| B2 logs and inventory into the catalog | Neither takes a `--table-s3` bucket as target or destination, and delivery refuses one (a target on another shard is not checked when set) | S3 smoke: both refused |
| B3 a copy reads the catalog | A copy's or part copy's source under `.s3tables/` of a `--table-s3` bucket is AccessDenied, whatever the destination; checked on the shard that copies | S3 smoke: CopyObject and UploadPartCopy; `catalogObject` in `tableIdsAndCatalogKeys` |
| B4 a commit stalls the server | set- and remove-properties sort the keys once (n log n); at most 1,000 requirements and updates a commit; the body at most 1 MiB | `jsonModelRefusesAndScales` (50,000 properties set twice and removed, under 2 s); `icebergUpdatesAsIcebergApplies` |
| B5 8 MiB before authentication | 1 MiB, read only for a request signed by one of the server's keys, or with a session's token, dated within 15 minutes | S3 smoke: "an unknown key's body is not read" |
| B6 no policy restricts S3 Tables | Recorded at first; then built (ADR-0084): table bucket and table policies decide every call and a table's data | `tablesPoliciesDecide`; S3 smoke; cluster smoke |
| B7 `set-location`'s boundary | The warehouse itself or under `<warehouse>/` (`withinWarehouse`), as for metadata locations | `tableIdsAndCatalogKeys`; `icebergUpdatesAsIcebergApplies` |
| B8 renames, routing | A rename's destination must be absent when it is staged (`renameObjectTo`, checked as a conditional PUT's If-None-Match, so it sees uncommitted records on a shard); the front reads GetTable's `tableArn` first, as the shard does; a request presigned for `s3tables` takes S3 Tables' route (and is refused, as on `serve`) | `renameToAnAbsentDestination`; cluster smoke: "get-table by its ARN through node 3", "a rename onto a table there" |
| B9 a `--table-s3` bucket made before M9 | Recorded at first; then built (ADR-0084 §5): the server and cluster nodes refuse to start, naming it | `tableBucketsMadeBeforeM9`; an upgrade from the release before M9, end to end |
| C1 remove-snapshots | Its refs (main's with the current snapshot), snapshot-log entries and kept snapshots' parents go with it, as PyIceberg applies it | `icebergUpdatesAsIcebergApplies`; PyIceberg: "remove-snapshots", rows read after it |
| C2 `last-updated-ms` | The commit's time when no snapshot sets it | the commit path; PyIceberg's commits |
| C3 the catalog's errors | Every error on `/iceberg/…`, a bad signature's too, in `{"error":{…}}` | S3 smoke: "an Iceberg error in Iceberg's shape" |
| C4 a create's ids | Field ids given once each, above 0; spec fields without an id given the next; a spec's and an order's columns the schema's; a sorted order is order 1 | `icebergCreateChecksIds` |
| C5 `.gz` | Refused | `tableIdsAndCatalogKeys`; S3 smoke |
| C6 values ignored | `owner` kept and given back; properties on metadata without them; a commit's `identifier` checked; CreateTable's `metadata` takes the model's members only, a non-string `type` refused. add-schema's `last-column-id` is left as PyIceberg applies it (the max of the table's and the schema's) | `createTableMetadataShapes`; PyIceberg: "its owner kept", "a commit naming another table" |
| C7 `-1` | The last added by the commit; 400 if none | `icebergUpdatesAsIcebergApplies` |
| C8 add-snapshot | A `null` parent is none. A v2 snapshot without `sequence-number` is still taken, as PyIceberg takes it | `icebergUpdatesAsIcebergApplies` |
| C9 names and fields | `namespaceId` in GetTable and ListTables (botocore's model has it); a rename naming neither a new name nor a new namespace is 400; Iceberg's rename into a missing namespace is NoSuchNamespace. Names left as they are: the model's pattern is `[0-9a-z_]*`, with no rule for the last character, and a rename onto itself stays ConflictException | S3 smoke: "get-table's namespaceId", "a rename to nothing new"; PyIceberg |
| C10 the JSON model | Leading zeros, a key twice, and strings not UTF-8 refused; the whole i64 range read | `jsonModel`, `jsonModelRefusesAndScales` |
| C11 leftovers | A commit with no updates writes nothing; a create or commit that loses removes its file; a purge that fails after the record is gone still answers the drop (DeleteTableBucket removes what is left) | PyIceberg: "a commit that changes nothing writes no file" |

**Found while fixing C6:** CreateTable's `metadata` was read by camelCase names (`sourceId`, `fieldId`, `orderId`,
`nullOrder`, `specId`). botocore sends the model's `locationName`s, Iceberg's own kebab-case names. So since slice 1,
every partition field's `source-id` was silently 0, and an order's id and null order were the defaults. The PyIceberg
check compared only the spec's field names, so it passed. The names are now the model's, and the check compares
each field's name, source and transform.

**Left as they are:**
- GetTable by a table's ARN reads the bucket's table records until it finds the id: linear in the tables, not
  quadratic, and under the store's lock, as ListTables is. An index of ids would be a second record to keep in step.
- A body over 1 MiB, from a key of the server's, is refused in S3's XML shape, before the request is known to be the
  catalog's.

**After the fixes** (ceesafec 0.54.0, CeeSafe.Web at CI's `ccda03a`):
- 357 unit tests pass.
- The S3 smoke passes with PyIceberg's 23 checks, and the cluster smoke's 132 pass with PyIceberg through node 2.
- The SDK matrix passes: boto3, Go, JavaScript, Java and .NET.

## Verdict

**M9 should not close yet.**
- **B1** lets any key holder forge catalog records and, through DeleteTable, purge the catalog or another table.
- **B2 and B3** write into the catalog or read it from outside.
- **B4 and B5** let one request hold the server or its memory.
- **C1 to C5** write Iceberg metadata a reader may refuse, or answer in a shape a client cannot read.

The recommendation:
- Fix B1 to B5, B7, B8 and C1 to C11, each with a test, after checking the *memory* points against the Iceberg
  spec and AWS's pages.
- Record B6 (no `s3tables:` policies) in ADR-0083 and the compatibility notes as not done, unless the owner wants
  it built.
- Choose B9's rule, then run the smokes, PyIceberg and the SDK matrix again.

Closing M9, and accepting ADR-0083, are the owner's decisions.

**After the fixes:** every finding is closed with its test, B6 and B9 as recorded rules (no `s3tables:` policies; an
upgrade note), and the C6 fix also corrected the S3 Tables API's spec and order names. M9's "done when" holds, and
M9 can close on the owner's word.

**B6 and B9 built** (the owner: "Tackle those two findings you recorded"; ADR-0084, proposed):
- **B6:** table bucket and table policies decide every S3 Tables and Iceberg call, and an engine's S3 calls on a
  table's data (`s3tables:GetTableData`/`PutTableData`).
- **B9:** the server, and a cluster node, refuse to start with a `--table-s3` bucket that S3 made before M9, naming
  it. That is checked end to end with the release before M9.
- **Evidence:** `tablesPoliciesDecide`, `tableBucketsMadeBeforeM9`; the S3 and cluster smokes.
