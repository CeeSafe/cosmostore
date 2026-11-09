# Group commit, 9 Nov 2026 (M4 slice 2)

Group commit across requests (ADR-0022), compared with the baseline (`2026-11-09-baseline.md`).

## Environment

| | |
|---|---|
| What | M4 slice 2: leader/follower group commit, body buffers sized to the body; ceesafec 0.24.1, default StoreConfig |
| Host | Apple M1, darwin 27.0.0 (macOS laptop, internal SSD, `F_FULLFSYNC`) |
| Client | `tools/bench` (go1.27.3), loopback, plain HTTP, SigV4 with UNSIGNED-PAYLOAD |
| Run | `tools/bench.sh -sizes 0,128,1024,4096,16384,65536,262144,1048576 -concurrency 1,8,32,128 -ops 1000` |
| Seed | 1; every GET body checked by MD5; fsck clean afterwards |
| Raw data | `2026-11-09-group-commit.json`; the 1 KiB rows from a rerun, `2026-11-09-group-commit-1k.json` |
| Load | The machine was shared: another session ran CeeSafe's test suites. Two earlier full runs at a load average of about 28 were discarded. This run's load average was 4 to 9. Its 1 KiB rows caught a burst (HEAD at 1,170/s at concurrency 1, where every other size gives 9,000 to 11,000), so they were rerun alone. |

## Findings

1. **Small writes scale with concurrency.**

   | 0 B to 4 KiB PUT | Concurrency 1 | 8 | 32 | 128 |
   |---|---|---|---|---|
   | Baseline | about 200/s | about 200/s | about 200/s | about 200/s |
   | Now | 165 to 195/s | about 830/s | 3,300 to 3,400/s | 4,800 to 5,600/s |

   - p99 at concurrency 32 fell from 190 to 550 ms to about 11 ms. At 128, it fell from 700 to 2,200 ms to 31 to
     37 ms.
   - Concurrency 1 is unchanged: one sync per write, and a p99 of 7 to 9 ms, with no timer.
2. **Batches hold about half the clients.** There are 250 syncs per 1,000 PUTs at concurrency 8, 64 at 32, and 17
   at 128.
   - The clients are closed-loop: those answered by one batch send their next PUT just after the next batch was
     written, so they wait for the one after.
   - The device allows about 210 flushes/s, from any number of threads (ADR-0022). Throughput is therefore about
     half the clients times 210, and larger batches would need a wait before writing. Rejected for now: a 1 ms wait
     did not help.
3. **Small reads were never held up by the lock but by a buffer.**

   | At concurrency 32 | Baseline | Now |
   |---|---|---|
   | GET, 1 KiB | about 2,300/s | 12,000/s |
   | GET, 4 KiB | about 300/s | 11,100/s |
   | HEAD | 11,000 to 14,000/s | 15,800 to 17,300/s |

   Each request used to allocate and zero a fresh 1 MiB body buffer on the event loop's thread. The baseline's
   finding 2 is corrected.
4. **Larger objects:**
   - **1 MiB at concurrency 32:** PUT went from about 100 to 172 MiB/s, and GET from 675 to 810 MiB/s.
   - **256 KiB to 1 MiB PUT** is still bound by syncs. Each object's extents are synced before its record, as
     ADR-0001 requires, so each object costs its own flush. Extents for many objects are not yet packed into one
     write.
5. **DELETE is unchanged, at about 210/s:** each delete is still its own commit (ADR-0022, "Rejected").
6. **Write amplification** is 1.00 to 1.04 above 1 KiB, as before. RSS peaked at 360 MiB, in the 1 MiB phases at
   concurrency 128, where each request holds a 1 MiB body buffer.

## Against the targets (`docs/targets.md`)

