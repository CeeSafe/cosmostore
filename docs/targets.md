# M4 performance targets

**Status: proposed (9 Nov 2026), awaiting confirmation.** The architecture's targets (§9) are directions:
- tiny-object throughput that scales with concurrency until the disk or CPU saturates;
- no per-object fsync on the packed path;
- memory bounded independently of the object count;
- predictable p99 under mixed load;
- listing proportional to the page;
- bounded recovery.

These turn them into numbers for this reference machine, from the baseline (`benchmarks/2026-11-09-baseline.md`).
Every target is measured with `tools/bench` (ADR-0021) unless it says otherwise. The M4 exit, and the p99 regression
gates, check against them.

**Reference machine:** Apple M1, internal SSD with `F_FULLFSYNC` (about 5 ms per sync), loopback, plain HTTP. On
other hardware the ratios (scaling, syncs per write) carry over; the absolute numbers do not.

| # | Target | Baseline | Proposed |
|---|---|---|---|
| T1 | Tiny PUT (0 B to 4 KiB) at concurrency 32 | about 200 ops/s | ≥ 3,000 ops/s |
| T2 | Syncs per 1,000 tiny PUTs at concurrency 32 | 1,000 | ≤ 50 (group commit) |
| T3 | Tiny PUT p99 at concurrency 32 | about 190 ms | ≤ 25 ms |
| T4 | Tiny PUT at concurrency 1 | about 200 ops/s, p99 6 ms | no worse: one write still costs one sync, and no timer adds idle latency (ROADMAP issue 7) |
| T5 | Tiny GET (128 B to 4 KiB) at concurrency 32 | about 2,300 ops/s | ≥ 15,000 ops/s, p99 ≤ 5 ms |
| T6 | HEAD at concurrency 32 | about 11,000 to 14,000 ops/s | ≥ 20,000 ops/s |
| T7 | No stall: p99.9 of any small-object phase at concurrency 8 | up to about 1 s | ≤ 50 ms, with checkpoints and compaction running |
| T8 | Large objects (1 MiB, concurrency 32) | PUT about 100 MiB/s, GET about 650 MiB/s | not lower (no regression) |
| T9 | Memory at 1M objects (index and caches, not request buffers) | not yet measured | ≤ 400 bytes per object, and no growth after the load ends |
| T10 | ListObjectsV2 page of 1,000 at 1M keys in one bucket | not yet measured (scans the whole index) | ≤ 20 ms p99, independent of the key count |
| T11 | Recovery at 1M objects (checkpoint plus journal tail) | not yet measured | ≤ 3 s to serving |
| T12 | Write amplification for small objects | 1.04 | ≤ 1.2, compaction included |

## How the numbers were chosen

- **T1 to T3, writes.** With group commit, a batch of N writes costs one sync. At about 5 ms per sync, 32 waiting
  clients can share each sync, which gives a ceiling of several thousand writes per second before the CPU or the
  request path limits it. The proposal leaves room for that.
- **T5 and T6, reads.** These need the read path out from under the store's lock: a record read on a worker thread
  without the lock, or a cache. 15,000 is about what HEAD reaches now, and HEAD reads no bytes.
- **T7, stalls.** The baseline's stalls fit a checkpoint taken under the lock (to verify). The target asks for the
  checkpoint to be written without holding requests up.
- **T9 to T11, scale.** These need a large-key-count run, which the generator does not do yet. T10 is the ordered
  index ROADMAP M4 lists.
- **T12** keeps compaction honest as the write path changes.

## Progress

| After | Met | Not yet |
|---|---|---|
| Slice 2, group commit (ADR-0022, `benchmarks/2026-11-09-group-commit.md`) | T1, T3, T4, T8, T12 | T2 (64 syncs per 1,000: batches hold half of the closed-loop clients); T5 (1 to 4 KiB GET at 11,000 to 12,000/s); T6 (HEAD at 15,800 to 17,300/s); T7, T9 to T11 not measured |
| Slice 3, reads on the event loop (ADR-0023, `benchmarks/2026-11-09-reads.md`) | T5 (15,500 to 16,200/s, p99 3.1 to 3.3 ms), T6 (37,000 to 42,000/s), T8 | T2; T7, T9 to T11 not measured |
| Slice 4, inline reads without the store's lock (ADR-0024, `benchmarks/2026-11-09-unlocked-reads.md`) | T5 with margin (22,900 to 25,200/s, p99 2.2 to 2.6 ms; 22,500 to 26,200/s at concurrency 128), T6, T8 | T2; T7, T9 to T11 not measured |
| Slice 5, deletes through group commit (ADR-0025, `benchmarks/2026-11-09-group-deletes.md`) | no new target; DELETE at 2,300 to 3,200/s at concurrency 32 (from about 200) | T2 (64 syncs per 1,000, for deletes too); T7, T9 to T11 not measured |
| Slice 6, the scale run (ADR-0021 amendment, `benchmarks/2026-11-09-scale-1m.md`) | T11 (0.87 s at 1M objects); T9's bytes (362 per object) | T9's no-growth (listing leaves 30 to 135 MiB); T10 (175 ms p99 per page at 1M keys); T7 (446 ms worst PUT during the fill: checkpoints under the lock); T2 |
| Slice 7, the ordered index (ADR-0026, `benchmarks/2026-11-09-ordered-index.md`) | T10 (0.8 to 1.3 ms p99 per page at 1M keys); T9's no-growth; T11 (1.54 s) | T9's bytes (423 per object, from 362: B-tree nodes half full, G29); T7; T2 |
| Slice 8, bucket numbers in index keys (ADR-0027, `benchmarks/2026-11-09-bucket-numbers.md`) | T9 (376 bytes per object, 396 after recovery), T10, T11 (1.43 to 1.55 s) | T7; T2 |
| Slice 9, checkpoints in steps (ADR-0028, `benchmarks/2026-11-09-stepped-checkpoints.md`) | T9, T10, T11 still; the 1M fill's slowest PUT 72 ms (from 446 to 662) | T7 (28 of 30 phases at concurrency 8; 55 and 109 ms in two); T2 |
