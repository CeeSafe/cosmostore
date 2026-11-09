# ADR-0031: Small PUTs on the event loop

**Status:** accepted for M4 (`src/storage/extent/extent.cee`, `src/store/object_store.cee`, `src/s3/objects.cee`),
10 Nov 2026

## Context

- **ROADMAP M4 plans journal shards and per-core appenders.** They pay off only if the device completes several
  flushes at once. A probe measured it: N writers, each appending 4 KiB to its own file and calling `F_FULLFSYNC`, for
  3 s each.

  | Writers | Syncs per second, in all | Each sync |
  |---:|---:|---:|
  | 1 | 221 | 4.5 ms |
  | 2 | 219 | 9.1 ms |
  | 4 | 289 | 13.9 ms |
  | 8 | 419 | 19.1 ms |

  The reference machine's SSD flushes about one at a time. Two journals get no more syncs than one, and eight get
  twice as many at four times the latency each.
- **At concurrency 8 and 32 the store already runs at the device's rate.** The M4 reference does about 200 syncs a
  second there, one batch per sync. Shards would split the same clients into smaller batches without adding syncs.
- **At concurrency 128 it does not.** Batches hold 50 to 60 writes, but a batch takes 10 to 12 ms against a 5 ms
  sync. About 6 ms a batch, or 100 µs a request, goes to serial work that is not the sync.
- **A profile found that work** (`sample`, 5 s of 128 B PUTs at concurrency 128). The event loop was busy 74% of the
  time:

  | Share of the loop | Where |
  |---:|---|
  | 19% | `Async.blocking` starting and joining a thread per call (CEESAFE_GAPS G28): 3 to 4 per PUT (`startPut`, `receiveBody`'s write and finish, `commitWith`) |
  | 20% | releasing the store's `AsyncMutex`, whose wake-up is a `write` system call: twice per PUT (`startPut`, `stagePut`) |
  | 3% | SigV4 |

  For an object kept inline (up to `inlineMaxBytes`, 128 KiB), none of the work behind those `Async.blocking` calls
  touches a file. The writer buffers the bytes, and staging appends to the batch in memory. Only staging into a full
  batch commits it, which is I/O.

## Decision

1. **The writer has in-memory steps** (`ObjectWriter`):
   - `fitsInline(n)`: whether n more bytes keep the object inline;
   - `writeInline`: appends them to the buffer and the MD5;
   - `finishInline`: completes an object that stayed inline, or gives null if it spilled into extents.
2. **The store stages an inline PUT without committing** (`putInlineDeferred`). It makes the checks of
   `putFinishedDeferred`, then encodes and stages the record, unless the batch must be committed first (full, or the
   segment is due to rotate). Then it stages nothing and gives null. It gives null for an object in extents too.
   `stageFinished` is now `encodePut`, `mustCommitBefore` and `stageEncoded`, shared by both paths.
3. **The S3 layer calls them directly, on the event loop,** for an object whose declared size is at most
   `inlineMaxBytes`:
   - `startPut`: the bucket check, admission and the writer;
   - `receiveBody`: each piece of the body, and the finish;
   - `stagePut`: an unconditional PUT.

   A larger object, a conditional PUT, and a full batch take the worker thread as before.
4. **The compiler proves it** (N0295): an async fn may not call anything that does I/O, transitively. Calling
   `ObjectWriter.finish` at the same place is refused, with the chain down to `DurableFile.syncData`.
5. **Group commit no longer queues requests for the turn** (ADR-0022 amendment). The first build of this change
   doubled throughput at concurrency 128, but broke batching at concurrency 32: 3 to 10 writes a batch instead of
   16, and 500 to 1,700 PUTs/s instead of 2,400 to 2,900. Requests already in the batch being cut queued for the
   commit turn behind the next leader, through syncs they did not need. Worker-thread steps had hidden that by
   spreading requests out. Now a request that finds a leader marked waits on that leader's barrier, and eight
   barriers are used in turn instead of two.
6. **Nothing about durability changes.** A staged PUT is published, and acknowledged, only after its batch's sync
   (ADR-0001, ADR-0022). The record and its bytes are those `stageFinished` wrote.

## Rejected

- **Journal shards on this device:** see the probe above. They stay in the plan for devices with parallel flushes
  (NVMe with power-loss protection, several disks), measured with the same probe first.
- **A yield before the leader cuts its batch** (one `Async.blocking` per batch, so requests already running stage
  first). It took batches at concurrency 32 from about 3 writes to 4 to 8, not to 16; the turn's queue was the cause.
- **Staging on a worker thread, keeping the rest:** 6,200 to 7,200 PUTs/s at concurrency 128, against 9,800 to
  11,100 with staging on the loop.
- **One lock round instead of two** (`startPut` and `stagePut`). `startPut` refuses a missing bucket or a full store
  before the body is read; merging would read the body first. It can follow if the unlock's cost still shows.
- **A thread pool in CosmoStore for `Async.blocking`.** G28 belongs in CeeSafe's runtime; avoiding the call where no
  I/O is done is right either way.

## Consequences

- **A small PUT starts no thread** unless its batch is full. Against the build before (`tools/perf_gate.sh`, 3
  rounds; `docs/benchmarks/2026-11-10-small-puts-on-the-loop.md`):
  - small writes at concurrency 128: 1.76 times the throughput and 0.56 times the p99 (0 B and 1 KiB PUTs at
    10,600 to 11,800/s, from 3,400 to 5,000, with p99 12 to 14 ms, from 37 to 48);
  - at concurrency 32: 1.09 times and 0.89 times, bounded by the device's flush rate; 4 KiB PUT at 3,118/s;
  - large objects and reads unchanged.
- **The `AsyncMutex` wake-up** (a `write` per unlock with a waiter) remains, now the larger part of the loop's
  overhead. It goes to CEESAFE_GAPS (G30).

## Tests

- **`inlinePutsStageWithoutCommitting`** (`src/store/group_tests.cee`):
  - the in-memory writer gives the MD5 `writeAll` gives;
  - a staged inline PUT makes no sync and is not visible until committed;
  - a missing bucket and too much metadata are refused, and an object in extents is not taken;
  - a spilled writer does not finish in memory;
  - staging until the batch is full: then nothing is staged, and the fallback commits the batch first;
  - all of it survives a reopen.
- **The group-commit fault sweeps** (once, sticky, torn, crash) now stage their inline writes through
  `putInlineDeferred`, falling back as the server does.
- **N0295:** a blocking call in the same place is refused (Decision 4).
- `ceesafec test` (131), `tools/s3_smoke.sh`, `tools/tls_smoke.sh`, the s3-tests subset (252), the boto3, Go,
  JavaScript and rclone checks.