| # | Target | Now (concurrency 32, 0 B to 4 KiB) | |
|---|---|---|---|
| T1 | Tiny PUT ≥ 3,000 ops/s | 3,312 to 3,387 | met |
| T2 | ≤ 50 syncs per 1,000 tiny PUTs | 64 | not met (finding 2) |
| T3 | Tiny PUT p99 ≤ 25 ms | 11.2 to 11.5 ms | met |
| T4 | Concurrency 1 no worse | 164 to 193/s, p99 7 to 22 ms | met (the 4 KiB p99 of 22 ms was a single outlier phase; the other sizes are 7 to 9 ms) |
| T5 | Tiny GET ≥ 15,000 ops/s, p99 ≤ 5 ms | 11,100 to 15,700, p99 4.1 to 7.3 ms | 0 B only |
| T6 | HEAD ≥ 20,000 ops/s | 15,800 to 17,300 | not met |
| T8 | 1 MiB not lower | PUT 172 MiB/s, GET 810 MiB/s | met |
| T12 | Write amplification ≤ 1.2 | 1.04 (4 KiB), 1.17 (1 KiB) | met |

## Full table

From `2026-11-09-group-commit.json`, with the 1 KiB rows from `2026-11-09-group-commit-1k.json`. Ops/s, then p99 in
ms.

| Size | Concurrency | PUT | GET | HEAD | Overwrite | DELETE | Syncs per 1,000 PUTs |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1 | 178 · 7.3 | 9,212 · 0.22 | 10,699 · 0.11 | 181 · 7.2 | 198 · 6.5 | 1,000 |
| 0 | 32 | 3,387 · 11.4 | 15,700 · 4.1 | 15,799 · 4.4 | 3,439 · 10.7 | 224 · 167 | 64 |
| 0 | 128 | 4,844 · 31.1 | 9,908 · 41.2 | 9,196 · 54.7 | 4,870 · 30.8 | 224 · 597 | 20 |
| 1 KiB | 1 | 193 · 8.6 | 6,176 · 0.26 | 10,752 · 0.11 | 195 · 7.0 | 205 · 6.3 | 1,000 |
| 1 KiB | 8 | 830 · 11.7 | 14,062 · 1.1 | 20,880 · 0.73 | 847 · 11.4 | 213 · 46 | 250 |
| 1 KiB | 32 | 3,317 · 11.2 | 12,076 · 4.8 | 17,045 · 3.5 | 3,359 · 11.0 | 212 · 165 | 64 |
| 1 KiB | 128 | 5,624 · 34.9 | 7,566 · 26.2 | 10,038 · 19.2 | 5,659 · 37.8 | 211 · 630 | 16 |
| 4 KiB | 1 | 164 · 22.0 | 6,108 · 0.24 | 10,993 · 0.11 | 198 · 9.1 | 202 · 6.3 | 1,000 |
| 4 KiB | 32 | 3,312 · 11.5 | 11,103 · 7.3 | 17,326 · 3.5 | 3,299 · 18.1 | 210 · 175 | 64 |
| 4 KiB | 128 | 5,009 · 37.4 | 7,681 · 24.8 | 10,019 · 19.3 | 5,424 · 36.2 | 214 · 651 | 17 |
| 64 KiB | 32 | 1,953 · 21.4 | 6,614 · 6.8 | 17,793 · 2.8 | 2,097 · 23.2 | 193 · 356 | 64 |
| 64 KiB | 128 | 2,788 · 68.6 | 5,365 · 29.3 | 10,317 · 18.6 | 3,031 · 70.1 | 206 · 651 | 17 |
| 1 MiB | 1 | 54 · 25.6 | 190 · 7.4 | 9,603 · 0.19 | 52 · 32.4 | 162 · 7.7 | 1,000 |
| 1 MiB | 32 | 172 · 297 | 810 · 85.5 | 17,207 · 2.7 | 180 · 261 | 171 · 229 | 184 |
| 1 MiB | 128 | 204 · 1,081 | 825 · 334 | 10,431 · 19.0 | 170 · 973 | 167 · 800 | 81 |

The JSON has every size (128 B, 16 KiB, 256 KiB too), concurrency 8, p50, p95, p99.9, and RSS.

## Next

1. **Reads without the store's lock** (T5, T6). HEAD at 15,000 to 17,000/s is now the request path. A lock and
   four or five `Async.blocking` threads per request (CEESAFE_GAPS G28) cost more than the read.
2. **Deletes through group commit,** the same way as PUTs.
3. **T2.** Decide whether the target should allow for closed-loop clients, or whether a short wait under load is
   worth adding.
