# Upkeep timing and compaction in steps, 9 Nov 2026 (M4 slice 10)

T7 at concurrency 8, first with upkeep's holds of the store timed (ADR-0029), then with compaction in steps too.

## Environment

| | |
|---|---|
| What | M4 slice 10; ceesafec 0.24.2, default StoreConfig (upkeep every 10 s, a checkpoint every 64 MiB of journal) |
| Host | Apple M1, darwin 27.0.0 (macOS laptop, internal SSD, `F_FULLFSYNC`) |
| Run | `tools/bench.sh -sizes 0,128,1024,4096,16384,65536 -concurrency 8 -ops 2000`; the "slow upkeep" column counts upkeep holds of 10 ms or more during each phase |
| Checks | Every GET checked; fsck clean afterwards; the server's log kept |
| Raw data | `2026-11-09-upkeep-timing-c8.json` (timing only), `2026-11-09-upkeep-in-steps-c8.json` (compaction in steps) |
| Load | 1-minute load average about 5 at each start; the 5-minute one 12 to 16 from earlier work |

## Findings

1. **Timing found the cause of the stalls left after ADR-0028.** With compaction still in one hold:
   - 29 of 30 phases had a p99.9 of 27 ms or less;
   - the one over, 64 KiB PUT at 126 ms, was the only phase with a slow hold;
   - the server's log named it: "upkeep held the store 111 ms (reaping 0, compaction 111: 1 segments removed, 576
     copied; lifecycle 0)";
   - the checkpoint in the same run held the store for under a millisecond.
2. **Compaction in steps:** 29 of 30 phases have a p99.9 within 50 ms.

   | | Compaction in one hold | In steps |
   |---|---|---|
   | Phases over 50 ms | 1 (126 ms, with a slow hold) | 1 (53 ms, with no slow hold) |
   | Worst p99.9 with compaction running | 126 ms | 36 ms (64 KiB DELETE, 52 slow holds) |
   | Compactions in the run | 1: 576 copies | 2: 863 and 816 copies, up to 53 MB |

   - **The one phase over,** 64 KiB PUT at 53.1 ms (p99 29 ms), had no upkeep hold of 10 ms or more during it.
     That points to the machine.
   - **Compaction's copy steps** each write and sync about 1 MiB under the lock, and many take 10 to 15 ms. Phases
     that ran beside them had up to 52 such holds, and their p99.9 stayed at 29 to 36 ms.
   - **Checkpoints** (873 and 960 entries here) took one step each and held the store for under a millisecond.

## Against the targets (`docs/targets.md`)

| # | Target | Now | |
|---|---|---|---|
| T7 | p99.9 ≤ 50 ms at concurrency 8, with checkpoints and compaction running | 29 of 30 phases; the 30th at 53 ms with no upkeep hold during it | met for the store's part; a quiet run to confirm |

## Next

1. **A quiet run** of the matrix, for T7 without the machine, and as the M4 reference.
2. **Copy steps:** a smaller batch (256 KiB) would shorten each hold, at the cost of more syncs, if a later run
   shows they matter.
