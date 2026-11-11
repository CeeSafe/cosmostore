# ADR-0037: A write buffer of 64 KiB

**Status:** accepted for M4 (`src/s3/serve.cee`), 11 Nov 2026

## Context

- **ceesafec 0.36.0 removed a thread per `Async.blocking` call** (CeeSafe ADR 0094, G28), and ADR-0036 removed the
  zeroing of fresh body buffers. A new profile of 1 MiB GETs at concurrency 32
  (`docs/benchmarks/2026-11-11-get-1mib-profile-0.36.md`, 60 `gdb` samples, server on two pinned cores) found the
  event loop still never idle:

  | Share | Where |
  |---:|---|
  | 58% | `sendmsg`, writing responses into sockets |
  | 15% | `Exchange.write` copying the body into CeeSafe.Web's write buffer (`OwnedBuffer.append`) |
  | 10% | `ceesafe_async_blocking_start` waking a parked worker (`futex`) |
  | 17% | the rest: parsing, SigV4, allocations |

- **The write buffer was CeeSafe.Web's default, 16 KiB** (`Limits.writeBufferBytes`). `Exchange.write` copies a
  body into it and sends it whenever it fills, so a 1 MiB GET took 64 copies and 64 `sendmsg` calls, each also
  waiting on the socket.
- **Each HTTP/1.1 connection holds two such buffers** (`out` and `pending`, CeeSafe.Web's `web_http1`), for the
  connection's life.

## Decision

**`Limits.writeBufferBytes` is 64 KiB** (`s3Server` in `src/s3/serve.cee`). A 1 MiB GET goes out in 16 writes.
Nothing else changes.

## Rejected

Alternating rounds of 1 MiB PUTs then GETs on the Debian server (server on cores 2 and 3, `tools/bench` on 0, 1, 4
and 5, no quota), 3 rounds, `a84b9e1` with ceesafec 0.36.0; RSS of the server after a load at concurrency 128:

| Write buffer | GETs/s, c32 | GETs/s, c128 | Peak RSS | RSS after |
|---:|---:|---:|---:|---:|
| 16 KiB (before) | 1,019 to 1,106 | 712 to 838 | 271 MiB | 232 MiB |
| **64 KiB** | **1,290 to 1,322** | **911 to 1,011** | **285 MiB** | **241 MiB** |
| 256 KiB | 1,231 to 1,322 | 1,017 to 1,048 | 336 MiB | 298 MiB |
| 1 MiB | 1,226 to 1,245 | 1,063 to 1,069 | | |

- **256 KiB and 1 MiB:** a little more at concurrency 128, for 57 MiB more after a load at 256 KiB, and four times
  that at 1 MiB (two buffers per connection, held while it is open).
- **No copy at all:** `Exchange.write` could send a slice larger than its buffer directly, after the head, when
  nothing is pending. That removes the 15% copy too, but it is a CeeSafe.Web change, for its own ADR.
- **`sendfile`:** as in ADR-0036, it would skip `DurableFile` and the CRC check on reads.

## Consequences

`tools/perf_gate.sh`, base `a84b9e1` (16 KiB), 5 rounds, client and server on cores 2 and 3, as ADR-0036's gate.
It passed, for 64 KiB and for 256 KiB:

| Group | 64 KiB: throughput | p99 | 256 KiB: throughput | p99 |
|---|---:|---:|---:|---:|
| large GETs, c1 | 1.12 | 0.92 | 1.17 | 0.91 |
| large GETs, c32 | 1.11 | 0.84 | 1.11 | 0.82 |
| large writes (2 groups) | 1.00 | 1.01 to 1.02 | 1.00 to 1.02 | 1.02 to 1.03 |
| small requests (6 groups) | 0.99 to 1.01 | 1.00 to 1.07 | 0.99 to 1.01 | 1.00 to 1.10 |

- **The gate's gain is smaller than the A/B's** because client and server share two cores there.
- **Memory:** about 9 MiB more after a load at concurrency 128, and 128 KiB for each open connection.
- **What is left:** `sendmsg` (the kernel copying into the socket), the copy into the write buffer, and the wake
  of a pooled worker for each read.

## Tests

The server's code is unchanged; only a limit is. Run on ceesafec 0.36.0 and CeeSafe.Web `82a3a73`, all passing:

- `ceesafec test` (136, no leaks);
- `tools/s3_smoke.sh` and `tools/tls_smoke.sh`;
- the s3-tests subset (252);
- the boto3, Go, JavaScript and rclone checks.
