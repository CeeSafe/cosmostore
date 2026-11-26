# ADR-0138: S3 Tables' table replication (M36)

**Status:** accepted, 26 Nov 2026 (the owner: "Yes, I accept ADR-0138 and close M36"). Proposed the same day, with
the owner's choices made:
- a replica is a copy ("A copy");
- destinations are on this server only ("This server only");
- a table's configuration replaces its bucket's ("Table's replaces").

M36 is ADR-0137's item A, with M35's B1 first (the owner: "A.", then "Yes, B1 first").

## Context

- **S3 Tables' replication API** (botocore 1.44.9's model, read here):
  - `PutTableBucketReplication`, `GetTableBucketReplication`, `DeleteTableBucketReplication` (`/table-bucket-replication`):
    a source table bucket's `{role, rules: [{destinations: [{destinationTableBucketARN}]}]}`, with a `versionToken`
    that a Put may give and a Delete must (ConflictException when it is not the current one);
  - `PutTableReplication`, `GetTableReplication`, `DeleteTableReplication` (`/table-replication`): the same for one
    table, "independently of bucket-level replication";
  - `GetTableReplicationStatus` (`/replication-status`): for each destination, `replicationStatus` (`pending`,
    `completed`, `failed`), the destination table's ARN, `lastSuccessfulReplicatedUpdate` (`metadataLocation`,
    `timestamp`) and a `failureMessage`;
  - `DisassociateTableReplication` (`PUT /table-replication/disassociate`): a replica made a standalone writable
    table, for good. In-flight copies to it fail, and its source's status for it reads `failed` from the next attempt.
    The AWS CLI 2.34.13 here does not have it yet; boto3 does.
  - **A replica in the destination** is a table at the source's namespace and name. `GetTable` gives it
    `managedByService` and `managedTableInformation.replicationInformation.sourceTableARN`, and `ListTables` gives
    `managedByService`. It is read-only until disassociated.
  - **Permissions** to configure: the call's own action, `GetTable` and `ListTables` on the source,
    `CreateTable` and `CreateNamespace` on the destination, and `GetTableMaintenanceConfig` on the source and
    `PutTableMaintenanceConfig` on the destination. The `role` is the IAM role S3 Tables assumes to copy.
- **What CosmoStore has:**
  - S3's bucket replication (ADR-0077): delivery through the journal's outbox, at least once, in order, as durable as
    the write; replicas across a cluster's shards (ADR-0078 §4);
  - table buckets, encryption and policies (M30, ADR-0084), roles (ADR-0075, ADR-0104), and clusters as `serve` (M31);
  - writers for every file a table holds: Avro manifests and manifest lists, Parquet with position deletes
    (compaction, M23 to M27), and deletion vectors in Puffin (M28).
- **An Iceberg table's files name each other by absolute path:**
  - its metadata names its manifest lists, earlier metadata files and statistics files;
  - a manifest list names manifests, and a manifest names data and delete files;
  - a position delete file holds the paths of the data files it deletes from, and a deletion vector's manifest entry
    names its data file.
  - A table's warehouse is `s3://<name>--table-s3/<id>/`, so a copy elsewhere is a rewrite of every path.

## Decision

