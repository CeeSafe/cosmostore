# ADR-0085: M10, what comes after S3 Tables (proposed)

**Status:** decided, 19 Nov 2026: the owner chose A, "and write the decoder here first". Proposed the same day. The owner: "propose M10". M9 (S3 Tables, ADR-0083 and ADR-0084) closed the same
day.

## Context

- **What M9 left refused** (ADR-0083 §6, `docs/compatibility.md`):
  - Table maintenance; encryption other than the server's; tags, replication, storage classes, metrics and record
    expiration.
  - Staged creates, nested namespaces, views and credential vending.
  - AssumeRole sessions in S3 Tables.
- **Maintenance is what keeps a table's storage bounded.**
  - **What grows:** every commit adds a metadata file, a manifest list and manifests. Nothing here removes old
    snapshots or the files only they reference, so a table's warehouse grows for as long as it is written.
  - **AWS's calls** (botocore's `s3tables` model, 2.34.13):
    - `PUT`/`GET /buckets/<arn>/maintenance/icebergUnreferencedFileRemoval` (`unreferencedDays`,
      `nonCurrentDays`).
    - `PUT`/`GET /tables/<arn>/<ns>/<name>/maintenance/{icebergSnapshotManagement,icebergCompaction}`
      (`minSnapshotsToKeep`, `maxSnapshotAgeHours`; `targetFileSizeMB`, `strategy`).
    - `GET …/maintenance-job-status`, each job `Not_Yet_Run`, `Successful`, `Failed` or `Disabled`.
  - **Snapshot expiry** changes only the metadata JSON, which the catalog already writes (ADR-0083 §5).
  - **Removing unreferenced files** means reading every live snapshot's manifest list and manifests, which are Avro.
    PyIceberg writes them deflate-compressed by default (`write.avro.compression-codec` is `gzip`). Neither an Avro
    reader nor an inflate decoder is in CosmoStore or in CeeSafe's lib/std (checked 19 Nov 2026).
  - **Compaction** rewrites Parquet data files: a Parquet reader and writer, and an engine's work inside the server.
- **Identities:** every key is one account's, and a key may do anything that no bucket policy denies.
  - There are no users and no identity policies on a key. Roles exist only through STS (ADR-0075), and S3 Tables
    refuses their sessions.
  - Restricting a key means a Deny in every bucket's policy (ADR-0043), or a role.
- **Smaller long-tail items** (`docs/compatibility.md`, Operations): HTTP/2 and SNI (CeeSafe.Web's), lifecycle
  transitions, SHA-1 checksums, ListMultipartUploads' `delimiter`, SSE-KMS against a KMS service.
- **Left for later by ADR-0079 §5:** S3 Metadata tables (a bucket's changes as an Iceberg table, which needs Parquet
  and Avro writers), S3 Vectors (a vector index service), and an Iceberg engine inside the server.

## Decision (proposed)

1. **M10 is one of these items**, each its own design ADR with a support matrix (what is done; what is refused,
   never silently ignored), on `serve` first and then a cluster, as M8 and M9 were.

   | # | Item | Done when |
   |---|---|---|
   | A | Table maintenance: snapshot management and unreferenced file removal (compaction stays NotImplemented) | The maintenance calls and the job status of AWS's model are taken. Snapshot management runs on a schedule and expires snapshots past `maxSnapshotAgeHours`, keeping `minSnapshotsToKeep`. Unreferenced file removal marks files no live snapshot references and removes them `nonCurrentDays` later. A PyIceberg table appended to many times keeps its warehouse bounded, and still reads back. On `serve` and on a cluster. |
   | B | Identities: users and identity policies | Each key belongs to a user, with identity policies (`s3:`, `s3express:` and `s3tables:` actions) that decide with the bucket's and table bucket's policies, as AWS's IAM does for one account. AssumeRole sessions are taken by S3 Tables, under their role's policies. Exercised by the AWS CLI and every SDK of the matrix. |
   | C | The long tail: lifecycle transitions to a colder class kept here, ListMultipartUploads' `delimiter`, SHA-1 checksums | Each refused today becomes taken and matrix-tested. HTTP/2 and SNI wait on CeeSafe.Web. |

2. **The recommendation is A.** It finishes M9: without it, a table written for a year keeps every file it ever
   wrote, and AWS sells S3 Tables on doing this for its users.
   - **Its cost** is an Avro reader (the container format, its binary encoding, Iceberg's manifest schemas) and an
     inflate decoder for deflate blocks.
     - The decoder is a gap for the CeeSafe repo, logged in `CEESAFE_GAPS.md`, and built here only if lib/std will
       not have one in time.
     - Neither needs C or `unsafe`.
   - **What it reads and writes:** it only reads Avro. It writes metadata JSON, which the catalog writes already,
     and deletes objects, which the purge already does. Its removals follow the ordering rule: the metadata that
     stops referencing a file is committed before the file goes.
   - **Compaction stays refused:** it would need Parquet and an engine's work in the server.
3. **B is the next candidate after A.** It is broader (every request's decision) and needs a format for users and
   their policies, kept as records of their own.
4. **Not in M10:** S3 Metadata tables, S3 Vectors, compaction, and an Iceberg engine inside the server.

## For the owner to decide (decided 19 Nov 2026)

- **Which item is M10:** A (recommended), B or C. The owner: **A**.
- **For A, the inflate decoder:** ask the CeeSafe repo for one in lib/std (CosmoStore's rule for a CeeSafe gap), or
  write it in CosmoStore and move it to lib/std later. The owner: **write it here first**. It is still logged in
  `CEESAFE_GAPS.md`, to move to lib/std later.

## Consequences

- One design ADR follows the choice, with its slices.
- For A: an Avro reader in the S3 layer, an inflate decoder (here or in lib/std), and the store's lifecycle
  scheduler running a table's maintenance jobs on the leader only (ADR-0058 §8).
