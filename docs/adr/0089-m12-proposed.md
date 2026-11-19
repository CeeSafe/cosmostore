# ADR-0089: M12, what comes after identities (proposed)

**Status:** decided, 19 Nov 2026: the owner chose A ("A: the long tail"), with archive classes refused; ADR-0090
designs it. Proposed the same day. The owner: "Continue to M12". M11 (identities, ADR-0088) closed the same day, and
ADR-0087 §3 named the long tail the next candidate.

## Context

- **Silently ignored, found while writing this ADR:** `x-amz-storage-class` on a general purpose bucket's PutObject
  (and CopyObject, CreateMultipartUpload) is taken and dropped. `--storage-class GLACIER` answers 200, the object
  reads at once, and HeadObject shows no class. That breaks the rule that what is not done is refused. Directory
  buckets refuse any class but `EXPRESS_ONEZONE` (`directory.cee`), as they should.
- **Still refused** (`docs/compatibility.md`), each answered NotImplemented or InvalidArgument, never ignored:
  - lifecycle transitions (`Transition`, `NoncurrentVersionTransition`);
  - ListMultipartUploads' `delimiter`;
  - SHA-1 checksums (`x-amz-checksum-sha1`), the one checksum of S3's five not taken;
  - the object lock fields of a POST form;
  - SSE-KMS's encryption context (`x-amz-server-side-encryption-context`) and `aws:kms:dsse`.
- **Left by M11** (ADR-0088 §2): a replication, inventory or logging configuration a user puts is authorized once,
  when it is put. A user whose policy later loses the destination keeps writing there until the configuration is
  put again. AWS checks the replication role at each replica.
- **Left by M10:** compaction, which needs a Parquet reader and writer, and refs' `max-ref-age-ms`.
- **Left by ADR-0079 §5:** S3 Metadata tables, S3 Vectors, and an Iceberg engine in the server.

## Decision (proposed)

1. **M12 is one of these items**, each its own design ADR with a support matrix (what is done; what is refused,
   never silently ignored), on `serve` first and then a cluster.

   | # | Item | Done when |
   |---|---|---|
   | A | The long tail | Storage classes first: `x-amz-storage-class` is recorded on the object and returned by HeadObject, GetObject and the listings, or refused (InvalidStorageClass), never dropped. Then each item above, refused today, is taken and tested in the SDK matrix: lifecycle transitions to the storage classes kept here (the class recorded on the object, its bytes where they are), ListMultipartUploads' `delimiter` (CommonPrefixes), SHA-1 checksums (stored, returned, composite for multipart), a POST form's object lock fields, SSE-KMS's encryption context (bound to the sealed data key, required to match on read). |
   | B | Configurations decided at delivery | A replication, inventory or logging configuration records who put it. Each replica, report and log object is authorized as that requester when it is written: refused writes are counted and reported (replication status FAILED), as AWS checks the role. A user removed, or a policy narrowed, stops its configurations' writes at once. |
   | C | Compaction for S3 Tables | A Parquet reader and writer, enough for Iceberg's data files. A `binpack` strategy rewrites a partition's small files into files of `targetFileSizeMB`, committed as a `replace` snapshot. PyIceberg reads the same rows after. |

2. **The recommendation is A.**
   - **Why:** every item is a refusal a client meets today. Each is small, and each is a matrix row, so A can be
     sliced and shipped one item at a time.
   - **Its first slice is a fix, not a feature:** storage classes are silently dropped today. Recording them is also
     what transitions need.
   - **What it stands on:**
     - transitions use lifecycle's existing rule engine (ADR-0020, ADR-0042), with storage classes recorded but not
       moved;
     - SHA-1 is lib/std's, as CRC32C and MD5 are;
     - the encryption context goes into SSE-KMS's envelope (ADR-0055), whose format needs one new field, under the
       journal's versioning rules.
3. **B is the next candidate.** It closes the one decision M11 makes once. A requester recorded on a configuration
   is a new field in three stored configurations, and each delivery path reads it. It is smaller than C, but it
   changes delivery, so it needs its own fault sweep (ADR-0004).
4. **C is not recommended now,** as ADR-0087 §4 said: Parquet is the largest of the three, and engines can compact
   through the catalog meanwhile.
5. **Not in M12:**
   - the IAM API;
   - S3 Metadata tables and S3 Vectors;
   - HTTP/2 and SNI, which are CeeSafe.Web's;
   - a KMS service (keys stay a local file, ADR-0055).

## For the owner to decide

- **Which item is M12:** A (recommended), B or C.
- **Whatever M12 is:** the dropped storage class should be fixed now, at least by refusing every class but
  `STANDARD` (InvalidStorageClass), in a slice of its own. It takes about an hour.
- **For A, transitions:** a transition can do one of two things.
  - **Record only (recommended):** the object's storage class changes, its bytes stay where they are, and
    GetObject answers as before. That is S3's answer for every class but the archive ones.
  - **Also refuse archive classes:** `GLACIER` and `DEEP_ARCHIVE` are refused (InvalidStorageClass), because their
    reads need RestoreObject, which is not built.
  - Either way, the same choice applies to `x-amz-storage-class` on writes.

## Consequences

- One design ADR follows the choice, with its slices.
- For A, the SSE-KMS envelope gains a field. Objects sealed before it have no context and read as before.
