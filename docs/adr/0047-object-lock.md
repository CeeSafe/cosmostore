# ADR-0047: Object lock and legal hold

**Status:** accepted for M5 (item 5), 13 Nov 2026, and built (`src/metadata/model.cee`,
`src/store/object_store.cee`, `src/store/bucket_config.cee`, `src/store/checkpoint.cee`, `src/s3/object_lock.cee`).

## Context

- **What S3 offers.** A bucket with object lock keeps versions from being removed: each version may have a
  *retention* (a mode, `GOVERNANCE` or `COMPLIANCE`, and a time it ends) and a *legal hold* (on or off). A delete
  that names a locked version is refused; a delete that names none still writes a delete marker. Governance
  retention gives way to a request that asks to bypass it and may; compliance retention to nothing; a legal hold
  to nothing until it is taken off. A bucket may give new versions a default retention.
- **Versions** (ADR-0041) are what is locked, and what a delete by id removes for good. Lifecycle rules remove
  noncurrent versions too (ADR-0042).
- **The roadmap** asks that the lock be enforced inside the commit: no path that removes a version may go round it.
- **A version's fields** live in its metadata (ADR-0012), and change in place by a SetTags record (ADR-0017), as
  its tags and its ACL do (ADR-0045).

## Decision

1. **A bucket's object lock configuration** is a `BucketConfig` record of kind 7: `E` for enabled, and for a
   default retention its mode and its period in days or in years (`E.G.d30`, `E.C.y2`). Checkpoint format 10 adds
   it to a bucket's entry; formats 1 to 9 load.
   - It needs the bucket's versioning enabled (InvalidBucketState otherwise), and from then on versioning cannot
     be suspended and the configuration cannot be taken off. The store refuses both, whoever asks.
   - CreateBucket with `x-amz-bucket-object-lock-enabled: true` makes the bucket, enables its versioning and sets
     the configuration: three records. A crash between them leaves a bucket without the lock, and the request
     has not been answered.
   - Get- and PutObjectLockConfiguration; ObjectLockConfigurationNotFoundError for a bucket without one. A
     default retention is 1 to 36,500 days or 1 to 100 years (InvalidRetentionPeriod), not both (MalformedXML).
2. **A version's lock** is a field of its metadata, `x-amz-object-lock`: the retention's mode (`N`, `G`, `C`), the
   legal hold (`0`, `1`) and the time the retention ends, in ms (`G0.1767225600000`). No field: no lock.
   - A new version gets the lock its request's fields give (`x-amz-object-lock-mode` with
     `-retain-until-date`, together and in the future; `-legal-hold`), on PutObject, CopyObject and
     CreateMultipartUpload. In a bucket without object lock that is InvalidRequest, checked before the body is
     read, and again by the store.
   - Without those fields the store adds the bucket's default retention as it stages the version, counted from
     that moment; for a multipart upload, from its completion. A bucket without object lock pays one lookup.
   - A copy never has its source's lock. GET and HEAD return the lock as S3's three fields.
3. **Changing it:** PutObjectRetention and PutObjectLegalHold (with `versionId`) write a SetTags record of a third
   format, whose last field is the lock. The version's id, ETag, generation, time, tags and ACL stay.
   - A retention that has ended, or none, changes freely. Compliance may only be made longer. Governance may be
     made longer in its own mode; anything else (shorter, another mode, off) needs the bypass.
   - A legal hold is put on and taken off by whoever may call PutObjectLegalHold.
   - GetObjectRetention is NoSuchObjectLockConfiguration for a version without one; GetObjectLegalHold answers
     `OFF`. All four are InvalidRequest in a bucket without object lock.
4. **What a locked version refuses,** decided in the store, where every removal of a version is staged
   (`stageTarget`, `deleteVersion`):
   - a delete that names it is not staged, and its outcome says so: AccessDenied for DeleteObject, an
     AccessDenied entry (with the version's id) in DeleteObjects, the other entries going on;
   - a lifecycle rule leaves it until its retention has ended and its hold is off (ADR-0042 otherwise unchanged);
   - a delete that names no version writes a delete marker over it, as S3 does: the version is still there.
   - **The bypass:** `x-amz-bypass-governance-retention: true` on a request that may do
     `s3:BypassGovernanceRetention`: a key no policy denies it, or an anonymous request a policy allows it. It
     lifts governance retention only.
   - **The check is made when the delete is staged,** against the published index, with the store's lock held.
     A version can be named only by its id, 16 random bytes that only its acknowledged PUT has told, so no delete
     can name a version whose locked PUT is still unpublished; and a retention or hold is set by a call that
     commits before it returns, under the same lock.
5. **Policy actions:** `s3:GetBucketObjectLockConfiguration`, `s3:PutBucketObjectLockConfiguration`,
   `s3:GetObjectRetention`, `s3:PutObjectRetention`, `s3:GetObjectLegalHold`, `s3:PutObjectLegalHold` and
   `s3:BypassGovernanceRetention`, checked as every other call (ADR-0043 §4). No ACL grants them.
6. **The cost.** A PUT looks up its bucket's configuration (one more lookup beside versioning's); a delete by
   version id reads the version's lock only in a bucket with object lock.

## Consequences

- A version under compliance retention cannot be removed through the API by anyone until it ends, nor its bucket
  deleted. The clock is the server's: moving it forward ends retentions early.
- **It is not a defence against whoever holds the disk.** The lock is enforced by the server; the files are
  ordinary files.
- A store with an object lock configuration, or checkpointed by this build, has checkpoint format 10; a journal
  with a PutObjectRetention or PutObjectLegalHold has a record an older build refuses.
- An error entry of DeleteObjects now names the version it was asked to remove, for every refusal, as S3 does.
- Compaction, recovery and checkpoints carry the lock as they carry any metadata; nothing in them removes a
  version.

## Rejected

- **Refusing at apply time** (when the record is applied after its sync, and at replay): the answer to the
  request would be known only after the commit, and replay would have to decide again with the same clock and the
  same bypass, neither of which a DeleteVersion record carries.
- **A lock table beside the index:** a second structure to recover, checkpoint and keep in step, for what is one
  field of a version.
- **Object lock without versioning:** an overwrite would have to be refused or kept, which is versioning.
- **A years period as calendar years:** S3 counts 365 days.
