# ADR-0084: Policies for S3 Tables, and table buckets made before M9

**Status:** proposed, 19 Nov 2026. The owner, on M9's exit review's B6 and B9 (recorded then as not done): "Tackle
those two findings you recorded."

## Context

- **B6:** nothing restricts a key in S3 Tables (ADR-0083 §6 as it was).
  - No `s3tables:` action is authorized against any policy, so every long-term key may make, change, drop and purge
    every table bucket. It may also read and write every table's files through S3, whatever Deny statements it meets
    on ordinary buckets.
  - A bucket policy cannot be put on a table bucket's hidden bucket either.
- **B9:** a general-purpose bucket named `<name>--table-s3`, made before M9 (S3's names allowed it), is read as table
  bucket `<name>`.
  - It becomes hidden, its bucket calls are refused, and its `.s3tables/` keys are read as catalog records.
  - Nothing marks a table bucket's hidden bucket as one, by design (ADR-0083 §2: one write makes it).
- **AWS's S3 Tables** (botocore's `s3tables` model, 2.34.13, for the calls; the user guide from memory for the
  actions, *memory* below):
  - **Table bucket policies:** `PUT`, `GET` and `DELETE /buckets/<arn>/policy`, the body `{"resourcePolicy": "<json>"}`.
  - **Table policies:** `PUT`, `GET` and `DELETE /tables/<arn>/<ns>/<name>/policy`.
  - **Answers:** PutTableBucketPolicy and PutTablePolicy answer 200 with no body; the deletes answer 204. A policy is
    at most 20,480 characters.
  - **Actions** are `s3tables:<Call>`: `s3tables:GetTable`, `s3tables:PutTableBucketPolicy`, and so on.
  - **Table data:** an engine's S3 calls on a table's files are `s3tables:GetTableData` (GetObject, HeadObject,
    ListParts) and `s3tables:PutTableData` (PutObject and the multipart calls), on the table's ARN (*memory*).
  - **Resources:** `arn:aws:s3tables:<region>:<account>:bucket/<name>`, and a table's
    `arn:aws:s3tables:<region>:<account>:bucket/<name>/table/<id>`.
- **What CosmoStore has:**
  - Bucket policies (ADR-0043): Allow and Deny statements with principals (`arn:aws:iam:::user/<key>`, `*`),
    actions, resources and conditions.
  - A key may do what no Deny refuses, and an anonymous request needs an Allow. The policy calls themselves are never
    refused to a key (ADR-0043 §4), so a key cannot lock itself out.

## Decision (proposed)

1. **Table bucket policies and table policies** (B6), with the six calls above.
   - **The grammar** is a bucket policy's (ADR-0043 §3):
     - Actions are `*` or `s3tables:<name>` (with `*` and `?`).
     - Resources are this table bucket's ARN or its tables' (`…:bucket/<name>`, `…:bucket/<name>/table/<id>`, with
       wildcards). Any region and account match, as CosmoStore has one of each.
     - Principals and conditions are a bucket policy's.
     - Another service's actions, or another bucket's resources, are MalformedPolicy (as a BadRequestException).
   - **Where they are kept:** each is a catalog object (ADR-0083 §3), so there is no new journal record.
     - A table bucket's policy is `.s3tables/policy`.
     - A table's is `.s3tables/table-policies/<table id>`. It is keyed by the id, so a rename keeps it. DeleteTable
       removes it, and DeleteTableBucket removes both, as the rest of the catalog.
