# Inline PUTs without the first lock round, 10 Nov 2026 (ADR-0032)

The build before the change (`5c81a49`) against the change, with `tools/perf_gate.sh` (ADR-0030): 3 rounds, each
running both builds in turn, 0 B to 4 KiB at concurrency 1, 32 and 128, 1,000 operations a phase (small reads 10,000).
Large objects were left out: their PUTs start as before.

## Environment

| | |
|---|---|
| Host | Apple M1, darwin 27.0.0, internal SSD with `F_FULLFSYNC`; ceesafec 0.24.2 |
| Load | 1-minute load average 9 to 14 from other sessions (a VM and a compiler test run; median group noise 1.3, so the gate judged it) |
| Checks | Every GET verified by MD5; fsck clean after each run; no errors |
| Raw data | `2026-11-10-inline-puts-without-the-lock.json` (the six runs) |

## Findings

- **A small gain, mostly within the noise.** Small writes at concurrency 128: 1.03 times the throughput and 0.95
  times the p99 (noise 1.21 and 1.35). Overwrites gained most: 0 B at 11,418/s from 9,991 at concurrency 128, and p99
  0.80 to 0.90 times in five of the six overwrite phases at concurrency 32 and 128.
- **At concurrency 32 nothing changed beyond the noise,** as expected: the device's flush rate bounds it. 4 KiB PUT
  at 3,169 to 3,186/s, above T1's 3,000 in both builds.
- **Syncs per 1,000 writes unchanged:** 1,000, 64 and 16 at concurrency 1, 32 and 128.
- **The first lock round was not where most of the loop's time went.** Not measured, the likely reason: an unlock
  costs a `write` only when a request waits for the lock (G30), and requests mostly queue for it at staging, where
  they arrive together after a batch is published. That round stays. A profile at concurrency 128 would show what
  the loop does now.

## The gate's report

| group | phases | p99, head / base | ops/s, head / base | noise, p99 / ops/s | |
|---|---:|---:|---:|---:|---|
| small writes, c1 | 9 | 0.99 | 1.00 | 1.32 / 1.12 | ok |
| small metadata reads, c1 | 4 | 1.00 | 1.01 | 1.07 / 1.35 | ok |
| small writes, c32 | 9 | 0.98 | 1.02 | 1.33 / 1.13 | ok |
| small metadata reads, c32 | 4 | 0.80 | 1.10 | 1.50 / 1.23 | ok |
| small writes, c128 | 9 | 0.95 | 1.03 | 1.35 / 1.21 | ok |
| small metadata reads, c128 | 4 | 0.87 | 1.03 | 2.85 / 1.18 | ok |
| small GETs, c1 | 2 | 0.99 | 1.02 | 1.32 / 1.58 | ok |
| small GETs, c32 | 2 | 0.95 | 1.05 | 1.69 / 1.48 | ok |
| small GETs, c128 | 2 | 0.94 | 1.06 | 1.45 / 1.34 | ok |

