# Checkpoints in steps, 9 Nov 2026 (M4 slice 9)

Checkpoints written in steps, with the store's lock released between them (ADR-0028), compared with the checkpoint
under the lock (`2026-11-09-bucket-numbers.md`).

## Environment

| | |
|---|---|
| What | M4 slice 9; ceesafec 0.24.2, default StoreConfig (a checkpoint every 64 MiB of journal) |
| Host | Apple M1, darwin 27.0.0 (macOS laptop, internal SSD, `F_FULLFSYNC`) |
| Runs | `tools/scale.sh` at 1M objects of 128 B (128 clients); `tools/bench.sh -sizes 0,128,1024,4096,16384,65536 -concurrency 8 -ops 2000` |
| Checks | Every listing page and every GET checked; fsck clean after both runs; no errors in the server's log |
| Raw data | `2026-11-09-stepped-checkpoints-1m.json`, `2026-11-09-stepped-checkpoints-c8.json` |
| Load | 1-minute load average 4 to 6 at both starts; the 5-minute average was still 10 to 17 from earlier work |

## Findings

1. **The fill's stalls are gone.**

   | 1M PUTs of 128 B, 128 clients | Checkpoint under the lock (slices 6 to 8) | In steps |
   |---|---|---|
   | Throughput | 4,865 to 5,128/s | 5,856/s |
   | p99 | 60 to 65 ms | 36 ms |
   | Slowest PUT | 446 to 662 ms | 72 ms |

   Checkpoints ran during the fill: the newest one left on disk is at LSN 952,414. Each one's encoding now holds the
   lock for 4,096 entries at a time.
2. **Memory, listing and recovery are unchanged:** 365 MiB idle at 1M objects (378 B per object), 383 MiB after
   recovery; listing 0.7 to 0.9 ms p99; recovery 1.48 s.
3. **T7 at concurrency 8:** 28 of 30 small-object phases have a p99.9 of at most 50 ms. Each phase has 2,000
   operations, so p99.9 is about the third-slowest request.

   | Over 50 ms | p99 | p99.9 |
   |---|---:|---:|
   | 128 B overwrite | 40.9 ms | 54.9 ms |
   | 16 KiB delete | 14.4 ms | 108.9 ms |

   - **The 128 B phases were disturbed throughout:** their GET and HEAD p99s are 2 and 7 ms, against 0.4 to 1.1 ms
     for every other size. That points to the machine, not the store.
   - **The 16 KiB delete** has one spike of about 109 ms in an otherwise quiet phase. Compaction, extent reaping and
     lifecycle still run under the lock (ADR-0028, Consequences). This run cannot tell a compaction from a machine
     hiccup.

## Against the targets (`docs/targets.md`)

| # | Target | Now | |
|---|---|---|---|
| T7 | p99.9 ≤ 50 ms at concurrency 8, with checkpoints and compaction running | 28 of 30 phases; 55 ms and 109 ms in two | not yet |
| T9 | ≤ 400 bytes per object | 378 B idle, 396 B recovered | met |
| T10 | Page of 1,000 ≤ 20 ms p99 | 0.7 to 0.9 ms | met |
| T11 | ≤ 3 s to serving | 1.48 s | met |

## Next

1. **T7:** time what the store's upkeep does (checkpoint steps, compaction, reaping), in the stats or the log, so a
   spike can be matched to its cause. Then move compaction's plan, which scans the whole index, out from under the
   lock, as the checkpoint was.
2. **A quiet run** of the whole matrix.
