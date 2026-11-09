# ADR-0024: Inline reads without the store's lock

**Status:** accepted for M4 slice 4 (`src/store/object_store.cee`, `src/store/pins.cee`,
`src/storage/journal/journal.cee`, `src/s3/objects.cee`), 9 Nov 2026

## Context

- **After ADR-0023, a GET with a body still read under the store's lock.** An inline object's record was read from
  its journal segment on a worker thread while the lock was held, so reads serialized on the lock and on a thread
  start each (CEESAFE_GAPS G28). At concurrency 128, 128 B to 4 KiB GETs ran at about 9,000/s, with a p99 of 18 to
  59 ms.
- **The lock protected the segment, not the record.** A published record never changes. But compaction removes a
  segment as soon as nothing live is in it (ADR-0005), and a read that is not under the lock could race that.
- **Extent reads already solved this** (ADR-0007): a reader pins its version's extents, and reaping leaves a pinned
  file on disk.

## Decision

1. **Opening a reader has two halves** (`ObjectStore.prepareReader`, `PreparedReader.open`).
   - **`prepareReader`** does no I/O, and the S3 layer calls it on the event loop under the lock (N0295 proves the
     no-I/O part).
     - It looks the version up and clamps the range.
     - An extent-backed version gets its `ExtentReader`, which opens files lazily, and its extent pin.
     - An inline version gets its record's locator, the segment file's path, and a **segment pin**.
   - **`open`** runs on a worker thread after the lock is released.
     - It reads the inline record through a handle of its own (`readRecordFile`) and verifies it whole, as
       `Journal.readRecord` does: header, body CRC, trailer and length.
     - The pin goes when the record has been read. The bytes are then in memory, as before.
   - `openReader`, for in-process callers, is the two halves in a row.
2. **Segment pins are extent pins keyed by segment id** (`ExtentPins.pinOne`, the store's `segmentPins`): an atomic
   count, whose drop only counts down, with no lock and no I/O.
3. **Compaction skips a pinned segment.** It removes a segment only when nothing live is in it and no reader pins
   it. A pinned one keeps its file, with nothing live and still in the segment table, and a later pass (the next
   `maintain`) removes it.
   - **Nothing new to recover.** A crash between the relocation commit and the unlink already leaves this state. After
     a restart, recovery lists the segment with nothing live, and compaction removes it.
   - The relocation copies are durable before any removal is considered, so the skip changes only when a file goes,
     never what is live.
4. **Reading the active segment** through a second handle is safe. A published record is synced and below the
   durable end, and the journal only appends past it.

## Rejected

- **Sharing the journal's open segment handles.** The handles live in the journal, under the lock. A separate open
  per read costs one `open` and one `close` on a worker thread, which runs in parallel.
- **A deferred list of segments to remove,** like the extents' (ADR-0007). Leaving the segment in the table is
  enough: compaction finds it again, and it needs no new state.
- **Copying inline payloads into the index,** so a GET needs no read at all. That costs memory per object (T9). A
  cache with a budget is the M4 path for that.

## Consequences

- A GET holds the store's lock only for index work. The disk read runs in parallel with other requests, including
  commits.
- A slow reader can keep a dead segment on disk until it has read its record: one record read, not a stream.
- **Results** are in `docs/benchmarks/2026-11-09-unlocked-reads.md`.

## Tests

- `src/store/pin_tests.cee`:
  - a reader prepared before compaction reads the right bytes after it, and its segment stays until then, with the
    file count matching the segment table;
  - the next pass removes that segment;
  - a pinned segment left on disk when the store stops is removed by a later pass after reopening;
  - every I/O step of `open`, failed in turn, fails the read, and leaves no pin behind.
- `inlineCorruptionIsDetected` (ADR-0005) also checks that a reader opened without the store refuses a rotted
  record (`DataCorrupt`).
- `ceesafec test` (112), `tools/s3_smoke.sh`, `tools/tls_smoke.sh`, the s3-tests subset, and the SDK checks.
- `tools/bench`, with every GET verified by MD5 and fsck clean afterwards.
