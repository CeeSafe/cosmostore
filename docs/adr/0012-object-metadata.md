# ADR-0012: Object metadata (x-amz-meta-* and stored headers)

**Status:** accepted for M3 slice 5, 8 Nov 2026

## Context

S3 stores two kinds of fields with an object, besides its Content-Type, and returns them on GET and HEAD:
- **user metadata,** `x-amz-meta-*`, at most 2 KiB of names and values. rclone keeps modification times there
  (`x-amz-meta-mtime`), and backup tools keep hashes and modes;
- **some request headers:** Content-Encoding, Content-Disposition, Cache-Control, Content-Language and Expires.

Put meta v1 (ADR-0001) reserved a section for these from the start: a u16 pair count, written as 0 until now.

## Decision

1. **One format.** The fields are a *metadata section*: a u16 pair count, then per pair a u16+bytes lowercase name and
   a u16+bytes value.
   - The section is the same in put meta (PutInline, PutExtent, UploadComplete), in UploadCreate meta, and in
     checkpoints.
   - Versions and uploads keep it as one validated blob (`metadata`, empty for none), so nothing is re-encoded on
     the way through.
2. **No journal format change.**
   - **Put meta:** records already carry the section, and old records have a count of 0.
   - **UploadCreate:** its meta gains the section at the end. A record written before this ends at the content type,
     which decodes as no metadata, and any other truncation is refused.
3. **Checkpoint format 3:** each object entry and each upload entry ends with its section. Formats 1 and 2 still
   load. This was checked with a store whose checkpoint the previous build wrote.
4. **What is stored:**
   - every `x-amz-meta-*` field, and the five headers above. User metadata over 2 KiB is `MetadataTooLarge`, refused
     before the body is read;
   - every stored field together is at most 8 KiB, which the store also checks;
   - the `aws-chunked` coding is removed from Content-Encoding, as S3 does, because it describes the transfer, not
     the object.
5. **Where it applies:**
   - PutObject, CreateMultipartUpload (the completed object takes the upload's fields), and CopyObject with
     `REPLACE` take the request's fields;
   - CopyObject with `COPY` keeps the source's;
   - UploadPart and UploadPartCopy take none, as in S3.
6. **GET and HEAD** send each stored field as a header. A `response-*` parameter overrides the stored header of the
   same name, and only one value is sent.

## Rejected

- **Separate fields in `ObjectVersion`** for each header. The set grows (S3 also stores
  `x-amz-website-redirect-location`, object lock fields, and more), and every new field would mean a checkpoint
  change. A section of pairs takes new names without one.
- **Keeping metadata in a side table** keyed by version. It would need its own durability and recovery, and the
  record already has the field.

## Tests

- **Unit:** put meta with metadata round-trips, and every truncation is refused. UploadCreate meta round-trips, and
  a record from before ADR-0012 decodes as no metadata.
- **Store** (`metadata_tests.cee`):
  - inline and extent objects keep their fields through the journal and through checkpoints;
  - an upload in a checkpoint keeps its fields, and its completed object has them;
  - fields over the limit are refused, and the object's extents are removed.
- **End to end** (`tools/s3_smoke.sh`):
  - user metadata and the stored headers on HEAD;
  - `aws-chunked` is not stored;
  - a `response-cache-control` override is the only Cache-Control sent, checked with curl's `--aws-sigv4`;
  - `aws s3 cp --metadata` of a multipart object;
  - copies with COPY and with REPLACE;
  - `MetadataTooLarge`.

## Not yet

- Non-ASCII values (S3 sends them RFC 2047-encoded). They are stored and returned as the client sent them.
- Object tags (`x-amz-tagging`), a separate set with its own API.
