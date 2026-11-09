# Small PUTs on the event loop, 10 Nov 2026 (ADR-0031)

The build before the change (`356c586`) against the change, with `tools/perf_gate.sh` (ADR-0030): 3 rounds, each
running both builds in turn, 0 B to 1 MiB at concurrency 1, 32 and 128, 1,000 operations a phase (small reads 10,000).

## Environment

| | |
|---|---|
| Host | Apple M1, darwin 27.0.0, internal SSD with `F_FULLFSYNC`; ceesafec 0.24.2 |
| Load | 1-minute load average 6 to 16 from other sessions (median group noise under 2, so the gate judged it) |
| Checks | Every GET verified by MD5; fsck clean after each run; no errors |
| Raw data | `2026-11-10-small-puts-on-the-loop.json` (the six runs) |

## Findings

- **Small writes at concurrency 128: 1.76 times the throughput, 0.56 times the p99.** 0 B and 1 KiB PUTs went from
  3,410 to 4,957/s to 10,602 to 11,780/s, and their p99 from 37 to 48 ms to 12 to 14 ms. 4 KiB PUTs went from 4,088
  to 8,704/s.
- **At concurrency 32, 1.09 times and 0.89 times:** the device's flush rate bounds it. 4 KiB PUT ran at 3,118/s
  (T1 asks for 3,000), with 64 syncs per 1,000 writes for every size, as before.
- **Large objects and reads did not change** beyond the noise: they take the same path as before.

## The gate's report

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
| small writes, c1 | 10 | 0.95 | 1.03 | 1.94 / 1.22 | ok |
| small metadata reads, c1 | 5 | 0.90 | 1.27 | 1.67 / 1.79 | ok |
| small writes, c32 | 10 | 0.89 | 1.09 | 1.56 / 1.25 | ok |
| small metadata reads, c32 | 5 | 0.69 | 1.14 | 2.43 / 1.93 | ok |
| small writes, c128 | 10 | 0.56 | 1.76 | 1.66 / 1.58 | ok |
| small metadata reads, c128 | 5 | 0.65 | 1.06 | 2.83 / 1.66 | ok |
| small GETs, c1 | 2 | 0.97 | 1.11 | 1.34 / 1.30 | ok |
| small GETs, c32 | 2 | 0.79 | 1.16 | 2.52 / 2.00 | ok |
| small GETs, c128 | 2 | 0.88 | 1.10 | 2.01 / 1.58 | ok |
| large writes, c1 | 2 | 0.97 | 1.06 | 1.59 / 1.34 | ok |
| large GETs, c1 | 1 | 0.64 | 1.42 | 2.13 / 1.75 | ok |
| large writes, c32 | 2 | 0.97 | 1.01 | 1.27 / 1.15 | ok |
| large GETs, c32 | 1 | 0.83 | 0.96 | 1.22 / 1.12 | ok |
| large writes, c128 | 2 | 0.94 | 0.96 | 1.12 / 1.16 | ok |
| large GETs, c128 | 1 | 1.06 | 0.98 | 1.29 / 1.12 | ok |

