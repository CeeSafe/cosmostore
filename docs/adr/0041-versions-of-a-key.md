# ADR-0041: The versions of a key

**Status:** accepted for M5 (item 1: versioning, delete markers, ListObjectVersions), 13 Nov 2026. Slices 1 to 3
are built (`src/metadata/version_index.cee`, `src/store/object_store.cee`, `src/store/checkpoint.cee`,
`src/store/version_tests.cee`, `src/s3/versions.cee`): the store keeps versions and the S3 API offers them. Slice 4,
the compatibility suites, is open.

## Context

- **The formats were made for versions** (ADR-0001, `src/metadata/model.cee`): every put and delete record carries
  a 16-byte version id, the null id (all zero) for an unversioned bucket, and the record types `DeleteMarker` and
  `DeleteVersion` exist. `ObjectVersion` has a `kind`.
- **The state was not.** The index maps a key to one version, its current one (ADR-0026). A put replaces it, a
  `DeleteVersion` removes the key whatever its id says, `DeleteMarker` is applied as nothing, and a checkpoint
  holds one entry per key. Buckets have no versioning state.
- **What S3 asks for:**
  - a bucket is unversioned, `Enabled` or `Suspended`, and never unversioned again;
  - with `Enabled`, a PUT adds a version with a new id, and a DELETE without an id adds a delete marker;
  - with `Suspended`, both write the null version, replacing the null version the key has, and leave the others;
  - a DELETE with a version id removes that version, marker or not, for good;
  - GET and HEAD without an id read the newest version, and answer 404 when it is a delete marker;
  - ListObjectVersions gives every version, keys in order and each key's versions newest first.
- **Constraints of M4 that stay:** 400 bytes per object in memory for an unversioned bucket (T9), a PUT's meta
  encoded before the store's lock is taken (ADR-0032), checkpoints written in steps from a snapshot of the index
  (ADR-0028), and recovery that needs nothing but the checkpoint and the journal after it.

## Decision

1. **A key's versions are a chain in the index, newest first.** The B-tree still maps a key to one slot of the
   version vector, the newest version's; a second vector, `links`, gives each slot the slot of the next older
   version. `links` is empty until the first key has two versions, so a store without versioning pays nothing for
   it. The newest version may be a delete marker; a key is in the index as long as it has any version.
2. **A record's meaning depends on the record alone, not on the bucket's state when it is replayed:**
   - a put (`PutInline`, `PutExtent`, `UploadComplete`) or a `DeleteMarker` with **the null id** removes the key's
     null version, wherever it is in the chain, and becomes the newest version;
   - with **another id** it becomes the newest version and removes nothing;
   - `DeleteVersion` removes the version with its id; when that was the newest, the next older one is the newest;
   - `Relocate` and `SetTags` find their version by id and generation anywhere in the chain.

   An unversioned bucket's records all carry the null id, so every journal written so far replays as before.
3. **The writer chooses the id under the store's lock.** A bucket's versioning state is a `BucketConfig` record of
   a new kind (3: one byte, 1 `Enabled`, 2 `Suspended`). A put's meta is encoded with the null id as now; when the
   bucket is `Enabled`, the id is a new one: 16 random bytes, drawn again if the key already has that id or they
   are all zero. A put's record is encoded where it is staged, under the lock, so the id is simply passed in. A DELETE without an id stages a
   `DeleteMarker` when the bucket is `Enabled` or `Suspended` (a new id or the null id), and a `DeleteVersion` of
   the null id when it is unversioned, as now.
4. **Versions are ordered by their LSN.** A chain's LSNs fall from the newest version on. Nothing else decides
   which version is current: not the clock, and not the id.
5. **Checkpoint format 6.** An object entry ends with a kind byte (0 object, 1 delete marker), and a bucket entry
   with its versioning byte. A key's versions are consecutive entries, oldest first, so loading pushes each onto
   its key; an entry whose LSN is not above the key's newest so far is corruption. The header's object count is
   the count of versions. Formats 1 to 5 still load.
