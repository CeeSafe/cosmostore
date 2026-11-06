# ADR-0001: One journal per shard, and its record format

**Status:** accepted (implemented in `src/storage/journal/`), 6 Nov 2026

## Context

The architecture document had two commit logs: a pack journal for small objects and a metadata WAL for large
ones. Recovery could not order a small PUT against a large PUT of the same key (ROADMAP.md, issue #1).

## Decision

1. **Each shard has exactly one journal, and it is the write-ahead log.** Every change is a journal record:
   object versions, deletes, bucket changes, multipart steps and checkpoints. Recovery order is LSN order.
2. **Small payloads live inside their record** (`PutInline`). Sealed journal segments *are* the packs, so no
   second copy exists. Large payloads go to extent files that are synced *before* their `PutExtent` record is
   staged (ADR-0003).
3. **Group commit.** Records are staged into a batch, which is written with one positional write and made
   durable with one data sync. Nothing in a batch is applied to the index or acknowledged before that sync
   returns. A batch is at most `maxBatchBytes`, and batch N+1 is written only after batch N's sync.
4. **Fail-stop on I/O error.** A failed write or sync puts the journal into the failed state, so it accepts
   nothing more until it is reopened. After a failed fsync the OS may have dropped dirty pages, so retrying
   the sync proves nothing.

## Segment file: `seg-<16 hex digits>.cj`

The header is 64 bytes, little-endian: magic `CSJSEG01`, u16 format version (1), u16 header length (64),
u32 flags, u64 segment id, u64 first LSN, u32 shard id, u32 reserved, i64 created (unix ms), reserved bytes,
then a u32 CRC32C of bytes 0..60.

## Record (v1)

The header is 48 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `CERC` |
| 4 | 1 | type: 1 PutInline, 2 PutExtent, 3 DeleteMarker, 4 DeleteVersion, 5 BucketCreate, 6 BucketDelete, 7 Checkpoint |
| 5 | 1 | flags; bit 0 means the payload is encrypted (reserved for SSE) |
| 6 | 2 | header length (48) |
| 8 | 4 | total length |
| 12 | 4 | meta length |
| 16 | 4 | payload length |
| 20 | 4 | body CRC32C over meta then payload |
| 24 | 8 | LSN |
| 32 | 8 | term (reserved for consensus; 0 on a single node) |
| 40 | 4 | reserved |
| 44 | 4 | header CRC32C over bytes 0..44 |

After the header come the meta bytes and the payload bytes, then an 8-byte trailer: magic `CEND` and the
total length again. A record is valid only if all of these check:
- the header CRC;
- total length = 48 + meta length + payload length + 8, and ≤ 16 MiB;
- a known type;
- the body CRC;
- the trailer.

Meta encodings (v1, first byte = format version) are in `src/metadata/model.cee`. **Versions are
first-class.** Every put carries a 16-byte version id, and unversioned buckets use the null id (all zeros),
so enabling versioning later needs no migration. A put also carries the size, the MD5 (the ETag), the
content type and a user-metadata count, which is 0 for now.

## Recovery

Segments are replayed in id order, and records must have strictly increasing LSNs.
- **Any invalid record in a sealed segment** (any segment but the newest) is corruption, so open fails.
- **The first invalid record at offset X in the newest segment**: if any valid record starts at or after
  X + `maxBatchBytes`, it belongs to a later batch, which was only written after X's batch was synced and
  acknowledged. That is corruption, so open fails. Otherwise everything from X on is an unacknowledged torn
  batch: it is truncated and the file is synced.
- **A newest segment with a torn or missing header** (crash during rotation) is reinitialised. A header that
  could not be *read* is an I/O error, and the open fails. Treating it as torn would wipe the segment
  (ADR-0004, bug 1).
- **A rotation that fails after its batch was synced** does not un-acknowledge the batch. `commit` returns Ok,
  and the journal is failed, so the next commit reports the error (ADR-0004, bug 4).

Tests: `journal_tests.cee` truncates at every byte, flips bits in sealed and acknowledged regions, and checks
rotation. `object_store_tests.cee` has the store-level crash-at-every-byte consistency test.
`journal_fault_tests.cee` fails every I/O operation of writing and of recovery in turn (ADR-0004).

## Consequences

- One sync per batch. Measured on a macOS laptop SSD with `F_FULLFSYNC`, 1 KiB objects: 216 PUT/s at one
  sync per PUT, and 28k PUT/s at 256 per batch.
- Replay rebuilds the in-memory index: about 480k records/s, including CRC checks.
- Overwrites and deletes leave dead records. Per-segment live-byte accounting exists (`SegmentUsage`), and
  compaction is ROADMAP M2.
