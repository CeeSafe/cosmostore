# Inline reads without the store's lock, 9 Nov 2026 (M4 slice 4)

Inline records read on a worker thread after the store's lock is released, with their segment pinned (ADR-0024),
compared with reads on the event loop (`2026-11-09-reads.md`).

## Environment

| | |
|---|---|
| What | M4 slice 4: `prepareReader` under the lock, `PreparedReader.open` without it; ceesafec 0.24.1, default StoreConfig |
| Host | Apple M1, darwin 27.0.0 (macOS laptop, internal SSD, `F_FULLFSYNC`) |
| Client | `tools/bench` (go1.27.3), loopback, plain HTTP, SigV4 with UNSIGNED-PAYLOAD |
| Run | `tools/bench.sh -sizes 0,128,1024,4096,65536,1048576 -concurrency 1,8,32,128 -ops 1000` |
| Seed | 1; every GET body checked by MD5; no errors; fsck clean afterwards |
| Raw data | `2026-11-09-unlocked-reads.json`; the 64 KiB and 1 MiB rows rerun, `2026-11-09-unlocked-reads-large.json` |
| Load | Not quiet. The run started at a 1-minute load average of 4.9, with the 5-minute one still at 18.5 after this slice's test suite. Its 64 KiB and 1 MiB phases were low across the board, HEAD included (20,800/s at 1 MiB, concurrency 32), so they were rerun alone, at a load of 6 to 13. |

## Findings

1. **Small GETs no longer serialize on the lock.**

   | 128 B to 4 KiB GET | Concurrency 8 | 32 | 128 |
   |---|---|---|---|
   | Reads on the event loop (slice 3) | 16,700 to 18,700/s | 15,500 to 16,200/s, p99 3.1 to 3.3 ms | 8,900 to 9,500/s, p99 18 to 59 ms |
   | Now | 19,100 to 21,900/s | 22,900 to 25,200/s, p99 2.2 to 2.6 ms | 22,500 to 26,200/s, p99 8.9 to 10.9 ms |

   GET now grows from concurrency 8 to 32, and holds at 128, where it fell before.
2. **GET at concurrency 1 is a little lower:** 6,100 to 7,900/s, from 8,100 to 8,700. Part of that is this run's
   noise. Part may be real: each read now opens and closes the segment's file, where the journal kept it open. A
   per-thread handle cache would remove that, if a quiet run shows it matters. HEAD is unchanged.
3. **Large objects: no change beyond noise.** The rerun gave 1 MiB GET at 764 MiB/s (concurrency 32), and the slice 3
   run gave 946. A back-to-back check settled it: the slice 3 build and this one, alternated twice on the same
   machine (load 7 to 10), gave:

   | 1 MiB GET at concurrency 32 | Round 1 | Round 2 |
   |---|---|---|
   | Slice 3 | 621 MiB/s | 538 MiB/s |
   | Slice 4 | 649 MiB/s | 603 MiB/s |

   The extent path differs only in where its reader is made (on the event loop now, with no I/O).
4. **PUT, HEAD and DELETE are unchanged:** PUT at 2,950 to 3,300/s at concurrency 32, and HEAD at 35,000 to
   37,000/s.

## Against the targets (`docs/targets.md`)

| # | Target | Now (concurrency 32) | |
|---|---|---|---|
| T5 | Tiny GET (128 B to 4 KiB) ≥ 15,000 ops/s, p99 ≤ 5 ms | 22,861 to 25,179, p99 2.2 to 2.6 ms | met, with margin |
| T6 | HEAD ≥ 20,000 ops/s | 35,751 to 37,360 | met |
| T8 | 1 MiB not lower than the baseline (PUT 100, GET 650 MiB/s) | PUT 184, GET 764 MiB/s (rerun) | met |

## Full table

From `2026-11-09-unlocked-reads.json`, with the 64 KiB and 1 MiB rows from the rerun. Ops/s, then p99 in ms.

| Size | Concurrency | PUT | GET | HEAD |
|---:|---:|---:|---:|---:|
| 0 | 1 | 198 · 7.3 | 11,756 · 0.21 | 13,528 · 0.17 |
| 0 | 32 | 3,040 · 15.4 | 37,234 · 1.77 | 35,751 · 3.71 |
| 0 | 128 | 5,045 · 38.7 | 38,361 · 5.12 | 33,077 · 6.09 |
| 128 | 32 | 3,285 · 11.6 | 24,084 · 2.38 | 36,216 · 2.81 |
| 128 | 128 | 4,935 · 33.1 | 26,216 · 10.6 | 38,358 · 5.88 |
| 1 KiB | 1 | 201 · 8.0 | 7,407 · 0.26 | 14,403 · 0.17 |
| 1 KiB | 8 | 859 · 12.2 | 19,285 · 0.87 | 36,106 · 0.49 |
| 1 KiB | 32 | 2,946 · 16.7 | 25,179 · 2.17 | 37,095 · 1.92 |
| 1 KiB | 128 | 5,480 · 30.3 | 25,984 · 8.88 | 36,005 · 7.94 |
| 4 KiB | 32 | 3,019 · 22.7 | 22,861 · 2.57 | 37,360 · 2.21 |
| 4 KiB | 128 | 4,738 · 42.7 | 22,457 · 10.9 | 36,645 · 7.43 |
| 64 KiB | 32 | 1,971 · 21.0 | 7,550 · 7.75 | 32,296 · 2.53 |
| 64 KiB | 128 | 3,070 · 62.3 | 9,538 · 24.0 | 37,683 · 6.04 |
| 1 MiB | 32 | 184 · 234 | 764 · 78.4 | 37,247 · 1.71 |
| 1 MiB | 128 | 208 · 972 | 708 · 272 | 40,093 · 4.93 |

The JSON files have every phase (overwrite and DELETE too), p50, p95, p99.9, and RSS.

## Next

1. **Deletes through group commit** (about 200/s at any concurrency).
2. **T2** (64 syncs per 1,000 PUTs).
3. **G28:** a GET still starts one thread for its read. A thread pool in CeeSafe's `Async.blocking` would lower the
   cost of every request that touches the disk.
