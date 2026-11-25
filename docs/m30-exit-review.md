# M30 exit review: S3 Tables' encryption, tags and storage class (25 Nov 2026)

**M30 closed, 25 Nov 2026** (the owner: "Close M30"), as built, with B1 to B9 recorded below.

**M30's exit (ADR-0125 item A; ADR-0126):**
- tags, storage class and encryption on table buckets and tables, through S3 Tables' calls and their creates;
- every file of an encrypted table sealed with its key: S3's writes, the catalog's metadata, and compaction's reads
  and writes;
- the AWS CLI and boto3 set, read and remove each; the SDK matrix sees the same answers; Terraform sets encryption
  and tags; a KMS table is read back by PyIceberg and Iceberg Java.

## How it was checked

- **`tools/iceberg_java_check.sh` with `ENCRYPTED=1`** (in CI beside the plain run; 50 checks): Iceberg Java's every
  phase on a table sealed under the KMS key `orders`, compaction, the reads by Java and PyIceberg, then every file of
  each table's warehouse sealed under the key.
- **`tools/iceberg_check.py`** (on `serve` and through a cluster's node, in the smokes):
  - tags, storage class and encryption through boto3, and tag conditions in policies;
  - a KMS table's S3 write sealed, and one asking for another encryption refused;
  - a KMS table made with its schema, its first metadata file sealed (the review's A1);
  - on a cluster, a configured create refused, then its settings set by their calls.
- **`tools/s3_smoke.sh`:** the AWS CLI's 24 checks of each call, including `aws:TagKeys` and `aws:RequestTag` in a
  table bucket's policy.
- **The SDK matrix:** Go (17 checks), JS (16), Java (12) and .NET (12), each with its own S3 Tables client.
- **`tools/terraform_check.sh`:** provider 6.70.0's KMS table bucket with tags and a tagged table, applied, read back,
  planned with no change and destroyed (on `serve`).
- **Unit tests:**
  - `tableFilesSealedAndOpened` and `multipartSealedFilesOpenByRanges`: sealed reads whole, by ranges and streamed,
    across chunks, parts and part headers;
  - `encryptedTablesMetadataSealed` and `stagedCreatesAreConfiguredAtOnce`;
  - `encryptedTableCompacted`, `encryptedTableJoined` and `clientSealedFilesOfAPlainTableAreLeft`;
  - `resourceTagConditions` and `requestTagConditions`.
  - The compaction tests fail when outputs are written in the clear or the plain table's sealed inputs are taken
    (mutation-checked).
- **The review:** two agents read ADR-0126 and the code without my notes. One covered encryption and sealed I/O,
  the other tags, policies, the API and clusters. Their findings come from reading. A1 was then shown by running
  the cluster smoke on the binary before its fix, which failed exactly on the new check (`(None, '')`, not
  `('aws:kms', 'orders')`).
- **After the fixes:** 532 unit tests; the cluster smoke (209 passed), the S3 smoke, and CI.

## Findings

### A. Fixed before closing

1. **High: on a cluster, an encrypted table's first metadata file was written in the clear.**
   - A create wrote the table's configuration and then read it back to choose the key, in the same request. A
     shard's write is not seen in its own request (ADR-0058), so the read found no encryption.
   - **Fixed:** a create's metadata is sealed by the encryption it was given (`writeMetadataSealedBy`).
   - **Check:** `iceberg_check.py`'s schemed KMS table, through the cluster.
2. **High: a write into an encrypted table could be stored in the clear when its configuration could not be
   read.** `tableWriteSse` took every read error as "no encryption".
   - **Fixed:** an error fails the write (InternalError); only a missing configuration means none.
3. **Medium: compacting a table without encryption opened the files a client had sealed and wrote their merge in
   the clear.** This covers every table made before M30.
   - **Fixed:** such a table's sealed files are left as they are, as before M30.
   - **Test:** `clientSealedFilesOfAPlainTableAreLeft`, which fails with the skip taken out.
4. **Medium: no test of sealed multipart inputs,** which engines' large files are.
   - **Added:** `multipartSealedFilesOpenByRanges`, covering ranges in a part, across parts, after a part's header and
     mid-chunk, and streamed.
5. **Medium: `aws:RequestTag` and `aws:TagKeys`, decided in §1, were not built.** A policy using them was refused
   (fail closed). Without them, anyone allowed TagResource could change the tag a `ResourceTag` Deny depends on.
   - **Built:** the tags a call sets or names, from its body or UntagResource's `tagKeys`.
   - `aws:TagKeys` takes `ForAllValues:` and `ForAnyValue:`, with IAM's semantics: an empty set holds for all and not
     for any, and `Not…` applies to each value. Without a set operator it is refused.
   - Neither is taken in an S3 policy.
   - **Tests:** `requestTagConditions`, and the CLI's policy checks.
6. **Low: a copy of a data key was left unwiped** in `preparePlain`, including on its error returns. The key is now
   taken last and its copy wiped.
7. **Low: a table inheriting its bucket's encryption was not checked for the key.** A KMS key retired since then
   let the create succeed and every write fail. Such a create is now refused, as an explicit one is.
8. **Low: an Iceberg create that lost its name to another left its configuration record.** It is now removed.

Found by the checks before the review (slice 5):
- a configured encryption whose key this server does not hold was taken;
- a staged create's files (a CTAS's data and manifests) were not sealed.

### B. Recorded, not fixed

1. **On a cluster, a table bucket's settings come after its create** (ADR-0126's consequences, accepted). Taking
   them in its create would need the store to stage a bucket and a write into it together.
2. **Configuration records can be orphaned:** createTable failing after its record, or a staged create replaced or
   never committed. They are not read, and are removed with their table bucket.
3. **Tag keys that differ only in case:** a condition finds the first of them.
4. **Tag lengths are counted in bytes, not characters,** and their character set is not checked.
5. **A table made before M30 has no configuration record:** its storage class follows its bucket's current one,
   not the one at its create.
6. **`aws:ResourceTag` and `aws:RequestTag` are taken in table bucket and table policies, not in identity
   policies,** where they are refused (fail closed).
7. **A tag call on a table reads every table record of its bucket** to find its id.
8. **Configuration writes are unconditional:** two configuration calls at once could lose one's change.
9. **A sealed manifest under a key not held is reported as missing** by the unreferenced-file sweep, which fails
   safely, deleting nothing.

## Where the code differs from ADR-0126

- **§1:** `aws:TagKeys` takes only the set operators (and `Null`).
- **§2:** Terraform has no storage class for table buckets.
- **§3:**
  - a KMS key must be one this server holds and isn't retiring;
  - AES256 needs the SSE-S3 key file;
  - an inherited encryption is checked too.
- **§4:**
  - a table without encryption keeps leaving sealed files uncompacted;
  - a staged create's configuration is written at its reserved id.
- **Clusters:** a configured CreateTableBucket is refused; tag calls are routed to their bucket's shard.
