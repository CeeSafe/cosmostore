# M18 exit review: archive storage classes (20 Nov 2026)

**M18's exit (ADR-0101 item A; ADR-0102, proposed):** a version is archived, restored with RestoreObject, read, and
archived again after its days, on `serve` and a cluster, through the SDKs.

## How it was checked

- **The evidence:**
  - **Unit tests:**
    - which versions read, by class and restore state;
    - restores belong to their class;
    - the restore record kept, and a value that is not a state refused before it is written;
    - the record's fault sweep (once, sticky, torn, crash).
  - **The S3 smoke,** with `--restore-hour-seconds 1`:
    - the classes taken, and their reads and copies refused;
    - a restore running, done, extended, and its refusals;
    - a copy of a restored version not restored.
  - **The cluster smoke:** a restore asked through one node, seen through another, read through a third.
  - **The SDK matrix:** boto3, Go, Java, JS and .NET each restore and read an object.
- **A review by a reader who had not written the code:** one Medium and several Lows, read, not reproduced.

## Findings

### A. Fixed before closing

1. **Medium: a copy, or a replica, of a restored version was restored without asking.**
   - **Why:** CopyObject's default copies the source's metadata, `x-cosmo-restore` with it, and replication copies
     a version's metadata whole.
   - **The effect:** a copy of a restored GLACIER object, archived, read at once.
   - **Another path:** a restored object copied onto itself to STANDARD kept a stale state that a later transition
     back to GLACIER would have made readable.
   - **Fixed:** copies and replicas never carry the restore state.
2. **Low: a restored GLACIER version moved to DEEP_ARCHIVE by lifecycle stayed restored.**
   - **Fixed:** a restore's state names the class it was made for, and counts only while the version has it. A
     state first written without a class still counts.
3. **Low: a website's error document in an archive class was served without a restore.** It is now checked as any
   read is.
4. **During the milestone, a bug from before it:** a SetTags record whose value its format refuses was written to the
   journal, and the store's next open failed on it.
   - **How it was found:** the restore record's test.
   - **Fixed:** each format's value is checked before the record is written.
   - **Why it never happened in use:** no writer passed such a value.
5. **During the milestone, M17's cluster removal:**
   - **What CI found:** the cluster smoke's key removal failed.
   - **Why:** a removal a node could not take yet was refused for good, and the smoke's own count was vacuous.
   - **Fixed:** such a removal now waits, and is tried again each cycle (`docs/m17-exit-review.md`, After closing).

### B. Recorded, not fixed

1. **Low: an archived version whose metadata is nearly full cannot be restored,** as the restore's field does not
   fit (MetadataTooLarge).
   - **The size it takes:** about 16 KB of stored headers and tags.
   - **The way out:** remove its tags first.
2. **Low: an archived GET is refused after its conditions and range are checked.** So a bad Range answers 416, and a
   matching If-None-Match 304, before 403. An inline version's record is read before the refusal.
3. **Low: `x-amz-restore`'s expiry-date is the exact time,** where S3 rounds it to the next midnight UTC.
4. **Low: what is not done:**
   - `s3:ObjectRestore:*` event notifications;
   - ListObjectsV2's `RestoreStatus` optional attribute;
   - SELECT restores.
5. **Low: a cluster key removal that waits is asked of every node each 2 s cycle,** until it is taken or the file
   changes.

## Decisions for the owner

- **Accept ADR-0102,** with §4 amended: a restore's state names its class, and copies and replicas never carry it.
- **Close M18.**