| phase | base p99 ms | head p99 ms | ratio | base ops/s | head ops/s | ratio | base syncs/1k | head syncs/1k | |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 0 B, c1, put | 6.21 | 6.20 | 1.01 | 203 | 212 | 1.04 | 1000 | 1000 |  |
| 0 B, c1, get | 0.21 | 0.15 | 0.97 | 12043 | 14592 | 1.16 | 0 | 0 |  |
| 0 B, c1, head | 0.18 | 0.10 | 0.97 | 12676 | 15067 | 1.19 | 0 | 0 |  |
| 0 B, c1, overwrite | 6.30 | 6.30 | 0.99 | 205 | 212 | 1.04 | 1000 | 1000 |  |
| 0 B, c1, delete | 7.94 | 7.43 | 0.91 | 199 | 207 | 1.04 | 1000 | 1000 |  |
| 0 B, c32, put | 21.07 | 11.55 | 0.58 | 2567 | 3330 | 1.30 | 64 | 64 |  |
| 0 B, c32, get | 3.20 | 1.81 | 0.76 | 30149 | 37117 | 1.23 | 0 | 0 |  |
| 0 B, c32, head | 6.12 | 1.56 | 0.46 | 34116 | 40471 | 1.19 | 0 | 0 |  |
| 0 B, c32, overwrite | 20.06 | 16.99 | 0.76 | 2709 | 3351 | 1.22 | 64 | 64 |  |
| 0 B, c32, delete | 12.28 | 10.91 | 0.88 | 3018 | 3394 | 1.12 | 64 | 64 |  |
| 0 B, c128, put | 47.62 | 14.36 | 0.35 | 3410 | 10602 | 3.02 | 21 | 16 |  |
| 0 B, c128, get | 20.74 | 5.77 | 0.57 | 34293 | 36896 | 1.00 | 0 | 0 |  |
| 0 B, c128, head | 17.54 | 6.35 | 0.41 | 35284 | 36911 | 1.08 | 0 | 0 |  |
| 0 B, c128, overwrite | 35.96 | 13.11 | 0.39 | 4164 | 11614 | 2.80 | 19 | 16 |  |
| 0 B, c128, delete | 20.17 | 16.16 | 0.84 | 7083 | 9195 | 1.30 | 16 | 16 |  |
| 1024 B, c1, put | 7.21 | 7.14 | 0.91 | 199 | 207 | 1.04 | 1000 | 1000 |  |
| 1024 B, c1, get | 0.29 | 0.27 | 0.96 | 7492 | 7996 | 1.07 | 0 | 0 |  |
| 1024 B, c1, head | 0.17 | 0.14 | 0.97 | 13771 | 14714 | 1.09 | 0 | 0 |  |
| 1024 B, c1, overwrite | 8.60 | 7.56 | 0.77 | 202 | 204 | 1.04 | 1000 | 1000 |  |
| 1024 B, c1, delete | 6.23 | 7.30 | 1.12 | 210 | 205 | 0.98 | 1000 | 1000 |  |
| 1024 B, c32, put | 12.45 | 12.37 | 0.90 | 3260 | 3324 | 1.04 | 64 | 64 |  |
| 1024 B, c32, get | 4.45 | 2.25 | 0.70 | 22121 | 26575 | 1.20 | 0 | 0 |  |
| 1024 B, c32, head | 4.11 | 2.06 | 0.60 | 35524 | 39190 | 1.14 | 0 | 0 |  |
| 1024 B, c32, overwrite | 12.42 | 10.93 | 0.86 | 3265 | 3372 | 1.05 | 64 | 64 |  |
| 1024 B, c32, delete | 11.32 | 11.47 | 1.01 | 3197 | 3387 | 1.06 | 64 | 64 |  |
| 1024 B, c128, put | 36.68 | 12.39 | 0.36 | 4957 | 11780 | 2.43 | 17 | 16 |  |
| 1024 B, c128, get | 10.32 | 10.05 | 0.95 | 23406 | 24453 | 1.05 | 0 | 0 |  |
| 1024 B, c128, head | 32.80 | 21.05 | 0.51 | 34594 | 37308 | 1.08 | 0 | 0 |  |
| 1024 B, c128, overwrite | 36.32 | 13.92 | 0.43 | 5465 | 11320 | 1.99 | 17 | 16 |  |
| 1024 B, c128, delete | 15.57 | 17.02 | 1.08 | 9265 | 8688 | 0.95 | 16 | 16 |  |
| 4096 B, c1, put | 7.38 | 6.21 | 0.87 | 199 | 207 | 1.04 | 1000 | 1000 |  |
| 4096 B, c1, get | 0.40 | 0.24 | 0.98 | 5994 | 7350 | 1.14 | 0 | 0 |  |
| 4096 B, c1, head | 0.20 | 0.12 | 0.96 | 12417 | 14965 | 1.21 | 0 | 0 |  |
| 4096 B, c1, overwrite | 9.01 | 7.56 | 0.88 | 185 | 204 | 1.10 | 1000 | 1000 |  |
| 4096 B, c1, delete | 7.57 | 7.50 | 0.98 | 209 | 203 | 0.99 | 1000 | 1000 |  |
| 4096 B, c32, put | 22.34 | 12.15 | 0.58 | 2629 | 3118 | 1.13 | 64 | 64 |  |
| 4096 B, c32, get | 3.56 | 2.85 | 0.89 | 19751 | 22088 | 1.12 | 0 | 0 |  |
| 4096 B, c32, head | 6.20 | 3.26 | 0.64 | 31513 | 36897 | 1.17 | 0 | 0 |  |
| 4096 B, c32, overwrite | 14.45 | 15.98 | 1.09 | 2840 | 3116 | 1.04 | 64 | 64 |  |
| 4096 B, c32, delete | 13.48 | 26.82 | 1.58 | 2990 | 2914 | 1.00 | 64 | 64 |  |
| 4096 B, c128, put | 46.01 | 17.38 | 0.50 | 4088 | 8704 | 1.97 | 17 | 16 |  |
| 4096 B, c128, get | 13.26 | 14.84 | 0.82 | 19172 | 18896 | 1.15 | 0 | 0 |  |
| 4096 B, c128, head | 28.12 | 19.78 | 0.96 | 30834 | 34384 | 1.14 | 0 | 0 |  |
| 4096 B, c128, overwrite | 47.96 | 17.70 | 0.39 | 4101 | 8367 | 2.04 | 17 | 16 |  |
| 4096 B, c128, delete | 25.08 | 18.34 | 0.75 | 6141 | 8837 | 1.45 | 16 | 16 |  |
| 1048576 B, c1, put | 36.53 | 27.14 | 0.95 | 40 | 52 | 1.12 | 1000 | 1000 |  |
| 1048576 B, c1, get | 10.77 | 4.82 | 0.64 | 178 | 253 | 1.42 | 0 | 0 |  |
| 1048576 B, c1, head | 1.24 | 0.18 | 0.67 | 7025 | 11602 | 1.77 | 0 | 0 |  |
| 1048576 B, c1, overwrite | 43.73 | 27.82 | 1.00 | 38 | 51 | 1.00 | 1000 | 1000 |  |
| 1048576 B, c1, delete | 6.40 | 7.56 | 1.08 | 193 | 185 | 0.97 | 1000 | 1000 |  |
| 1048576 B, c32, put | 328.29 | 277.14 | 0.92 | 160 | 173 | 1.06 | 173 | 174 |  |
| 1048576 B, c32, get | 69.81 | 57.97 | 0.83 | 785 | 800 | 0.96 | 0 | 0 |  |
| 1048576 B, c32, head | 1.79 | 1.44 | 1.13 | 35590 | 39422 | 1.00 | 0 | 0 |  |
| 1048576 B, c32, overwrite | 279.40 | 287.18 | 1.03 | 174 | 164 | 0.96 | 117 | 122 |  |
| 1048576 B, c32, delete | 21.25 | 21.35 | 1.03 | 1842 | 1910 | 0.96 | 64 | 64 |  |
| 1048576 B, c128, put | 1205.76 | 1120.17 | 0.91 | 197 | 208 | 0.94 | 94 | 74 |  |
| 1048576 B, c128, get | 233.13 | 247.60 | 1.06 | 768 | 752 | 0.98 | 0 | 0 |  |
| 1048576 B, c128, head | 5.26 | 3.92 | 1.04 | 40720 | 43559 | 1.02 | 0 | 0 |  |
| 1048576 B, c128, overwrite | 1075.99 | 1070.86 | 0.96 | 181 | 166 | 0.99 | 25 | 20 |  |
| 1048576 B, c128, delete | 33.36 | 33.18 | 1.03 | 4298 | 4278 | 0.99 | 16 | 16 |  |

gate: passed
