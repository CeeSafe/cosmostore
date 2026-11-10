# Large GETs, 10 Nov 2026 (ADR-0034)

The comparison run found CosmoStore's 1 MiB GETs at half SeaweedFS's rate. This records the profile, the variants
tried, and what each did.

## Environment

| | |
|---|---|
| Profile | Apple M1, `sample` for 5 s while 30 runs of `tools/bench` read 300 1 MiB objects at concurrency 8; load average 26 to 62 from other sessions |
| Gates | The Debian server of the comparison run (Xeon E3-1245 V2, 8 MiB L3; data-center SSD), in the `cosmostore-prof` container (2 CPUs); `tools/perf_gate.sh`, base `9c8bc1b`; load average under 10 |
| CRC32C | 64 MiB, 20 times, best of five runs, on the M1 (load average about 60) |

## Profile, before

Busy samples, outside the event loop's idle `kevent` (about 2,900):

| Samples | Where |
|---:|---|
| 811 | `Crc32c.update` |
| 769 | `thread_start` (`Async.blocking`, G28) |
| 534 | `sendmsg` |
| 341 | `Vector.resize` zeroing the 1 MiB buffer |
| 155, 82 | `pread`, `open` |

After the loop change and a pool (of 32 then): `Crc32c.update` 740, `sendmsg` 430, `thread_start` 369, `pread` 159,
no zeroing; 1 MiB GETs at 701 to 761/s, from 394 to 508.

## Variants on the Debian server

1 MiB GETs at concurrency 32, 5 rounds each, head against base (the first row also in a 3-round run of the full
matrix, with the same result):

| Variant | Throughput | p99 |
|---|---:|---:|
| all three changes, pool of 32 | 1.08 | **1.52** |
| loop and pool of 32, no `takeReady` | 1.04 | **1.51** |
| pool of 32 alone, with the last read | 1.01 | **1.58** |
| loop alone, no pool | 0.95 | 0.99 |
| loop and `takeReady`, no pool | 0.94 | 1.02 |
| **all three, pool of 4** (adopted) | 1.02 | 0.99 |

The pool of 32 is what raised the p99. The adopted change, at both concurrencies:

| 1 MiB | Throughput | p99 |
|---|---:|---:|
| GET, concurrency 1 | 1.20 | 0.89 |
| GET, concurrency 32 | 1.02 | 0.99 |
| PUT, concurrency 1 | 1.06 | 0.96 |
| PUT, concurrency 32 | 1.00 | 0.97 |

## CRC32C

| Implementation | MB/s |
|---|---:|
| lib/std `Crc32c` (slicing-by-8) | 1,476 |
| C, `__crc32cd`, one chain (`clang -O2 -march=armv8-a+crc`) | 6,986 |

The C program is a measurement only; CosmoStore calls no C. CEESAFE_GAPS G31.

## Conclusions

- On Linux, the zeroing and the worker threads cost less than on macOS; the CRC32C bounds large GETs. The gap to
  SeaweedFS stays until CeeSafe can use the CPU's CRC instruction (G31).
- A buffer pool must stay small enough for the cache: a first-in, first-out pool cycles through all its buffers.
