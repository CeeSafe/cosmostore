# ADR-0034: Large GETs with fewer worker threads and reused buffers

**Status:** accepted for M4 (`src/s3/objects.cee`, `src/s3/server.cee`, `src/store/object_store.cee`), 10 Nov 2026

## Context

- **The comparison run** (`docs/benchmarks/2026-11-10-comparison.md`) found 1 MiB GETs at 460/s at concurrency 32,
  against 920 for SeaweedFS and 760 for RustFS on the same 2 CPUs.
- **A profile** (`sample`, 5 s of 1 MiB GETs at concurrency 8 on the M1) put the server's busy time in:

  | Share | Where |
  |---:|---|
  | 28% | `Crc32c.update`: the extent's checksum, verified as it is read (ADR-0003) |
  | 26% | `thread_start`: three `Async.blocking` calls per GET (open the reader, read, and a last read that finds the end), each a thread (G28) |
  | 18% | `sendmsg`: the socket |
  | 12% | zeroing a new 1 MiB buffer for each GET (`Vector.resize`) |
  | 8% | `pread` and `open` |

## Decision

1. **Read until the planned length is sent.** The GET loop no longer makes a last read to find the end: one worker
   thread less per GET. A reader that ends early still ends the loop; the response's length tells the client.
2. **An extent reader needs no opening** (`PreparedReader.takeReady`): it is taken on the event loop, without a
   worker thread. Only an inline record is read from its segment on one. N0295 checks that `takeReady` does no I/O.
3. **Full-size body buffers are reused** from a small pool (`takeBodyBuffer`, `giveBodyBuffer`): a `Channel` of 4.
   PUT and GET take a 1 MiB buffer from it when it has one, and give it back; it is not zeroed again. A reused
   buffer holds an earlier body's bytes, and every use sends or stores only what its last read filled
   (`buf[0..n]`).

## Rejected

- **A pool of 32 buffers.** On the Debian server (8 MiB L3) it raised 1 MiB GETs' p99 at concurrency 32 by about
  half (1.51 to 1.58 times, over 5 rounds, in each variant that had it), for no throughput. The channel hands its
  buffers out in turn, so 32 MiB cycled through the cache, where glibc's `malloc` gives back the block just freed.
  With 4, the p99 is unchanged.
- **Skipping the CRC check on reads.** It is the largest cost, but it is what finds a damaged extent (ADR-0003).
  SeaweedFS checks its CRC on reads too. The fix is a faster CRC32C, which is CeeSafe's (G31).
- **A smaller body buffer,** to make zeroing cheaper: more reads, and so more worker threads (G28).

## Consequences

Against `9c8bc1b`, `tools/perf_gate.sh` on the Debian server, 5 rounds, 1 MiB
(`docs/benchmarks/2026-11-10-large-gets.md`):

| 1 MiB | Throughput | p99 |
|---|---:|---:|
| GET, concurrency 1 | 1.20 times | 0.89 |
| GET, concurrency 32 | 1.02 | 0.99 |
| PUT, concurrency 1 | 1.06 | 0.96 |
| PUT, concurrency 32 | 1.00 | 0.97 |

- **On the M1,** where large blocks are returned to the system and come back zeroed, 1 MiB GETs at concurrency 8
  went from 394 to 508/s to 701 to 761/s with the first two changes (a pool of 32 then), under load (average 26).
  Not measured again with the pool of 4.
- **The comparison's gap is not closed.** On Linux the zeroing and the threads cost less; the CRC32C is what bounds
  large GETs, and with lib/std's software CRC (1.5 GB/s against 7 GB/s for the CPU's instruction, G31) it stays.
- A GET of an object in extents now uses one worker thread, for its single read (up to 1 MiB).

## Tests

- **`extentReadersAreReadyWithoutOpening`** (`src/store/large_object_tests.cee`): an extent reader is ready at once,
  only once, and reads the object back; an inline record is not ready, and `open` reads it.
- **The read loop and the pool** are the S3 layer's: `tools/s3_smoke.sh` (ranges, multipart, 3 MB objects),
  `tools/tls_smoke.sh`, the s3-tests subset (252), the boto3, Go, JavaScript and rclone checks. `ceesafec test` (135).
