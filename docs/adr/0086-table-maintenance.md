# ADR-0086: Table maintenance, snapshot management and unreferenced file removal (M10)

**Status:** accepted, 19 Nov 2026 (the owner: "Accept and close"). Proposed the same day. M10 is item A of ADR-0085 (the owner: "A, and write the decoder here first").

## Context

- **What S3 Tables keeps doing to a table** (ADR-0083): each commit writes a metadata file, a manifest list and
  manifests, and the engine writes data files. Nothing removes old snapshots or the files only they reference, so a
  warehouse grows for as long as its table is written.
- **AWS's maintenance** (botocore's `s3tables` model, 2.34.13; the user guide from memory for the defaults,
  *memory* below):
  - **A table bucket's:** `icebergUnreferencedFileRemoval` (`unreferencedDays`, `nonCurrentDays`). A file no
    snapshot references for `unreferencedDays` is marked noncurrent, and deleted `nonCurrentDays` after that.
    Enabled by default with 3 and 10 (*memory*).
  - **A table's:**
    - `icebergSnapshotManagement` (`minSnapshotsToKeep`, `maxSnapshotAgeHours`) expires snapshots. It is enabled by
      default with 1 and 120 (*memory*).
    - `icebergCompaction` (`targetFileSizeMB`, `strategy`).
  - **The calls:** `PUT`/`GET /buckets/<arn>/maintenance[/<type>]`, `PUT`/`GET /tables/<arn>/<ns>/<name>/maintenance[/<type>]`
    and `GET …/maintenance-job-status`, each job `Not_Yet_Run`, `Successful`, `Failed` or `Disabled`, with its last
    run's time and a failure's message.
- **What the files are:**
  - **Metadata:** each metadata JSON lists its snapshots, each with its manifest list, and the earlier metadata
    files in its `metadata-log`.
  - **Manifests:** a manifest list (Avro) names manifests, and a manifest (Avro) names data and delete files.
  - **Compression:** PyIceberg compresses each Avro block with deflate by default. Snappy, zstandard and bzip2 are
    its other codecs.
- **What CosmoStore has:** the catalog's JSON model and commit path (ADR-0083 §5), the store's upkeep loop
  (`--maintain-seconds`), and a purge of a warehouse prefix. It has no Avro reader, and no inflate decoder:
  lib/std has none (G35). The owner chose to write the decoder here first.

## Decision

1. **The calls**, as AWS's model has them:
   - **Configuration:** Put/GetTableBucketMaintenanceConfiguration for `icebergUnreferencedFileRemoval`, and
     Put/GetTableMaintenanceConfiguration for `icebergSnapshotManagement` and `icebergCompaction`.
   - **Status:** GetTableMaintenanceJobStatus.
   - **Defaults:** each is `enabled` with AWS's defaults until it is configured.
   - **Compaction** is taken only as `disabled` (NotImplemented when enabled), and its status reads `Disabled`.
   - **Authorization:** each call is an `s3tables:` action under ADR-0084's policies.
   - **Storage:** configurations and job status are catalog objects (`.s3tables/maintenance/…`), so there is no new
     record.
2. **Snapshot management**, per table, when enabled:
   - **What stays**, as Iceberg's own expiry decides (M10's exit review, A4, A5):
     - every ref's head, and the current snapshot;
     - on each branch, its newest `minSnapshotsToKeep`, and those younger than `maxSnapshotAgeHours`. The ref's own
       `min-snapshots-to-keep` and `max-snapshot-age-ms` win where it has them. The ancestry walk tracks what it
       visited, so a cycle ends it and a ref's head on the way does not.
   - **What expires:** a snapshot nothing keeps, once older than `maxSnapshotAgeHours`.
   - **Refs:** a ref's `max-ref-age-ms` is not applied, so refs never expire here.
   - **The commit:** the expired snapshots are removed as a `remove-snapshots` commit, applied as ADR-0083 §5
     applies one. It is a new metadata file swapped in by If-Match. If another commit wins, the job stops and tries
     again next run.
   - It changes only metadata. Their files are left to unreferenced file removal.
