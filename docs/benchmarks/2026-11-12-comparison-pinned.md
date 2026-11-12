# Comparison run on pinned cores again: CosmoStore, SeaweedFS, Garage and RustFS, 12 Nov 2026

The 11 Nov pinned comparison (`2026-11-11-comparison-pinned.md`) again, on the same server and with the same
images, matrix and pinning. Only CosmoStore changed: it is built from `56cc1d2` (ceesafec 0.36.0, CeeSafe.Web
`c799f14`, ADR-0036 and ADR-0038), not `d509388`. Made with `tools/compare/compare.sh` (`CPUSET`, the client
pinned as on 11 Nov) and `tools/compare/report.py`.

## Environment

| | |
|---|---|
| Host | Debian 13, Linux 6.12; Intel Xeon E3-1245 V2 (4 cores, 8 threads); Intel SSDSC2KB480G7 (SATA SSD with power-loss protection); ext4 |
| Server | one at a time, Docker 29.3, `--cpuset-cpus 2,3` (two physical cores, no quota), host network, loopback |
| Client | `tools/bench` on the host, `taskset -c 0,1,4,5` (the other two physical cores, both threads); fixed seeds, every GET verified by MD5 |
| Matrix | 0 B, 4 KiB, 64 KiB, 1 MiB; concurrency 1, 32, 128; 2,000 operations a phase (small reads 6,000); 20 warm-up PUTs first |
| Load | The host also serves mail and SQL Server containers, on any core. The run began on a quiet host (load average 0.14); no other heavy work ran during it |
| Raw data | `2026-11-12-comparison-pinned.json` (the six runs, with each server's image) |

The servers and their configurations are those of 10 and 11 Nov: SeaweedFS 4.53 and Garage v2.5.0 each with fsync
on and as shipped; RustFS 1.0.4 once, since its default (`strict`) syncs. "Default" columns are not durable.

## Findings

- **CosmoStore leads the durable servers in 59 of the 60 cells.** The exception is 1 MiB deletes at concurrency
  128: 4,090/s against 4,730 for SeaweedFS with fsync (0.87 times).
- **1 MiB GETs are no longer the weak spot.** At concurrency 32 and 128 it served 1,539 and 1,231/s, against 948 to
  1,021 for SeaweedFS and RustFS: 1.21 to 1.51 times the fastest other server. On 11 Nov it was 0.59 to 0.67 times.
  At concurrency 1, 412/s against 289 to 301.
- **Small and medium reads:**
  - GETs of 4 KiB at concurrency 32 and 128: 26,400 to 26,700/s, 3.4 to 3.5 times RustFS (7,700);
  - GETs of 64 KiB: 12,000 and 10,400/s, 1.7 to 1.9 times RustFS (6,000 to 6,300);
  - HEADs: 32,200 to 33,300/s at concurrency 32 and 128, 2.4 to 2.9 times RustFS.
- **Small writes, durable:** 0 B and 4 KiB PUTs at concurrency 32 and 128 ran at 11,300 to 16,900/s, 3.2 to 9.4
  times the next durable server; 2.8 to 5.4 times SeaweedFS and Garage without fsync.
- **1 MiB PUTs:** 230/s at concurrency 32 and 265/s at 128, the fastest durable server (RustFS 187 and 243). The
  servers without fsync are within 10% either way.
- **Where a server without fsync is ahead:** at concurrency 1, small PUTs, overwrites and deletes (CosmoStore 0.80
  to 0.96 times Garage's or SeaweedFS's default), 1 MiB PUTs and overwrites (0.74 to 0.75 times Garage's default)
  and 1 MiB deletes (0.65 times). CosmoStore syncs every one of those writes; they do not.
- **Memory:** CosmoStore peaked at 279 MiB RSS (234 on 11 Nov; ADR-0036's pool of 32 body buffers), Garage at 121 to
  124, RustFS at 1,103, SeaweedFS at 1.7 GiB.
- **No errors** in any run.

## Against 11 Nov

Throughput and p99, this run over 11 Nov, geometric mean over each server's 60 phases:

| run | ops/s | p99 |
|---|---:|---:|
| CosmoStore | 1.20 | 0.84 |
| SeaweedFS, fsync | 1.00 | 1.00 |
| Garage, fsync | 0.99 | 1.02 |
| RustFS | 1.00 | 0.98 |
| SeaweedFS, default | 0.99 | 1.01 |
| Garage, default | 1.00 | 1.00 |

The other servers are within 2% of 11 Nov, so the setup held still and CosmoStore's gain is its own:

| CosmoStore, ops/s | 11 Nov (`d509388`) | 12 Nov (`56cc1d2`) | ratio |
|---|---:|---:|---:|
| 1 MiB GET, c32 | 632 | 1,539 | 2.44 |
| 1 MiB GET, c128 | 582 | 1,231 | 2.11 |
| 64 KiB GET, c32 | 5,520 | 12,016 | 2.18 |
| 4 KiB GET, c32 | 12,768 | 26,737 | 2.09 |
| 1 MiB PUT, c128 | 159 | 265 | 1.66 |
| small PUTs, overwrites and deletes | | | 1.16 to 1.28 |

Between the two builds: ADR-0036 (a body-buffer pool of 32), ceesafec 0.36.0's thread pool for `Async.blocking`
(G28; its own gate gave small GETs at concurrency 32 1.43 times), and ADR-0038 (CeeSafe.Web sending large writes
without a copy). Each change's own A/B is in its ADR and the ROADMAP.

## Anomalies and limits

- **p99 of 1 MiB GETs at concurrency 128:** 183 ms here, down from 267 ms on 11 Nov, but ADR-0038's A/B found it 20%
  above ADR-0037's 64 KiB build; that is still open.
- **Garage, 4 KiB GET:** the 48 ms p99 at concurrency 1 and 32 in both configurations (23 and 720/s) is still there,
  as on 10 and 11 Nov.
- **One run per configuration.** Differences under about 20% between servers should not be read as real.
- **Load average:** it reached 37 at the end, during RustFS's deletes, as on 11 Nov: RustFS's threads waiting on
  the disk, not CPU. RustFS ran last.
- **The rest is as on 10 Nov:**
  - this SSD's power-loss protection makes flushes fast;
  - only CosmoStore reports syncs and write amplification;
  - two cores per server suits a single-node store.

## Tables

Operations per second and p99 in ms, per operation, size and concurrency. "Default" columns are not durable.

#### put: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,656 | 988 | 842 | 361 | 1,757 | 1,956 |
| 0 B, 32 | 16,898 | 3,814 | 1,563 | 866 | 5,059 | 4,730 |
| 0 B, 128 | 12,160 | 3,853 | 1,806 | 765 | 4,420 | 3,966 |
| 4 KiB, 1 | 1,464 | 286 | 129 | 344 | 865 | 590 |
| 4 KiB, 32 | 11,363 | 1,215 | 310 | 858 | 2,125 | 1,596 |
| 4 KiB, 128 | 11,274 | 1,469 | 335 | 851 | 2,476 | 1,547 |
| 64 KiB, 1 | 765 | 239 | 108 | 297 | 609 | 524 |
| 64 KiB, 32 | 1,691 | 862 | 294 | 759 | 1,477 | 1,045 |
| 64 KiB, 128 | 1,787 | 840 | 293 | 763 | 1,530 | 1,033 |
| 1 MiB, 1 | 107 | 77 | 88 | 102 | 113 | 144 |
| 1 MiB, 32 | 230 | 149 | 158 | 187 | 220 | 253 |
| 1 MiB, 128 | 265 | 144 | 148 | 243 | 210 | 242 |

#### put: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.91 | 1.42 | 2.51 | 3.61 | 0.80 | 0.69 |
| 0 B, 32 | 5.53 | 16.26 | 44.41 | 69.39 | 12.77 | 13.50 |
| 0 B, 128 | 51.14 | 78.59 | 204.73 | 269.09 | 75.34 | 70.32 |
| 4 KiB, 1 | 0.98 | 4.36 | 12.97 | 3.58 | 1.29 | 5.80 |
| 4 KiB, 32 | 4.33 | 56.53 | 218.65 | 59.13 | 51.50 | 38.83 |
| 4 KiB, 128 | 14.66 | 128.34 | 1163.66 | 220.34 | 81.80 | 183.02 |
| 64 KiB, 1 | 1.59 | 4.91 | 24.87 | 4.45 | 2.45 | 2.80 |
| 64 KiB, 32 | 25.90 | 68.09 | 246.70 | 62.63 | 35.12 | 59.16 |
| 64 KiB, 128 | 77.93 | 284.10 | 1503.38 | 222.21 | 169.36 | 231.82 |
| 1 MiB, 1 | 10.16 | 14.02 | 17.04 | 10.89 | 10.13 | 8.42 |
| 1 MiB, 32 | 197.46 | 604.20 | 408.20 | 214.91 | 422.64 | 208.40 |
| 1 MiB, 128 | 822.22 | 2577.41 | 2223.34 | 858.78 | 1900.21 | 959.61 |

#### get: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 8,721 | 2,458 | 4,122 | 3,178 | 2,436 | 4,079 |
| 0 B, 32 | 29,828 | 8,041 | 7,329 | 8,583 | 8,398 | 9,221 |
| 0 B, 128 | 33,000 | 8,537 | 7,000 | 8,394 | 8,326 | 8,048 |
| 4 KiB, 1 | 5,452 | 1,572 | 23 | 2,858 | 1,486 | 23 |
| 4 KiB, 32 | 26,737 | 4,489 | 716 | 7,727 | 4,450 | 719 |
| 4 KiB, 128 | 26,358 | 4,562 | 2,789 | 7,670 | 4,399 | 2,543 |
| 64 KiB, 1 | 2,559 | 1,204 | 1,047 | 1,645 | 1,203 | 936 |
| 64 KiB, 32 | 12,016 | 3,534 | 2,148 | 6,308 | 3,596 | 1,682 |
| 64 KiB, 128 | 10,352 | 3,675 | 1,799 | 6,042 | 3,654 | 1,515 |
| 1 MiB, 1 | 412 | 290 | 186 | 289 | 301 | 186 |
| 1 MiB, 32 | 1,539 | 1,020 | 489 | 948 | 1,011 | 468 |
| 1 MiB, 128 | 1,231 | 972 | 438 | 928 | 1,021 | 469 |

#### get: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.19 | 0.54 | 0.33 | 0.49 | 0.58 | 0.33 |
| 0 B, 32 | 3.01 | 9.04 | 8.79 | 14.69 | 7.46 | 7.81 |
| 0 B, 128 | 6.98 | 27.96 | 35.02 | 50.38 | 30.19 | 32.91 |
| 4 KiB, 1 | 0.26 | 0.77 | 48.00 | 0.56 | 0.87 | 48.01 |
| 4 KiB, 32 | 3.79 | 13.22 | 48.25 | 15.74 | 13.11 | 48.25 |
| 4 KiB, 128 | 10.35 | 49.29 | 52.78 | 52.35 | 70.83 | 77.37 |
| 64 KiB, 1 | 0.55 | 1.06 | 1.23 | 0.90 | 1.09 | 1.31 |
| 64 KiB, 32 | 6.74 | 20.28 | 21.54 | 18.39 | 19.31 | 26.35 |
| 64 KiB, 128 | 27.98 | 64.67 | 86.77 | 61.75 | 64.87 | 142.11 |
| 1 MiB, 1 | 3.27 | 4.71 | 6.74 | 4.02 | 4.12 | 6.88 |
| 1 MiB, 32 | 44.15 | 53.72 | 92.57 | 74.61 | 59.13 | 94.44 |
| 1 MiB, 128 | 182.47 | 254.32 | 338.62 | 252.28 | 216.78 | 302.97 |

#### head: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 8,798 | 1,913 | 4,162 | 3,777 | 1,914 | 4,134 |
| 0 B, 32 | 33,322 | 5,774 | 10,171 | 13,497 | 5,941 | 10,319 |
| 0 B, 128 | 33,313 | 6,473 | 7,437 | 12,295 | 6,250 | 10,311 |
| 4 KiB, 1 | 8,675 | 2,465 | 4,437 | 3,597 | 2,458 | 4,385 |
| 4 KiB, 32 | 32,681 | 8,409 | 9,632 | 13,248 | 8,175 | 10,364 |
| 4 KiB, 128 | 33,333 | 9,055 | 7,873 | 13,165 | 8,355 | 10,458 |
| 64 KiB, 1 | 8,850 | 2,453 | 4,600 | 4,151 | 2,481 | 4,323 |
| 64 KiB, 32 | 33,285 | 8,673 | 10,541 | 13,363 | 8,260 | 10,486 |
| 64 KiB, 128 | 32,195 | 8,768 | 7,947 | 13,144 | 9,044 | 10,408 |
| 1 MiB, 1 | 8,498 | 2,454 | 4,502 | 2,761 | 2,429 | 4,354 |
| 1 MiB, 32 | 33,093 | 7,799 | 10,381 | 12,278 | 8,572 | 10,473 |
| 1 MiB, 128 | 33,040 | 8,760 | 9,871 | 11,486 | 8,986 | 10,164 |

#### head: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.19 | 0.71 | 0.32 | 0.41 | 0.64 | 0.34 |
| 0 B, 32 | 2.06 | 12.49 | 5.55 | 14.33 | 10.19 | 4.93 |
| 0 B, 128 | 7.11 | 34.26 | 29.79 | 25.96 | 35.69 | 18.48 |
| 4 KiB, 1 | 0.18 | 0.53 | 0.29 | 0.47 | 0.51 | 0.30 |
| 4 KiB, 32 | 2.32 | 7.72 | 5.42 | 14.31 | 8.75 | 4.97 |
| 4 KiB, 128 | 6.37 | 22.97 | 26.60 | 22.68 | 33.74 | 18.98 |
| 64 KiB, 1 | 0.18 | 0.55 | 0.26 | 0.44 | 0.47 | 0.31 |
| 64 KiB, 32 | 1.51 | 6.09 | 4.69 | 14.45 | 9.06 | 4.90 |
| 64 KiB, 128 | 7.58 | 26.60 | 26.41 | 23.25 | 22.03 | 18.57 |
| 1 MiB, 1 | 0.18 | 0.51 | 0.28 | 0.47 | 0.56 | 0.29 |
| 1 MiB, 32 | 1.50 | 6.83 | 4.71 | 14.68 | 6.08 | 4.64 |
| 1 MiB, 128 | 5.82 | 23.32 | 22.20 | 27.01 | 22.26 | 23.42 |

#### overwrite: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,726 | 950 | 562 | 302 | 1,715 | 2,171 |
| 0 B, 32 | 17,982 | 3,751 | 915 | 777 | 4,862 | 3,962 |
| 0 B, 128 | 19,462 | 4,486 | 1,127 | 744 | 5,395 | 4,284 |
| 4 KiB, 1 | 1,422 | 289 | 163 | 290 | 802 | 561 |
| 4 KiB, 32 | 12,213 | 1,203 | 295 | 741 | 1,962 | 1,501 |
| 4 KiB, 128 | 13,665 | 1,301 | 332 | 732 | 2,299 | 1,545 |
| 64 KiB, 1 | 720 | 233 | 146 | 252 | 578 | 470 |
| 64 KiB, 32 | 1,736 | 826 | 272 | 653 | 1,351 | 970 |
| 64 KiB, 128 | 1,634 | 822 | 300 | 641 | 1,368 | 1,014 |
| 1 MiB, 1 | 104 | 76 | 82 | 93 | 109 | 139 |
| 1 MiB, 32 | 214 | 148 | 162 | 189 | 202 | 245 |
| 1 MiB, 128 | 245 | 143 | 177 | 235 | 209 | 240 |

#### overwrite: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.82 | 1.40 | 9.76 | 4.55 | 0.75 | 0.73 |
| 0 B, 32 | 2.88 | 17.09 | 107.35 | 62.17 | 12.83 | 19.88 |
| 0 B, 128 | 9.93 | 44.51 | 522.97 | 264.59 | 36.12 | 56.68 |
| 4 KiB, 1 | 1.01 | 4.27 | 10.33 | 4.72 | 1.86 | 2.29 |
| 4 KiB, 32 | 4.13 | 43.50 | 300.50 | 64.08 | 33.06 | 45.42 |
| 4 KiB, 128 | 15.11 | 155.50 | 976.57 | 254.33 | 91.30 | 174.07 |
| 64 KiB, 1 | 1.65 | 5.08 | 13.81 | 4.62 | 2.20 | 2.71 |
| 64 KiB, 32 | 20.06 | 65.43 | 269.49 | 71.55 | 41.94 | 62.26 |
| 64 KiB, 128 | 143.26 | 305.85 | 1056.06 | 337.14 | 202.19 | 273.15 |
| 1 MiB, 1 | 12.07 | 14.79 | 16.06 | 12.14 | 10.23 | 9.44 |
| 1 MiB, 32 | 204.33 | 655.14 | 388.13 | 240.99 | 1121.90 | 208.46 |
| 1 MiB, 128 | 859.60 | 2610.59 | 1613.06 | 780.19 | 1826.41 | 907.67 |

#### delete: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,801 | 1,112 | 510 | 95 | 2,239 | 2,032 |
| 0 B, 32 | 13,649 | 4,944 | 935 | 243 | 6,185 | 3,662 |
| 0 B, 128 | 10,570 | 5,196 | 926 | 233 | 6,195 | 4,628 |
| 4 KiB, 1 | 1,804 | 1,018 | 338 | 88 | 1,886 | 1,793 |
| 4 KiB, 32 | 13,157 | 3,290 | 751 | 227 | 3,253 | 3,666 |
| 4 KiB, 128 | 10,395 | 4,929 | 895 | 225 | 5,002 | 3,840 |
| 64 KiB, 1 | 1,748 | 1,042 | 356 | 67 | 1,766 | 1,898 |
| 64 KiB, 32 | 13,212 | 3,543 | 782 | 169 | 3,782 | 3,121 |
| 64 KiB, 128 | 10,321 | 4,009 | 903 | 164 | 4,780 | 4,197 |
| 1 MiB, 1 | 1,215 | 908 | 450 | 69 | 1,859 | 1,867 |
| 1 MiB, 32 | 4,349 | 3,864 | 782 | 204 | 3,695 | 3,496 |
| 1 MiB, 128 | 4,091 | 4,725 | 767 | 199 | 4,263 | 4,236 |

#### delete: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.77 | 1.22 | 9.89 | 13.23 | 0.59 | 0.84 |
| 0 B, 32 | 3.38 | 10.37 | 113.75 | 172.85 | 8.39 | 19.17 |
| 0 B, 128 | 16.76 | 38.51 | 703.28 | 814.23 | 37.23 | 52.90 |
| 4 KiB, 1 | 0.87 | 1.29 | 36.00 | 13.46 | 0.78 | 1.27 |
| 4 KiB, 32 | 3.19 | 41.33 | 123.88 | 196.49 | 38.60 | 22.16 |
| 4 KiB, 128 | 14.81 | 45.62 | 663.40 | 769.08 | 61.47 | 90.02 |
| 64 KiB, 1 | 0.92 | 1.27 | 28.91 | 19.94 | 0.97 | 1.34 |
| 64 KiB, 32 | 3.14 | 30.15 | 182.00 | 251.91 | 31.64 | 30.43 |
| 64 KiB, 128 | 14.86 | 94.57 | 573.74 | 1070.07 | 56.40 | 55.13 |
| 1 MiB, 1 | 1.25 | 3.55 | 14.20 | 31.57 | 0.71 | 1.42 |
| 1 MiB, 32 | 11.27 | 28.12 | 113.31 | 197.88 | 28.10 | 37.02 |
| 1 MiB, 128 | 34.32 | 47.13 | 779.95 | 844.07 | 83.28 | 66.79 |

#### Errors and memory

| run | errors | largest RSS, MiB |
|---|---:|---:|
| CosmoStore | 0 | 279 |
| SeaweedFS, fsync | 0 | 1778 |
| Garage, fsync | 0 | 121 |
| RustFS (fsync by default) | 0 | 1103 |
| SeaweedFS, default | 0 | 1704 |
| Garage, default | 0 | 124 |
