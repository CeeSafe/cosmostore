# Comparison run on pinned cores: CosmoStore, SeaweedFS, Garage and RustFS, 11 Nov 2026

The 10 Nov comparison (`2026-11-10-comparison.md`) again, on the same server and with the same images and matrix.
Two things changed. Each server now runs on two pinned cores, not under a CPU quota, and the client has two
physical cores of its own. CosmoStore is built from `d509388` (ceesafec 0.30.0, ADR-0034 and ADR-0035), not
`1aa265d`. Made with `tools/compare/compare.sh` (`CPUSET`, `CLIENT_CPUSET`) and `tools/compare/report.py`.
The run again with CosmoStore `56cc1d2` (ceesafec 0.36.0), 12 Nov, is `2026-11-12-comparison-pinned.md`.

## Environment

| | |
|---|---|
| Host | Debian 13, Linux 6.12; Intel Xeon E3-1245 V2 (4 cores, 8 threads); Intel SSDSC2KB480G7 (SATA SSD with power-loss protection); ext4 |
| Server | one at a time, Docker 29.3, `--cpuset-cpus 2,3` (two physical cores, no quota), host network, loopback |
| Client | `tools/bench` on the host, `taskset -c 0,1,4,5` (the other two physical cores, both threads); fixed seeds, every GET verified by MD5 |
| Matrix | 0 B, 4 KiB, 64 KiB, 1 MiB; concurrency 1, 32, 128; 2,000 operations a phase (small reads 6,000); 20 warm-up PUTs first |
| Load | The host also serves mail and SQL Server containers, on any core. The run began just after the build comparison below (load average 7.9, falling); no other heavy work ran during it |
| Raw data | `2026-11-11-comparison-pinned.json` (the six runs, with each server's image) |

The servers and their configurations are those of 10 Nov: SeaweedFS 4.53 and Garage v2.5.0 each with fsync on
and as shipped; RustFS 1.0.4 once, since its default (`strict`) syncs. "Default" columns are not durable.

## Findings

- **Small writes, durable: CosmoStore 3.5 to 8.0 times the next durable server.** 0 B and 4 KiB PUTs at
  concurrency 32 and 128 ran at 9,500 to 14,600/s. SeaweedFS with fsync, the next, ran at 1,200 to 3,900/s. CosmoStore
  is also 2.9 to 4.6 times SeaweedFS and Garage without fsync. Its p99 at concurrency 32 is 5.8 ms (0 B) and 10.3 ms
  (4 KiB), against 16 to 243 ms for the others.
- **Small reads: 1.5 to 3.7 times.**
  - GETs of 0 B at concurrency 32 and 128: 32,400 to 32,900/s, against 8,900 to 9,800 for the next.
  - GETs of 4 KiB: 11,700 to 12,800/s, against 7,700 to 7,800 for RustFS.
  - HEADs: 32,500 to 33,800/s, 2.4 to 2.7 times RustFS.
- **64 KiB:**
  - PUTs: 1,680 to 1,750/s, 2.1 times SeaweedFS with fsync and ahead of every server without it.
  - GETs: 5,500/s at concurrency 32 and 5,000/s at 128. That is 1.4 to 1.5 times SeaweedFS but 0.87 and 0.78 times
    RustFS (6,300 to 6,400/s).
- **1 MiB:**
  - **PUTs:** in the middle, at 159 to 167/s at concurrency 32 and 128, against 147 to 252. RustFS leads the durable servers, at 233/s
    at concurrency 128.
  - **GETs are still CosmoStore's weak spot:** 632/s at concurrency 32 and 582/s at 128, against 930 to 1,050 for
    SeaweedFS and RustFS (0.59 to 0.67 times). That is up from 459 to 465/s on 10 Nov, and at concurrency 1 it is
    the fastest (337/s against 186 to 303).
- **Deletes:** 8,500 to 10,700/s for small objects at concurrency 32 and 128, against 3,500 to 5,200 for SeaweedFS
  with fsync. At 1 MiB and concurrency 128, SeaweedFS is ahead (4,760/s against 3,630).
- **Memory:** CosmoStore peaked at 234 MiB RSS, Garage at 124 to 138, RustFS at 1,064, SeaweedFS at 1.6 to 1.7 GiB.
- **No errors** in any run.

## Against 10 Nov

Throughput and p99, this run over 10 Nov, geometric mean over each server's 60 phases:

| run | ops/s | p99 |
|---|---:|---:|
| CosmoStore | 1.17 | 0.82 |
| SeaweedFS, fsync | 1.04 | 0.96 |
| Garage, fsync | 1.04 | 0.92 |
| RustFS | 1.09 | 1.12 |
| SeaweedFS, default | 1.02 | 1.01 |
| Garage, default | 1.04 | 0.95 |

The other servers moved 2 to 9%: the setup is fairer, but it did not change their ranking. CosmoStore's larger gain
is its own: ADR-0034 (large GETs), ADR-0035 (small requests) and ceesafec 0.30.0's CRC32C (G31). Four builds of
CosmoStore were run on pinned cores (two rounds, alternating), on GETs:

| build | 64 KiB, c32 | 64 KiB, c128 | 1 MiB, c32 | 1 MiB, c128 |
|---|---:|---:|---:|---:|
| `1aa265d` (10 Nov) | 4,240 | 3,970 | 414 | 426 |
| `d98531b` (ADR-0034) | 4,160 | 3,950 | 451 | 427 |
| `f7a52bd` (ADR-0035, ceesafec 0.24.2) | 4,200 | 3,980 | 447 | 434 |
| `d509388` (ceesafec 0.30.0) | 4,650 | 4,510 | 505 | 463 |

These ran with the client on cores 4 to 7 (see below), so their level is below the tables'. Between builds, the
CRC32C instruction gives 7 to 14% on GETs of 64 KiB and 1 MiB, and ADR-0034 9% on 1 MiB GETs at concurrency 32. The
perf gate on the same cores (5 rounds, all sizes up to 1 MiB, the client in the server's cores) gave 0.30.0 1.19
and 1.20 times on 1 MiB GETs, 1.06 on 1 MiB PUTs, and no change on small requests.

## Anomalies and limits

- **A first pinned run was discarded.** It put the client on cores 4 to 7. On this CPU, cpu N and cpu N+4 are the
  two threads of one core, so the client shared the servers' cores 2 and 3 (through 6 and 7). It cost CosmoStore
  most, the fastest server: 64 KiB GETs ran at 4,550/s against 5,520 here. `compare.sh` now documents this next to
  `CLIENT_CPUSET`.
- **Garage, 4 KiB GET:** the 48 ms p99 at every concurrency, in both configurations, is still there (10 Nov).
- **One run per configuration.** Differences under about 20% between servers should not be read as real; the
  build table above alternates two rounds.
- **Load average:** during RustFS's deletes, it reached 40 to 44. These were RustFS's threads waiting on the disk,
  not CPU: no other work was running. RustFS ran last, and no other run overlapped it.
- **The rest is as on 10 Nov:**
  - this SSD's power-loss protection makes flushes fast;
  - only CosmoStore reports syncs and write amplification;
  - two cores per server suits a single-node store.

## Tables

Operations per second and p99 in ms, per operation, size and concurrency. "Default" columns are not durable.

#### put: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,431 | 942 | 838 | 363 | 1,747 | 2,042 |
| 0 B, 32 | 14,627 | 3,871 | 1,621 | 869 | 4,764 | 4,333 |
| 0 B, 128 | 13,144 | 3,706 | 1,486 | 859 | 4,456 | 4,436 |
| 4 KiB, 1 | 1,217 | 278 | 128 | 345 | 856 | 618 |
| 4 KiB, 32 | 9,511 | 1,201 | 308 | 873 | 2,059 | 1,590 |
| 4 KiB, 128 | 11,244 | 1,401 | 337 | 865 | 2,454 | 1,491 |
| 64 KiB, 1 | 710 | 244 | 106 | 298 | 607 | 503 |
| 64 KiB, 32 | 1,684 | 805 | 292 | 761 | 1,479 | 1,023 |
| 64 KiB, 128 | 1,747 | 824 | 281 | 768 | 1,524 | 1,022 |
| 1 MiB, 1 | 97 | 77 | 89 | 102 | 111 | 147 |
| 1 MiB, 32 | 167 | 150 | 160 | 183 | 221 | 252 |
| 1 MiB, 128 | 159 | 147 | 147 | 233 | 211 | 241 |

#### put: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1.06 | 1.40 | 2.62 | 3.59 | 0.81 | 0.67 |
| 0 B, 32 | 5.80 | 17.17 | 48.65 | 80.33 | 15.94 | 15.72 |
| 0 B, 128 | 59.59 | 85.95 | 222.31 | 255.53 | 73.26 | 54.08 |
| 4 KiB, 1 | 1.10 | 4.43 | 10.97 | 4.20 | 1.53 | 4.09 |
| 4 KiB, 32 | 10.27 | 59.27 | 242.62 | 54.03 | 58.58 | 42.90 |
| 4 KiB, 128 | 14.23 | 150.57 | 1035.84 | 252.12 | 78.29 | 214.87 |
| 64 KiB, 1 | 1.71 | 4.95 | 18.72 | 4.31 | 2.18 | 4.33 |
| 64 KiB, 32 | 21.64 | 72.87 | 265.24 | 63.89 | 34.64 | 57.18 |
| 64 KiB, 128 | 80.99 | 321.97 | 1147.83 | 265.45 | 163.46 | 278.39 |
| 1 MiB, 1 | 12.63 | 13.80 | 14.93 | 11.79 | 11.31 | 8.71 |
| 1 MiB, 32 | 312.28 | 667.22 | 425.88 | 223.77 | 394.58 | 201.36 |
| 1 MiB, 128 | 1444.71 | 2608.79 | 1498.68 | 827.14 | 1826.79 | 843.39 |

#### get: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 8,907 | 2,460 | 4,378 | 3,203 | 2,472 | 4,345 |
| 0 B, 32 | 32,382 | 8,222 | 7,634 | 8,508 | 8,504 | 9,774 |
| 0 B, 128 | 32,876 | 8,715 | 6,990 | 8,436 | 8,942 | 7,508 |
| 4 KiB, 1 | 5,006 | 1,539 | 23 | 2,850 | 1,525 | 23 |
| 4 KiB, 32 | 12,768 | 4,475 | 720 | 7,735 | 4,287 | 719 |
| 4 KiB, 128 | 11,680 | 4,372 | 2,800 | 7,790 | 4,635 | 2,551 |
| 64 KiB, 1 | 2,439 | 1,214 | 1,054 | 1,638 | 1,215 | 935 |
| 64 KiB, 32 | 5,520 | 3,639 | 2,101 | 6,333 | 3,661 | 1,663 |
| 64 KiB, 128 | 4,974 | 3,528 | 1,705 | 6,389 | 3,677 | 1,506 |
| 1 MiB, 1 | 337 | 297 | 186 | 289 | 303 | 187 |
| 1 MiB, 32 | 632 | 1,052 | 491 | 948 | 1,003 | 471 |
| 1 MiB, 128 | 582 | 985 | 445 | 927 | 1,004 | 466 |

#### get: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.18 | 0.56 | 0.30 | 0.49 | 0.56 | 0.31 |
| 0 B, 32 | 2.20 | 9.23 | 9.29 | 14.78 | 7.31 | 7.74 |
| 0 B, 128 | 8.24 | 24.92 | 35.96 | 48.71 | 27.54 | 31.24 |
| 4 KiB, 1 | 0.33 | 0.86 | 47.99 | 0.55 | 0.87 | 48.00 |
| 4 KiB, 32 | 5.86 | 12.98 | 48.25 | 15.99 | 14.06 | 48.22 |
| 4 KiB, 128 | 21.35 | 54.87 | 55.18 | 48.58 | 47.81 | 81.51 |
| 64 KiB, 1 | 0.55 | 1.05 | 1.11 | 0.94 | 1.02 | 1.31 |
| 64 KiB, 32 | 10.81 | 18.77 | 22.17 | 18.63 | 18.24 | 26.37 |
| 64 KiB, 128 | 43.95 | 74.06 | 94.21 | 57.30 | 64.84 | 149.64 |
| 1 MiB, 1 | 3.62 | 4.10 | 6.63 | 3.92 | 3.95 | 6.92 |
| 1 MiB, 32 | 67.05 | 54.58 | 91.17 | 77.25 | 55.61 | 95.18 |
| 1 MiB, 128 | 266.81 | 241.70 | 337.85 | 239.24 | 204.93 | 309.20 |

#### head: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 8,884 | 1,922 | 4,157 | 3,738 | 1,907 | 4,152 |
| 0 B, 32 | 33,532 | 6,023 | 9,086 | 12,937 | 5,827 | 10,520 |
| 0 B, 128 | 33,787 | 6,435 | 7,474 | 12,638 | 6,662 | 10,285 |
| 4 KiB, 1 | 8,615 | 2,467 | 4,394 | 3,606 | 2,491 | 4,403 |
| 4 KiB, 32 | 32,504 | 8,222 | 10,114 | 13,541 | 8,719 | 10,348 |
| 4 KiB, 128 | 33,651 | 8,565 | 7,544 | 13,300 | 8,735 | 10,465 |
| 64 KiB, 1 | 8,844 | 2,475 | 4,341 | 3,938 | 2,465 | 4,385 |
| 64 KiB, 32 | 33,054 | 8,485 | 10,460 | 13,472 | 8,222 | 10,566 |
| 64 KiB, 128 | 33,682 | 8,704 | 7,291 | 12,051 | 8,749 | 10,608 |
| 1 MiB, 1 | 8,659 | 2,360 | 4,391 | 2,815 | 2,425 | 4,383 |
| 1 MiB, 32 | 24,172 | 8,162 | 10,512 | 12,546 | 7,584 | 10,327 |
| 1 MiB, 128 | 33,194 | 8,817 | 10,389 | 12,001 | 8,324 | 10,582 |

#### head: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.18 | 0.65 | 0.32 | 0.42 | 0.68 | 0.32 |
| 0 B, 32 | 2.01 | 9.71 | 6.73 | 14.75 | 13.38 | 4.66 |
| 0 B, 128 | 7.83 | 35.19 | 27.73 | 25.38 | 36.80 | 19.13 |
| 4 KiB, 1 | 0.18 | 0.55 | 0.30 | 0.48 | 0.47 | 0.30 |
| 4 KiB, 32 | 2.22 | 9.07 | 4.88 | 14.36 | 6.07 | 5.25 |
| 4 KiB, 128 | 6.50 | 31.54 | 30.31 | 22.67 | 29.26 | 18.25 |
| 64 KiB, 1 | 0.17 | 0.47 | 0.30 | 0.51 | 0.47 | 0.30 |
| 64 KiB, 32 | 1.58 | 6.60 | 4.69 | 14.38 | 8.88 | 4.62 |
| 64 KiB, 128 | 5.76 | 27.37 | 33.76 | 30.59 | 29.37 | 17.95 |
| 1 MiB, 1 | 0.18 | 0.61 | 0.30 | 0.48 | 0.49 | 0.30 |
| 1 MiB, 32 | 3.08 | 7.96 | 4.65 | 14.50 | 10.60 | 4.74 |
| 1 MiB, 128 | 5.66 | 23.38 | 18.26 | 35.99 | 34.04 | 18.03 |

#### overwrite: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,405 | 956 | 569 | 324 | 1,731 | 1,945 |
| 0 B, 32 | 14,610 | 3,726 | 1,102 | 759 | 4,879 | 3,635 |
| 0 B, 128 | 20,821 | 4,225 | 1,326 | 688 | 5,391 | 4,354 |
| 4 KiB, 1 | 1,199 | 276 | 163 | 307 | 797 | 579 |
| 4 KiB, 32 | 9,820 | 1,213 | 281 | 759 | 1,945 | 1,410 |
| 4 KiB, 128 | 11,166 | 1,338 | 345 | 737 | 2,195 | 1,477 |
| 64 KiB, 1 | 689 | 236 | 149 | 257 | 567 | 461 |
| 64 KiB, 32 | 1,694 | 790 | 287 | 658 | 1,327 | 970 |
| 64 KiB, 128 | 1,692 | 800 | 303 | 637 | 1,378 | 1,033 |
| 1 MiB, 1 | 94 | 77 | 82 | 94 | 110 | 138 |
| 1 MiB, 32 | 166 | 146 | 166 | 189 | 203 | 243 |
| 1 MiB, 128 | 161 | 144 | 174 | 243 | 210 | 240 |

#### overwrite: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1.07 | 1.43 | 10.19 | 4.08 | 0.73 | 0.74 |
| 0 B, 32 | 5.07 | 17.74 | 90.59 | 64.32 | 13.61 | 17.09 |
| 0 B, 128 | 11.12 | 51.41 | 529.88 | 344.02 | 43.09 | 52.52 |
| 4 KiB, 1 | 1.14 | 4.56 | 10.33 | 4.24 | 1.70 | 2.16 |
| 4 KiB, 32 | 4.42 | 43.21 | 279.09 | 62.84 | 31.56 | 44.17 |
| 4 KiB, 128 | 14.44 | 160.37 | 949.48 | 253.04 | 93.79 | 207.18 |
| 64 KiB, 1 | 1.75 | 5.07 | 11.00 | 4.54 | 2.24 | 2.64 |
| 64 KiB, 32 | 50.98 | 74.20 | 279.08 | 70.98 | 47.14 | 64.83 |
| 64 KiB, 128 | 93.56 | 303.87 | 928.44 | 298.22 | 186.69 | 259.83 |
| 1 MiB, 1 | 11.64 | 14.30 | 16.35 | 12.09 | 10.44 | 8.79 |
| 1 MiB, 32 | 272.61 | 626.14 | 449.77 | 245.69 | 1062.12 | 222.11 |
| 1 MiB, 128 | 1447.24 | 2560.80 | 1412.00 | 813.70 | 1821.09 | 1018.13 |

#### delete: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,429 | 1,063 | 532 | 94 | 2,223 | 1,830 |
| 0 B, 32 | 10,664 | 4,901 | 950 | 240 | 5,795 | 3,704 |
| 0 B, 128 | 8,894 | 5,180 | 924 | 238 | 6,498 | 4,218 |
| 4 KiB, 1 | 1,541 | 980 | 353 | 88 | 1,872 | 1,912 |
| 4 KiB, 32 | 10,536 | 3,496 | 877 | 225 | 3,657 | 4,049 |
| 4 KiB, 128 | 8,547 | 4,816 | 979 | 223 | 5,253 | 3,748 |
| 64 KiB, 1 | 1,540 | 996 | 343 | 66 | 1,809 | 1,936 |
| 64 KiB, 32 | 10,578 | 4,252 | 750 | 168 | 4,122 | 3,231 |
| 64 KiB, 128 | 8,608 | 4,623 | 849 | 164 | 5,129 | 4,374 |
| 1 MiB, 1 | 984 | 1,022 | 422 | 67 | 1,653 | 1,931 |
| 1 MiB, 32 | 3,758 | 3,233 | 828 | 202 | 4,119 | 3,247 |
| 1 MiB, 128 | 3,632 | 4,760 | 910 | 197 | 4,845 | 3,882 |

#### delete: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1.18 | 1.27 | 7.40 | 13.91 | 0.59 | 0.88 |
| 0 B, 32 | 3.88 | 11.54 | 84.63 | 177.65 | 14.29 | 17.51 |
| 0 B, 128 | 19.13 | 38.63 | 1030.48 | 763.80 | 32.94 | 79.93 |
| 4 KiB, 1 | 0.99 | 1.35 | 31.81 | 13.60 | 0.78 | 1.14 |
| 4 KiB, 32 | 4.12 | 45.65 | 122.25 | 201.63 | 26.94 | 23.55 |
| 4 KiB, 128 | 18.96 | 43.30 | 912.13 | 756.81 | 45.37 | 85.78 |
| 64 KiB, 1 | 1.05 | 1.36 | 30.51 | 19.35 | 0.91 | 1.21 |
| 64 KiB, 32 | 4.10 | 13.03 | 105.60 | 254.08 | 18.32 | 30.08 |
| 64 KiB, 128 | 17.71 | 57.80 | 876.02 | 1084.00 | 56.94 | 69.60 |
| 1 MiB, 1 | 1.42 | 1.34 | 14.19 | 32.30 | 0.92 | 1.24 |
| 1 MiB, 32 | 9.52 | 45.17 | 99.22 | 200.38 | 16.82 | 22.49 |
| 1 MiB, 128 | 38.48 | 42.13 | 755.84 | 857.12 | 64.67 | 82.96 |

#### Errors and memory

| run | errors | largest RSS, MiB |
|---|---:|---:|
| CosmoStore | 0 | 234 |
| SeaweedFS, fsync | 0 | 1625 |
| Garage, fsync | 0 | 138 |
| RustFS (fsync by default) | 0 | 1064 |
| SeaweedFS, default | 0 | 1699 |
| Garage, default | 0 | 124 |
