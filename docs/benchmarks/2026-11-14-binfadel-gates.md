# The p99 gate on binfadel, 14 Nov 2026: the 0.41.0 move, and M5

Two runs of `tools/perf_gate.sh` (3 rounds, each base then head in turn; sizes 0, 1 KiB, 4 KiB, 1 MiB; concurrency
1 and 32; 1,000 operations a phase) on binfadel: Ubuntu 24.04, Intel Xeon E-2236 (6 cores, 12 threads), NVMe. The
server ran on CPUs 2,3 (their sibling threads 8,9 idle), the load generator on 4,5,10,11 (`taskset`). The host also
runs other services (a key-value store, SQL Server); the load average peaked at 3.8 of 12 threads.

Each commit was built with its own pins (its `ci.yml`): `b8a794e` with ceesafec 0.38.0 and CeeSafe.Web `c799f14`,
`48709f4` with 0.41.0 and `c799f14`, `67947c6` with 0.45.0 and `9592f2d`. No request in the matrix asks for
encryption: the M5 run measures what versioning, policies, ACLs, Object Lock, notifications, CORS, quotas, rate
limits and the compilers cost a request that uses none of them.

1. **`b8a794e` → `48709f4`** (ceesafec 0.38.0 → 0.41.0, `serve` raises its open-file limit): the change CI's gate
   failed on 12 Nov (run 43321032635: large writes at concurrency 32, p99 1.31, ops/s 0.76, on a shared macOS
   runner). Here: passed, that group 0.98 and 1.02.
2. **`48709f4` → `67947c6`** (all of M5, ceesafec 0.41.0 → 0.45.0, CeeSafe.Web `c799f14` → `9592f2d`): passed.

# Regression gate

3 rounds, each running the base and the head build in turn. Each head run is compared with the
base run of its round; a phase's ratio is the median over the rounds (p99 with 2.0 ms added to both sides).
A group fails when the geometric mean of its phases' ratios passes the tolerance: p99 × 1.25 for writes and
× 1.50 for reads, ops/s × 0.80.
A phase fails on errors, or on syncs per 1,000 writes above the base's × 1.25 + 5.

A group fails only if it is also past the base's own spread between rounds (its noise); one past the tolerance
but within its noise is reported as noisy. When the median group noise is above
2.00, the machine was too busy to tell, and the run is inconclusive unless a phase failed.

| group | phases | p99, head / base | ops/s, head / base | noise, p99 / ops/s | |
|---|---:|---:|---:|---:|---|
| small writes, c1 | 10 | 1.00 | 1.01 | 1.06 / 1.14 | ok |
| small metadata reads, c1 | 5 | 1.00 | 0.97 | 1.01 / 1.10 | ok |
| small writes, c32 | 10 | 0.99 | 1.00 | 1.21 / 1.10 | ok |
| small metadata reads, c32 | 5 | 0.98 | 1.01 | 1.06 / 1.01 | ok |
| small GETs, c1 | 2 | 1.00 | 0.97 | 1.02 / 1.05 | ok |
| small GETs, c32 | 2 | 1.00 | 0.99 | 1.05 / 1.03 | ok |
| large writes, c1 | 2 | 1.00 | 1.01 | 1.16 / 1.02 | ok |
| large GETs, c1 | 1 | 1.00 | 1.00 | 1.11 / 1.15 | ok |
| large writes, c32 | 2 | 0.98 | 1.02 | 1.09 / 1.01 | ok |
| large GETs, c32 | 1 | 0.80 | 1.00 | 1.19 / 1.04 | ok |

