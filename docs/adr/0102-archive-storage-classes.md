# ADR-0102: Archive storage classes (M18)

**Status:** proposed, 20 Nov 2026. M18 is item A of ADR-0101 (the owner: "A: archive classes"). Restore times are
AWS's, scaled (the owner's choice).

## Context

- **What M12 took** (ADR-0090): STANDARD, REDUCED_REDUNDANCY, STANDARD_IA, INTELLIGENT_TIERING, ONEZONE_IA and
  GLACIER_IR.
  - **How a class is stored:** in a version's metadata (`STORAGE_CLASS_FIELD`). A lifecycle transition changes it
    by a metadata-only SetTags record (format 4).
  - **What M12 refused:** GLACIER and DEEP_ARCHIVE, as their reads need RestoreObject.
- **What S3 does with them:**
  - **Reads:** an archived version's GetObject, and a copy from it, answer 403 InvalidObjectState until it is
    restored.
  - **RestoreObject** (`POST ?restore`, a `RestoreRequest` of `Days` and a `Tier`) starts a restore. It answers:
    - 202 Accepted for a new one;
    - 409 RestoreAlreadyInProgress while one runs;
    - 200 for an object already restored, whose days it changes.
  - **After the tier's time:** a temporary copy reads for `Days`, and HeadObject shows
    `x-amz-restore: ongoing-request="false", expiry-date="…"` (while restoring, `ongoing-request="true"`).
  - **After the days:** the copy is gone, and the version is archived again.
  - **The tiers:**
    - GLACIER: Expedited 1–5 minutes, Standard 3–5 hours, Bulk 5–12 hours;
    - DEEP_ARCHIVE: Standard within 12 hours, Bulk within 48; no Expedited.

## Decision (proposed)

1. **The classes.**
   - **Where they are taken:** GLACIER and DEEP_ARCHIVE are stored classes, after GLACIER_IR in S3's waterfall. They
     are taken on PutObject, CopyObject, CreateMultipartUpload, POST forms, replication's class and lifecycle
     transitions (including GLACIER to DEEP_ARCHIVE).
   - **Where they are read:** listings and HeadObject show them, as the other classes.
2. **The bytes stay where they are.** This is a model of S3's tiers for clients and tools, not a cold store: an
   archived version's bytes are not moved, and its reads are refused by its state alone.
3. **Archived reads.**
   - **What is refused:** GetObject, CopyObject from the version, and UploadPartCopy from it, with 403
     InvalidObjectState, unless the version is restored now.
   - **What is not:** HeadObject, listings, tagging, ACLs, deletes and the server's own reads (replication,
     inventory, scrub).
4. **A restore's state.**
   - **Where it is kept:** in the version's metadata (`x-cosmo-restore`): when it is ready and when it expires,
     both absolute times. A new SetTags format (6) sets it, a metadata-only record when the version's generation
     still matches.
   - **What is computed at each request, so no background job is needed:**
     - **Restoring:** before the ready time. HeadObject says `ongoing-request="true"`; reads are refused.
     - **Restored:** from the ready time to the expiry. HeadObject says `ongoing-request="false"` and the expiry
       date; reads are taken.
     - **Archived again:** after the expiry, as if never restored. A new RestoreObject may start another.
   - **Amended by the exit review (docs/m18-exit-review.md, A1 and A2):**
     - **The state names its class** (`<ready> <expiry> <class>`), and counts only while the version has that class:
       a version moved to another archive class is archived again.
     - **Copies and replicas never carry the state.**
5. **RestoreObject.**
   - **The request:** `RestoreRequest` with `Days` (1 to 30,000), and `GlacierJobParameters.Tier` (Standard by
     default).
   - **The answers:**
     - 202 for a new restore;
     - 409 RestoreAlreadyInProgress while one runs;
     - 200 for a restored version, whose expiry it moves to now plus `Days`;
     - 403 InvalidObjectState for a version that is not GLACIER or DEEP_ARCHIVE;
     - 400 InvalidArgument for Expedited on DEEP_ARCHIVE.
   - **Not taken:** `SELECT` restores (`Type`, `OutputLocation`): 501 NotImplemented.
   - **Its authorization:** `s3:RestoreObject`.
6. **The times** (the owner's choice: AWS's, scaled).
   - **The values:** GLACIER Expedited 3 minutes, Standard 4 hours, Bulk 8 hours; DEEP_ARCHIVE Standard 12 hours,
     Bulk 48 hours.
   - **The scale:** `--restore-hour-seconds N` sets how many seconds an hour of them, and a day of `Days`, takes:
     3,600 by default, 1 in tests. It applies on `serve` and each node.
7. **On a cluster:**
   - the restore's record goes through the shard's log, as a SetTags does;
   - each node decides with its own clock. Nodes' clocks differ by the cluster's skew (ADR-0065), so a read at the
     edge of a restore's window may go either way on two nodes, as S3's own eventual expiry does.

## Slices

1. The classes stored and archived reads refused, on `serve`.
2. RestoreObject:
   - SetTags format 6 with its replay and fault sweep;
   - the restore's state, and `x-amz-restore`;
   - reads while restored;
   - `--restore-hour-seconds`.
3. A cluster, and the SDK matrix (boto3, Go, Java, JS and .NET restore an object).
4. The exit review.

## Consequences

- **The journal:** SetTags format 6 is new, so an older binary cannot open a store that has one.
- **Storage:** none. An archived version costs what it did before.
