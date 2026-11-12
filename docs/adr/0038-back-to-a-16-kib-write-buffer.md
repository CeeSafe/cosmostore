# ADR-0038: Back to a 16 KiB write buffer

**Status:** accepted for M4 (`src/s3/serve.cee`, CI's `CEESAFE_WEB_REF`), 12 Nov 2026; supersedes ADR-0037

## Context

- **ADR-0037 raised `Limits.writeBufferBytes` to 64 KiB** because `Exchange.write` copied every body into the
  write buffer and sent it from there: 15% of the event loop's time on 1 MiB GETs, and 64 sends per GET at 16 KiB.
  It named the fix it did not make: send a large slice without the copy, a CeeSafe.Web change.
- **CeeSafe.Web now does that** (its ADR 0013 amendment 4, PR #12, merged as `c799f14`): over HTTP/1.1, once the
  buffer is empty, what is left of a write at least as large as the buffer goes to the socket as it is, after the
  head (and a chunk header, if chunked), in one vectored write. CosmoStore writes a GET's body in 1 MiB slices, so
  each slice now goes out in one write, whatever the buffer's size.
- **The 64 KiB buffer still costs memory:** each HTTP/1.1 connection holds two (`out` and `pending`), 128 KiB, for
  the connection's life, against 32 KiB at 16 KiB.

## Decision

- **CI pins CeeSafe.Web `c799f14`** (`CEESAFE_WEB_REF`), from `82a3a73`. Between them, besides the change above,
  are only the QUIC and HTTP/3 shims' fixes, fuzzing, docs and plans.
- **`s3Server` no longer sets `Limits.writeBufferBytes`:** it is CeeSafe.Web's default again, 16 KiB.

## Measurements

Debian server, server on cores 2 and 3, `tools/bench` on 0, 1, 4 and 5, no quota, 1 MiB PUTs then GETs, 3
alternating rounds. Base: `fe50ca3` (64 KiB, CeeSafe.Web `82a3a73`); head: this change (16 KiB, `c799f14`); both on
ceesafec 0.36.0.

| Build | GETs/s, c32 | p99, c32 (ms) | GETs/s, c128 | p99, c128 (ms) |
|---|---:|---:|---:|---:|
| 64 KiB, with the copy (`fe50ca3`) | 1,284 to 1,331 | 74 to 94 | 924 to 981 | 187 to 206 |
| **16 KiB, without the copy** | **1,333 to 1,360** | **64 to 81** | **1,218 to 1,343** | **223 to 278** |

- **Concurrency 128:** about 1.3 times the GETs. Its p99 rose by about a fifth, not yet explained; a likely
  reason is that more requests are in flight at once, each sent in one large write, so the slowest wait longer for
  their turn on two cores. The gate (concurrency 1 and 32) does not run at 128.
- **Concurrency 32:** a little more throughput, p99 within noise.
- **Memory:** after a load at concurrency 128, 228 and 264 MiB at 64 KiB, 250 and 199 MiB at 16 KiB. The run to run
  spread (the body-buffer pool, the allocator) hides the 12 MiB the smaller buffers save at 128 connections.

`tools/perf_gate.sh`, base `fe50ca3` against this change, 5 rounds, client and server on cores 2 and 3, as
ADR-0037's gate. It passed:

| Group | Throughput, head / base | p99, head / base |
|---|---:|---:|
| large GETs, c1 | 1.06 | 0.98 |
| large GETs, c32 | 1.08 | 1.00 |
| large writes (2 groups) | 0.98 to 1.00 | 1.00 to 1.02 |
| small requests (6 groups) | 1.00 to 1.01 | 0.96 to 1.00 |

The gate's gain is smaller than the A/B's, as in ADR-0037, because client and server share two cores there.

## Rejected

- **Keeping 64 KiB:** CeeSafe.Web's own A/B (ADR 0013 amendment 4) found 16 and 64 KiB alike once large writes
  skip the buffer (concurrency 32: 1,314 to 1,344 against 1,329 to 1,354 GETs/s), for four times the memory per
  connection.

## Tests

The server's code is unchanged; a limit is gone and the CeeSafe.Web pin moves. Run on ceesafec 0.36.0 and
CeeSafe.Web `c799f14`, all passing: `ceesafec check` and `fmt --check`; `ceesafec test` (136, no leaks);
`tools/s3_smoke.sh` and `tools/tls_smoke.sh`; the s3-tests subset (252); the boto3, Go, JavaScript and rclone checks.
CeeSafe.Web's test `large_writes_go_out_directly` checks the bytes such a write sends, chunked and with a declared
length.
