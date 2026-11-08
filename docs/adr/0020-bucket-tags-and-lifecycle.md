# ADR-0020: Bucket tags and lifecycle rules

**Status:** accepted for M3 slice 13 (`src/store/bucket_config.cee`, `src/s3/bucket_config.cee`), 9 Nov 2026

## Context

- **Bucket tags.** Up to 50 per bucket. Tools read and set them for cost allocation and policy.
- **Lifecycle rules.** These are what S3 users rely on to expire logs and temporary data, and to clean up abandoned
  multipart uploads. A bucket had neither. Its state was its creation time and object count, and ADR-0017's 7-day
  upload expiry was store-wide.

## Decision

1. **The bucket keeps both** (`BucketInfo.tags`, `BucketInfo.lifecycle`):
   - **tags** in the canonical URL-encoded form object tags use (ADR-0017);
   - **rules** as a compact binary blob (`encodeLifecycle`), from which GET writes the XML back.
2. **One new record, `BucketConfig` (journal code 14):** bucket, kind (1 tags, 2 lifecycle), and value (empty: cleared).
   - `applyRecord` applies it, live and at recovery, like every record. It is never live for compaction, since the
     bucket in the index and every later checkpoint hold the value.
   - Deleting a bucket drops its settings with it, so a bucket made again with the same name starts bare.
3. **Checkpoint format 5** adds both values to each bucket entry. Formats 1 to 4 still load.
4. **What a rule is:**
   - **Filter:** a prefix, tags, `ObjectSizeGreaterThan` and `ObjectSizeLessThan` (`<Filter>`, its `<And>`, or the
     legacy top-level `<Prefix>`);
   - **Status:** Enabled or Disabled;
   - **Actions:** `Expiration` (Days or Date) and `AbortIncompleteMultipartUpload`.
   - **Checks, as S3 makes them:**
     - every rule has an action;
     - Days are at least 1, and a Date is midnight UTC;
     - IDs are unique, up to 255 characters, and one is made for a rule without one;
     - an upload abort cannot have a tag filter, because uploads have no tags;
     - at most 1,000 rules.
   - **Refused with NotImplemented, rather than accepted and ignored:** `Transition` and `NoncurrentVersion*`. They
     need storage classes or versioning.
   - **`ExpiredObjectDeleteMarker` is accepted and kept,** as S3 accepts it on an unversioned bucket, where it does
     nothing because there are no delete markers. It cannot be combined with Days or Date.
   - **A rule comes back in the form it was given:** a legacy top-level `<Prefix>` stays one, and a `<Filter>` stays
     a Filter, as S3 returns them. s3-tests compares the rules it reads back with the rules it wrote.
5. **Enforcement** (`ObjectStore.applyLifecycle(now)`):
   - an object expires when an enabled rule's filter takes it and the rule's time has come. For Days, that is its
     modification time plus the days, rounded up to the next midnight UTC, as S3 rounds; a Date is its own time;
   - expired objects are deleted with one batch commit per bucket, as DeleteObjects does, at most 1,000 per bucket
     per run;
   - uploads past a matching rule's DaysAfterInitiation are aborted;
   - `maintain` runs it at most every `lifecycleEveryMillis` (an hour by default; S3 runs about daily), so the
     store's lock is held only briefly.
6. **The S3 surface:**
   - Get, Put and DeleteBucketTagging (up to 50 tags; NoSuchTagSet when there are none);
   - Get, Put and DeleteBucketLifecycleConfiguration (NoSuchLifecycleConfiguration when there is none);
   - bodies checked against Content-MD5 and `x-amz-checksum-*`.

## Rejected

- **Storing the lifecycle XML as sent.** GET has to return S3's normalised form, and enforcement needs parsed rules;
  a blob of parsed rules serves both.
- **Running lifecycle every upkeep round (10 s).** Each run scans the index, and nothing in S3's model needs more
  than daily.

## Tests

- **Unit:**
  - the rules blob round-trips and refuses truncations;
  - filter matching: prefix, size, whole tags only;
  - rounding to the next midnight UTC;
  - the XML parses (And, Tag, sizes, the legacy Prefix, a made ID, Date) and is written back;
  - eight documents S3 refuses are refused.
- **Store:**
  - both settings survive the journal and a checkpoint, a delete clears them, and a recreated bucket starts bare;
  - `applyLifecycle` at now plus 0, 3, 5 and 32 days expires by tag, prefix, size and date, aborts an old upload,
    and leaves objects that are too young, too large, or under a disabled rule;
  - the multipart fault sweeps set bucket tags.
- **End to end** (`tools/s3_smoke.sh`): bucket tags set, read and deleted; lifecycle rules set and read back,
  transitions refused, and deleted.
- **s3-tests:** with the `lifecycle` marker included, 13 lifecycle configuration tests pass, and so does bucket
  tagging. Two do not: noncurrent-version rules, and a transition with a bad date. Transitions are NotImplemented
  before their date is read.

## Not yet

- Lifecycle by object age in s3-tests: those tests (`lifecycle_expiration`) depend on RGW's debug clock, which turns
  days into seconds.
- An ordered index, so enforcement need not scan every key (ROADMAP M4).
