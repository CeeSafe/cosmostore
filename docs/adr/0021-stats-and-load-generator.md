# ADR-0021: The stats endpoint and the M4 load generator

**Status:** accepted for M4 slice 1 (`src/s3/stats.cee`, `tools/bench/`, `tools/bench.sh`), 9 Nov 2026

## Context

M4's exit asks for documented performance targets that are met, and p99 regression gates. The architecture's benchmark
plan (§9) lists what to measure:
- ops/s and MiB/s;
- p50, p95, p99 and p99.9;
- syncs per 1,000 PUTs and write amplification;
- RAM per object;
- listing at scale, and recovery time.

It also says to establish a baseline before aiming at targets. Until now, the only numbers were from `cosmostore
bench`, which calls the store directly with one writer and no HTTP.

## Decision

1. **The store counts its work** (`StoreCounters`, `ObjectStore.counters()`), cumulative since it opened:
   - payload bytes accepted (objects and parts);
   - bytes written: journal records, extent files and checkpoints;
   - compaction's copied bytes and removed segments;
   - checkpoints taken.
   Together with the journal's sync count, these give syncs per 1,000 writes, and write amplification (bytes
   written per payload byte), from the server's own view.
2. **`GET /_cosmostore/stats`** returns them as JSON, with the object, segment, upload and extent counts and the
   server's request count.
   - It is SigV4-authenticated like any request. `_cosmostore` can never be a bucket, because `_` is not allowed in
     bucket names.
   - It is a monitoring read, not part of S3.
3. **`tools/bench`** is a load generator in Go. It signs with the Go SDK's SigV4 signer, but sends its own HTTP
   requests, so SDK overhead stays out of the numbers.
   - **Phases:** for each object size and concurrency, it runs PUT, GET, HEAD, overwrite and DELETE on its own keys.
   - **Bodies** come from the seed and the key, and every GET is checked by MD5. A run is repeatable, and a wrong byte
     is an error.
   - **Measured:** ops/s, MiB/s, and p50, p95, p99, p99.9 and max per phase. Around each phase it reads the stats
     endpoint for syncs per 1,000 operations and write amplification. With `-pid`, it also samples the server's RSS.
   - **Output:** a Markdown table and, with `-json`, the results with their environment (host, CPU, OS, Go version,
     seed, and a label for the commit and settings).
   - Requests use UNSIGNED-PAYLOAD, as an SDK over TLS often sends them; the MD5 check covers the bytes instead.
4. **`tools/bench.sh`** runs the generator against a fresh `cosmostore serve`, with the server's PID, and runs fsck
   on the store afterwards. Runs that are kept go in `docs/benchmarks/`, with their JSON.

## Rejected

- **Warp, or another external tool, as the only generator.** The plan asks for fixed seeds and correctness checks.
  An external tool can be added beside this one for comparison runs (M4's last item).
- **Stats in the log, or at shutdown.** A benchmark needs them before and after each phase, while the server runs.
- **Unauthenticated stats.** Object and byte counts say something about the data.

## Consequences

- **The first baseline** (`docs/benchmarks/2026-11-09-baseline.md`) is the reference for M4's targets.
- **The p99 regression gates** M4 asks for will compare runs of this generator.
