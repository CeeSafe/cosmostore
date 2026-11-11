# ADR-0036: A body-buffer pool of 32

**Status:** accepted for M4 (`src/s3/server.cee`), 11 Nov 2026

## Context

- **The pinned comparison run** (`docs/benchmarks/2026-11-11-comparison-pinned.md`) left 1 MiB GETs at concurrency
  32 and 128 at 0.59 to 0.67 times SeaweedFS and RustFS. The ROADMAP asked for a profile.
- **The profile** (`docs/benchmarks/2026-11-11-get-1mib-profile.md`, 60 `gdb` samples, server on two pinned
  cores) found the event loop's thread never idle:

  | Share | Where |
  |---:|---|
  | 52% | `sendmsg`, writing responses into sockets |
  | 15% | a fresh 1 MiB body buffer, zeroed (`takeBodyBuffer`) |
  | 15% | starting the worker thread of each `Async.blocking` read (G28) |
  | 18% | the rest |

- **The pool held 4 buffers** (ADR-0034), so at concurrency 32 most GETs allocated one. glibc gives a freed 1 MiB
  block back to the system, so each allocation maps new pages and faults them in.
- **ADR-0034 rejected a pool of 32.** It raised 1 MiB GETs' p99 at concurrency 32 by half, for no throughput. That
  was measured inside a `--cpus 2` quota, whose stalls ADR-0035 later found in the p99, and with lib/std's software
  CRC32C, then the largest cost of a large GET.

## Decision

**The pool keeps 32 full-size body buffers** (`BODY_BUFFERS`), from 4. Nothing else changes: PUT and GET take a
1 MiB buffer from it when it has one and give it back, and a miss allocates as before.

## Rejected

- **Allocating on the worker thread,** inside the first `Async.blocking` read, so that the event loop never zeroes:
  no gain (669 to 693 GETs/s against 664 to 715). The cost is the fresh pages, wherever they are touched.
- **16 buffers:** 827 GETs/s at concurrency 32 but 661 at 128, for 186 MiB idle.
- **128 buffers:** 846 GETs/s at concurrency 128 too, but 251 MiB idle. Concurrency 32 gains nothing over 32.
- **`sendfile` for GET bodies,** for the socket copy: it bypasses `DurableFile` and the CRC check on reads, which
  ADR-0034 kept.

## Consequences

`tools/perf_gate.sh` on the Debian server, base `d509388` (4 buffers), 5 rounds, client and server on cores 2 and 3
without a quota, as ADR-0034's gate but pinned. The gate passed:

| 1 MiB | Throughput | p99 |
|---|---:|---:|
| GET, concurrency 1 | 1.00 times | 1.04 |
| GET, concurrency 32 | 1.13 | 0.90 |
| PUT, concurrency 32 | 1.05 | 0.95 |
| small requests (6 groups) | 0.99 to 1.01 | 0.93 to 1.01 |

- **Client on other cores** (as the comparison run): 1 MiB GETs at concurrency 32 went from 664 to 715/s to 819 to
  859/s, and at 128 from 591 to 632/s to 643 to 794/s, in alternating rounds.
- **ADR-0034's p99 rise did not come back:** its cause was the quota, or the CRC, not the cache.
- **Memory:** after a load at concurrency 128, the server's idle RSS is about 220 MiB, against 100 MiB with 4
  buffers. For scale, in the comparison run Garage used about 125 MiB, RustFS 1 GiB and SeaweedFS 1.7 GiB.
- **Still to do:** a thread per `Async.blocking` call (G28, 15% of the event loop) is CeeSafe's, and the next
  step. The socket copy remains.

## Tests

The pool's code is unchanged; only its size is. Run on ceesafec 0.30.0 and CeeSafe.Web `82a3a73`, all passing:

- `ceesafec test` (136, no leaks);
- `tools/s3_smoke.sh` and `tools/tls_smoke.sh`;
- the s3-tests subset (252);
- the boto3, Go, JavaScript and rclone checks.
