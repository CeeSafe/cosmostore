# ADR-0061: Extents on a cluster: pushed to a majority before their record, fetched where missing (M6 item 5)

**Status:** accepted for M6 item 5 (ADR-0056 §8), 15 Nov 2026, as recommended (the owner: "I accept ADR-0061 as
recommended"), asked for by the owner ("Go ahead and start", after item 4); built.

## Context

- **Extents** (ADR-0003) are the files of objects past the inline limit (128 KiB by default): `ext-<16 hex>.ce`, a
  64-byte header and up to 64 MiB of the object's bytes, under the store's `extents/`. Ids are random 64-bit values.
  A PutExtent, UploadPart or UploadComplete record names its extents in a manifest (id, length, CRC32C); every extent
  is synced, and the directory, before its record is staged (the ordering rule of ADR-0001).
- **On a cluster** (ADR-0058 §10, ADR-0060) a shard refuses what writes an extent: records replicate, files do not.
  **ADR-0056 §8:** the leader writes a large object's extent, sends it to the shard's other replicas, and proposes the
  record only after a majority has synced it (the leader counts); a replica that has the record but not the extent
  fetches it from one that has it. **Done when** large objects survive the loss of a replica.
- **A trap in recovery:** a store sweeps orphan extents (on disk, named by no version or upload) when it opens. In a
  Raft log the entries after the checkpoint are not applied at open (ADR-0058 §6), so their extents look like orphans
  and would be removed, though the entries may be committed.

## Decision

1. **The ordering rule, on a cluster:** a record that names extents is proposed only once a majority of the shard's
   replicas (the leader counts) has each of them synced, file and directory. The leader's front (ADR-0060 §5), after
   the shard's S3 server has answered a write, reads the entries the write staged, takes the extents their manifests
   name (PutExtent, UploadPart; an UploadComplete's parts were pushed with their UploadParts), and sends each to every
   other replica of the shard at once. When a majority holds them it proposes the entries as before; when it cannot
   within FRONT_COMMIT_MS, it cuts its entries off (they are uncommitted and its own) and answers 503.
2. **Pushing an extent:** `POST /extent` on the peer port, signed (ADR-0059 §4): u32 shard, u64 id, the file byte for
   byte. The replica checks the header (magic, id, CRC), writes it as `ext-<id>.ce` (replacing one of the same id),
   syncs it and the directory, and answers 204. An extent that arrives before its record is an orphan until the record
   is applied, and is not swept meanwhile (§4).
3. **Fetching what is missing:** every two seconds, each replica lists the extents its versions and uploads name that
   it does not have (a replica outside the majority, back from a crash, or after a snapshot, which carries no extents),
   asks the shard's other replicas for each (`POST /extent-fetch`: u32 shard, u64 id; the file, or 404), checks it
   against its manifest's length and CRC32C, and installs it as in §2. A read of an extent the leader lacks fails
   until then; the client's retry finds it.
4. **Orphans on a replica:** no sweep at open. Upkeep sweeps an extent only when no version or upload names it, no
   entry after the applied index names it, and its file is more than ten minutes old (a push whose record has not yet
   come). Extents of superseded versions are removed when their supersession is applied, on every replica, as now.
5. **Bodies:** the front holds a request and a response whole (ADR-0060 §8), so a single request moves at most 64 MiB:
   a PUT of up to 64 MiB, any object by multipart upload (each part a request), and any object by ranged GETs, as the
   AWS CLI and SDKs download large objects. A whole GET of an object larger than 64 MiB is refused (EntityTooLarge)
   until the front streams.

## As built (15 Nov 2026)

- **The store** (`src/store/object_store.cee`): a Raft log no longer refuses records that name extents; no orphan sweep
  at open in a Raft log; `extentsOfEntries`, `extentFileBytes`, `installExtent` (header checked: magic, id, CRC),
  `missingExtents` (with each extent's length and CRC from its manifest) and `sweepRaftOrphans` (§4), run by the
  replica's upkeep.
- **The node** (`src/cluster/front.cee`, `node.cee`): `pushExtents` before `proposeStaged`, to every follower at once,
  a majority counted; `abandonStaged` cuts the write's entries off when there is none; `POST /extent` and
  `POST /extent-fetch` on the peer port; `fetchForever` every two seconds, each fetched file checked against its
  manifest's length and CRC32C before it is installed.
- **A whole GET past 64 MiB** fails with an error (the front cannot hold the answer); ranged GETs, which the AWS CLI
  and SDKs use for large objects, work.
- **Tests:** `raftStoreKeepsAndRepairsExtents` (the extents of an unapplied entry survive an open and the sweep, a
  missing one is listed and installed, a wrong one refused), which fails if the sweep at open comes back or the
  Raft sweep stops sparing the unapplied tail; `tools/cluster_s3_smoke.sh` with a follower down during a 20 MB PUT
  and a 40 MB multipart upload, which it fetches when it comes back, and both objects read after the leader's loss.

## Consequences

- Large objects and multipart uploads work on a cluster. A write that names extents costs their transfer to the other
  replicas before its Raft round: the bytes cross the network once per follower, as the records do.
- A replica can be without an extent for a while (§3); reads go to the leader, which is in the majority for every
  extent written in its own term, and repairs any other within seconds.
- Copies between two shards' buckets stay refused (ADR-0060).

## Rejected

- **Extents in the Raft log:** every byte of every large object through the journal of every replica, then compacted
  again; the journal holds records, the extent files hold bytes (ADR-0003).
- **Proposing first and pushing after:** a committed record whose extents are on one replica only is lost with it.
- **Erasure-coding extents now:** item 8.