| phase | base p99 ms | head p99 ms | ratio | base ops/s | head ops/s | ratio | base syncs/1k | head syncs/1k | |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 0 B, c1, put | 1.31 | 1.37 | 1.02 | 1275 | 1146 | 0.90 | 1000 | 1000 |  |
| 0 B, c1, get | 0.11 | 0.10 | 1.00 | 13325 | 12611 | 0.93 | 0 | 0 |  |
| 0 B, c1, head | 0.09 | 0.10 | 1.00 | 13457 | 12719 | 0.98 | 0 | 0 |  |
| 0 B, c1, overwrite | 1.29 | 1.34 | 1.02 | 1248 | 1260 | 0.99 | 1000 | 1000 |  |
| 0 B, c1, delete | 1.36 | 1.04 | 0.93 | 1239 | 1331 | 1.04 | 1000 | 1000 |  |
| 0 B, c32, put | 4.93 | 4.37 | 0.87 | 12546 | 12355 | 1.00 | 64 | 64 |  |
| 0 B, c32, get | 1.61 | 1.48 | 0.96 | 48860 | 50559 | 1.03 | 0 | 0 |  |
| 0 B, c32, head | 1.51 | 1.51 | 1.01 | 51009 | 51384 | 1.00 | 0 | 0 |  |
| 0 B, c32, overwrite | 3.22 | 3.15 | 1.00 | 12600 | 12893 | 0.97 | 64 | 64 |  |
| 0 B, c32, delete | 2.87 | 2.89 | 1.00 | 14322 | 14003 | 0.98 | 64 | 64 |  |
| 1024 B, c1, put | 1.38 | 1.34 | 1.01 | 1155 | 1208 | 1.06 | 1000 | 1000 |  |
| 1024 B, c1, get | 0.20 | 0.21 | 1.00 | 9384 | 9296 | 0.97 | 0 | 0 |  |
| 1024 B, c1, head | 0.13 | 0.13 | 1.00 | 13423 | 13336 | 0.99 | 0 | 0 |  |
| 1024 B, c1, overwrite | 1.40 | 1.18 | 0.94 | 1092 | 1180 | 1.09 | 1000 | 1000 |  |
| 1024 B, c1, delete | 1.33 | 1.34 | 1.01 | 1242 | 1232 | 1.00 | 1000 | 1000 |  |
| 1024 B, c32, put | 3.30 | 3.32 | 0.99 | 12377 | 12751 | 1.03 | 64 | 64 |  |
| 1024 B, c32, get | 2.01 | 2.12 | 1.03 | 42312 | 41105 | 0.97 | 0 | 0 |  |
| 1024 B, c32, head | 1.72 | 1.64 | 0.93 | 49375 | 50432 | 1.03 | 0 | 0 |  |
| 1024 B, c32, overwrite | 3.49 | 4.98 | 1.04 | 12812 | 13229 | 1.06 | 64 | 64 |  |
| 1024 B, c32, delete | 2.92 | 2.96 | 0.99 | 14195 | 14290 | 0.99 | 64 | 64 |  |
| 4096 B, c1, put | 0.99 | 1.44 | 1.05 | 1181 | 1110 | 0.96 | 1000 | 1000 |  |
| 4096 B, c1, get | 0.22 | 0.24 | 1.01 | 8305 | 8052 | 0.98 | 0 | 0 |  |
| 4096 B, c1, head | 0.09 | 0.10 | 1.01 | 13574 | 13373 | 0.99 | 0 | 0 |  |
| 4096 B, c1, overwrite | 1.36 | 1.43 | 1.00 | 1141 | 1146 | 1.00 | 1000 | 1000 |  |
| 4096 B, c1, delete | 1.23 | 1.28 | 1.01 | 1275 | 1321 | 1.04 | 1000 | 1000 |  |
| 4096 B, c32, put | 3.43 | 3.45 | 1.00 | 11471 | 11523 | 1.00 | 64 | 64 |  |
| 4096 B, c32, get | 2.12 | 2.04 | 0.97 | 40471 | 40217 | 1.00 | 0 | 0 |  |
| 4096 B, c32, head | 1.35 | 1.32 | 0.99 | 51926 | 51584 | 1.00 | 0 | 0 |  |
| 4096 B, c32, overwrite | 3.44 | 3.34 | 0.98 | 11590 | 11484 | 0.99 | 64 | 64 |  |
| 4096 B, c32, delete | 2.89 | 2.78 | 1.00 | 13927 | 14243 | 1.04 | 64 | 64 |  |
| 1048576 B, c1, put | 8.08 | 8.73 | 1.06 | 141 | 141 | 1.00 | 1000 | 1000 |  |
| 1048576 B, c1, get | 2.73 | 2.74 | 1.00 | 454 | 461 | 1.00 | 0 | 0 |  |
| 1048576 B, c1, head | 0.12 | 0.09 | 1.00 | 12751 | 13426 | 0.98 | 0 | 0 |  |
| 1048576 B, c1, overwrite | 9.54 | 8.94 | 0.95 | 141 | 141 | 1.01 | 1000 | 1000 |  |
| 1048576 B, c1, delete | 1.60 | 1.57 | 0.99 | 777 | 796 | 1.02 | 1000 | 1000 |  |
| 1048576 B, c32, put | 111.63 | 107.94 | 0.97 | 416 | 424 | 1.02 | 181 | 189 |  |
| 1048576 B, c32, get | 48.50 | 38.22 | 0.80 | 2375 | 2396 | 1.00 | 0 | 0 |  |
| 1048576 B, c32, head | 1.00 | 1.03 | 0.99 | 50843 | 50795 | 1.00 | 0 | 0 |  |
| 1048576 B, c32, overwrite | 109.14 | 107.48 | 1.00 | 407 | 413 | 1.02 | 166 | 164 |  |
| 1048576 B, c32, delete | 7.18 | 7.46 | 1.03 | 4848 | 4797 | 0.99 | 64 | 64 |  |