2. **The decision**, as for an ordinary bucket (ADR-0043 §4):
   - Every S3 Tables call (except CreateTableBucket and ListTableBuckets, which name no table bucket) is authorized
     as `s3tables:<Call>` on a resource:
     - **The table bucket's:** GetTableBucket, DeleteTableBucket, its policy calls, the namespace calls, CreateTable
       and ListTables.
     - **The table's:** GetTable, DeleteTable, RenameTable, Get/UpdateTableMetadataLocation and its policy calls.
   - **What applies:** the table bucket's policy, and for a table's resource that table's policy too.
     - A Deny in either refuses (ForbiddenException).
     - Otherwise a key may.
     - A broken stored policy refuses, as a bucket's does (ADR-0043 §9).
   - **The policy calls** are never refused to a key, so a key cannot lock itself out.
   - **The principal** is the request's key; a `GetSessionToken` session's is its key's.
   - **Who may call at all:** anonymous requests, AssumeRole sessions and directory-bucket sessions are refused, as
     before (ADR-0083 §6).
3. **The Iceberg catalog's calls** are authorized as the S3 Tables calls they are:
   - `/config` as GetTableBucket.
   - Namespace list, create, load, HEAD and drop as ListNamespaces, CreateNamespace, GetNamespace and DeleteNamespace.
   - Table list and create as ListTables and CreateTable.
   - A table's load and HEAD as GetTableMetadataLocation, its commit as UpdateTableMetadataLocation, its drop as
     DeleteTable, and a rename as RenameTable.
   - A refusal is 403 ForbiddenException in Iceberg's shape.
4. **Table data through S3:**
   - **The keys:** in a table bucket's hidden bucket, an object's key must begin with a table's id (a UUID's form)
     and `/`. A table's files are under its warehouse `s3://<hidden>/<id>/` (ADR-0083 §4), so an engine writes
     nowhere else. Another key is AccessDenied.
   - **Listings and multipart listings** name a prefix that begins with a table's id.
   - **The check:** each object call is authorized as `s3tables:GetTableData` (GET, HEAD, listings, ListParts) or
     `s3tables:PutTableData` (PUT, the multipart calls, a copy's destination, DELETE, DeleteObjects' keys), on the
     table's ARN. Both policies apply, as in §2.
   - **A copy's or a part copy's source** in a hidden bucket is authorized as `s3tables:GetTableData` on its table.
   - **Already in force:** the catalog's keys (`.s3tables/`) stay out of S3's reach (ADR-0083 §2).
   - This is in addition to the hidden bucket's own S3 checks; those find no bucket policy there.
5. **Table buckets made before M9** (B9): `serve`, and each shard of a cluster node, refuse to start when a
   `--table-s3` bucket holds a key that is neither `.s3tables/…` nor `<table id>/…`.
   - **Why that is exact:** from §4 on, a table bucket holds no other key, so such a key shows a general-purpose
     bucket made before M9.
   - **The message** names the bucket and says what to do: with the release before M9, which opens the same store
     (M9 added no format), copy its objects to another bucket and delete it.
   - **The cost:** the check skips each prefix it has seen (a listing from just after `<id>/`), so it reads a
     bucket's tables, not its objects.
   - **An empty bucket** of such a name cannot be told from an empty table bucket. It is read as one, which loses
     no data; DeleteTableBucket removes it.

## Consequences

- No new journal record and no new checkpoint format: policies are catalog objects.
- Each S3 call into a table's files reads up to two small catalog records (their index lookups when there are none),
  under the store's lock that the call takes anyway.
- An engine that writes outside its table's warehouse, or lists the whole hidden bucket, is refused.
- `serve` and cluster nodes check every `--table-s3` bucket when they start.

## Rejected

- **Policies on the hidden bucket as S3 bucket policies** (`s3:` actions on `<name>--table-s3`): those are not AWS's
  for table buckets, and the hidden bucket's name is ours, not the client's.
- **An index of table ids** for table policies keyed by name: keying them by id needs none, and a rename keeps them.
- **Reading a pre-M9 `--table-s3` bucket as an ordinary bucket** rather than refusing to start: every check that
  reads a name's shape would need the server's list of such buckets. Refusing names the bucket once, and the release
  before M9 moves it.
- **AssumeRole sessions in S3 Tables** (role policies with `s3tables:` actions): a further step, not needed to restrict
  a key. They stay refused.
