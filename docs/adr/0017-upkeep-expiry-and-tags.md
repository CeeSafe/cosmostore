# ADR-0017: The server's upkeep, upload expiry, object tags, and copy conditions

**Status:** accepted for M3 slice 10, 8 Nov 2026

## Context

- **Upkeep.** `cosmostore serve` never called `ObjectStore.maintain`. Only the soak test and `bench` did. A
  long-running server therefore never checkpointed or compacted. Its journal grew forever, recovery replayed all of
  it, and deferred extents were reaped only as a side effect of later commits.
- **Abandoned uploads.** A multipart upload nobody completes or aborts keeps its parts' space forever. S3 ends them
  with a lifecycle rule, MinIO by default after 24 hours.
- **Tags.** S3 keeps up to 10 tags per object. They are set at PUT, CreateMultipartUpload and CopyObject, changed in
  place by PutObjectTagging and DeleteObjectTagging without a new version, and counted on GET and HEAD.
- **Copy conditions.** CopyObject's own If-Match and If-None-Match (on the destination) were NotImplemented.

## Decision

1. **The server runs `maintain` every 10 s,** as a task raced beside the HTTP server (`Async.race`). If the server
   stops, the task is cancelled.
   - The store's mutex is now an `Arc<AsyncMutex<ObjectStore>>`, shared by the handlers and the task.
   - `maintain` runs on a worker thread under the lock, so requests wait while it runs. A due checkpoint writes the
     whole index, which a large store will notice. Checkpointing without the lock is M4 work.
   - A failed run is logged (`cosmostore: maintenance failed: …`) and tried again at the next interval.
2. **Upload expiry.** `StoreConfig.uploadExpiryMillis` (7 days; 0 for never): `maintain` aborts uploads initiated
   longer ago, each with an UploadAbort record, exactly as AbortMultipartUpload would. The record format and the
   fault model are unchanged. `expireUploads(cutoff)` is the same step with an explicit cutoff, for tests.
3. **Tags live in the version's metadata,** as the field `x-amz-tagging` (ADR-0012). Its value is the canonical
   URL-encoded tag set, `k1=v1&k2=v2`.
   - So tags need no checkpoint change.
   - They travel with multipart and with COPY copies.
   - GET and HEAD do not send the field: they send `x-amz-tagging-count`.
   - The stored-field limit grows from 8 to 16 KiB, because ten tags of 128 and 256 characters can take about
     11 KiB URL-encoded.
4. **One new record, `SetTags` (journal code 13).**
   - **Meta:** bucket, key, version id, generation, and the new tag text (empty to remove them).
   - **Apply:** like compaction's Relocate, it changes the version only if that version is still the key's current
     one. So a SetTags replayed after an overwrite changes nothing.
   - **What it leaves alone:** the version's ETag, generation and modification time. Its record is never live,
     because the index and every later checkpoint hold the tags.
   - **Fault sweeps:** the multipart workload now sets tags in all five sweep modes.
5. **S3's tag rules:**
   - at most 10 tags, with unique keys;
   - keys of 1 to 128 characters and values of at most 256, in UTF-8;
   - anything else is `InvalidTag`.
   - `x-amz-tagging` is the URL-encoded form; PutObjectTagging's body is the Tagging XML, whose keys keep their
     spaces and have their entities decoded.
   - CopyObject follows `x-amz-tagging-directive`, apart from the metadata directive: COPY (the default) keeps the
     source's tags, and REPLACE takes `x-amz-tagging`.
6. **CopyObject destination conditions** use PUT's resolver (ADR-0014):
   - If-None-Match `*` or a list of ETags, and If-Match, checked atomically with the commit;
   - If-Match on a key with no object is NoSuchKey.

## Tests

- **Store:**
  - tags change in place, keeping the generation and the other fields;
  - tags survive the journal and a checkpoint, and an overwrite brings its own;
  - tags on a missing key are NoSuchKey;
  - expiry before and after an upload's start, `maintain` leaving a fresh upload, and the abort surviving a
    restart;
  - the multipart fault sweeps include SetTags.
- **Unit:** tag parsing and canonical form, S3's limits, and the XML form.
- **End to end:**
  - tags at PUT, the count on HEAD, put-object-tagging keeping the ETag, copies with COPY and REPLACE,
    delete-object-tagging, eleven tags, and a missing key;
  - copy destination conditions;
  - by hand, 72 MB of inline objects: the server checkpointed on its own within 7 s, kept serving, and fsck was
    clean after a SIGKILL.

## Not yet

- **Configuring the expiry and the interval** from `serve`'s command line.
- **Bucket lifecycle rules,** of which upload expiry is S3's `AbortIncompleteMultipartUpload`.
- **Maintenance that does not hold the store's lock** throughout.
