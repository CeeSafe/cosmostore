# ADR-0083: S3 Tables and the Iceberg REST catalog (M9)

**Status:** proposed, 19 Nov 2026. Slices 1 and 2 built the same day. The owner: "Next we need s3 tables iceberg". ADR-0079 §1 item 2 and §4 sketched
S3 Tables for when Iceberg engines are meant to run against CosmoStore. This ADR is that design, as M9's one item.

## Context

- **AWS's S3 Tables API** (the user guide's S3 Tables pages and the API reference, read 19 Nov 2026):
  - **The API:** REST-JSON, signed for the service `s3tables`. A table bucket is named by its ARN in the path,
    URL-encoded (`arn:aws:s3tables:<region>:<account>:bucket/<name>`). The calls:

    | Call | Method and path |
    |---|---|
    | CreateTableBucket | `PUT /buckets` (`{"name"}` → `{"arn"}`) |
    | GetTableBucket | `GET /buckets/<arn>` |
    | ListTableBuckets | `GET /buckets?prefix&maxBuckets&continuationToken` |
    | DeleteTableBucket | `DELETE /buckets/<arn>` |
    | CreateNamespace | `PUT /namespaces/<arn>` (`{"namespace":["n"]}`) |
    | ListNamespaces | `GET /namespaces/<arn>` |
    | Get/DeleteNamespace | `GET`/`DELETE /namespaces/<arn>/<ns>` |
    | CreateTable | `PUT /tables/<arn>/<ns>` (`{"name","format":"ICEBERG","metadata"?}` → `{"tableARN","versionToken"}`) |
    | GetTable | `GET /get-table?tableBucketARN&namespace&name` (or `tableArn`) |
    | ListTables | `GET /tables/<arn>?namespace&prefix&maxTables&continuationToken` |
    | DeleteTable | `DELETE /tables/<arn>/<ns>/<name>?versionToken` |
    | RenameTable | `PUT /tables/<arn>/<ns>/<name>/rename` |
    | Get/UpdateTableMetadataLocation | `GET`/`PUT /tables/<arn>/<ns>/<name>/metadata-location` |

  - **Errors:** BadRequestException 400, ForbiddenException 403, NotFoundException 404, ConflictException 409,
    TooManyRequestsException 429, InternalServerErrorException 500.
  - **Names:**
    - A table bucket: 3 to 63 of `a-z0-9-`, beginning and ending with a letter or digit. It may not begin `xn--`,
      `sthree-`, `amzn-s3-demo-` or `aws`, nor end `-s3alias`, `--ol-s3`, `--x-s3` or `--table-s3`.
    - Namespaces and tables: 1 to 255 of `a-z0-9_`, beginning with a letter or digit. Namespaces are one level, and
      none begins `aws`.
    - Each table also has an id, and a table ARN `…:bucket/<name>/table/<id>`.
  - **A table:**
    - **Its fields:** a `warehouseLocation`, an `s3://` location S3 makes for it where the engine writes data and
      metadata files with the S3 API. Also a `metadataLocation`, which must lie within that warehouse location and
      end `.metadata.json`, and a `versionToken`.
    - **The compare-and-set:** UpdateTableMetadataLocation takes the token. AWS's pages say only that a conflict is
      ConflictException 409, and that the token is the table's version. Reading it as a compare-and-set of the
      metadata location is ours.
  - **Maintenance and the rest:**
    - Maintenance is compaction, snapshot expiry and unreferenced-file removal, configured per table and per bucket.
    - There are also policies, encryption, tags, replication, storage classes, metrics and migration.
  - **The Iceberg REST endpoint:**
    - **Where:** `https://s3tables.<region>.amazonaws.com/iceberg`, signed for `s3tables`. The `warehouse` is the
      table bucket's ARN, and the path's `{prefix}` is that ARN URL-encoded.
    - **Its calls:** config, the namespace and table calls (list, create, load, exists, drop), commit (update) and
      rename.
    - **Not taken:** staged creates, `purgeRequested=false`, nested namespaces, OAuth and views. A namespace
      property other than `owner` is not taken either.
