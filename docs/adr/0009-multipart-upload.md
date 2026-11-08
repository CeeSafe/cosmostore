# ADR-0009: Multipart upload

**Status:** accepted for M3 slice 2 (`src/store/uploads.cee`, `src/s3/multipart.cee`), 8 Nov 2026

## Context

`aws s3 cp` switches to multipart above 8 MB, and SDKs do the same for large objects. S3's model:
- `CreateMultipartUpload` returns an upload id;
- `UploadPart` stores parts 1 to 10,000 (at most 5 GiB each), and uploading a part number again replaces it;
- `CompleteMultipartUpload` names the parts to use, in ascending order, with their ETags. Every part but the last
  must be at least 5 MiB. Parts not named are discarded. The object's ETag is the MD5 of the named parts' binary
  MD5s, then `-N` for N parts;
- `AbortMultipartUpload` discards every part. `ListParts` and `ListMultipartUploads` show the state.

ADR-0003 planned this: each part is stored as extents, and completing writes one record with the concatenated
manifest. The store is single-writer and journal-first (ADR-0001), so an upload's state must be in the journal and
in checkpoints, or a restart loses it.

## Decision

### Records (journal codes 9 to 12)

All meta starts with the format byte (1), as the other records' do. Each record is acknowledged only after its batch
syncs (ADR-0001).

| Record | Meta | Payload |
|---|---|---|
| `UploadCreate` (9) | upload id (16), bucket, key, i64 initiated ms, content type | none |
| `UploadPart` (10) | upload id, u32 part number, u64 size, md5 (16), i64 mtime ms | the part's manifest |
| `UploadAbort` (11) | upload id, i64 mtime ms | none |
| `UploadComplete` (12) | PutExtent's meta, then upload id and u32 part count | the object's manifest |

- **Upload ids** are 16 random bytes, written as 32 hex digits.
- **Parts are always extents.** A part writer has no inline buffer, so its bytes go straight to extent files, and
  they are durable (`ObjectWriter.finish`) before its `UploadPart` record is staged. An empty part has no extents.
- **`UploadComplete` is self-contained.** Its payload is the manifest of the named parts, in order, so the object
  never depends on the upload's state after the record. Its meta's MD5 is the multipart ETag's digest.

### State

1. **`StoreState.uploads`**, keyed by upload id: bucket, key, content type, initiated time, and the parts in
   part-number order (number, size, MD5, mtime, extents).
2. **Applying records**, live and at recovery, through `applyRecord`:
   - `UploadPart` replaces a part of the same number, whose extents become dead (reaped once durable, ADR-0003);
   - `UploadAbort` makes every part's extents dead;
   - `UploadComplete` removes the upload. Extents of parts it does not name become dead, and the named ones move to
     the new version, which retires the key's previous version as a PUT does;
   - `BucketDelete` drops the bucket's uploads, so a bucket created again with the same name does not inherit them.
3. **Space:** part extents count in `extentBytes` from their `UploadPart` record on. Upload records hold no inline
   payload, so they are never live for compaction: checkpoints carry the upload state.
4. **The orphan sweep and fsck** treat part extents as live.
5. **Multipart versions** keep their part count (`ObjectVersion.parts`, 0 for a single PUT). Their stored MD5 is the
   ETag digest, not the bytes' MD5. So fsck checks a multipart object's size and every extent's CRC32C, but not an
   MD5 of its bytes.

### Checkpoint format 2

- Header byte 56 (reserved in format 1) is the upload count.
- An object entry ends with a u32 part count.
- Upload entries (kind 3) follow the objects: id, bucket, key, initiated ms, content type, u32 part count, then per
  part u32 number, u64 size, md5, i64 mtime, and a manifest.
- Format 1 checkpoints still load, with no uploads and no part counts.

### Checks

- **Create** needs the bucket; **UploadPart** needs the upload, for the same bucket and key. A part's size is
  admitted (ADR-0006) before its first byte, and again at its commit.
- **A part that arrives after its upload was completed or aborted** gets `NoSuchUpload`, and its extents are removed.
- **Complete** checks, under the lock:
  - the part list is not empty, and numbers strictly ascend (`InvalidPartOrder`);
  - each named part exists with that ETag (`InvalidPart`);
  - every part but the last is at least `minPartBytes` (5 MiB; `EntityTooSmall`);
  - the total is at most `maxUploadBytes` (5 TiB, as S3; `EntityTooLarge`).
  - Complete is not admitted against the reserve: it adds a record of at most a few hundred KiB, and it frees space.
- **Part numbers** are 1 to 10,000.

### The S3 surface

- `POST /b/k?uploads` (Create), `PUT /b/k?partNumber&uploadId` (UploadPart), `POST /b/k?uploadId` (Complete),
  `DELETE /b/k?uploadId` (Abort), `GET /b/k?uploadId` (ListParts), and `GET /b?uploads` (ListMultipartUploads,
  without `delimiter`).
- UploadPart takes the same body as PutObject: aws-chunked, `Content-MD5`, and `x-amz-checksum-*`.
- The Complete body is read whole, at most 1 MiB, and checked against `x-amz-content-sha256`. A minimal parser reads
  `<Part>`, `<PartNumber>` and `<ETag>`, and anything else in the body is ignored.
- ETags are `"<hex>-N"` wherever a multipart object's ETag appears: PUT, GET/HEAD, listing, and `If-Match`.
- New errors: `NoSuchUpload` 404, `InvalidPart` 400, `InvalidPartOrder` 400, `EntityTooSmall` 400 and
  `MalformedXML` 400.

## Rejected

- **Upload state in side files.** A second durable structure needs its own ordering and recovery. Records in the
  journal reuse ADR-0001's ordering, the checkpoint, and the fault sweeps.
- **Complete by part numbers only** (the record names parts, and the manifest is rebuilt from the upload). Recovery
  would then depend on every earlier `UploadPart` record, including ones compaction may have removed. The
  checkpoint has them, but a self-contained record is simpler to reason about.
- **Copying parts into new extents at Complete.** It doubles the I/O of a large upload for nothing: extents can be
  any length, and the reader walks any manifest.
- **A whole-object MD5 at Complete.** It needs a read of every byte, and S3 does not give one either.

## Not yet

- `UploadPartCopy` (it comes with CopyObject), and `GET ?partNumber`.
- Expiring abandoned uploads (S3's lifecycle rule `AbortIncompleteMultipartUpload`). Until then an abandoned upload
  keeps its parts until it is aborted.
- `delimiter` in ListMultipartUploads.

## As built (8 Nov 2026)

- **Files:** `src/store/uploads.cee` (state, meta, apply), the upload methods of `ObjectStore`, checkpoint format 2
  in `src/store/checkpoint.cee`, and `src/s3/multipart.cee`. PutObject's body handling became `bodySpec` and
  `receiveBody` (`src/s3/objects.cee`), which UploadPart shares.
- **Tests:**
  - `src/store/upload_tests.cee`;
  - multipart fault sweeps in `src/store/fault_tests.cee` (once, sticky, torn, crash, crash during open);
  - parser and ETag unit tests in `src/s3/s3_unit_tests.cee`;
  - the multipart section of `tools/s3_smoke.sh`.
- **Format 1 compatibility** was checked by opening, with the new build, a store whose checkpoint the previous build
  wrote: 300 objects, and fsck found no problems.
- **Measured** (macOS laptop, loopback): `aws s3 cp` of 256 MiB in 32 parts takes 1.6 s up and 0.75 s down.
