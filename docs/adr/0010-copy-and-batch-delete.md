# ADR-0010: CopyObject, UploadPartCopy and DeleteObjects

**Status:** accepted for M3 slice 3 (`src/s3/copy.cee`, `src/s3/delete.cee`, `ObjectStore.deleteObjects`),
8 Nov 2026

## Context

- **Copies:** `aws s3 cp s3://… s3://…` uses CopyObject, and above 8 MB a multipart upload whose parts are
  UploadPartCopy. SDKs and rclone use both for server-side copies and renames.
- **Batch deletes:** `aws s3 rm --recursive`, `aws s3 sync --delete` and every SDK's bulk delete use DeleteObjects,
  with up to 1,000 keys per request.
- **The store's constraints:** an extent belongs to exactly one version or upload part. Reaping unlinks an extent
  when the record that retires its owner is durable (ADR-0003), and pins hold it for readers (ADR-0007).

## Decision

### Copies are a read and a write inside the server

1. **No shared extents.** A copy reads the source through a pinned `ObjectReader` and writes new extents through an
   `ObjectWriter`, then commits as a PUT (`putFinished`) or a part (`putPart`). No record format changes, and every
   ownership rule stays as it is.
   - Sharing extents would save the copy's I/O. But it needs reference counts in the index, the checkpoint and the
     orphan sweep, and reaping would then depend on them. That waits for evidence that copies matter for
     performance.
2. **The lock:**
   - **The plan** takes the lock once: the source's metadata, its conditions and range, the destination's admission
     (ADR-0006) and writer, and the reader, which pins the source's extents.
   - **The bytes** move a step (1 MiB) at a time on worker threads without the lock, as PUT and GET bodies do.
   - **The commit** takes the lock again.
   - A source overwritten or deleted during the copy is still read whole, because its extents are pinned.
3. **The source:** `x-amz-copy-source`, URL-encoded, as `bucket/key` or `/bucket/key`.
   - `?versionId=null` is accepted; any other version id is NotImplemented (buckets are unversioned).
   - The source may be at most 5 GiB, or the range for a part (InvalidRequest).
4. **Conditions:** the four `x-amz-copy-source-if-*` conditions are checked in RFC 9110's order, and any failure is
   PreconditionFailed, as S3 answers.
   - Conditions on the destination (`If-Match`, `If-None-Match` on CopyObject) are NotImplemented for now.
5. **Metadata:**
   - `x-amz-metadata-directive: COPY` (the default) keeps the source's content type, and `REPLACE` takes the
     request's.
   - A copy onto itself without REPLACE is InvalidRequest.
   - A copy is one PUT, so its ETag is the plain MD5 of its bytes, even when the source was multipart, as in S3.
6. **UploadPartCopy:** `x-amz-copy-source-range: bytes=first-last` must give both ends, within the source
   (InvalidArgument otherwise). Without it, the whole source is copied.
7. **GetObjectTagging** returns an empty `TagSet`, which is true since tags cannot be set (PutObjectTagging is
   NotImplemented). The AWS CLI reads it before every multipart copy.

### DeleteObjects commits once

8. **`ObjectStore.deleteObjects(bucket, keys)`** stages one `DeleteVersion` record per existing key and commits the
   batch: one journal write and one sync. A full batch commits early (`wouldOverflow`), as staged PUTs do.
   - Keys that are missing still count as deleted (as in S3) and stage nothing.
   - Keys that are invalid (empty, over 1 KiB) are reported per key.
   - Nothing is acknowledged before the commit returns. If it fails, the whole request fails, though an early
     sub-batch may already be durable. Deletes are idempotent, so a retry is safe.
9. **The body:**
   - It is read whole, at most 8 MiB and 1,000 keys.
   - It is checked against `x-amz-content-sha256`, `Content-MD5` and a header `x-amz-checksum-*` (BadDigest). The
     Complete body of ADR-0009 now gets the same check.
   - Keys keep their spaces, and XML entities are decoded.
   - `<Quiet>true</Quiet>` reports only errors.

## Tests

- **Store:** `batch_delete_tests.cee` checks one sync per batch, the per-key validity, reaping, and recovery.
  `uploadWorkload`'s fault sweeps end with a batch delete.
- **Unit:** the delete body parser (entities, kept spaces, version ids), and copy ranges.
- **End to end** (`tools/s3_smoke.sh`):
  - copy-object, with COPY and REPLACE and onto itself;
  - a missing source, and a failed copy condition;
  - an encoded key;
  - `aws s3 cp` of 20 MB from S3 to S3, through UploadPartCopy, with the exact `-3` ETag;
  - part copies by range, and a range past the end;
  - delete-objects, including quiet mode.

## Not yet

- Destination conditions on CopyObject, and `x-amz-tagging-directive`.
- A copy source's other versions.
- Shared extents for zero-copy copies.
