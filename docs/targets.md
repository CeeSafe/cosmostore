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
