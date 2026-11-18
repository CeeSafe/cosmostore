# ADR-0081: RenameObject for directory buckets

**Status:** proposed, 18 Nov 2026. Found missing by the M8 exit review (finding A9): ADR-0080 lists RenameObject as
a call directory buckets take, and it was not built. It needs a journal record of its own, an on-disk format change,
so it is this ADR's, for the owner to accept or leave out of M8.

## Context

- **AWS's RenameObject** (the API reference and the user guide's "renaming objects in directory buckets", read
  18 Nov 2026): `PUT /<key>?renameObject` on a directory bucket, with `x-amz-rename-source` naming the source key in
  the same bucket. It is atomic and copies no data. The object keeps all its metadata: the storage class, the
  encryption, the creation and last-modified dates, the checksums. Optional fields:
  - conditions on the destination: `If-Match`, `If-None-Match` (`*`: 412 if the destination exists),
    `If-Modified-Since`, `If-Unmodified-Since`;
  - conditions on the source: `x-amz-rename-source-if-match` and the matching `-if-none-match`,
    `-if-modified-since` and `-if-unmodified-since`;
  - `x-amz-client-token`, which makes a retry idempotent.

  A key ending in `/` cannot be renamed. A ReadWrite session is needed, and a ReadOnly session is refused. Directory
  buckets only: a general-purpose bucket refuses the call.
- **What CosmoStore has:** an object's version is a key's index entry naming its payload (inline, or extents by
  manifest). `Relocate` (ADR-0005) already moves a version's locator by a record, if the version is still current.
  Directory buckets are never versioned, and have no notifications or replication (ADR-0080 §6). On a cluster the
  record goes through the bucket's shard's Raft log, and a write's request id is kept for retries (ADR-0068).

## Decision (proposed)

1. **A record `Rename`**, appended to `RecordType` so the existing values do not change. Its meta: the bucket, the
   source key, the destination key, and the source's version identity (its write's sequence number, as `Relocate`
   names it). Applying it, at commit and at replay alike:
   - if the source's current version is still that one, the destination's index entry becomes it, with its
     locator, metadata and dates;
   - the source key's entry goes, and the destination's previous version (if any) is freed as a PUT's would be;
   - otherwise it changes nothing (the commit answers 412 or NoSuchKey, as below).

   No payload is copied or written. The extents keep their single owner, now under another key, so neither the
   garbage collector nor the scrubber changes.
2. **Ordering (ADR-0001):** the answer comes after the journal batch holding the record is synced, as for every
   write. The conditions are checked under the store's lock against the index, with the commit, as PUT's
   `If-Match` is (ADR-0017).
3. **The checkpoint format does not change:** a checkpoint holds the index, which a rename leaves in a state a PUT
   and a DELETE could have made.
4. **The S3 call:**
   - **Errors:**
     - a source that does not exist, or a source key ending in `/`: NoSuchKey;
     - a destination key ending in `/`: InvalidArgument;
     - a condition that fails: PreconditionFailed;
     - a source in another bucket (a `/` in `x-amz-rename-source` names a key, not a bucket): the key is in this
       bucket, as S3 reads it;
     - on a general-purpose bucket: NotImplemented.
   - **Authorization:** `s3:PutObject` on the destination and `s3:DeleteObject` on the source, for a long-term key.
     A session is authorized by its bucket and mode (ADR-0080 §4), and a ReadOnly session is refused.
   - **`x-amz-client-token`:** the store keeps the last tokens of each bucket in memory, with their answers, for 10
     minutes. A repeat answers the same.
     - On `serve`, a restart forgets them: a repeat after a restart finds no source, and answers NoSuchKey.
     - On a cluster, the token is the write's request id (ADR-0068), kept in the Raft log's sessions, so a repeat
       through any node answers the same.
5. **Fault sweep:** `renameFaults{Once,Sticky,Torn,Crash}` over a rename of an inline object and of an extent
   object, with a PUT racing the destination. After every fault and crash, exactly one of these holds: the source
   is there with its bytes, or the destination is there with the source's bytes and the source is gone. The
   destination's previous bytes are freed only after the record is durable.
6. **Tests:**
   - unit tests of the conditions and the errors;
   - the S3 smoke's `s3api rename-object`, with and without a session, and the cluster smoke's;
   - boto3's `rename_object`, and the other SDKs where theirs has it.

## Consequences

- One record type more in the journal and the Raft log. A store written by this version cannot be read by an older
  one once a rename is in it; that is the same rule as for any new record (ADR-0005).
- `docs/compatibility.md` and ADR-0080 list RenameObject as taken.

## Rejected

- **A copy and a delete:** it is not atomic. A crash between them leaves two objects, and a reader can see neither
  or both. It also copies the data, which RenameObject never does.
- **Leaving it NotImplemented:** this is what the code does now, and ADR-0080 lists it as not done until this ADR is
  accepted. AWS's directory buckets document it as theirs, and a client that renames gets a 501.