0. **M35's B1 first** (slice 0): the orphan sweep's reads (every table, view, staged and pin record, the warehouse's
   ids, each view's objects) are done off the store's hold, as the per-table run's are. Under the hold, only each id
   or file about to go is read again (its records and pins absent, its tables' references still known) before its
   delete. Measured on a table bucket of 10,000 tables, before and after.
1. **The configuration** (slice 1):
   - The six configuration calls store a table bucket's or a table's configuration as a catalog record, with a
     version token per write. A Put whose token is not the current one, and a Delete whose token is not, are
     Conflict.
   - A destination is a table bucket of this server, not the source's own. A destination elsewhere is
     NotImplemented, as the owner chose below.
   - `role` is kept and given back. It must be a role ARN this server knows (the roles file, ADR-0075, or the IAM API's, ADR-0104), but copies run
     as the server, as the outbox's do.
   - **Authorization** is the caller's, as AWS lists it: the call's own action, plus the permissions on the source and
     on every destination. The actions are named in the log records (ADR-0130).
   - **Which configuration a table follows:** its own when it has one, else its bucket's, as the owner chose below.
2. **The replica** (slices 1 and 2), a copy, as the owner chose below:
   - **A table of its own:** in the destination, at the source's namespace (made if it is not there) and name, with
     its own id and warehouse, its record marked as a replica of the source's ARN.
   - **Its files:** the source's, copied, and each rewritten where it names a path: metadata, manifest lists,
     manifests, position delete files, and deletion vectors' entries. Each is sealed with the destination's
     encryption (ADR-0126).
   - **It is read-only:** its record is changed only by replication. A commit through either API, an S3 write into
     its warehouse, and its compaction and snapshot management are refused or skipped. Its unreferenced-file removal
     runs, so files of snapshots its source expired go.
   - **A name the destination already holds** with a table that is not this source's replica: the copy fails, and
     the status says why.
   - **`DisassociateTableReplication`** clears its mark, for good. It is then writable, and its maintenance runs as
     configured.
3. **The copy** (slice 2):
   - **Asked in the commit:** a commit of a replicated table writes, in the same step, an ask per destination
     (`.s3tables/replication/asks/<id>/<destination>`), so it is as durable as the commit (ADR-0001). A
     configuration Put asks for each table it newly takes in.
   - **Done by a loop per node (per shard on a cluster):**
     - it reads the source's current metadata and everything it references, off the hold;
     - it writes the destination's files, files first;
     - it changes the replica's record last, conditional on the generation it read. A replica is then never ahead
       of files it has.
   - **At least once:** a copy cut short is taken again, its files written again under the same keys, and files the
     record never named are the destination's unreferenced files.
   - **Only what the replica lacks** is copied: a file whose rewritten key the destination holds is skipped. A data
     file is the same bytes as its source.
   - **Back-off:** a failure is noted with its message (`failed`) and tried again with back-off. A source deleted
     ends its asks. A replica deleted is made again at the next commit.
4. **Across a cluster's shards** (slice 3): the destination's writes go to its shard's leader as the front routes
   them, as S3 replicas do across shards (ADR-0078 §4). The source's shard keeps the ask until its copy is acknowledged.
5. **Status** (slices 2 and 3): `GetTableReplicationStatus` gives, per destination:
   - `pending` while an ask waits;
   - `completed` with the replica's metadata location and time;
   - `failed` with its message.
   It is read from the asks and from a status record per destination, written by each copy.
6. **The checks** (slice 4):
   - **unit tests:** the configuration (version tokens, Conflict, authorization), each file kind's rewrite, a
     replica's refusals, a copy cut short and taken again, and disassociation;
   - **the AWS CLI and boto3:** configure, commit, read the replica (`GetTable`'s `managedByService`, its metadata
     location), the status, disassociate (boto3), and delete;
   - **PyIceberg:** a source appended and its rows deleted, its replica read with the same rows;
   - **Iceberg Java:** a v3 source with deletion vectors, its replica read;
   - **the cluster smoke:** source and destination table buckets on different shards; and **CI**.
7. **The exit review** (slice 5).

## For the owner to decide

- **What a replica is:**
  - **a copy (recommended):** its own warehouse, every file copied and rewritten to name its own paths. It outlives its
    source and is read with the destination's permissions and encryption, as AWS's replicas are. Its cost is a
    rewrite of each metadata, manifest and position delete file, and the copy of each data file;
  - **a reference:** its metadata names the source's files where they are, pinned against the source's removal. It
    is cheap, but it is lost with its source, and reading it needs the source's permissions.
- **Where a destination may be:**
  - **this server only (recommended for M36):** a table bucket here, on `serve` or across a cluster's shards;
  - **other endpoints too:** another CosmoStore's (or S3 Tables') table bucket, through `--replication-targets` as
    S3's replication does (ADR-0077 §6). This needs the destination's catalog and warehouse calls signed there, and
    is a milestone's worth again.
- **A table's configuration and its bucket's:**
  - **the table's replaces its bucket's (recommended):** a table with its own configuration follows it alone, as its
    own maintenance configuration replaces its bucket's;
  - **both:** the table goes to the destinations of both.

## Consequences

- **S3 Tables' API is served here in full** but for migrations.
- **Every commit of a replicated table** writes one more record per destination, in its step.
- **A replica's storage** is its source's again, per destination.
