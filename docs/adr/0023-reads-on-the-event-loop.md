# ADR-0023: Reads on the event loop

**Status:** accepted for M4 slice 3 (`src/s3/objects.cee`, `src/s3/server.cee`), 9 Nov 2026

## Context

- **After group commit (ADR-0022), the request path capped reads,** not the disk:
  - 1 to 4 KiB GET ran at 11,000 to 12,000/s at concurrency 32 (T5 asks for 15,000);
  - HEAD ran at 15,800 to 17,300/s (T6 asks for 20,000).
- **Every store call ran on a worker thread** (ADR-0008 §2), even one that only looks up the index. In CeeSafe 0.24,
  `Async.blocking` starts and joins a thread per call (CEESAFE_GAPS G28).
  - A HEAD held the store's lock across one such call.
  - An inline GET made three: the plan (index lookup and record read), then two reads of a reader whose bytes were
    already in memory.
- **The compiler can prove a call does no I/O.** An async fn must not block (N0295), and the check follows every call
  down to the file or socket operation. So a store call that compiles on the event loop is known to do no I/O, and a
  later change that adds I/O to it fails to build.

## Decision

1. **Store calls that only touch memory run on the event loop,** under the store's lock, which is never held across an
   await on these paths:
   - `headObject` (HeadObject, the metadata half of GetObject, GetObjectAttributes and GetObjectTagging);
   - `bucketExists` (HeadBucket, GetBucketLocation and the other bucket checks);
   - `listBucketInfo` (ListBuckets).
2. **GetObject plans on the event loop.** The conditions, range and part are worked out from the index lookup. Only a
   body's reader takes a worker thread: an inline record's read from its journal segment, or an extent reader's open.
   A HEAD, a 304, a 412 and an empty body take none.
3. **An inline body is sent in one write** (`ObjectReader.takeInline`): its bytes were read and verified when the
   reader opened, so streaming them through worker threads only copied memory.
4. **Listing stays on a worker thread.** It does no I/O, but it scans the index (T10), which could hold the event loop
   for milliseconds at a large key count.
   - **Amended by ADR-0026 (M4 slice 7):** listing reads only its page of the ordered index now, so it runs on the
     event loop too.

## Rejected

- **Reading inline records without the store's lock.** The read would race compaction, which removes a segment as
  soon as it holds nothing live (ADR-0005). Doing it needs segment pins, like the extent pins of ADR-0007. Not needed
  for T5 at this point; it can come with the read cache.
- **A cache of inline payloads.** ROADMAP M4 lists one. The benchmark reads each key once, so it would not show here,
  and it changes nothing about the cost of a request. Later, with a workload that repeats reads.

## Consequences

- A HEAD is now an index lookup with no thread. A small GET makes one worker-thread call instead of three.
- **Results** are in `docs/benchmarks/2026-11-09-reads.md`.

## Tests

- The compiler's N0295 check is the guard: each call moved to the event loop compiles only if it does no I/O. A probe
  that called a committing store function from the same place failed to build, naming the `syncData` it reaches.
- `ceesafec test`, `tools/s3_smoke.sh` (ranges, conditional GETs, empty objects), `tools/tls_smoke.sh`, the s3-tests
  subset and the SDK checks.
- `tools/bench`, with every GET verified by MD5 and fsck clean afterwards.
