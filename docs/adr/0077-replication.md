# ADR-0077: Bucket replication (M7 item 6)

**Status:** accepted, 16 Nov 2026 (the owner: "Yes, accept ADR-0071 to 0077"); proposed the same day for M7 item 6 (ADR-0071); §6 and §7 (other endpoints) added the same day. The scope (replicas that keep their source's version id
and ETag; destinations on this server first, other S3 endpoints in a second slice) was chosen by the owner,
16 Nov 2026.

## Context

- S3 replication copies new versions of a bucket's objects, by rules (a key prefix, a priority, whether delete
  markers go too), to a destination bucket, asynchronously. A replica keeps its source's version id, ETag, metadata
  and encryption; the source reports `x-amz-replication-status` `PENDING`, `COMPLETED` or `FAILED`, the replica
  `REPLICA`. Both buckets must have versioning enabled. Replicas are not replicated again.
- CosmoStore's journal is already an outbox of every write's event, delivered at least once across crashes, with a
  durable cursor (ADR-0048).

## Decision

1. **The configuration** is a `BucketConfig` of kind 16 (checkpoint format 23): `Put/Get/DeleteBucketReplication`,
   S3's `ReplicationConfiguration` (`Role` taken and ignored; up to 1,000 rules of `ID`, `Priority`, `Status`, a
   `Filter` or `Prefix` on the key, `DeleteMarkerReplication`, and a `Destination` bucket ARN on this server). The
   source's and every destination's versioning must be enabled (InvalidRequest), and stay so (suspending a source's
   versioning while it has rules is InvalidBucketState). At one destination the enabled rule that takes a key with
   the highest `Priority` decides, its delete-marker setting too; two rules giving one priority are InvalidArgument,
   a priority past u32 too, and a `DeleteMarkerReplication` status is `Enabled` or `Disabled` (the M7 review's A3).
   A destination `StorageClass` other than `STANDARD` is NotImplemented (A2). A rule's elements may come in any
   order (the Go SDK writes them alphabetically, the rule's `Status` after `DeleteMarkerReplication`'s; it was
   MalformedXML until the SDK matrix found it, 18 Nov 2026). Filters on tags,
   `ExistingObjectReplication`, replica
   modification sync, replication time control and destinations elsewhere are NotImplemented.
2. **Replication rides the outbox.** When a write's record is applied, every enabled rule whose filter takes the key
   adds its destination as one more target of the record's event (a new object or a completed upload always; a
   delete marker when the rule says so; the removal of a version never, as S3). So replication is as durable as the
   write (the event is the record, ADR-0048 §2), at least once, in order, retried with the outbox's back-off, and
   counted with the notifications' targets. The outbox counts a bucket with replication rules as one that has rules.
3. **A replica** is the source version's stored bytes, read without the store's lock through a pinned reader and
   written through an `ObjectWriter`, then put by `ObjectStore.putReplica`: a version of the destination's key with
   the source's version id, MD5 and part count (a `PutInline`/`PutExtent` record whose meta ends with the part count
   after its extras section; older records have none and read as 0), its content type, its metadata and its extras
   as they are, so its ETag and its encryption envelope are the source's, and `x-amz-replication-status: REPLICA`
   added to its stored fields. A version the destination's key already has is passed over, so delivering again
   writes nothing. A delete marker is replicated as a marker with the source's id. A source version that is a replica,
   or that no longer exists, has nothing to replicate.
4. **Status** is not stored: a source version that a rule takes is `COMPLETED` when every destination has its id,
   `PENDING` while its event waits in the outbox, else `FAILED` (a destination that went away, lost its versioning,
   or refused the replica: the event is then passed over and the failure counted and logged, so one bad destination
   does not hold the outbox). The replica's `REPLICA` is its stored field.
5. **A cluster's S3 port** refused `PutBucketReplication` at first (its outbox was not delivered there); ADR-0078 §4
   built it, a replica into the cluster keeping its source's version id across shards.
6. **Other endpoints** (part 2): `serve --replication-targets` names them, a line each: `<id> <http or https url>
   <access key> <secret key> [region]` (the file's text is wiped once read). A rule's destination
   `arn:cosmostore:s3::<id>:<bucket>` (kept as `<id>:<bucket>`) replicates there; an id the file does not have is
   InvalidArgument. A replica is sent as SigV4 requests with an unsigned payload: one PUT of the version's plaintext,
   or, for a multipart version, a multipart upload with its parts' sizes, so its ETag is the source's (except under
   SSE-KMS, whose ETag is not an MD5); its content type, user metadata, stored headers and
   `x-amz-replication-status: REPLICA` go with it, and `x-amz-server-side-encryption: AES256` when the source was
   sealed (SSE-S3 and SSE-KMS versions are opened here with the master keys and sent in the clear over the
   connection, so use https; SSE-C versions cannot be, and are refused). A delete marker is a DELETE there. The
   version id there is the endpoint's own: S3 has no way to set one. A CosmoStore destination keeps a PUT's
   `x-amz-replication-status: REPLICA`, so a replica is not replicated again. An answer of 2xx is done; no answer, 5xx,
   408 and 429 are tried again with the outbox's back-off; any other is a refusal.
7. **Refusals are noted:** a remote destination's refusal is passed over and its key and version id kept in a
   `BucketConfig` of kind 17 on the source bucket (its newest 1,000; checkpoint format 24), so the version reads
   `FAILED`, after a restart too; a remote destination's version reads `PENDING` while its event waits, then
   `COMPLETED`.


## Consequences

- `replicasKeepTheirSourcesIdAndEtag` (inline and extent replicas reopened from the journal and from a checkpoint,
  a replica asked for twice, a destination without versioning) and the fault sweep `replicaFaults{Once,Sticky,Torn,
  Crash}` (two sources and their replicas, a fault at every I/O point: an acknowledged replica is there with its
  source's id, MD5, parts and bytes, an unacknowledged one is whole or absent, no orphan extents).
- The S3 smoke replicates a small object, a 9 MiB multipart object and an SSE-S3 object between two buckets and
  compares version ids, ETags (`-2` for the multipart one) and bytes, reads `COMPLETED` and `REPLICA`, replicates a
  delete marker with its id, and with rules both ways checks a replica is not sent back.
- `replicationToOtherEndpoints` (the targets file, remote ARNs, the failure list); the S3 smoke starts a second server
  as an endpoint and replicates a small object with metadata, a 9 MiB multipart object (ETag `-2` kept) and an
  SSE-KMS object (its plaintext, sealed there by SSE-S3) to it, a delete marker, a rule to a bucket it does not have
  (`FAILED`, also after a restart), and reads `COMPLETED` after a restart.
- A sealed version's size is its plaintext's while its stored bytes are longer (ADR-0046 §2): the copy reads to the
  end of what is stored and the replica takes the source's size.

## Rejected

- **New version ids for replicas** (a copy through the S3 layer): simpler, but clients that follow versions across
  buckets, and S3's own semantics, expect the source's id and ETag.
- **A stored status per version:** a metadata write per replication, journaled and itself an event; the status
  follows from the destination and the outbox's cursor.
