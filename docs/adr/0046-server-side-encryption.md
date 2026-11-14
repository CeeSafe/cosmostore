# ADR-0046: Server-side encryption (SSE-S3 and SSE-C)

**Status:** accepted for M5 (item 4), 14 Nov 2026, as built (the owner, asking for its status to be settled with
the rest of item 4), and built (`src/s3/sse.cee`, `src/store/sealed.cee`). Proposed 13 Nov 2026, when sealing waited
for AES-256-GCM in CeeSafe's lib/std (G33). SSE-KMS is ADR-0055.

**14 Nov 2026: built.** G33 is fixed in ceesafec 0.45.0 (CeeSafe ADR 0135). `serve --sse-key-file`; SSE-S3, SSE-C and
a bucket's default on PutObject, POST object, CopyObject, CreateMultipartUpload, UploadPart, UploadPartCopy and
CompleteMultipartUpload, and on GetObject, HeadObject and GetObjectAttributes (ranges and `?partNumber` too); the
reader over stored offsets; `fsck` of sealed versions. SSE-KMS stays NotImplemented. Changed from the text below
as it was built, and marked there: SSE-C's ETag (§6), its answer to another key (§6), Complete taking SSE-C's key
(§6), SSE-S3's field on a read (§5), and a bucket's default needing the key file (§5).

**Multipart, revised 14 Nov 2026** (chosen with the user, over the part's index first chosen the same day): each
upload of a part is sealed under a key of its own, derived from the object's data key and a random salt that the
part's stored bytes start with (§2). The part's index could not be used: a part is sealed when it is uploaded,
before its place among the completed parts is known, and a part uploaded twice under one number would have reused
nonces under one key. No format changes.

## Context

- **What S3 offers.** SSE-S3 (`x-amz-server-side-encryption: AES256`): the server encrypts with keys it keeps.
  SSE-C (`x-amz-server-side-encryption-customer-algorithm`, `-key`, `-key-MD5`): the request brings a 256-bit key,
  which the server uses and forgets, and every later read must bring it again. A bucket can name a default
  (PutBucketEncryption). Both are AES-256.
- **What the formats reserved.** A record's flags have a bit for "the payload is encrypted" (ADR-0001), and the
  roadmap planned an envelope slot. Neither can carry it as built: `Journal.stage` writes flags 0, a Relocate
  record restages a payload with new flags, and a checkpoint keeps no flags per version. What a version does keep
  everywhere, in its record, in the index and in checkpoints, is its metadata fields (ADR-0012), where its tags
  (ADR-0017) and ACL (ADR-0045) already live.
- **How bytes are stored** (ADR-0003, ADR-0010): an object's bytes go through an `ObjectWriter` into a PutInline
  record's payload (up to 128 KiB) or into extents, each with one CRC32C; a multipart upload's parts keep their
  own extents and CompleteMultipartUpload joins their manifests without rewriting a byte; a copy reads its source
  and writes it again; compaction moves inline payloads without looking at them. A GET with a range reads from the
  middle of an extent or payload. The writer computes the MD5 of what it is given.
- **The cipher.** lib/std has SHA-256, HMAC-SHA256 and the system's random source, and no cipher; CosmoStore calls
  no C. The owner chose to wait for AES-256-GCM in lib/std (G33) over a cipher in CosmoStore's own code.
- **The master key** (chosen with the user, 13 Nov 2026): a key file named when `serve` starts, like the
  credentials file, wrapping a data key per object.

## Decision

1. **Encryption is above the store.** The S3 layer seals an object's bytes before the `ObjectWriter` and opens
   them after the reader. The store, the journal, extents, checkpoints and compaction carry ciphertext as they
   carry any bytes, and their CRCs cover it. A version's size in the index stays the size of its plaintext, which
   is what every S3 answer gives.
2. **An object is sealed in chunks of 64 KiB** with AES-256-GCM under a data key of its own, 32 random bytes
   (`Random.fill`) made for the object and used for nothing else.
   - A chunk is its ciphertext and its 16-byte tag. An object of `n` bytes has `max(1, ceil(n / 65536))` chunks:
     an empty object is one empty chunk, so its tag is there to check.
   - A chunk's nonce is 12 bytes: 4 zero bytes and the chunk's index in its part (u64), little-endian. The data
     key is one object's, and a multipart part's key is one upload of that part's, so no nonce repeats under a key.
   - A chunk's associated data is one byte: 1 for the last chunk of its part, else 0. Chunks cannot be reordered
     (the nonce), dropped from the end (the last flag) or cut short (the tag).
   - **Stored length:** `n + 16 * chunks`. Plaintext offset `p` of a part is in chunk `p / 65536`, which starts at
     stored offset `(p / 65536) * 65552` of the part. A range reads the chunks it touches whole and opens each:
     a range read is checked as a whole read is, which the extent CRC does not do for a partial read (ADR-0003).
   - **Multipart:** CreateMultipartUpload makes the data key, and its envelope goes with the upload's metadata to
     the completed object. Each UploadPart draws a random 16-byte salt and seals the part under
     HMAC-SHA256(data key, `cosmostore sse part v1` and the salt); the part's stored bytes are the salt and then
     its chunks, so a part is `16 + n + 16 * chunks` bytes. A part uploaded again under its number gets another
     salt and so another key. Complete joins the manifests as now, and the parts' plaintext sizes (`extras`,
     ADR-0015) give each part's stored offset. A range reads, under one reader, the chunks it touches and the
     salts of the parts after its first; when it starts after its first part's first chunk, that part's salt is
     read apart (16 bytes).
   - Nothing ties a part to its place: whoever can write the disk can swap two parts with their salts, as they can
     move a sealed object and its envelope (Consequences). A part changed, cut short or under another salt does not
     open.
   - The parts are admitted at their plaintext size, 16 bytes in 64 KiB below what they store.
   - **Reading the stored bytes** needs the store to give a range of what is stored rather than of the size it
     reports: a reader over stored offsets beside `prepareReaderOf`.
