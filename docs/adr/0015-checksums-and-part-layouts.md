# ADR-0015: Stored checksums and part layouts

**Status:** accepted for M3 slice 8 (`src/store/checksum.cee`), 8 Nov 2026

## Context

Until now a version kept only its MD5 (the ETag). S3 does more, and clients rely on it:
- S3 stores an object's flexible checksum, CRC32, CRC32C, CRC64NVME, SHA-1 or SHA-256, and returns it on GET and
  HEAD when the request says `x-amz-checksum-mode: ENABLED`. The Go and JavaScript SDKs send that by default, and
  check the body against it.
- Since 2025, S3 gives every new object a CRC64NVME when the client names no checksum.
- A multipart object's checksum is either COMPOSITE (the checksum of its parts' checksums, shown with `-N`) or
  FULL_OBJECT (a CRC of every byte).
- GetObjectAttributes and GET/HEAD `?partNumber` need each part's size, and its checksum. A multipart version kept
  neither.

## Decision

1. **Extras.** Each version keeps a blob beside its metadata (ADR-0012): the checksum's algorithm, type and value,
   and for a multipart object each part's size and checksum. `ObjectExtras` reads and writes it (`checksum.cee`).
   An empty blob means a version written before this ADR: no checksum, and no part layout.
2. **Records**, each with an optional trailing section, so records written before this decode as having none:
   - **PutInline / PutExtent:** an extras section after the metadata.
   - **UploadComplete:** an extras section after the part count.
   - **UploadCreate:** the checksum algorithm and type after the metadata.
   - **UploadPart:** the part's checksum after the mtime.
3. **Checkpoint format 4** adds the extras to object entries, and the algorithm, type and part checksums to upload
   entries. Formats 1 to 3 still load.
4. **Which checksum is stored:**
   - **A PUT** stores the client's checksum (validated, ADR-0008 §7), else a CRC64NVME computed as the body streams.
     So does a copy. A copy may also name another algorithm (`x-amz-checksum-algorithm`), and otherwise keeps a
     single-part source's algorithm.
   - **An upload** takes `x-amz-checksum-algorithm` and `x-amz-checksum-type` at create. The type defaults to
     COMPOSITE for CRC32, CRC32C and SHA256, and to FULL_OBJECT for CRC64NVME. SHA256 cannot be FULL_OBJECT, and
     CRC64NVME cannot be COMPOSITE (InvalidRequest). Without an algorithm, the upload gets CRC64NVME FULL_OBJECT,
     as S3 does.
   - **A part** stores its checksum in the upload's algorithm. A part may name another algorithm only in a
     defaulted upload, and then gets both: the client's checked, the upload's stored.
   - **SHA-1** is NotImplemented: lib/std has none (CEESAFE_GAPS G26).
5. **A multipart object's checksum** is computed at complete, from the parts' checksums alone:
   - **COMPOSITE:** the algorithm over the parts' raw checksums, in order;
   - **FULL_OBJECT:** the parts' CRCs combined. This is zlib's `crc32_combine` GF(2) method, generalised to any
     reflected CRC up to 64 bits whose init and xorout are all ones, which covers CRC32, CRC32C and CRC64NVME.
     No byte is read again.
   - **Checked before the commit:** a checksum the request names for the object must match (BadDigest). A part
     named with a checksum must have that one (InvalidPart).
   - Parts without checksums (an upload from before this ADR) give the layout without a checksum.
6. **What is returned:**
   - **GET/HEAD with `x-amz-checksum-mode: ENABLED`:** `x-amz-checksum-<algorithm>` and `x-amz-checksum-type` for
     a whole-object read, or the part's own checksum for `?partNumber`. Nothing is returned for a Range.
   - **PUT and UploadPart:** the stored checksum. Complete and CopyObject include it in their XML. CreateMultipartUpload
     echoes a declared algorithm and type. ListParts shows each part's.
7. **`?partNumber=N` on GET/HEAD:**
   - **A multipart object:** part N's bytes (206, Content-Range) and `x-amz-mp-parts-count`. A part past the last is
     InvalidPart.
   - **A single PUT:** part 1 is the whole object, and any other part is InvalidPart.
   - **With a Range** it is InvalidRequest.
   - **A multipart version from before this ADR** kept no layout, so the request is NotImplemented.
8. **GetObjectAttributes** (`?attributes`, `x-amz-object-attributes`) returns any of these:
   - ETag, without quotes, as S3 sends it;
   - Checksum;
   - ObjectParts, with PartsCount, its markers, and per part the size and checksum. It pages with
     `x-amz-max-parts` and `x-amz-part-number-marker`, and appears for multipart objects only;
   - StorageClass and ObjectSize.

## Rejected

- **Computing a FULL_OBJECT checksum by reading the object at complete.** It is a read of every byte, which the
  combine makes unnecessary.
- **Keeping the checksum in the metadata section** (ADR-0012) under reserved names. Those fields are sent as headers
  on every GET; checksums are sent only when asked for, and the part layout is not a header at all.

## Tests

- **Unit:**
  - the combine equals a whole-buffer CRC at every cut point, for all three CRCs;
  - s3-tests' reference values for three 5 MiB parts (CRC32 FULL_OBJECT `WgDhBQ==`, CRC64NVME FULL_OBJECT
    `i+6LR0y3eFo=`, SHA-256 COMPOSITE) match;
  - every record's new section round-trips, and records without it decode as before.
- **Store** (`checksum_tests.cee`):
  - extras survive the journal and a checkpoint;
  - FULL_OBJECT and COMPOSITE completion;
  - a wrong object checksum is BadDigest, and a wrongly named part is InvalidPart;
  - uploads without checksums give the layout alone;
  - an upload's checksums survive a checkpoint.
- **s3-tests:** 14 more pass, among them every checksum helper, GET `?partNumber`, and GetObjectAttributes.
