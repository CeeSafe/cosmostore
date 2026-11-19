# M12 exit review: the long tail (19 Nov 2026)

**M12's exit (ROADMAP, M12; ADR-0090, proposed):** each item refused today is taken and tested in the SDK matrix,
on `serve` and on a cluster. Storage classes are recorded or refused, never dropped.

## How it was checked

- **The evidence:**
  - **Unit tests:** 385, among them `lifecycleTransitionsRecordClasses`, `transitionCrashAtEveryByteIsConsistent`,
    `uploadsGroupedByDelimiter`, `sha1MatchesFips180` and `kmsEncryptionContextIsSealed`.
  - **The S3 smoke:** storage classes, transitions, the uploads' delimiter, SHA-1 and the encryption context.
  - **The cluster smoke:** 144 checks, each item through other nodes.
  - **The SDK matrix:** five SDKs.
- **Two reviews by readers who had not written the code:**
  - **Correctness and durability:** reproduced against `serve`.
  - **Conformance with S3:** botocore's model, and *memory* where marked.

## The item

| Done when | Verdict |
|---|---|
| Storage classes recorded or refused, never dropped | holds for writes and reads; **A2**, **B4**, **B6** |
| Each item taken and tested in the SDK matrix | holds |
| On `serve` | **A1**: one object stops lifecycle for the whole server |
| On a cluster | **A3**: lifecycle never runs on a cluster; SSE-KMS is not served there |

## Findings

### A. Must fix

1. **High: one object near the metadata limit stops lifecycle for the whole server, at every pass** (reproduced).
   - **Where:** a transition adds `x-amz-storage-class` to the version's metadata. A version within ~33 bytes of
     MAX_METADATA_BYTES makes `setFieldOf` fail with MetadataTooLarge, and `applyLifecycle` returns that error.
   - **What stops:** every bucket after it gets no expirations, transitions or upload aborts, and the full scan is
     tried again every upkeep.
   - **Who can do it:** anyone who may write: a large Cache-Control or Content-Disposition, and ten tags.
2. **Medium: directory buckets take Transition rules,** which would record a class other than EXPRESS_ONEZONE.
3. **Medium: lifecycle never runs on a cluster.**
   - **What is missing:** `src/cluster` checkpoints, compacts and sweeps but does not call `applyLifecycle`, so a
     cluster takes transitions, and expirations too (before M12), and never applies them.
   - **What this breaks:** ADR-0090 §7, and the rule that what is not done is refused.
4. **Medium: transitions sync once each, under the store's lock.** That is up to 1000 syncs a bucket a run, where
   deletes are one batch.
5. **Medium: `x-amz-transition-default-minimum-object-size` is ignored,** and S3's 128 KB floor is not applied
   (botocore).
   - **What happens:** a bogus value is taken, and a 3-byte object moves to GLACIER_IR.
   - **What S3 does:** objects under 128 KB are not moved to the classes CosmoStore keeps, unless the rule has a
     size filter.
6. **Medium: a POST form's `x-amz-checksum-*` fields are ignored.** A wrong `x-amz-checksum-sha1` field answers
   204.

### B. Conformance

1. **Medium: REDUCED_REDUNDANCY is taken as a transition target** (both reviews). It is not in botocore's
   TransitionStorageClass, and its waterfall rank is STANDARD's, so the rule never acts.
2. **Medium: S3's checks between one rule's transitions are missing** (*memory*):
   - a class twice;
   - Days and Date mixed;
   - out of waterfall order;
   - Expiration not after the transitions;
   - 30 days in STANDARD_IA before ONEZONE_IA.
3. **Low: replication's `Destination/StorageClass`** other than STANDARD is still NotImplemented. That is a
   refusal, but now that classes are kept it can be taken.
4. **Low: a copy onto itself with an unchanged class** is accepted. S3 wants something changed (*memory*).
5. **Low: `docs/compatibility.md` says bucket keys are "reported off",** but the header is refused, even `false`.
6. **Low: the class is checked before the bucket is,** so GLACIER to a missing bucket gets InvalidStorageClass,
   not NoSuchBucket (*memory*).
7. **Low, before M12: PutObject's answer has no `x-amz-checksum-type`.**

### C. Durability notes

1. **Downgrade:** a binary before M12 cannot read SetTags format 4, lifecycle v3 or checksum code 5. Recovery must
   refuse such a record, not take it for a torn tail. To be confirmed, and "no downgrade past M12" recorded.
2. **The fault sweep for transitions is thin:** one record cut at every byte. A checkpoint after a transition, and
   an injected fault, are not covered.
3. **SHA-1 is byte at a time:** correct but slow. It has no vectors at the 55, 56, 63 and 64 byte padding
   boundaries.

Checked and right (both reviews):
- **Storage classes:** on every write, read and listing, copies' and uploads' included.
- **Lifecycle:**
  - due times, `NewerNoncurrentVersions`, expiration before transition, delete markers, null versions, locked
    versions, never back up the waterfall;
  - old rule versions decode, and format 4 replays.
- **The uploads' delimiter:** markers, counting, encoding and pagination.
- **SHA-1:** headers and trailers, composite multipart, BadDigest.
- **The POST form's lock fields.**
- **SSE-KMS's context:** on Put, Copy, CreateMultipartUpload and POST, sealed under the AAD and refused when malformed.

## Verdict

**M12 should not close yet.**
- **A1** lets one object stop lifecycle for every bucket.
- **A3** leaves a cluster taking rules it never applies.
- **A2 and A4 to A6** are smaller.

**The recommendation:** fix A, B1, B2 and C1, and B3 to B7 where they are cheap. A3 needs the owner's choice:
- **(a)** run lifecycle on each shard's leader, as Raft writes. This is the larger fix, and gives a cluster
  expiration too.
- **(b)** refuse lifecycle configurations on a cluster until (a), with `compatibility.md` saying so.

Closing M12 and accepting ADR-0090 are the owner's decisions.
