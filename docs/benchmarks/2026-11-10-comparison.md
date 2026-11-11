# Comparison run: CosmoStore, SeaweedFS, Garage and RustFS, 10 Nov 2026

ROADMAP M4: "a comparison run against SeaweedFS, Garage and RustFS on identical hardware, with raw data published."
Each server ran alone on the same host, in a container with the same CPU limit, its data on the same filesystem,
measured by `tools/bench` (ADR-0021). `tools/compare/compare.sh` runs one server; `tools/compare/report.py` makes the
tables below.

## Environment

| | |
|---|---|
| Host | Debian 13, Linux 6.12; Intel Xeon E3-1245 V2 (4 cores, 8 threads, 2012); Intel SSDSC2KB480G7 (data-center SATA SSD with power-loss protection); ext4 |
| Containers | Docker 29.3, one server at a time, `--cpus 2`, host network, listening on loopback |
| Client | `tools/bench` on the host, not CPU-limited; fixed seeds, every GET verified by MD5 |
| Matrix | 0 B, 4 KiB, 64 KiB, 1 MiB; concurrency 1, 32, 128; 2,000 operations a phase (small reads 6,000: `-read-repeat 3`); 20 warm-up PUTs first |
| Load | The host also serves mail and SQL Server containers; its load average stayed under 3.5 of 8 |
| Raw data | `2026-11-10-comparison.json` (the six runs, with each server's image) |

## The servers and their durability

| Run | Version | Configuration |
|---|---|---|
| CosmoStore | `1aa265d` | as built: every write synced before it is acknowledged (group commit, ADR-0022) |
| SeaweedFS, fsync | 4.53 (`chrislusf/seaweedfs:4.53`) | `weed server -s3`, `-volume.max=0`; `fs.configure -locationPrefix=/buckets/ -fsync=true`: the volume's data and index, and the filer's leveldb, synced before the reply (its own group commit) |
| SeaweedFS, default | 4.53 | the same without the fsync rule: no sync |
| Garage, fsync | v2.5.0 (`dxflrs/garage:v2.5.0`) | one node, LMDB, `metadata_fsync = true`, `data_fsync = true`, `compression_level = "none"` |
| Garage, default | v2.5.0 | `metadata_fsync` and `data_fsync` false (their defaults), zstd level 1 (its default) |
| RustFS | 1.0.4 (`rustfs/rustfs:1.0.4`) | one disk, `RUSTFS_DURABILITY_MODE=strict`, its default: data, metadata and directory entries synced. Its default is durable, so it ran once |

The "fsync" columns are the like-for-like comparison: every acknowledged write is on disk. The "default" columns are
what these servers do as shipped, and lose acknowledged writes on a power cut.

## Findings

- **Small writes, durable: CosmoStore 2.7 to 7.7 times the next server.** 0 B and 4 KiB PUTs at concurrency 32 and
  128: 8,200 to 10,400/s, against 1,200 to 3,500 for SeaweedFS with fsync (the next), 330 to 1,600 for Garage and
  840 to 880 for RustFS. The p99 is also the lowest: 4.7 to 6.3 ms at concurrency 32, against 23 to 214 ms. CosmoStore
  durable is also ahead of SeaweedFS and Garage without fsync (1,700 to 4,700/s).
- **Small reads: 1.5 to 2.9 times.** GET of 0 B and 4 KiB at concurrency 32 and 128: 10,600 to 23,400/s, against
  7,100 to 9,100 for the next (RustFS for 4 KiB; Garage or SeaweedFS without fsync for 0 B). HEAD at 22,400 to
  24,200/s, about twice RustFS and 2.4 to 4.4 times SeaweedFS and Garage.
- **Deletes:** 7,700 to 9,100/s for small objects at concurrency 32 and 128, against 3,500 to 4,800 for SeaweedFS
  with fsync; RustFS deletes at 60 to 180/s.
- **1 MiB objects: CosmoStore is in the middle, and behind in reads.**
  - PUT: 160/s at concurrency 32 and 128, against 145 to 252 for the others. Its p99 at concurrency 128 (1.5 s) is
    Garage's, below SeaweedFS's (2.6 s), and 1.8 times RustFS's.
  - GET: 459 to 465/s at concurrency 32 and 128, against 920 to 930 for SeaweedFS and 760 for RustFS. This is the
    one place CosmoStore is clearly behind, and the next thing to look at: with 2 CPUs, the read path's copies and
    checksum checks may bound it.
  - At concurrency 1, 85 PUTs/s against 78 to 147.
- **Memory:** CosmoStore peaked at 216 MiB RSS, Garage at 121 to 123, RustFS at 783, SeaweedFS (master, volume, filer
  and S3 in one process) at 1.7 to 1.8 GiB.
- **No errors** in any run.

## Anomalies and limits

- **Garage, 4 KiB GET:** a p50 of 44 ms at every concurrency, in both configurations (23/s at concurrency 1, 708 at
  32); 0 B and 64 KiB are fast. A fixed delay of about 40 ms on one size looks like a delayed-ACK interaction (Nagle). 4 KiB is just above
  Garage's 3,072-byte inline threshold, so it takes the block path. Not investigated: worth reporting upstream.
- **One run per configuration,** not paired rounds like the p99 gate. A configuration's run took 3 to 10 minutes.
  Differences under about 20% should not be read as real.
- **The client shared the host,** without a CPU limit. It loaded every server equally, but at high request rates its
  own work is part of what is measured.
- **This SSD has power-loss protection**, so its flushes are fast: CosmoStore made 1,312 synced PUTs a second at
  concurrency 1 here, against about 200 on the M1 reference machine. Servers that sync more often per write
  (Garage's LMDB, RustFS's several files per object) would fall further behind on a disk without it.
- **Syncs per 1,000 writes and write amplification** come from CosmoStore's stats endpoint, so only CosmoStore has
  them (63 to 64 syncs per 1,000 at concurrency 32, as on the M1).
- **Two CPUs per server** suits a single-node store; a server built to spread over more cores could do relatively
  better with more.
- **`--cpus 2` is a quota, not two cores** (found 11 Nov 2026, ADR-0035): each 100 ms, a container may use 200 ms of
  CPU on any of the host's 8 threads, then waits for the next period. A server busy on many threads at once uses its
  quota early and stalls for the rest of the period, which shows in the p99, not in the throughput. Measured on
  CosmoStore with the client inside the quota: 0-byte GETs' p99 30 ms with the quota, 7.7 ms on 2 pinned cores, at
  about the same rate. Here the client was outside it, but the p99 columns may still hold such stalls, likely more
  for servers that spread over many threads. `CPUSET=2,3` pins the cores instead: the run again on pinned cores, 11 Nov, is `2026-11-11-comparison-pinned.md`.

## Tables

Operations per second and p99 in ms, per operation, size and concurrency. "Default" columns are not durable.

#### put: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,312 | 946 | 813 | 360 | 1,776 | 2,118 |
| 0 B, 32 | 10,409 | 3,429 | 1,591 | 871 | 4,748 | 4,356 |
| 0 B, 128 | 9,442 | 3,505 | 1,429 | 874 | 4,648 | 4,135 |
| 4 KiB, 1 | 1,132 | 281 | 129 | 334 | 842 | 652 |
| 4 KiB, 32 | 9,023 | 1,169 | 328 | 883 | 2,140 | 1,684 |
| 4 KiB, 128 | 8,211 | 1,395 | 350 | 836 | 2,298 | 1,679 |
| 64 KiB, 1 | 643 | 237 | 113 | 278 | 618 | 589 |
| 64 KiB, 32 | 1,729 | 758 | 323 | 756 | 1,431 | 1,062 |
| 64 KiB, 128 | 1,594 | 798 | 278 | 734 | 1,499 | 993 |
| 1 MiB, 1 | 85 | 78 | 101 | 99 | 113 | 147 |
| 1 MiB, 32 | 160 | 150 | 252 | 174 | 221 | 188 |
| 1 MiB, 128 | 161 | 145 | 169 | 234 | 212 | 184 |

#### put: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1.08 | 1.43 | 3.01 | 3.88 | 0.77 | 0.62 |
| 0 B, 32 | 6.25 | 22.63 | 57.56 | 70.70 | 14.03 | 18.67 |
| 0 B, 128 | 62.38 | 78.64 | 223.51 | 186.90 | 47.55 | 73.29 |
| 4 KiB, 1 | 1.17 | 4.34 | 34.31 | 3.77 | 1.47 | 4.00 |
| 4 KiB, 32 | 4.67 | 53.39 | 213.85 | 60.78 | 33.82 | 35.45 |
| 4 KiB, 128 | 23.45 | 140.15 | 765.68 | 225.79 | 112.33 | 164.57 |
| 64 KiB, 1 | 5.62 | 4.95 | 32.22 | 4.35 | 2.02 | 2.32 |
| 64 KiB, 32 | 43.18 | 74.11 | 223.96 | 67.80 | 39.49 | 68.89 |
| 64 KiB, 128 | 88.85 | 323.67 | 1387.30 | 229.18 | 146.56 | 251.34 |
| 1 MiB, 1 | 12.96 | 13.89 | 11.33 | 10.96 | 10.35 | 8.20 |
| 1 MiB, 32 | 274.07 | 694.67 | 217.54 | 221.69 | 417.56 | 283.42 |
| 1 MiB, 128 | 1469.11 | 2604.51 | 1440.66 | 825.86 | 1794.37 | 1193.38 |

#### get: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 7,661 | 2,447 | 4,304 | 3,177 | 2,446 | 4,117 |
| 0 B, 32 | 22,538 | 7,662 | 7,825 | 7,970 | 7,745 | 9,148 |
| 0 B, 128 | 23,352 | 7,959 | 7,167 | 7,863 | 8,000 | 7,315 |
| 4 KiB, 1 | 4,767 | 1,580 | 23 | 2,902 | 1,587 | 23 |
| 4 KiB, 32 | 11,200 | 4,129 | 708 | 7,160 | 4,184 | 708 |
| 4 KiB, 128 | 10,600 | 4,067 | 2,828 | 7,086 | 4,166 | 2,404 |
| 64 KiB, 1 | 2,247 | 1,245 | 1,056 | 1,629 | 1,242 | 939 |
| 64 KiB, 32 | 5,958 | 3,309 | 1,991 | 5,785 | 3,285 | 1,635 |
| 64 KiB, 128 | 5,761 | 3,353 | 1,539 | 5,569 | 3,433 | 1,507 |
| 1 MiB, 1 | 231 | 273 | 179 | 287 | 296 | 184 |
| 1 MiB, 32 | 465 | 930 | 425 | 764 | 938 | 401 |
| 1 MiB, 128 | 459 | 918 | 388 | 757 | 898 | 400 |

#### get: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.20 | 0.57 | 0.32 | 0.49 | 0.60 | 0.32 |
| 0 B, 32 | 3.82 | 8.01 | 16.24 | 13.56 | 7.63 | 5.72 |
| 0 B, 128 | 23.32 | 30.52 | 35.41 | 33.57 | 31.09 | 44.89 |
| 4 KiB, 1 | 0.32 | 0.81 | 48.00 | 0.53 | 0.80 | 48.01 |
| 4 KiB, 32 | 4.86 | 14.08 | 48.21 | 13.94 | 13.45 | 48.18 |
| 4 KiB, 128 | 22.43 | 58.09 | 52.07 | 36.13 | 67.40 | 92.07 |
| 64 KiB, 1 | 0.58 | 1.04 | 1.16 | 0.92 | 1.07 | 1.32 |
| 64 KiB, 32 | 7.94 | 18.11 | 38.20 | 16.48 | 19.32 | 37.69 |
| 64 KiB, 128 | 39.87 | 70.76 | 98.46 | 45.77 | 66.91 | 159.02 |
| 1 MiB, 1 | 5.11 | 4.92 | 6.25 | 4.10 | 4.08 | 6.58 |
| 1 MiB, 32 | 87.72 | 62.05 | 102.83 | 80.69 | 61.73 | 108.40 |
| 1 MiB, 128 | 400.45 | 209.34 | 421.60 | 239.45 | 244.00 | 376.25 |

#### head: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 7,817 | 1,897 | 4,329 | 3,643 | 1,908 | 4,134 |
| 0 B, 32 | 23,039 | 5,418 | 9,522 | 11,405 | 5,471 | 9,593 |
| 0 B, 128 | 23,714 | 5,831 | 7,384 | 11,413 | 5,936 | 9,319 |
| 4 KiB, 1 | 7,975 | 2,476 | 4,437 | 3,630 | 2,452 | 4,400 |
| 4 KiB, 32 | 22,969 | 7,718 | 9,567 | 11,839 | 7,742 | 9,682 |
| 4 KiB, 128 | 24,039 | 8,031 | 7,502 | 11,973 | 8,010 | 9,595 |
| 64 KiB, 1 | 8,328 | 2,474 | 4,410 | 4,006 | 2,455 | 4,309 |
| 64 KiB, 32 | 22,434 | 7,911 | 9,394 | 12,433 | 7,964 | 9,567 |
| 64 KiB, 128 | 24,205 | 8,005 | 7,509 | 11,989 | 7,979 | 9,654 |
| 1 MiB, 1 | 8,152 | 2,426 | 4,431 | 3,024 | 2,479 | 4,388 |
| 1 MiB, 32 | 23,141 | 7,722 | 9,426 | 10,408 | 7,782 | 9,670 |
| 1 MiB, 128 | 23,955 | 8,238 | 9,323 | 10,101 | 7,210 | 9,384 |

#### head: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 0.19 | 0.67 | 0.30 | 0.42 | 0.66 | 0.32 |
| 0 B, 32 | 3.71 | 11.02 | 5.21 | 4.98 | 10.95 | 5.14 |
| 0 B, 128 | 23.28 | 38.43 | 35.12 | 17.91 | 36.71 | 20.70 |
| 4 KiB, 1 | 0.19 | 0.50 | 0.29 | 0.48 | 0.56 | 0.30 |
| 4 KiB, 32 | 3.75 | 7.92 | 5.15 | 4.53 | 8.25 | 5.10 |
| 4 KiB, 128 | 27.59 | 27.69 | 34.81 | 16.13 | 29.14 | 20.00 |
| 64 KiB, 1 | 0.17 | 0.52 | 0.28 | 0.46 | 0.51 | 0.31 |
| 64 KiB, 32 | 3.75 | 6.75 | 5.37 | 4.15 | 6.61 | 5.22 |
| 64 KiB, 128 | 24.42 | 31.34 | 35.92 | 17.18 | 34.92 | 20.72 |
| 1 MiB, 1 | 0.18 | 0.56 | 0.29 | 0.44 | 0.49 | 0.31 |
| 1 MiB, 32 | 3.70 | 7.54 | 7.50 | 6.20 | 6.61 | 5.05 |
| 1 MiB, 128 | 22.77 | 27.42 | 19.23 | 26.43 | 36.42 | 20.52 |

#### overwrite: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,322 | 960 | 525 | 298 | 1,774 | 1,868 |
| 0 B, 32 | 10,201 | 3,522 | 995 | 752 | 4,560 | 3,492 |
| 0 B, 128 | 13,314 | 3,698 | 1,177 | 716 | 5,102 | 4,012 |
| 4 KiB, 1 | 1,186 | 271 | 157 | 290 | 815 | 629 |
| 4 KiB, 32 | 7,121 | 1,105 | 275 | 733 | 1,922 | 1,507 |
| 4 KiB, 128 | 8,920 | 1,281 | 308 | 718 | 2,223 | 1,662 |
| 64 KiB, 1 | 680 | 231 | 146 | 238 | 579 | 529 |
| 64 KiB, 32 | 1,553 | 716 | 260 | 620 | 1,283 | 970 |
| 64 KiB, 128 | 1,595 | 784 | 307 | 608 | 1,348 | 1,045 |
| 1 MiB, 1 | 83 | 76 | 82 | 89 | 110 | 140 |
| 1 MiB, 32 | 156 | 146 | 194 | 174 | 216 | 184 |
| 1 MiB, 128 | 159 | 144 | 203 | 221 | 208 | 186 |

#### overwrite: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1.08 | 1.39 | 9.63 | 4.16 | 0.80 | 0.68 |
| 0 B, 32 | 5.48 | 20.18 | 190.08 | 71.85 | 14.27 | 19.49 |
| 0 B, 128 | 11.68 | 72.95 | 492.15 | 205.92 | 42.94 | 58.89 |
| 4 KiB, 1 | 1.18 | 4.47 | 12.29 | 4.22 | 1.68 | 2.02 |
| 4 KiB, 32 | 5.90 | 49.29 | 264.22 | 75.32 | 34.33 | 44.20 |
| 4 KiB, 128 | 16.64 | 177.45 | 897.28 | 207.88 | 83.26 | 151.29 |
| 64 KiB, 1 | 1.76 | 5.00 | 12.38 | 4.88 | 2.51 | 3.31 |
| 64 KiB, 32 | 22.13 | 94.80 | 277.88 | 75.34 | 47.98 | 74.49 |
| 64 KiB, 128 | 85.50 | 309.72 | 845.66 | 256.45 | 173.72 | 221.61 |
| 1 MiB, 1 | 13.12 | 14.34 | 13.96 | 15.26 | 10.34 | 8.73 |
| 1 MiB, 32 | 311.61 | 615.34 | 315.46 | 214.64 | 403.97 | 288.18 |
| 1 MiB, 128 | 1365.61 | 2614.66 | 1089.35 | 1031.43 | 1871.97 | 1169.04 |

#### delete: operations per second

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1,424 | 1,123 | 456 | 84 | 2,283 | 1,662 |
| 0 B, 32 | 9,128 | 4,560 | 692 | 179 | 5,979 | 3,647 |
| 0 B, 128 | 7,712 | 4,823 | 910 | 179 | 5,940 | 4,344 |
| 4 KiB, 1 | 1,393 | 975 | 330 | 80 | 1,934 | 1,834 |
| 4 KiB, 32 | 8,973 | 3,549 | 559 | 171 | 3,623 | 3,665 |
| 4 KiB, 128 | 7,762 | 4,687 | 828 | 175 | 4,490 | 3,827 |
| 64 KiB, 1 | 1,405 | 972 | 323 | 60 | 1,941 | 1,840 |
| 64 KiB, 32 | 9,069 | 4,014 | 592 | 117 | 3,804 | 3,193 |
| 64 KiB, 128 | 7,809 | 4,310 | 682 | 116 | 4,652 | 3,585 |
| 1 MiB, 1 | 953 | 937 | 318 | 64 | 1,870 | 1,837 |
| 1 MiB, 32 | 3,644 | 3,291 | 683 | 152 | 4,097 | 2,978 |
| 1 MiB, 128 | 3,342 | 4,229 | 744 | 151 | 5,372 | 4,047 |

#### delete: p99, ms

| size, concurrency | CosmoStore | SeaweedFS, fsync | Garage, fsync | RustFS (fsync by default) | SeaweedFS, default | Garage, default |
|---|---:|---:|---:|---:|---:|---:|
| 0 B, 1 | 1.05 | 1.17 | 10.53 | 14.09 | 0.55 | 0.80 |
| 0 B, 32 | 4.55 | 12.12 | 221.49 | 204.39 | 8.59 | 21.85 |
| 0 B, 128 | 19.27 | 43.04 | 980.59 | 892.11 | 38.31 | 55.49 |
| 4 KiB, 1 | 1.05 | 1.36 | 21.81 | 14.37 | 0.83 | 1.06 |
| 4 KiB, 32 | 4.22 | 35.24 | 226.49 | 209.87 | 28.63 | 43.04 |
| 4 KiB, 128 | 17.47 | 41.69 | 547.02 | 1020.03 | 65.71 | 69.85 |
| 64 KiB, 1 | 1.03 | 1.32 | 24.49 | 18.85 | 0.88 | 1.30 |
| 64 KiB, 32 | 4.13 | 17.79 | 325.01 | 371.41 | 25.02 | 25.24 |
| 64 KiB, 128 | 17.15 | 48.59 | 601.21 | 1291.71 | 57.19 | 91.98 |
| 1 MiB, 1 | 1.39 | 2.55 | 21.66 | 18.51 | 1.00 | 1.19 |
| 1 MiB, 32 | 10.00 | 53.10 | 246.70 | 276.48 | 22.57 | 48.60 |
| 1 MiB, 128 | 47.35 | 48.77 | 591.26 | 1091.80 | 41.88 | 88.75 |

#### Errors and memory

| run | errors | largest RSS, MiB |
|---|---:|---:|
| CosmoStore | 0 | 216 |
| SeaweedFS, fsync | 0 | 1660 |
| Garage, fsync | 0 | 121 |
| RustFS (fsync by default) | 0 | 783 |
| SeaweedFS, default | 0 | 1824 |
| Garage, default | 0 | 123 |
