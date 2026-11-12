# The M4 matrix on an Intel Mac mini, 12 Nov 2026

The M4 reference run's matrix (`2026-11-09-m4-reference.md`) on a second machine: a 2018 Mac mini with an Intel
Core i7. It is **not** the reference machine (Apple M1, `docs/targets.md`), so it does not settle T1 at 4 KiB or T7;
that run is still to do. It shows how the targets carry over to a machine whose syncs are four times slower, and it
found a failure the M1 had not shown (below).

## Environment

| | |
|---|---|
| What | `805464a` (ceesafec 0.36.0, CeeSafe.Web `c799f14`), default StoreConfig |
| Host | Mac mini 2018, Intel Core i7-8700B (6 cores, 12 threads), 32 GB, Apple SSD AP0512M, macOS 15.7.3, `F_FULLFSYNC` |
| Toolchain | ceesafec 0.36.0's `osx-x64` release; Apple clang 17; OpenSSL 3.6.4 built from source (CeeSafe.Web's `web_tls` names Homebrew's Apple Silicon path, so the build's copy pointed at it) |
| Client | `tools/bench` (go1.27.3, built for amd64), loopback, plain HTTP, SigV4 with UNSIGNED-PAYLOAD |
| Run | `tools/bench.sh -sizes 0,128,1024,4096,16384,65536,262144,1048576 -concurrency 1,8,32,128 -ops 1000`, as the reference; open-file limit 10,240 (`ulimit -n`); no scale run |
| Checks | Every GET verified by MD5; no errors; fsck clean |
| Load | 39 samples, one every 30 s: load average 1.1 to 3.3. Nothing else ran (Photos and Spotlight had finished indexing after a restart) |
| Raw data | `2026-11-12-mac-mini-intel.json` |

## One sync is 22 ms here

A PUT at concurrency 1 costs one sync. The mini runs 45 a second (22 ms each), the M1 193 (5.2 ms): its syncs are
4.3 times slower. Everything bound by syncs scales with that, and the targets set on the M1 in milliseconds and
operations per second do not hold here. Counted in syncs, the mini matches the M1:

| # | Target (M1) | Mini | M1 reference | In syncs |
|---|---|---:|---:|---|
| T1 | tiny PUT at concurrency 32 ≥ 3,000/s | 688 to 694/s | 2,908 to 3,267/s | the same: both 64 syncs per 1,000 PUTs, so 15.6 PUTs a sync; 0.22 to 0.24 times the M1, as the sync rate (0.23) |
| T2 | ≤ 70 syncs per 1,000 tiny PUTs, c32 | 64 | 64 | met |
| T3 | tiny PUT p99 at c32 ≤ 25 ms | 46.4 to 50.9 ms | 11.4 to 16.2 ms | 2.1 to 2.3 syncs on both |
| T4 | tiny PUT at c1 no worse than the baseline | 45/s | 175 to 201/s | one sync a PUT on both |
| T5 | tiny GET at c32 ≥ 15,000/s, p99 ≤ 5 ms | 23,213 to 30,563/s, p99 ≤ 3.2 ms | 20,595 to 26,980/s | met (no syncs) |
| T6 | HEAD at c32 ≥ 20,000/s | 29,050 to 39,383/s | 34,170 to 41,828/s | met |
| T7 | p99.9 ≤ 50 ms at c8, small objects, with upkeep | 0.5 to 140.6 ms; 13 of 30 phases over 50 | 0.5 to 53.1 ms | 50 ms is 9.6 M1 syncs; the mini's worst is 6.3 of its own |
| T8 | 1 MiB at c32 not below the baseline | PUT 41, GET 2,526 MiB/s | PUT 183, GET 856 MiB/s | PUT 0.22 times (sync-bound), GET 2.95 times |
| T12 | write amplification ≤ 1.2 | 1.09 | | met |

- **What does not depend on syncs is faster than the M1:** GETs of 128 B to 4 KiB 1.1 to 1.3 times, HEADs 0.77 to
  1.14 times, 1 MiB GETs 2.95 times.
- **One phase is worse even in syncs:** 64 KiB deletes at concurrency 8, at 148/s (0.17 times the M1, against 0.23
  for syncs) and a p99 of 138 ms (6.2 syncs, against 2.7). It had 31 upkeep holds of 10 ms or more (the M1: none):
  these deletes empty whole segments, and compaction's steps each wait on a sync that costs 22 ms here.
  Upkeep holds of 10 ms or more (ADR-0029) are counted in 27 of the 120 phases up to 64 KiB, against 3 on the M1,
  because one sync alone passes 10 ms here.
- **Memory:** 55 MiB RSS at most.

## A failure: out of open files, the store fail-stops

The first run used the shell's default limit, 256 open files (macOS's default, and what a process started over
ssh gets). At 256 KiB PUTs and concurrency 128 the server needed more: 128 sockets, an extent file for each upload
in progress (above 128 KiB), segments and the listener. An open failed with "too many open files", and:

- the journal **fail-stopped**: `Journal.writeStaged` opens a second handle to the active segment for each group
  commit's sync ticket, before it writes anything, and fails the journal if that open fails. A failed rotation
  (`rotate`, creating the next segment) fails it too;
- every later write got 503 until a restart, through the rest of the run (25 phases, 1,000 errors each);
- the log said only `journal error`, without the cause;
- nothing acknowledged was lost: fsck was clean.

The same phase alone, under each limit: at 256, a journal error; at 10,240, no error. The failure is not a
durability violation (ADR-0001 holds: no batch was acknowledged), but a temporary shortage of descriptors stopped
the store for good. CeeSafe has no way to read or raise the limit (`setrlimit`), so `serve` cannot raise its own
soft limit to the hard one, as servers usually do (CEESAFE_GAPS G32).