gate: passed
# Regression gate

3 rounds, each running the base and the head build in turn. Each head run is compared with the
base run of its round; a phase's ratio is the median over the rounds (p99 with 2.0 ms added to both sides).
A group fails when the geometric mean of its phases' ratios passes the tolerance: p99 × 1.25 for writes and
× 1.50 for reads, ops/s × 0.80.
A phase fails on errors, or on syncs per 1,000 writes above the base's × 1.25 + 5.

A group fails only if it is also past the base's own spread between rounds (its noise); one past the tolerance
but within its noise is reported as noisy. When the median group noise is above
2.00, the machine was too busy to tell, and the run is inconclusive unless a phase failed.

| group | phases | p99, head / base | ops/s, head / base | noise, p99 / ops/s | |
|---|---:|---:|---:|---:|---|
| small writes, c1 | 10 | 1.00 | 0.96 | 1.08 / 1.13 | ok |
| small metadata reads, c1 | 5 | 1.00 | 0.97 | 1.01 / 1.10 | ok |
| small writes, c32 | 10 | 1.03 | 0.92 | 1.18 / 1.12 | ok |
| small metadata reads, c32 | 5 | 1.01 | 0.93 | 1.15 / 1.09 | ok |
| small GETs, c1 | 2 | 0.99 | 1.03 | 1.01 / 1.03 | ok |
| small GETs, c32 | 2 | 0.99 | 0.94 | 1.05 / 1.02 | ok |
| large writes, c1 | 2 | 1.04 | 1.00 | 1.04 / 1.01 | ok |
| large GETs, c1 | 1 | 1.04 | 0.98 | 1.02 / 1.05 | ok |
| large writes, c32 | 2 | 1.02 | 0.99 | 1.03 / 1.01 | ok |
| large GETs, c32 | 1 | 1.12 | 1.03 | 1.15 / 1.04 | ok |