3. **The envelope is a field of the version's metadata,** `x-amz-server-side-encryption`, as text:
   `v1.<mode>.<key id>.<nonce>.<wrapped data key>`, the last two in hex.
   - `mode` is `s3` or `c`. The wrapped data key is the data key sealed with AES-256-GCM (48 bytes with its tag)
     under the master key the id names, or under the request's key for SSE-C (key id `-`), with a random 12-byte
     nonce and the mode as associated data.
   - About 140 bytes a version, in its record, the index and checkpoints. GET and HEAD do not return the field;
     they return S3's response fields for the mode.
   - A copy never has its source's envelope: it is opened and sealed again, or stored in the clear, as the
     request asks. Relocation moves the payload and the field together.
4. **The key file** (`serve --sse-key-file <path>`): lines of `<key id> <base64 of 32 bytes>`; `#` starts a
   comment. The first key seals new objects; every key opens the objects sealed under it, so a key is rotated by
   putting a new first line and keeping the old one. Key ids are 1 to 32 characters of `A-Z a-z 0-9 _ -` and
   differ. The file is read once, at start, before the store opens, and a file that does not parse stops `serve`.
   Without the option, a request for SSE-S3 is InvalidRequest. An object whose key id is not in the file cannot be
   read: InternalError, and a line in the log naming the id.
5. **SSE-S3:** `x-amz-server-side-encryption: AES256` on PutObject, CopyObject, CreateMultipartUpload and POST
   object, or the bucket's default (Put-, Get- and DeleteBucketEncryption, `BucketConfig` kind 11, checkpoint
   format 14; `aws:kms` is NotImplemented). Responses to writes and reads of such an object carry the field. Its
   ETag is the MD5 of the plaintext, as in S3, which the S3 layer computes itself.
   - *As built:* the field on GetObject, HeadObject, UploadPart or Complete is InvalidArgument, as S3 answers
     (s3-tests). PutBucketEncryption without a key file is InvalidRequest: the default could not be honoured. A
     write that brings no fields reads the default only while some bucket has one (a count, as for CORS), so an
     inline PUT still starts without the store's lock (ADR-0032).
   - A POST form's file has no size in advance: the sealer holds a full chunk until more comes, so it knows the
     last chunk without the size.
6. **SSE-C:** the three customer fields on the same calls, and on UploadPart, GetObject, HeadObject,
   GetObjectAttributes and, as the `x-amz-copy-source-` fields, on a copy's source.
   - The key must be 32 bytes and its MD5 must match (InvalidArgument); the algorithm must be `AES256`.
   - Only over TLS: InvalidRequest when `serve` listens without it, as S3 answers plain HTTP.
   - A read without the key, or with SSE-S3's field, is InvalidRequest; with another key the data key does not
     open: *as built,* InvalidRequest (400), as s3-tests has S3 answer, not AccessDenied. A key brought for an
     object in the clear is InvalidRequest. The key is never stored or logged.
   - *As built,* its ETag is HMAC-SHA256 of the plaintext's MD5 under the request's key, its first 16 bytes: not
     the MD5, which would let whoever reads a listing test a guess, and not the MD5 of what is stored, which
     changes with every upload of a part (a random salt, §2), so Complete could not find a part uploaded again.
   - *As built,* CompleteMultipartUpload of an SSE-C upload takes its key too (400 without, or with another), as
     the AWS CLI sends it and s3-tests expects.
   - A presigned URL does not carry the key: the fields come with the request.
7. **Fields an operation does not take** (SSE-KMS's, or encryption fields on an operation that has none) are
   NotImplemented, so nothing asked to be sealed is stored in the clear. Before this ADR they were ignored, and the
   object was stored in the clear under a 200.

## Consequences

- An encrypted object costs 16 bytes per 64 KiB and about 140 bytes of metadata, and its bytes pass the cipher
  once each way; a copy passes it twice.
- **What is not encrypted:** keys, user metadata, tags, sizes, times, and the digests kept with a version. An
  SSE-S3 object's ETag and its stored checksum (ADR-0015) are digests of its plaintext, in the clear on disk, as
  S3 returns them: whoever holds the disk can test a guess of the content against them. SSE-C keeps the checksum
  and not the MD5.
- The master keys are in a file beside the credentials. Whoever reads the disk and that file reads everything;
  the file belongs on other storage than the data, or in memory only on hosts that can give it so.
- Losing a master key loses every object sealed under it. Rotation leaves old objects under old keys; sealing
  them again is a CopyObject onto themselves.
- The envelope names no bucket or key: an attacker who can write to the disk can move a sealed object and its
  envelope to another key, as they could move a clear one.
- The record flag of ADR-0001 stays reserved and unused.

## Rejected

- **Sealing in the store,** under the journal: compaction and recovery would need keys, and SSE-C's key is a
  request's.
- **One nonce and one tag per object:** a range read could not be opened without reading from the start, and a
  16 MiB limit of one GCM call per record would not cover extents.
- **Sealing each object directly under the master key:** every object would share a key, nonces would have to be
  random and their number bounded, and rotation would mean rewriting data, not envelopes.
- **Deriving the master key from the credentials file:** rotating an access key would then lose data.
- **A cipher in CosmoStore's own code** (a table-free AES, or ChaCha20-Poly1305 under S3's `AES256` name): G33.
- **SSE-KMS:** after this, behind a provider interface (roadmap M5 item 4).
