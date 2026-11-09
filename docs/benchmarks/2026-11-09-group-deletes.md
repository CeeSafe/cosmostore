# Deletes through group commit, 9 Nov 2026 (M4 slice 5)

DeleteObject staged and acknowledged once published, sharing syncs with PUTs (ADR-0025), compared with inline reads
without the store's lock (`2026-11-09-unlocked-reads.md`).

## Environment

| | |
|---|---|
| What | M4 slice 5: `deleteObjectDeferred` and `awaitPublished` for DELETE; ceesafec 0.24.1, default StoreConfig |
| Host | Apple M1, darwin 27.0.0 (macOS laptop, internal SSD, `F_FULLFSYNC`) |
| Client | `tools/bench` (go1.27.3), loopback, plain HTTP, SigV4 with UNSIGNED-PAYLOAD |
| Run | `tools/bench.sh -sizes 0,1024,4096,65536 -concurrency 1,8,32,128 -ops 1000` |
| Seed | 1; every GET body checked by MD5; no errors; fsck clean afterwards |
| Raw data | `2026-11-09-group-deletes.json` |
| Load | **Not quiet.** The run started at a 1-minute load average of 4.9, but the 5-minute one stayed between 12 and 22: other sessions ran a Parallels VM (about 170% CPU), a clang build and `sqlcmd`. PUT, GET and HEAD came in 10 to 40% under the previous runs, which this slice does not change, so only the DELETE rows are compared here. |

## Findings

1. **DELETE scales with concurrency, as PUT does.**

   | DELETE, 0 B to 64 KiB objects | Concurrency 1 | 8 | 32 | 128 |
   |---|---|---|---|---|
   | Before (one commit each, under the lock) | about 200/s | about 210/s | 190 to 225/s, p99 165 to 356 ms | 205 to 225/s, p99 600 to 650 ms |
   | Now | 186 to 204/s | 509 to 796/s | 2,278 to 3,219/s, p99 11 to 28 ms | 5,134 to 8,815/s, p99 16 to 36 ms |
   | Syncs per 1,000 | 1,000 | 250 | 64 | 16 |

   Deletes batch like PUTs (ADR-0022, finding 2): half the clients per batch, so about 64 syncs per 1,000 at 32
   clients. At 128 they run faster than PUTs, since a delete carries no body to receive.
2. **Concurrency 1 is unchanged:** one delete, one sync, p99 8 to 12 ms.
3. **The 0 B delete at concurrency 8** (509/s, p99 92 ms) was below the other sizes (774 to 796/s) in the same run.
   It is the run's first DELETE phase, at its loudest point.

## Against the targets (`docs/targets.md`)

No target names DELETE. T7 (no stall) gains from this: a delete no longer holds the store's lock across a sync, so
the requests behind it do not wait the 5 ms.

## DELETE rows

From `2026-11-09-group-deletes.json`. Ops/s, then p99 in ms.

| Size | Concurrency 1 | 8 | 32 | 128 |
|---:|---:|---:|---:|---:|
| 0 | 200 · 8.9 | 509 · 92.1 | 2,932 · 19.9 | 6,507 · 28.7 |
| 1 KiB | 204 · 8.0 | 782 · 20.7 | 3,064 · 13.4 | 8,815 · 16.3 |
| 4 KiB | 186 · 12.3 | 796 · 13.3 | 2,278 · 27.9 | 5,134 · 35.7 |
| 64 KiB | 188 · 10.1 | 774 · 15.9 | 3,219 · 11.4 | 8,551 · 16.7 |

The JSON has every phase, p50, p95, p99.9, and RSS. Its PUT, GET and HEAD rows were taken under the load above and
are not a reference.

## Next

1. **T2** (64 syncs per 1,000 at concurrency 32), still open: now for deletes too.
2. **A quiet reference run** of the whole matrix, to replace this one's PUT, GET and HEAD rows.
3. **T7, T9 to T11:** stall, memory, listing and recovery at scale, which the generator does not measure yet.