6. **The snapshot keeps a changed key's whole chain** (ADR-0028's `before`), and gives the checkpoint a key's
   versions together.
7. **Everything that walks the index walks the chains:** compaction's plan (a noncurrent inline version's record is
   live), `verify`, the per-bucket count that refuses to delete a bucket that is not empty (now versions, markers
   included), and the extent accounting. A delete marker has no payload and its record is never live: the index and
   every later checkpoint hold it.
8. **Reads of the current object skip markers:** HEAD, GET, the conditional PUT's "key exists", and ListObjects
   treat a key whose newest version is a delete marker as absent.
9. **Lifecycle expiration leaves versioned buckets alone until M5's item 2** gives it noncurrent-version rules: in
   a bucket that is `Enabled` or `Suspended` it expires nothing. Unversioned buckets are unchanged.

10. **In the S3 API a version id is 32 hex digits, and `null` for the null id.** Other text is InvalidArgument; an
    id the key does not have is NoSuchVersion on a read and succeeds on a delete, as in S3.
    - **Reads** (GET, HEAD, GetObjectAttributes, GetObjectTagging, a copy's source) take `versionId` and, in a bucket
      with versioning, name the version they read in `x-amz-version-id` (`x-amz-copy-source-version-id` for a
      copy). A read that meets a delete marker carries `x-amz-delete-marker: true` and the marker's id: a 404 for
      a key whose newest version is one, a 405 for the marker named by its id.
    - **Writes** (PUT, CopyObject, CompleteMultipartUpload, POST object) return `x-amz-version-id` when the bucket
      gave the version an id, so not when it is suspended or has no versioning.
    - **DELETE** without an id returns the marker it wrote; with one, the id, and whether what it removed was a
      marker. The null id in a bucket without versioning names the key's one object. DeleteObjects does the same per
      entry, in its one commit; an entry whose id is no version id gets a NoSuchVersion error.
    - **ListObjectVersions** counts versions, delete markers and common prefixes against `max-keys`. A page ends
      with its last entry's key and version id, and the next page starts after that version of that key; if the
      version was removed in between, after the key.
    - **MFA delete** is NotImplemented.

## Consequences

- An unversioned store's memory, records and timings do not change; format 6 adds one byte per version and per
  bucket to a checkpoint.
- A version in memory costs what an object does, plus four bytes once any key has two.
- A store that has written format 6, or a `DeleteMarker` or a record with a version id, cannot be opened by an
  older build: a `DeleteMarker` would be skipped and a versioned put would replace the key's object.
- GET by version id walks the chain: linear in the key's version count.

## Rejected

- **Every version as its own B-tree entry** (key, then inverted LSN): ListObjectVersions falls out, but every
  lookup of a current object becomes a seek, every unversioned key carries eight more bytes, and ListObjects must
  step over noncurrent versions.
- **Noncurrent versions in a second ordered map:** the current path is untouched, but each noncurrent version
  repeats its key, and the snapshot has two structures to keep consistent.
- **Deciding by the bucket's state at replay:** recovery would depend on the order of a config record and the
  writes around it, and a record could mean two things.
- **Version ids from the LSN:** a put's meta is encoded before its LSN is known (ADR-0032), and ids would be
  guessable one from the next.

## Slices

1. The index's chains, the records' meaning, checkpoint format 6, the walks (this ADR's 1, 2, 4 to 7), with the
   fault sweep.
2. The store's API: versioning state, ids at staging, delete markers, reads and deletes by version id, listing
   versions (3, 8, 9).
3. S3: PutBucketVersioning and GetBucketVersioning, `x-amz-version-id` and `versionId` on object requests,
   `x-amz-delete-marker`, ListObjectVersions, DeleteObjects with versions, copy sources and tags by version.
4. The compatibility suites and SDK matrix for versioning, and the README.
