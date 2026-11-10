# ADR-0035: Small requests with less zeroing and a cached signing key

**Status:** accepted for M4 (`src/s3/server.cee`, `src/s3/sigv4.cee`, `src/s3/request.cee`, `src/s3/post.cee`),
11 Nov 2026

## Context

- **The ROADMAP asked for a profile at concurrency 128,** to see whether G30 (an AsyncMutex unlock wakes waiters
  with a `write` to a pipe) still costs at staging.
- **The Mac was too loaded** (load average 72), so the profile ran on the Debian server of the comparison run, in
  the `cosmostore-prof` container (2 CPUs): 150 `gdb` stack samples of the server during 4 KiB PUTs at concurrency
  128 (`docs/benchmarks/2026-11-11-c128-profile.md`).
- **G30 did not show:** no sample was in the pipe's `write`, and one in the AsyncMutex.
- **The event loop's thread was busy 87% of the time.** Two costs stood out:

  | Share | Where |
  |---:|---|
  | 13% | zeroing the body buffer: `bodyStep` gave a 4 KiB PUT 20 KiB, the body and 16 KiB of slack for aws-chunked framing (ADR-0022), zeroed for each request |
  | 6% | deriving the SigV4 signing key: four HMAC-SHA256s over the secret, the date, the region and the service, for each request, though it changes once a day |

  The rest: SigV4's canonical request and signature (10%), MD5 for the ETag (9%), HTTP parsing and the socket.

## Decision

1. **The body buffer's slack is 1 KiB** (`BODY_SLACK`), from 16 KiB. A 4 KiB PUT zeroes 5 KiB. aws-chunked framing
   is about 90 bytes a chunk; a body whose framing does not fit takes one more read, which the chunk decoder already
   handles (reads end anywhere).
2. **The signing key is cached, one per credential** (`SigningKeyCache`, `cachedSigningKey`), for the last date and
   region it was derived for:
   - **No lock:** a sequence lock over atomics. A write makes `seq` odd, stores the scope and the key's four words,
     then makes it even again; a read that sees `seq` odd, or changed between its two loads, is a miss and derives
     the key. A write that finds another under way is skipped.
   - **Only what fits is cached:** an 8-byte date and a region of up to 16 bytes, packed into words and compared
     whole (the region's length too); service `s3` only. Anything else is derived as before.
   - **Header, query and chunk signatures** use it through `S3Request.verify`, and POST policies through
     `checkPostSignature`. The key sits in memory next to the secret it is derived from.

## Rejected

- **A pool of small body buffers,** which would need no zeroing at all: sizes vary, the channel is first in, first
  out (ADR-0034 found a FIFO pool hurt the cache), and a quarter of the zeroing is left.
- **A `Mutex` around the cache:** async code must not block (N0295).
- **A key per day computed at startup:** the region comes from the client, and the clock's day changes while the
  server runs.

## Consequences

`tools/perf_gate.sh` on the Debian server, 5 rounds, sizes 0 and 4 KiB, concurrency 32 and 128:

| Group | Slack, against `d98531b`: p99 / ops/s | Cache, against the slack (two runs): p99 / ops/s |
|---|---:|---:|
| small writes, c32 | 1.03 / 1.02 | 1.03, 1.02 / 1.10, 1.08 |
| small metadata reads, c32 | 0.96 / 1.02 | 1.12, 1.18 / 1.13, 1.11 |
| small writes, c128 | 1.00 / 1.04 | 1.08, 1.03 / 1.00, 1.10 |
| small metadata reads, c128 | 0.95 / 0.99 | 1.12, 1.07 / 1.06, 1.13 |
| small GETs, c32 | 1.02 / 1.00 | 1.08, 1.08 / 1.05, 1.02 |
| small GETs, c128 | 1.03 / 1.01 | 1.06, 0.99 / 1.04, 1.01 |

- **4 KiB PUTs** with the slack: 1.07 times at concurrency 32 and 1.04 at 128 (phase medians), p99 unchanged.
- **The cache** raises throughput 8 to 13% in four of six groups, in both runs. Every gate passed.
- **The p99 of small reads rose 7 to 18% while their p50 fell 15 to 28%.** These phases' p99 is not the requests'
  own cost: at concurrency 32 a 0-byte GET's p50 is 1 ms and its p99 23 ms, a stall that some requests wait
  behind, and with faster requests more of them do. The stall is the next thing to find (ROADMAP).
- **G30 stays open** in CEESAFE_GAPS.md, but costs nothing measurable at staging now.

## Tests

- **`signingKeyCacheKeepsOneScope`** (`src/s3/s3_unit_tests.cee`): the cached key equals `signingKey`'s; another day
  or region is derived and replaces it; a prefix of the region misses; a region over 16 bytes is not cached and is
  still derived correctly.
- **The SigV4 examples** (5 tests), `tools/s3_smoke.sh`, `tools/tls_smoke.sh`, the s3-tests subset, and the boto3,
  Go, JavaScript and rclone checks, which sign with header, query, chunked and POST signatures. `ceesafec test` (136).
