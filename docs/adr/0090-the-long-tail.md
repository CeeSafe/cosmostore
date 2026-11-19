# ADR-0090: The long tail, what S3 clients meet refused (M12)

**Status:** proposed, 19 Nov 2026. M12 is item A of ADR-0089 (the owner: "A: the long tail"); archive classes are
refused (the owner's choice).

## Context

ADR-0089 lists what a client meets refused today, and one thing silently dropped: `x-amz-storage-class` on a general
purpose bucket. Each item below is small, and each becomes a row of the support matrix, tested in the SDK matrix.

## Decision (proposed)

1. **Storage classes** (first, as a fix).
   - **Taken:** `STANDARD`, `REDUCED_REDUNDANCY`, `STANDARD_IA`, `ONEZONE_IA`, `INTELLIGENT_TIERING` and `GLACIER_IR`.
     They are recorded on the object and the bytes stay where they are, so reads answer as for `STANDARD`.
   - **Refused (InvalidStorageClass):** `GLACIER` and `DEEP_ARCHIVE`, whose reads need RestoreObject, and any other
     name.
   - **Where it is taken:** `x-amz-storage-class` on PutObject, CopyObject, CreateMultipartUpload and a POST form's
     field. A copy onto itself that changes only the class is allowed, as on S3.
   - **Where it is answered:**
     - HeadObject and GetObject return `x-amz-storage-class`, except for `STANDARD`, as S3 does;
     - ListObjects (v1, v2), ListObjectVersions, ListParts and ListMultipartUploads, GetObjectAttributes and
       inventory reports give the object's own class.
   - **Directory buckets** keep `EXPRESS_ONEZONE` only.
2. **Lifecycle transitions** (ADR-0020, ADR-0042).
   - `Transition` and `NoncurrentVersionTransition` are taken, by days or date, to the classes of §1. They are
     refused for the archive classes.
   - A transition rewrites the object's metadata with its new class, in the store's metadata update, journaled as
     tags are. It does not move bytes.
   - GetBucketLifecycleConfiguration returns the rules as put.
3. **ListMultipartUploads' `delimiter`:** CommonPrefixes, grouped as ListObjects groups keys, with `prefix` and the
   key and upload id markers.
4. **SHA-1 checksums:** `x-amz-checksum-sha1` is checked, stored and returned (`x-amz-checksum-mode`), and composite
   for multipart, as SHA-256 is. It uses lib/std's SHA-1, which `src/storage/checksums/checksums.cee` pins.
5. **A POST form's object lock fields:** `x-amz-object-lock-mode`, `x-amz-object-lock-retain-until-date` and
   `x-amz-object-lock-legal-hold`, as the headers of PutObject (ADR-0047). They are authorized as
   `s3:PutObjectRetention` and `s3:PutObjectLegalHold` (ADR-0088 §2).
6. **SSE-KMS's encryption context** (ADR-0055).
   - **Taken:** `x-amz-server-side-encryption-context`, base64 JSON of string pairs, with S3's default context (the
     bucket's ARN) added.
   - **Where it is kept:** in the data key's envelope, as authenticated data of its seal, so a stored context cannot
     be changed without the key failing to open.
   - **Returned** on Head and Get.
   - **Compatibility:** objects sealed before it have none, and read as before. `aws:kms:dsse` stays refused.
7. **On a cluster:** every item, through every node. **Slices** follow this order, each with its smoke and SDK
   checks.

## Slices

1. Storage classes on writes, reads and listings (§1).
2. Lifecycle transitions (§2).
3. ListMultipartUploads' `delimiter` (§3) and SHA-1 checksums (§4).
4. A POST form's object lock fields (§5) and SSE-KMS's encryption context (§6).
5. The cluster and the SDK matrix; the exit review.

## Consequences

- **The journal:** no new record kind. The class is metadata (a stored field), and transitions use the metadata
  update tags use.
- **SSE-KMS's envelope** gains a field, under its version: older envelopes read as having none.
- `docs/compatibility.md` loses its "refused" entries for each item.
