# ADR-0042: Lifecycle rules and the versions of a key

**Status:** accepted for M5 (item 2: lifecycle with noncurrent versions), 13 Nov 2026, and built
(`src/store/bucket_config.cee`, `ObjectStore.applyLifecycle`, `src/s3/bucket_config.cee`).

## Context

- **Lifecycle rules** (ADR-0020) expire objects by age or date, filtered by prefix, tags and size, and abort old
  multipart uploads. `applyLifecycle` runs them from upkeep, at most 1,000 deletes per bucket and run, in one commit.
- **Versions** (ADR-0041) made that wrong for a bucket with versioning: deleting the current version there writes a
  delete marker and frees nothing, and nothing ever removes a noncurrent version. Until this ADR, rules expired
  nothing in such a bucket (ADR-0041 §9), `NoncurrentVersionExpiration` was NotImplemented, and
  `ExpiredObjectDeleteMarker` was stored and did nothing.
- **What S3 does in a bucket with versioning, enabled or suspended:**
  - `Expiration` by days or date acts on the current version only: it writes a delete marker over an object, and
    removes nothing;
  - `NoncurrentVersionExpiration` removes a version `NoncurrentDays` after it stopped being the current one, and,
    with `NewerNoncurrentVersions`, only when that many newer noncurrent versions are kept;
  - a delete marker that is its key's only version is an *expired object delete marker*: it is removed by
    `ExpiredObjectDeleteMarker`, and also by an `Expiration` by days or date once the marker itself is that old.

## Decision

1. **A rule has two more numbers:** `noncurrentDays` (0: no such action) and `newerNoncurrent` (0 to 100 versions
   to keep). The rules blob is version 2 when any rule has them, with the two after each rule's fields; otherwise it
   is written as version 1, byte for byte as before. Both versions load.
2. **A version became noncurrent when the next newer version of its key was written:** that version's modification
   time. Nothing more is stored. The expiry time is rounded up to the next midnight UTC, as an object's is
   (ADR-0020).
3. **One pass over a bucket's keys decides, per key, from its chain** (`applyLifecycle`):
   - **the current version, an object:** a matching rule whose `Expiration` has passed deletes the key as a DELETE
     without a version id does: the object goes in a bucket without versioning, a delete marker is written in one
     with it;
   - **the current version, a delete marker with no older version:** removed, by its id, when a matching rule has
     `ExpiredObjectDeleteMarker`, or an `Expiration` whose time since the marker was written has passed;
   - **each noncurrent version, delete markers too:** removed, by its id, when a matching rule's
     `NoncurrentVersionExpiration` has passed since it became noncurrent and at least `newerNoncurrent` noncurrent
     versions of the key are newer than it.
4. **A delete marker has no size and no tags,** so a rule that filters by either never takes one; the prefix is all
   that can match it. A noncurrent object version is matched with its own size and tags.
5. **All of a bucket's deletes of one run are one commit** (`deleteMany`, ADR-0041 §10), still at most about 1,000 a
   bucket and run; a key's chain is not split between runs once it is begun. The records are the ones a client's
   DELETE writes (`DeleteVersion`, `DeleteMarker`), stamped with the run's time, so recovery and the fault sweeps
   cover them as they are.
6. **A run acts on the state it finds.** A key whose current version expires gets its marker in this run; the object
   under it is noncurrent from then, and a later run removes it, and then the marker that is left alone. Nothing is
   chained within a run.
7. **With versioning suspended, the marker over an expired object has the null id,** and applying it removes the
   key's null version, wherever that is in the chain (ADR-0041 §2). So the run that expires such a key's current
   object does not also delete its null version by id: in the batch that delete would follow the marker and remove
   the marker, and the object would be current again. With versioning enabled the marker has its own id, and the
   null version goes by its id like any other.
8. **In the S3 API** `NoncurrentVersionExpiration` takes `NoncurrentDays` (1 or more) and `NewerNoncurrentVersions`
   (1 to 100), and is written back by GetBucketLifecycleConfiguration. `ExpiredObjectDeleteMarker` with a tag filter
   is InvalidRequest, as in S3. Transitions stay NotImplemented.
9. **A version no rule can take yet costs the pass one comparison.** Each run works out, per bucket, the latest
   time a current object may have been written, and a version may have become noncurrent, for any enabled rule to be
   due (`lifecycleCutoffs`): the run's time less the rule's days, or any time once a rule's date has passed. Only a
   version inside the cutoff is checked against the rules, cheapest parts first (prefix, versions to keep, time),
   and its tags are read out of its metadata only for a rule that filters by them. The cutoffs never hide a due
   version: due means the days have passed and midnight after them.

## Consequences

- A bucket without versioning behaves as before: its keys have one version, so only the first case applies.
- A bucket with versioning and an `Expiration` rule alone keeps growing: markers hide objects but free nothing. That
  is S3's behaviour; `NoncurrentVersionExpiration` is what frees space.
- The pass reads every version of a bucket that has rules, under the store's lock, as it read every object before.
- A store whose rules use the new action has a version 2 blob in its journal and checkpoints, which an older build
  refuses to load (as it already refuses checkpoint format 6).

## Rejected

- **Storing when a version became noncurrent:** a field in every version, in memory and in checkpoints, for a time
  the chain already gives.
- **Removing the object and its marker in the run that expires the current version:** not what S3 does, and a rule
  with `Expiration` alone would then destroy data that versioning was enabled to keep.
- **A separate record type for lifecycle deletes:** replay would need to know the rules; a delete is a delete.
