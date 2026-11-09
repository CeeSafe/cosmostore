# ADR-0027: Bucket numbers in index keys

**Status:** accepted for M4 slice 8 (`src/metadata/model.cee`, `src/store/object_store.cee`, `src/store/checkpoint.cee`),
9 Nov 2026

## Context

- **The ordered index (ADR-0026) put T9 over its target:** 423 bytes per object at 1M objects (408 MiB), and 454
  after recovery, against 400. The hash map it replaced took 362.
- **Where the bytes go,** from the generated C (`ceesafec build --emit c`) and the B-tree's layout:
  - an `ObjectVersion` is 208 bytes, in `VersionIndex`'s dense vector;
  - an `IndexKey` is 48 bytes, two vectors (bucket and key). The B-tree's nodes reserve room for 32 keys and sit
    about half full after in-order inserts (CEESAFE_GAPS G29), so each key costs about twice its size there;
  - each key's bucket and key bytes are heap allocations of their own, 16 bytes or more each.
- **Every key carried its own copy of its bucket's name,** although a store has few buckets.

## Decision

1. **An `IndexKey` is `{ bucket: u32, key: Vector<u8> }`:** the bucket's number, not its name. That is 32 bytes
   instead of 48, with one heap allocation instead of two.
2. **Numbers are the store's own, in memory only.**
   - `StoreState.addBucket` gives the next number when a bucket is created: by a BucketCreate record, live or replayed,
     or by a checkpoint's bucket entry. A bucket already there keeps its number.
   - `removeBucket` drops it. A re-created bucket gets a new number, and none of the old keys, since a bucket is
     deleted only when empty.
   - `bucketNames` maps numbers back to names, for what writes names out: checkpoints, fsck reports and compaction's
     Relocate records.
   - **Nothing on disk changes.** Records and checkpoints still name buckets, so each open numbers them afresh.
3. **Lookups go through the bucket's name** (`keyFor`). A bucket that is not there gets `NO_BUCKET` (0xFFFFFFFF),
   which no bucket is given, so its keys find nothing, as before. The 4,294,967,295th bucket creation fails with
   `InsufficientStorage` rather than reuse it.
4. **Order:** the index is ordered by bucket number, then key. Only a bucket's own keys are ever listed, and they
   are still in byte order. Lifecycle expiry now seeks to its bucket's first key and stops at the next bucket,
   instead of walking the whole index.
5. **A record whose bucket is missing when it is applied:**
   - a delete, tag change or relocation applies as nothing, since there is no version to change;
   - a PUT is retired at once, with its extents reaped and its record dead. Admission checks the bucket under the
     lock, so this does not happen. Before, such a PUT was indexed under a bucket that did not exist.

## Rejected

- **Moving the version's rarely used fields out of line** (extents, metadata and extras: 72 bytes, empty for most
  small objects). It touches about 90 places. The bucket number brought T9 back under 400 at a fraction of that, and
  it stays a follow-up.
- **Persisting bucket numbers.** They would be a format change, for nothing that needs them on disk.

## Consequences

- **T9 is met again:** 376 bytes per object at 1M objects, and 396 after recovery
  (`docs/benchmarks/2026-11-09-bucket-numbers.md`).
- The checkpoint format and the journal are unchanged; a store written before this opens as it did.

## Tests

- **`bucketNumbersSurviveRecreateAndReopen`** (`src/store/listing_tests.cee`):
  - a bucket emptied, deleted and created again lists none of its old keys;
  - a missing bucket's key finds nothing;
  - buckets created before and after a checkpoint keep their keys through two reopens, numbered from the checkpoint,
    then from a later checkpoint;
  - fsck finds no problem.
- `listingMatchesTheReference` (ADR-0026), the checkpoint, compaction, lifecycle and fault-sweep tests:
  `ceesafec test` (116).
- `tools/s3_smoke.sh`, `tools/tls_smoke.sh`, the s3-tests subset, the SDK checks, and `tools/scale.sh` at 1M objects.