| phase | base p99 ms | head p99 ms | ratio | base ops/s | head ops/s | ratio | base syncs/1k | head syncs/1k | |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 0 B, c1, put | 7.11 | 7.52 | 1.00 | 196 | 201 | 1.01 | 1000 | 1000 |  |
| 0 B, c1, get | 0.13 | 0.14 | 1.00 | 14134 | 13847 | 1.01 | 0 | 0 |  |
| 0 B, c1, head | 0.10 | 0.12 | 1.00 | 14447 | 14254 | 1.01 | 0 | 0 |  |
| 0 B, c1, overwrite | 7.17 | 8.08 | 1.10 | 203 | 205 | 1.00 | 1000 | 1000 |  |
| 0 B, c1, delete | 7.28 | 7.24 | 1.06 | 206 | 205 | 1.02 | 1000 | 1000 |  |
| 0 B, c32, put | 11.42 | 11.52 | 1.01 | 3226 | 3257 | 1.01 | 64 | 64 |  |
| 0 B, c32, get | 1.72 | 1.56 | 0.96 | 36036 | 38243 | 1.06 | 0 | 0 |  |
| 0 B, c32, head | 1.96 | 1.64 | 0.92 | 36004 | 36214 | 1.03 | 0 | 0 |  |
| 0 B, c32, overwrite | 13.69 | 12.11 | 0.86 | 3157 | 3215 | 1.02 | 64 | 64 |  |
| 0 B, c32, delete | 13.62 | 11.48 | 0.98 | 3256 | 3249 | 0.99 | 64 | 64 |  |
| 0 B, c128, put | 14.52 | 13.95 | 0.93 | 11035 | 11397 | 1.03 | 16 | 16 |  |
| 0 B, c128, get | 6.33 | 5.90 | 0.89 | 38767 | 37416 | 0.97 | 0 | 0 |  |
| 0 B, c128, head | 5.68 | 5.65 | 1.00 | 37915 | 37915 | 1.01 | 0 | 0 |  |
| 0 B, c128, overwrite | 15.53 | 13.84 | 0.90 | 9991 | 11418 | 1.14 | 16 | 16 |  |
| 0 B, c128, delete | 17.28 | 16.74 | 0.98 | 8940 | 8957 | 1.00 | 16 | 16 |  |
| 1024 B, c1, put | 6.35 | 7.07 | 1.07 | 199 | 194 | 1.00 | 1000 | 1000 |  |
| 1024 B, c1, get | 0.22 | 0.22 | 0.99 | 7506 | 7902 | 1.00 | 0 | 0 |  |
| 1024 B, c1, head | 0.13 | 0.17 | 1.00 | 14358 | 13782 | 1.01 | 0 | 0 |  |
| 1024 B, c1, overwrite | 7.05 | 7.31 | 1.03 | 201 | 193 | 0.97 | 1000 | 1000 |  |
| 1024 B, c1, delete | 7.56 | 6.77 | 0.82 | 192 | 192 | 1.00 | 1000 | 1000 |  |
| 1024 B, c32, put | 11.96 | 11.84 | 0.99 | 3283 | 3231 | 1.05 | 64 | 64 |  |
| 1024 B, c32, get | 2.43 | 2.32 | 0.98 | 26248 | 26635 | 1.01 | 0 | 0 |  |
| 1024 B, c32, head | 2.29 | 1.51 | 0.79 | 37100 | 41858 | 1.13 | 0 | 0 |  |
| 1024 B, c32, overwrite | 14.79 | 11.46 | 0.80 | 3234 | 3241 | 1.01 | 64 | 64 |  |
| 1024 B, c32, delete | 14.56 | 19.28 | 1.14 | 3323 | 3279 | 1.00 | 64 | 64 |  |
| 1024 B, c128, put | 12.94 | 12.87 | 1.05 | 11268 | 11379 | 1.02 | 16 | 16 |  |
| 1024 B, c128, get | 9.09 | 8.56 | 0.96 | 25911 | 26947 | 1.00 | 0 | 0 |  |
| 1024 B, c128, head | 8.83 | 8.48 | 0.97 | 35047 | 37625 | 1.07 | 0 | 0 |  |
| 1024 B, c128, overwrite | 16.24 | 14.54 | 0.89 | 11027 | 10680 | 1.03 | 16 | 16 |  |
| 1024 B, c128, delete | 16.14 | 16.16 | 1.03 | 9271 | 8998 | 0.98 | 16 | 16 |  |
| 4096 B, c1, put | 9.31 | 7.98 | 0.89 | 181 | 190 | 1.05 | 1000 | 1000 |  |
| 4096 B, c1, get | 0.21 | 0.22 | 1.00 | 7183 | 7236 | 1.03 | 0 | 0 |  |
| 4096 B, c1, head | 0.10 | 0.10 | 1.00 | 14814 | 15042 | 1.02 | 0 | 0 |  |
| 4096 B, c1, overwrite | 7.21 | 7.08 | 0.99 | 185 | 187 | 1.01 | 1000 | 1000 |  |
| 4096 B, c1, delete | 7.07 | 7.02 | 1.00 | 204 | 189 | 0.93 | 1000 | 1000 |  |
| 4096 B, c32, put | 12.18 | 12.39 | 1.00 | 3184 | 3169 | 0.97 | 64 | 64 |  |
| 4096 B, c32, get | 2.69 | 2.51 | 0.93 | 24240 | 25485 | 1.08 | 0 | 0 |  |
| 4096 B, c32, head | 3.83 | 1.52 | 0.59 | 34067 | 38198 | 1.18 | 0 | 0 |  |
| 4096 B, c32, overwrite | 14.22 | 12.46 | 0.88 | 3048 | 3186 | 1.03 | 64 | 64 |  |
| 4096 B, c32, delete | 18.26 | 23.00 | 1.17 | 3082 | 3247 | 1.08 | 64 | 64 |  |
| 4096 B, c128, put | 18.57 | 16.22 | 0.86 | 8584 | 8750 | 1.02 | 16 | 16 |  |
| 4096 B, c128, get | 10.36 | 9.33 | 0.92 | 22278 | 25052 | 1.12 | 0 | 0 |  |
| 4096 B, c128, head | 26.82 | 14.72 | 0.67 | 35831 | 38664 | 1.06 | 0 | 0 |  |
| 4096 B, c128, overwrite | 17.39 | 16.30 | 0.98 | 8667 | 8742 | 1.03 | 16 | 16 |  |
| 4096 B, c128, delete | 16.82 | 15.96 | 0.98 | 8806 | 9123 | 1.06 | 16 | 16 |  |

gate: passed