3. **Unreferenced file removal**, per table of a table bucket where it is enabled:
   - **What is referenced:** the current metadata file and those in its `metadata-log`; every snapshot's manifest
     list; every manifest those lists name; every data and delete file those manifests name (whatever an entry's
     status); and the metadata's statistics files.
   - **The rest:** every other object under the table's warehouse prefix is unreferenced.
   - **The sweep:** each run notes when it first found each such file unreferenced, in a catalog object. It deletes
     a file once it has stayed unreferenced for `unreferencedDays + nonCurrentDays`.
   - **A file referenced again** leaves the notes. So does a file being written by a commit not yet made: it is
     first noted now, and deleted only days later.
   - **The ordering rule:** a file is deleted only when the committed metadata no longer references it, as read in
     that run.
   - **What stops a run:** not knowing a reference never deletes a file (M10's exit review, A1 to A3, A6). The run
     ends as Failed, deleting nothing, on:
     - any manifest it cannot read: a codec not taken (the message names it), a damaged file, or a schema it does
       not know;
     - a reference it cannot place: a scheme other than `s3://`, `s3a://` and `s3n://`, or a key of the hidden
       bucket under no table's id;
     - metadata of a format other than 1 and 2, `snapshots` that is not a list, or a snapshot naming neither a
       manifest list nor (format 1) inline `manifests`.
   - **References elsewhere:** one into another bucket names no file of this table bucket, and is passed by.
   - **Forms of a key:** a key that matches a referenced one after percent-decoding, or with `//` made `/`, is taken
     as referenced, never deleted.
   - **Other tables' files:** a reference into another table's prefix pins that table. Its pin is an object
     `.s3tables/maintenance/shared/<its id>/<this id>`. A pinned table's run deletes nothing (Failed, naming the
     table that pins it) while the pinning table is there.
   - **The sweep re-reads the table first.** If it was dropped, or its metadata changed since the run read it, the
     sweep does nothing, and the next pass reads it again.
4. **The readers**, in the S3 layer, with no C and no `unsafe`:
   - **An inflate decoder** (RFC 1951: stored, fixed and dynamic Huffman blocks), with an output limit.
   - **An Avro object container reader:**
     - **The container:** the header's schema and codec, its blocks, its sync marker.
     - **The codecs:** `null` and `deflate`.
     - **The data:** the binary encoding of the schema's types (null, boolean, int, long, float, double, bytes,
       string, record, enum, array, map, union, fixed), each record read into the JSON model.
   - **Other codecs:** snappy, zstandard and bzip2 make a run Failed, and its message names the codec.
   - **Bounds** (M10's exit review, B1, B2):
     - A count is at most the bytes left, so each item takes one at least. i64's least is refused before it is
       negated.
     - An `int` fits 32 bits, and a varint's 10th byte holds the 64th bit only.
     - A file's blocks decode to 64 MiB at most in all.
   - **Names:** a named type inherits its enclosing namespace, and a short name matching two full names is
     refused.
5. **When jobs run:**
   - **The loop:** beside the store's upkeep, a table maintenance pass runs every hour of a day (a day is 86,400 s,
     or `serve --tables-day-seconds` for tests, as `--inventory-day-seconds` is). Each pass runs each table's jobs
     once.
   - **How it holds the store:** snapshot management holds the store for one table's run (one metadata file read
     and one written). Unreferenced file removal holds it for each manifest list's or manifest's read, decodes it
     outside, then holds it for the sweep.
   - **On a cluster:** every hour of a day, a node lists the tables of each shard it leads from that shard's store.
     It then asks for each table's jobs through its own front, as a client would (ADR-0058 §8, as inventory does on
     a cluster). So each job is a shard's write, behind the shard's gate and committed by Raft.
     - **The call:** `POST /tables/<arn>/<ns>/<name>/maintenance-run?type=<job>`, CosmoStore's own, signed for
       `s3tables` and authorized as `s3tables:PutTableMaintenanceConfiguration`. It runs one job, since a shard's
       request does not read its own writes.
     - **Per-job status:** each job's status is an object of its own, so two jobs never write over each other's.
     - **On `serve`** the call is taken too, to run a job now.
6. **Not done:** compaction (refused when enabled), refs' `max-ref-age-ms`, and removing files outside a table's
   warehouse. Days are the wall clock's; on a cluster each node should run with the same `--tables-day-seconds`.

## Slices

1. The inflate decoder and the Avro reader, tested against vectors and against PyIceberg's own manifests.
2. The maintenance calls and job status; snapshot management; the pass on `serve`.
3. Unreferenced file removal.
4. On a cluster.
5. PyIceberg end to end (a table appended many times stays bounded and reads back), the SDK matrix, and the exit
   review.

## Consequences

- CosmoStore carries an inflate decoder until lib/std has one (G35); it moves there then.
- A table bucket deletes files by itself, by default as AWS's does. A `nonCurrentDays` and `unreferencedDays` of at
  least one day each, and a failed read deleting nothing, are what keep that safe.
- No new journal record and no new checkpoint format.

## Rejected

- **Deleting a file once it is unreferenced and old** (by its last-modified time), without noting when it became
  unreferenced: a file referenced until yesterday would go at once. Noting it gives the days AWS's model gives.
- **Expiry deleting the files only its expired snapshots reference** (as Java's ExpireSnapshots can): two jobs that
  delete would need to agree. Here only one deletes.
- **Skipping a manifest the reader cannot decode:** a file it names would look unreferenced and be deleted.