- **The Iceberg REST catalog** (the OpenAPI spec, `rest-catalog-open-api.yaml`, and the table spec, read 19 Nov 2026):
  - **The server writes the metadata:** the server writes each version's `metadata.json`. A create sends a schema,
    a spec, an order and properties. A commit sends `requirements` (`assert-create`, `assert-table-uuid`,
    `assert-ref-snapshot-id`, `assert-current-schema-id`, …) and `updates` (`add-schema`, `add-snapshot`,
    `set-snapshot-ref`, `set-properties`, …).
  - **Answers:** the server checks the requirements against the current metadata (409 CommitFailedException if one
    fails), applies the updates and writes the new file. It answers `metadata-location` and `metadata`.
  - **Errors:** `{"error":{"message","type","code"}}`.
  - **Data files:** the engine writes these, with manifests and manifest lists, through its own S3 client. Our
    catalog vends no credentials (`X-Iceberg-Access-Delegation` is not honoured), and the engine uses its own keys
    and endpoint.
- **What boto3 sends to a custom endpoint, checked 19 Nov 2026** (boto3 1.42.97 against a stub): the paths above,
  with the ARN as one URL-encoded segment, JSON bodies, and signed for `s3tables`.
  - **A collision:** `/buckets`, `/namespaces/…`, `/tables/…` and `/get-table` are also an S3 bucket's paths. Only
    the signature's service tells them apart.
- **What CosmoStore has:**
  - Buckets and conditional writes: If-Match, and If-None-Match `*` (ADR-0015, ADR-0017).
  - RenameObject's atomic move in the store (ADR-0081), which works on any unversioned bucket.
  - A JSON reader (policies, ADR-0043), with no JSON value model.
  - Hidden reserved bucket names (directory buckets, ADR-0080).

## Decision (proposed)

1. **Routing by the signature's service.**
   - A request signed for `s3tables` is S3 Tables': the table bucket calls on the paths above, and the Iceberg REST
     catalog under `/iceberg/v1/…`.
   - Every other request is S3's as before, so a bucket named `buckets` or `tables` is unchanged.
   - S3 Tables' answers and errors are REST-JSON: the body `{"message"}`, with `x-amzn-ErrorType`. The Iceberg
     catalog's are its own, `{"error":{…}}`.
2. **A table bucket is a hidden bucket.**
   - Table bucket `<name>` is the store bucket `<name>--table-s3`, its warehouse. CreateTableBucket makes it, and
     DeleteTableBucket deletes it once it has no namespaces.
   - S3's CreateBucket refuses `--table-s3` names (as it refuses `--x-s3` ones), and ListBuckets leaves them out.
   - Its ARN is `arn:aws:s3tables:<region>:<account>:bucket/<name>`, and its `tableBucketId` is a UUID kept with it.
3. **The catalog is objects, and its compare-and-set is a conditional write.**
   - **Where records live:** a namespace is the object `.s3tables/namespaces/<ns>`, and a table is
     `.s3tables/tables/<ns>/<name>`, in the table bucket's hidden bucket. Each is a small JSON record. A table's
     holds its id, dates, `metadataLocation` and `warehouseLocation`.
   - **The token:** a table's `versionToken` is its record's generation, so UpdateTableMetadataLocation is a PUT
     with If-Match on it, and a create is a PUT with If-None-Match `*`.
   - **What it costs:** no new journal record and no new checkpoint format. Durability is the object store's,
     already swept, and a cluster gets it from the bucket's shard.
   - **Renames:** RenameTable is RenameObject's atomic move of the record (ADR-0081). The id and warehouse are kept.
   - **Deletes:** DeleteTable deletes the record, if its `versionToken` matches when one is given, then the objects
     under the table's warehouse prefix. DeleteNamespace refuses a namespace that has tables (409).
   - **Reserved keys:** S3 calls on a hidden bucket may not touch `.s3tables/` keys.
