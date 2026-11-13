# ADR-0052: Bucket quotas

**Status:** accepted for M5 (item 7, fourth part), 14 Nov 2026, and built (`src/store/object_store.cee`,
`src/store/bucket_config.cee`, `src/store/checkpoint.cee`, `src/s3/quota.cee`).

## Context

- **The store has one limit:** its capacity and the volume's free space, with a reserve (ADR-0006, ADR-0040). Any
  bucket may use all of it.
- **A bucket's use is half counted.** The store keeps each bucket's number of versions (it is what DeleteBucket
  checks), counted as records are applied and again from a checkpoint's objects. It keeps no count of bytes.
- **S3 has no quota call.** RGW and MinIO have their own, in admin APIs; the admin API here is a later part of
  item 7.

## Decision

1. **A bucket's use** is two numbers the store keeps with the bucket: the bytes of its versions (their sizes as
   S3 reports them) and how many versions it has, delete markers included. Both follow the index: a version
   installed adds, one removed or replaced takes away. Neither is stored: they are counted as records are
   applied, and from a checkpoint's objects when one is loaded.
2. **A quota** is a `BucketConfig` record of kind 10: the most bytes and the most versions, 0 for no limit of that
   kind. Checkpoint format 13 adds it to a bucket's entry; formats 1 to 12 load. A write that would take the
   bucket past either is QuotaExceeded (403) and leaves nothing: a PUT, a copy, a form upload, and a multipart
   upload when it is completed (its parts are not counted before; the upload is kept, and completes once there is
   room).
   - **Checked in the store, with the write's other admissions:** against the bucket's use as published. In a
     bucket whose versioning is not enabled, a write replaces the key's null version: that version's bytes are
     not counted against the new one, and the count stays.
   - **A delete is never refused,** though a delete marker is a version and is counted once written. Nor are
     lifecycle rules, tagging, ACLs or any call that writes no object.
   - Putting a quota below what a bucket holds takes nothing away: the bucket takes no more until it is under.
3. **The calls** are not S3's: `PUT /<bucket>?quota` with `<Quota><MaxBytes>…</MaxBytes><MaxObjects>…</MaxObjects></Quota>`
   (one at least, above 0; InvalidArgument otherwise), `GET /<bucket>?quota` (the limits, 0 for none, and the
   bucket's `Bytes` and `Objects`, with or without a quota), and `DELETE /<bucket>?quota`. They are checked as
   every call (ADR-0043 §4) under `s3:GetBucketQuota` and `s3:PutBucketQuota`: a key no policy denies, or whoever
   a policy allows.
4. **The cost.** Every version installed or removed updates its bucket's bytes where it already updated its
   count. A write looks the quota up with the bucket it already looks up; a bucket without one pays that and
   nothing more.

## Consequences

- A bucket can be kept to a size and a count, and its use can be read without listing it.
- **The limit can be passed by what is in flight:** the check counts published writes, so writes staged or in
  their sync when another is admitted are not in the total yet. The overshoot is at most what was in flight;
  the next write is refused.
- The bytes counted are the objects' sizes, not what they occupy: not their records, their extents' headers,
  an upload's parts before it is completed, or versions waiting to be reaped.
- A store with a quota, or checkpointed by this build, has checkpoint format 13.
- Tools that speak S3 do not know the calls; `tools/s3_raw.py presign … quota` signs them for curl.

## Rejected

- **Counting bytes on disk:** it moves with compaction and reaping, so a write could be refused or admitted by
  what the upkeep happened to do.
- **Reserving a write's bytes when it is staged,** so nothing in flight escapes the count: a second total to keep
  right through every failed, discarded and replayed write, for an overshoot that is bounded.
- **Refusing a delete marker at the count:** a full bucket could not be emptied by its owner's usual deletes.
- **A quota per access key:** objects have no owner but the one account (ADR-0045).
- **Waiting for the admin API:** the limit is the bucket's, as its policy and its CORS rules are, and is read and
  written where they are.
