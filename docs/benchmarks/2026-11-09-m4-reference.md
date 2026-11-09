# M4 reference, 9 Nov 2026

The whole matrix and the 1M-object scale run at commit `7e99bb0` (M4 slice 10), on a quiet machine. It is compared
with the baseline (`2026-11-09-baseline.md`) and checked against every target (`docs/targets.md`). This is the
reference for M4's p99 regression gates.

## Environment

| | |
|---|---|
| What | `7e99bb0`: group commit, reads on the event loop and without the store's lock, the ordered index, checkpoints and compaction in steps (ADR-0022 to ADR-0029); ceesafec 0.24.2, default StoreConfig |
| Host | Apple M1, darwin 27.0.0 (macOS laptop, internal SSD, `F_FULLFSYNC`) |
| Client | `tools/bench` (go1.27.3), loopback, plain HTTP, SigV4 with UNSIGNED-PAYLOAD |
| Runs | `tools/bench.sh -sizes 0,128,1024,4096,16384,65536,262144,1048576 -concurrency 1,8,32,128 -ops 1000`, then `tools/scale.sh` (1M objects of 128 B, 128 clients) |
| Checks | Every GET verified by MD5, every listing page checked; no errors; fsck clean after both runs |
| Load | **Quiet:** 19 samples, one every 30 s. The 1-minute load average was 1.8 to 4.4 (median 3.6), and the 5-minute one 2.7 to 3.6. No other session's builds or tests ran. |
| Raw data | `2026-11-09-m4-reference.json` (matrix), `2026-11-09-m4-reference-1m.json` (scale) |

## Against the targets

| # | Target | Baseline | M4 reference | |
|---|---|---|---|---|
| T1 | Tiny PUT (0 B to 4 KiB) at concurrency 32 ≥ 3,000 ops/s | 179 to 202 | 3,161 to 3,267; 4 KiB at 2,908 | 3 of 4 sizes; 4 KiB 3% short (3,300 in earlier runs) |
| T2 | ≤ 70 syncs per 1,000 tiny PUTs at concurrency 32 (restated) | 1,000 | 64 | met |
| T3 | Tiny PUT p99 at concurrency 32 ≤ 25 ms | 189 to 550 ms | 11.4 to 16.2 ms | met |
| T4 | Tiny PUT at concurrency 1 no worse | 70 to 196/s, p99 6 to 72 ms | 175 to 201/s, p99 6.3 to 12.1 ms | met |
| T5 | Tiny GET (128 B to 4 KiB) at concurrency 32 ≥ 15,000 ops/s, p99 ≤ 5 ms | 294 to 2,289/s, p99 16 to 647 ms | 20,595 to 26,980/s, p99 2.1 to 4.8 ms | met |
| T6 | HEAD at concurrency 32 ≥ 20,000 ops/s | 1,049 to 14,566 | 34,170 to 41,828 | met |
| T7 | p99.9 ≤ 50 ms at concurrency 8, with checkpoints and compaction running | up to 271 ms | 29 of 30 phases (0.5 to 49.7 ms); 4 KiB PUT at 53.1 ms | 29 of 30; the 30th had no upkeep hold |
| T8 | 1 MiB at concurrency 32 not lower | PUT 102, GET 675 MiB/s | PUT 183, GET 856 MiB/s | met |
| T9 | ≤ 400 bytes per object at 1M, no growth after the load | not measured | 377 B idle, 398 B recovered; no growth after listing | met |
| T10 | ListObjectsV2 page of 1,000 at 1M keys ≤ 20 ms p99 | not measured (164 ms at slice 6) | 0.77 to 1.23 ms | met |
| T11 | Recovery at 1M objects ≤ 3 s | not measured | 1.48 s | met |
| T12 | Write amplification for small objects ≤ 1.2, compaction included | 1.04 | 1.09 for the run (1.04 to 1.17 per size) | met |

## Notes on the targets

- **T1, 4 KiB at 2,908/s.** The phase's p99 was 16.2 ms and its syncs per 1,000 were 64, the same as the other
  sizes. The same phase ran at 3,304 to 3,312/s in the group-commit and reads runs. This is run-to-run variance of
  the device's flush rate; it is not a regression that one change explains. It stays recorded as short.
- **T7, 4 KiB PUT at 53.1 ms.** Its p99 was 11.3 ms, and only its two slowest requests passed 50 ms. No upkeep hold
  of 10 ms or more happened during the phase (the "slow upkeep" column). The run's four checkpoints held the store for
  at most a millisecond each, and its two compactions with copies (998 and 625) made no hold of 10 ms or more during
  this phase. The previous run's one phase over was also a PUT phase at 53 ms with no upkeep hold, so these are most
  likely the device's occasional slow flush.
- **T12, write amplification.** The 1 to 64 KiB PUT and overwrite phases wrote about 696 MB of objects. Their journal
  and extents wrote 1.04 to 1.17 per byte, by size, and compaction copied 57 MB during the run (the server's log). That
  is about 758 MB written, 1.09 times the objects. Per phase, a compaction's copies land in whichever phase is running:
  16 KiB overwrite at concurrency 1 shows 2.03, and 64 KiB PUT at concurrency 8 shows 1.63.

## Throughput, baseline to M4

At concurrency 32, 0 B to 4 KiB unless noted.

| | Baseline | M4 |
|---|---:|---:|
| PUT | 179 to 202/s | 2,908 to 3,267/s |
| PUT at concurrency 128 | 96 to 196/s, p99 0.7 to 2.2 s | 4,777 to 5,642/s, p99 29 to 46 ms |
| GET (128 B to 4 KiB) | 294 to 2,289/s | 20,595 to 26,980/s |
| GET at concurrency 128 | 648 to 2,034/s | 21,750 to 28,223/s |
| HEAD (all sizes) | 1,049 to 14,566/s | 34,170 to 41,828/s |
| DELETE | 151 to 217/s | 2,973 to 3,275/s |
| 1 MiB PUT, GET | 102, 675 MiB/s | 183, 856 MiB/s |

## The scale run (1M objects of 128 B)

| | |
|---|---|
| Fill | 5,030 PUTs/s at 128 clients, p50 23 ms, p99 59 ms, slowest 215 ms |
| Memory (footprint) | 364 MiB after the fill and after 30 s idle (377 B per object), 364 MiB after listing, 384 MiB after recovery (398 B) |
| Listing (p99) | 0.77 to 1.23 ms a page, at the first, middle and last keys, before and after recovery |
| Recovery | 1.48 s from launch to serving after a SIGKILL |
| Checkpoints | four during the fill, at 241,237 to 966,424 entries, in 59 to 236 steps; the longest step held the store 11 ms |

The fill's slowest PUT (215 ms) did not come from upkeep. No hold of 10 ms or more was logged beside the
checkpoints' 3 to 11 ms steps. Its p99 at 128 clients is not a target.

## Open after M4

- **T1 at 4 KiB** sits at the edge of the device's flush rate; a margin needs larger batches or fewer syncs per batch.
- **Copy steps** hold the store for one 1 MiB write and sync, 10 to 15 ms each (ADR-0029).
- **CEESAFE_GAPS:**
  - G28: `Async.blocking` starts a thread per call;
  - G29: `OrderedMap` is half empty after in-order inserts.

  Either fix in CeeSafe would give headroom on T5, T6 and T9.
- **Not done from ROADMAP M4:**
  - journal shards and per-core appenders;
  - the comparison against SeaweedFS, Garage and RustFS;
  - the p99 regression gates in CI, which this run is the reference for.
