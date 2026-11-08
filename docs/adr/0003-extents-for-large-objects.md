# ADR-0003: Extents for large objects

**Status:** accepted (implemented in `src/storage/extent/` and `src/store/`), 6 Nov 2026

## Decision

1. **One write path.** Every PUT streams through an `ObjectWriter`, which keeps up to `inlineMaxBytes`
   (default 128 KiB) in memory.
   - If the stream ends within that limit, the object is **inline**: its bytes are the payload of a
     `PutInline` record (ADR-0001).
   - Otherwise it spills into **extent files** of at most `extentMaxBytes` (default 64 MiB). Each extent is
     synced when sealed, and the extent directory is synced once at `finish`. The object is then published
     by a `PutExtent` record whose payload is the **manifest**.
   - PUTs are limited to `maxObjectBytes` (5 GiB, as in S3).
2. **Extent file** `extents/ext-<16 hex>.ce`: a 64-byte header, then raw bytes.
   - Header: magic `CSEXT001`, id, created ms, and a CRC32C at byte 60.
   - Ids are random 64-bit values, created with `O_EXCL` and retried on a collision, so concurrent writers
     need no coordination.
3. **Manifest v1:** u32 count, then per extent u64 id, u64 length and u32 CRC32C of its bytes. The object's
   MD5 (ETag) and size are in the record's meta, exactly as for inline objects.
4. **Ordering.** Extents and their directory entries are durable before the `PutExtent` record is staged, and
   the record is acknowledged only after its batch syncs (ADR-0001).
5. **Garbage, reclaimed without a separate log.**
   - **Superseded or deleted versions:** applying the record that retires a version queues its extents in
     `deadExtents`. The files are unlinked after that record's batch is durable (`reapExtents`).
   - **Refused writes** (precondition failure, missing bucket): their extents are unlinked at once.
   - **Writers dropped before `finish`** (client disconnect): the writer removes its extents in its `drop`
     block.
   - **Journal commit failures:** extents are *not* removed, because the record may be on disk.
   - **At open, the orphan sweep** removes every extent no live version references. That covers crashes
     between finish and commit, crashes before reaping, and failed commits.
6. **Reads** stream through `ObjectReader` / `ExtentReader` over any byte range. An extent read whole, from
   its first byte to its last, is checked against its CRC32C, and a mismatch is `DataCorrupt` (never served
   as data). Partial-range reads are not verified, because the CRC covers whole extents. Per-block CRCs
   (for example every 1 MiB) are future work for verified range reads and scrub.

## Consequences

- **Tests** (`large_object_tests.cee`) cover:
  - the inline/extent boundaries and extent counts;
  - every range across extent boundaries;
  - reaping on overwrite, delete and refused writes;
  - the orphan sweep and abandoned writers;
  - corruption detection;
  - a crash at every journal byte with every extent present. Recovery always gives one whole version and
    leaves only its extents.
- **Measured** (macOS laptop, `F_FULLFSYNC`, streaming 1 MiB chunks, MD5 and CRC in software):

  | Object size | PUT | GET + verify |
  |---|---|---|
  | 1 MiB | 70/s (70 MiB/s) | 420 MiB/s |
  | 8 MiB | 149 MiB/s | 539 MiB/s |
  | 128 MiB | 161 MiB/s | 548 MiB/s |

  "GET + verify" includes regenerating the expected bytes.
- **Medium objects are sync-bound.** Each extent-backed PUT costs one data sync per extent plus one
  directory sync, about 14 ms on this disk. Options for M4:
  - pre-create and directory-sync a pool of extent files, which removes the directory sync from the request
    path;
  - pack medium objects from several PUTs into shared extents that are synced once per batch;
  - raise `inlineMaxBytes` where the journal's sequential write wins.
- **Large-object throughput is not yet profiled.** Software MD5 and CRC32C on the request thread are the
  likely limit (hypothesis). Hardware CRC (CEESAFE_GAPS.md G9), and overlapping hashing with I/O, are the
  levers.
- **Concurrency (M3+).** An extent is unlinked as soon as the superseding record is durable. A reader that
  has an extent open keeps reading it (POSIX), but one that has not opened its next extent yet would fail.
  Before concurrent readers exist, reaping must wait for in-flight readers (a reference count or grace
  period, M2). Done: readers pin their extents (ADR-0007).
- **Multipart upload** will store each part as one or more extents. `CompleteMultipartUpload` then writes a
  single `PutExtent` record with the concatenated manifest, and its ETag is the MD5 of the part MD5s plus
  `-N`, which the manifest needs an S3 ETag field for. Done (ADR-0009): the version keeps its part count, and its
  MD5 field holds the ETag's digest.
