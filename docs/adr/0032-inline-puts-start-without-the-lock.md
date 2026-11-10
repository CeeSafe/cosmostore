# ADR-0032: Inline PUTs start without the store's lock

**Status:** accepted for M4 (`src/store/object_store.cee`, `src/s3/objects.cee`, `src/s3/serve.cee`), 10 Nov 2026

## Context

- **A PUT took the store's lock twice** (ADR-0031):
  - `startPut`: the bucket check, admission and a writer;
  - `stagePut`: the checks again (`checkPut`), then staging.
- **Each round costs the event loop an unlock.** With a waiter, the unlock wakes it with a `write` system call
  (CEESAFE_GAPS G30). After ADR-0031 that was the largest part of the loop's overhead at concurrency 128.
- **ADR-0031 kept both rounds:** `startPut` refuses a missing bucket or a full store before the body is read. Merging
  the rounds would read the body first.
- **For an inline object, that early refusal saves little.** Its declared size is at most `inlineMaxBytes` (128 KiB),
  so at most that much is read before the refusal. And `checkPut` repeats both checks under the second lock.
- **`newWriter` reads nothing that changes while the store is open:**
  - the extent directory;
  - `inlineMaxBytes` and `extentMaxBytes`;
  - a clone of the channel on which an abandoned writer queues its extents.

## Decision

1. **`ObjectStore.writerFactory`** gives those values as a `WriterFactory`. Its `newWriter` makes the same writer
   `ObjectStore.newWriter` does, without the store. `keepsInline(size)` says whether a declared size stays inline.
2. **`serve` makes one when the store opens** and keeps it in `S3App.writers`.
3. **PutObject (`startPutObject`) uses it for an object whose declared size keeps it inline:** no lock round before
   the body. The bucket check and admission run when the PUT is staged (`checkPut`, under the lock that staging
   takes anyway).
4. **A larger object starts as before** (`startPut`), refused, if it must be, before its body is read.
5. **POST object keeps `startPut`.** Its form gives no size before the file, so it passes 0. Without the lock, a POST
   to a missing bucket would read the whole file before being refused.

Nothing about durability changes. A writer from the factory is the store's writer: its object stages, commits and is
discarded the same way. Its extents are made in the same directory, and its drop queues them on the same channel.

## Rejected

- **One lock round for every PUT.** A large PUT to a missing bucket, or to a full store, would be refused only after
  its body is read (ADR-0031, Rejected).
- **A bucket check without the lock**, so that inline PUTs to a missing bucket are still refused early. The bucket map
  is the store's, under its lock. A request for a missing bucket is a client error, and reading at most 128 KiB
  first costs little.

## Consequences

- **An inline PUT takes the store's lock once,** to stage.
- **A small gain, mostly within the noise** (`tools/perf_gate.sh`, 3 rounds against `5c81a49`;
  `docs/benchmarks/2026-11-10-inline-puts-without-the-lock.md`):
  - small writes at concurrency 128: 1.03 times the throughput, 0.95 times the p99; overwrites gained most (0 B at
    11,418/s from 9,991; p99 0.80 to 0.90 times in five of six overwrite phases at concurrency 32 and 128);
  - concurrency 1 and 32 unchanged, syncs per 1,000 writes unchanged; the gate passed.
- **The change is kept for what it removes:** a lock round and its unlock per small PUT, with no cost found. The
  remaining overhead at concurrency 128 needs a profile before the next change.
- **A PUT of an inline-sized object to a missing bucket or a full store** is refused after its body is read, with the
  same error as before (NoSuchBucket, InsufficientStorage).

## Tests

- **`factoryWritersAreTheStores`** (`src/store/group_tests.cee`):
  - `keepsInline` matches `inlineMaxBytes`;
  - a factory writer's inline object stages without committing and is published with the batch;
  - a missing bucket is refused at staging, inline or spilled; the spilled object's extents are removed;
  - a spilled object is staged and committed;
  - an abandoned writer's extents are reaped by the next commit;
  - all of it reads back after a reopen.
- **`tools/s3_smoke.sh`:** a small PUT and a large PUT to a missing bucket both give NoSuchBucket.
- **The s3-tests subset** (252) includes `test_object_write_to_nonexist_bucket`.
- `ceesafec test` (132), `tools/tls_smoke.sh`, the boto3, Go, JavaScript and rclone checks.