4. **The warehouse.**
   - A table's `warehouseLocation` is `s3://<name>--table-s3/<table id>/`, and its metadata location must begin
     with it and end `.metadata.json` (or `.metadata.json.gz`).
   - The engine reads and writes there with the S3 API and its own keys, through this server's endpoint
     (`s3.endpoint`).
5. **The Iceberg REST catalog** (`/iceberg/v1`, the `{prefix}` a table bucket's ARN):
   - **Its calls:** `GET /config`, and namespaces: list, create, load, HEAD and drop, with the `owner` property
     only. Tables: list, create, load, HEAD, drop with `purgeRequested=true`, and commit. Rename.
     - **Create:** writes `<warehouse>/metadata/00000-<uuid>.metadata.json` (format version 2).
     - **Commit:** checks every requirement against the current metadata, applies the updates and writes
       `<warehouse>/metadata/<n>-<uuid>.metadata.json`. Then it swaps the record's location by If-Match. A swap
       that loses is 409 CommitFailedException, which an engine retries.
   - **Updates taken:** assign-uuid, upgrade-format-version (to 2), add-schema, set-current-schema, add-spec,
     set-default-spec, add-sort-order, set-default-sort-order, add-snapshot, set-snapshot-ref, remove-snapshots,
     remove-snapshot-ref, set-location (within the warehouse), set-properties and remove-properties. An unknown
     update or requirement is 400.
   - **Not taken (as AWS):** staged creates, `purgeRequested=false`, nested namespaces, views, OAuth and
     credential vending.
   - **What it needs:** a JSON value model (parse, edit, write), which the S3 layer gains for this.
6. **Not done, refused (NotImplemented):** maintenance configurations, table bucket and table policies (as S3
   Control: long-term keys and their `GetSessionToken` sessions), encryption other than the server's default,
   tags, replication, storage classes, metrics, logging, record expiration and migration. CreateTable's `metadata`
   (an Iceberg schema given to the S3 Tables API itself) is taken and written as the first metadata file.
7. **On a cluster** (slice 3): a table bucket's calls go to its hidden bucket's shard. ListTableBuckets merges the
   shards, as ListBuckets does (ADR-0060). The catalog's records live on the same shard as the table's data.
8. **Tests:**
   - Unit tests of names, ARNs, records, the JSON model, requirements and updates.
   - The S3 smoke: the table bucket API through the AWS CLI (`aws s3tables`).
   - A PyIceberg check (`tools/iceberg_check.py`): create a namespace and a table, append twice, read the rows
     back, a conflicting commit refused, a rename and a drop.
   - The cluster smoke, and boto3's and the other SDKs' `s3tables` clients.

## Slices

1. **The S3 Tables API:** table buckets, namespaces and tables, the records and their compare-and-set, the warehouse
   and the refusals. Then the CLI in the S3 smoke, and boto3.
2. **The Iceberg REST catalog:** the JSON model, metadata files, requirements and updates. Then PyIceberg end to end.
3. **On a cluster.**
4. **The rest of the SDK matrix.**

## Consequences

- No new journal record and no new checkpoint format: the catalog is objects in a hidden bucket.
- The S3 layer gains a JSON value model.
- `docs/compatibility.md` gains an S3 Tables matrix.

## Rejected

- **The catalog as a `BucketConfig` record of the table bucket** (ADR-0079 §4 first thought): every commit would
  rewrite every table's entry, and the compare-and-set would need a check of its own. Objects with conditional
  writes give both.
- **A store bucket per table** (AWS's `<uuid>--table-s3` per table): one per table bucket is enough here, and a
  table's prefix is its warehouse.
- **The engine writes metadata files and the catalog only swaps locations** (the S3 Tables API's own model): that
  works through `UpdateTableMetadataLocation`, which slice 1 has, but Iceberg REST clients expect the server to
  write them.
