# ADR-0090: The long tail, what S3 clients meet refused (M12)

**Status:** accepted, 19 Nov 2026 (the owner: "Accept and close"), as amended after M12's exit review. Proposed
the same day. M12 is item A of ADR-0089 (the owner: "A: the long tail"); archive classes are
refused (the owner's choice).

## Context

ADR-0089 lists what a client meets refused today, and one thing silently dropped: `x-amz-storage-class` on a general
purpose bucket. Each item below is small, and each becomes a row of the support matrix, tested in the SDK matrix.

## Decision

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
   - **Replication** (amended after M12's exit review): a rule's `Destination/StorageClass` is one of these, and its
     replicas are recorded with it.
2. **Lifecycle transitions** (ADR-0020, ADR-0042).
   - `Transition` and `NoncurrentVersionTransition` are taken, by days or date, to the classes of §1. They are
     refused for the archive classes.
   - A transition rewrites the object's metadata with its new class, in the store's metadata update, journaled as
     tags are. It does not move bytes.
   - GetBucketLifecycleConfiguration returns the rules as put.
   - **Amended after M12's exit review:**
     - S3's checks between one rule's transitions;
     - REDUCED_REDUNDANCY refused as a target;
     - S3's 128 KB floor, unless the rule filters by size;
     - `x-amz-transition-default-minimum-object-size` taken, kept and answered;
     - directory buckets take no transitions;
     - a version without room in its metadata for the class is skipped.
3. **ListMultipartUploads' `delimiter`:** CommonPrefixes, grouped as ListObjects groups keys, with `prefix` and the
   key and upload id markers.
4. **SHA-1 checksums:** `x-amz-checksum-sha1` is checked, stored and returned (`x-amz-checksum-mode`), and composite
   for multipart, as SHA-256 is. lib/std has no SHA-1 (CEESAFE_GAPS G26, still so in 0.77.1), so it is FIPS 180-4 in
   plain CeeSafe (`src/storage/checksums/sha1.cee`), as CRC-32 is, checked against FIPS 180's vectors.
5. **A POST form's object lock fields:** `x-amz-object-lock-mode`, `x-amz-object-lock-retain-until-date` and
   `x-amz-object-lock-legal-hold`, as the headers of PutObject (ADR-0047). They are authorized as
   `s3:PutObjectRetention` and `s3:PutObjectLegalHold` (ADR-0088 §2).
6. **SSE-KMS's encryption context** (ADR-0055).
   - **Taken:** `x-amz-server-side-encryption-context`, base64 of a JSON object of strings, at most 4 KB, kept and
     returned as the request gave it. S3 also adds its default pair, `aws:s3:arn` (the bucket's or the object's ARN);
     CosmoStore does not, since its KMS is a local key file that no one else asks about. A client that compares the
     context it gets back with the one it sent sees them equal here, and on AWS sees the extra pair.
   - **Where it is kept:** in the data key's envelope (`v1.kms.<key>.<nonce>.<wrapped>.<context>`), as authenticated
     data of its seal, so a stored context cannot be changed without the key failing to open.
   - **Returned** on PutObject, CopyObject and CreateMultipartUpload, as AWS's models answer it, and on Head and Get
     too, where SDKs do not read it.
   - **Compatibility:** objects sealed before it have none, and read as before. `aws:kms:dsse` stays refused.
7. **On a cluster:** every item, through every node, but SSE-KMS's context: a node has no KMS key file, so SSE-KMS
   is not served on a cluster at all (before M12). Lifecycle rules, expirations included, run on each shard's
   leader as a write (amended after M12's exit review, A3, by the owner's choice; `node --lifecycle-seconds`). **Slices** follow this order, each with its smoke and SDK
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