| phase | base p99 ms | head p99 ms | ratio | base ops/s | head ops/s | ratio | base syncs/1k | head syncs/1k | |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 0 B, c1, put | 1.33 | 1.40 | 1.02 | 1193 | 1067 | 0.86 | 1000 | 1000 |  |
| 0 B, c1, get | 0.11 | 0.12 | 1.01 | 13035 | 13036 | 0.95 | 0 | 0 |  |
| 0 B, c1, head | 0.12 | 0.10 | 0.99 | 13500 | 13303 | 0.99 | 0 | 0 |  |
| 0 B, c1, overwrite | 1.34 | 1.36 | 1.00 | 1189 | 1127 | 1.00 | 1000 | 1000 |  |
| 0 B, c1, delete | 1.19 | 1.32 | 1.05 | 1203 | 1191 | 1.01 | 1000 | 1000 |  |
| 0 B, c32, put | 4.49 | 4.98 | 1.03 | 13583 | 11879 | 0.87 | 64 | 64 |  |
| 0 B, c32, get | 1.60 | 1.52 | 0.98 | 49128 | 46686 | 0.96 | 0 | 0 |  |
| 0 B, c32, head | 1.52 | 1.62 | 1.04 | 50225 | 47140 | 0.94 | 0 | 0 |  |
| 0 B, c32, overwrite | 3.06 | 3.31 | 1.00 | 13688 | 12278 | 0.90 | 64 | 64 |  |
| 0 B, c32, delete | 2.87 | 3.10 | 1.05 | 14112 | 13258 | 0.93 | 64 | 64 |  |
| 1024 B, c1, put | 1.38 | 1.36 | 1.00 | 1128 | 1067 | 0.95 | 1000 | 1000 |  |
| 1024 B, c1, get | 0.21 | 0.20 | 1.00 | 9416 | 9231 | 0.96 | 0 | 0 |  |
| 1024 B, c1, head | 0.14 | 0.14 | 1.00 | 13211 | 12775 | 0.97 | 0 | 0 |  |
| 1024 B, c1, overwrite | 1.33 | 1.36 | 0.98 | 1167 | 1170 | 0.97 | 1000 | 1000 |  |
| 1024 B, c1, delete | 1.34 | 1.24 | 0.97 | 1138 | 1278 | 1.12 | 1000 | 1000 |  |
| 1024 B, c32, put | 3.41 | 3.34 | 0.98 | 12612 | 12274 | 0.97 | 64 | 64 |  |
| 1024 B, c32, get | 2.09 | 2.08 | 0.99 | 41472 | 39038 | 0.95 | 0 | 0 |  |
| 1024 B, c32, head | 1.60 | 1.57 | 1.00 | 50180 | 46696 | 0.93 | 0 | 0 |  |
| 1024 B, c32, overwrite | 3.52 | 3.73 | 1.09 | 12910 | 12284 | 0.95 | 64 | 64 |  |
| 1024 B, c32, delete | 2.97 | 3.13 | 1.05 | 14273 | 13216 | 0.93 | 64 | 64 |  |
| 4096 B, c1, put | 1.31 | 1.47 | 1.05 | 1216 | 996 | 0.82 | 1000 | 1000 |  |
| 4096 B, c1, get | 0.22 | 0.19 | 0.98 | 8031 | 8786 | 1.11 | 0 | 0 |  |
| 4096 B, c1, head | 0.11 | 0.11 | 1.00 | 13701 | 13258 | 0.98 | 0 | 0 |  |
| 4096 B, c1, overwrite | 1.28 | 1.41 | 1.04 | 1212 | 1075 | 0.89 | 1000 | 1000 |  |
| 4096 B, c1, delete | 1.20 | 1.06 | 0.93 | 1292 | 1310 | 0.99 | 1000 | 1000 |  |
| 4096 B, c32, put | 3.54 | 3.77 | 1.02 | 12462 | 10664 | 0.89 | 64 | 64 |  |
| 4096 B, c32, get | 2.10 | 2.17 | 0.99 | 40682 | 38136 | 0.93 | 0 | 0 |  |
| 4096 B, c32, head | 1.35 | 1.37 | 1.01 | 51530 | 47485 | 0.92 | 0 | 0 |  |
| 4096 B, c32, overwrite | 3.39 | 3.81 | 1.05 | 11701 | 11048 | 0.93 | 64 | 64 |  |
| 4096 B, c32, delete | 2.83 | 3.05 | 1.04 | 14489 | 13260 | 0.91 | 64 | 63 |  |
| 1048576 B, c1, put | 8.11 | 8.47 | 1.04 | 141 | 140 | 1.00 | 1000 | 1000 |  |
| 1048576 B, c1, get | 2.71 | 2.86 | 1.04 | 476 | 469 | 0.98 | 0 | 0 |  |
| 1048576 B, c1, head | 0.11 | 0.09 | 0.99 | 13666 | 13058 | 0.98 | 0 | 0 |  |
| 1048576 B, c1, overwrite | 8.34 | 8.73 | 1.04 | 141 | 142 | 1.00 | 1000 | 1000 |  |
| 1048576 B, c1, delete | 1.57 | 1.59 | 1.01 | 763 | 784 | 0.99 | 1000 | 1000 |  |
| 1048576 B, c32, put | 106.71 | 110.03 | 1.03 | 424 | 418 | 0.99 | 183 | 185 |  |
| 1048576 B, c32, get | 42.54 | 44.82 | 1.12 | 2386 | 2455 | 1.03 | 0 | 0 |  |
| 1048576 B, c32, head | 1.00 | 1.09 | 1.03 | 51497 | 46868 | 0.92 | 0 | 0 |  |
| 1048576 B, c32, overwrite | 106.85 | 107.01 | 1.00 | 414 | 409 | 0.99 | 155 | 161 |  |
| 1048576 B, c32, delete | 7.12 | 7.89 | 1.05 | 4838 | 4725 | 0.98 | 64 | 63 |  |

gate: passed
