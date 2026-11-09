# ADR-0022: Group commit across requests

**Status:** accepted for M4 slice 2 (`src/storage/journal/journal.cee`, `src/store/object_store.cee`,
`src/s3/group_commit.cee`), 9 Nov 2026

## Context

- **The baseline (ADR-0021) found writes serialized.** Each PUT committed its own journal batch, with its own sync,
  under the store's lock (ADR-0008 §4). That gave about 200 writes/s at any concurrency, and a p99 that grew with the
  queue: 700 ms at 128 clients.
- **The store could already batch.** Staged records share one write and one sync (`commitStaged`). But only one
  caller could stage, because the sync ran under the lock that every request needs.
- **ROADMAP issue 7 rules out a timer window,** which adds its delay to every write at low concurrency. It asks for
  leader/follower group commit: the first waiter syncs at once, and whoever arrives during that sync joins the next
  batch.

## Decision

1. **The journal splits a commit in two** (`Journal.writeStaged`, `SyncTicket.sync`, `Journal.finishSync`).
   - `writeStaged` writes the staged batch at the end of the active segment without syncing it, and returns a
     ticket. The ticket holds its own handle of the segment, so the sync can run on a worker thread without the
     journal.
   - New records stage behind the batch in flight, at `writtenEnd`. `writeOffset` stays the durable end, and reads
     stop there.
   - `finishSync` takes the sync's result:
     - success makes the batch durable;
     - failure fails the journal, as any failed sync does (fail-stop, ADR-0002).
   - **At most one batch is in flight.** On macOS, concurrent `F_FULLFSYNC`s on one file do not overlap. A probe
     measured about 210 flushes/s from 1, 2 and 4 threads alike, so a second sync in flight would gain nothing.
   - `commit` (the existing path, under the lock) also makes a batch in flight durable, with the same sync.
   - **A segment rotates only when nothing is staged,** since staged records hold positions in it. If staging finds
     the segment full, it commits first (`needsRotation`), which rotates. That is one sync under the lock per segment,
     every 128 MiB by default.
2. **The store publishes in LSN order** (`beginGroupSync`, `finishGroupSync`, `isPublished`).
   - `beginGroupSync` moves the staged records' applies to the batch in flight. `finishGroupSync` applies them once
     the sync succeeded. Nothing is visible, or acknowledged, before then (ADR-0001).
   - **`commitStaged` takes a batch in flight with it.** Every other mutation calls it under the lock: deletes, bucket
     operations, conditional writes, checkpoints, compaction. It publishes the batch in flight and then the staged
     records, in LSN order, so a later write always wins. The leader's late `finishGroupSync` then finds its batch
     done and changes nothing.
   - **`putFinishedDeferred`** stages an unconditional PUT and returns its generation (its LSN) without committing it.
     A conditional PUT is checked against every earlier write, so it still commits at once (`putFinishedWith`).
   - `isPublished(lsn)` tells a caller whether its write may be acknowledged.
3. **The S3 layer acknowledges a PUT only when its record is published** (`awaitPublished`). PutObject, POST and
   CopyObject all commit through `commitPut`.
   - **The leader holds the commit turn** (an `AsyncMutex`). Under the store's lock it writes the batch. It then hands
     the turn on and syncs on a worker thread without the lock, while other requests stage the next batch. Last, it
     publishes the batch under the lock.
   - **A batch in flight has a barrier.** There are two, by the batch's parity, and the leader holds its batch's
     barrier while it syncs. A request whose record is in that batch waits on the barrier, not behind the next
     leader. With a single turn, half the waiters sat through a second sync they did not need.
   - **The next leader waits for the barrier of the batch before it,** then writes everything staged meanwhile.
   - **A fast path:** a request whose LSN is below `S3App.published`, the mark the last leader saw, returns without
     the store's lock. Async tasks run on the event loop's one thread, so these marks change only between awaits.
   - **A leader that goes away** (its request is cancelled mid-sync) leaves a batch in flight with no one to finish
     it. The next waiter finds nothing to write but its record unpublished, and commits everything with
     `commitStaged` under the lock.
   - **Idle cost is nothing:** a lone PUT finds no batch in flight, leads, and syncs at once. There is no timer.
4. **Body buffers fit the body** (`bodyStep`): at most 1 MiB, and no more than the body plus 16 KiB of slack for
   aws-chunked framing. Every PUT and GET used to allocate and zero a fresh 1 MiB buffer on the event loop's
   thread. A profile under load put about 60% of that thread's time there, and that, not the store's lock, was
   what capped small GETs at about 2,300/s in the baseline.

## Rejected

- **A timer window** (ROADMAP issue 7). An experiment that had the next leader wait 1 ms, under load only, lowered
  throughput and did not make batches larger.
- **Two syncs in flight.** The device serializes flushes (above), so it would add ordering work for no gain.
- **A commit task that owns the journal.** It would need the store's state on another task, or a channel
  round-trip per write. The leader/follower turn gets the same batching with the existing lock.
- **Group commit for DELETE and the other mutations.** They are rarer, and they stay one commit each. Each still
  takes a batch in flight with it.
  - **Amended by ADR-0025 (M4 slice 5):** DeleteObject now goes through group commit too. DeleteObjects and the
    other mutations still commit at once.

## Consequences

- **Batches grow with load.** With closed-loop clients, each batch holds about half of them, because those answered
  by one batch send their next request after the next batch was written. At 32 clients that is about 63 syncs per
  1,000 PUTs, and the device's flush rate (about 210/s) bounds throughput at roughly 16 × 210.
- **Results** are in `docs/benchmarks/2026-11-09-group-commit.md`.
- **CeeSafe:** `Async.blocking` starts a thread per call (CEESAFE_GAPS G28). A pool would cut the cost of each small
  request's four or five blocking steps.

## Tests

- **Store:**
  - a batch publishes only its own records, not those staged during its sync;
  - one batch at a time;
  - `commitStaged` takes a batch in flight, in LSN order, and the leader's late result applies nothing twice;
  - a conditional PUT is published when it returns;
  - a failed sync publishes nothing and fails the store;
  - full segments rotate under group commit, and everything recovers.
- **Fault sweeps** (once, sticky, torn and crash, ADR-0004) of a group-commit workload:
  - writes staged during a sync, inline and extent-backed;
  - a batch in flight taken by `commitStaged`.
  The model acknowledges a write exactly when the store says it is published.
- **End to end:**
  - `tools/s3_smoke.sh`, `tools/tls_smoke.sh`, the s3-tests subset (252), and the SDK checks;
  - `tools/bench` at up to 128 concurrent clients, with every GET verified and fsck clean afterwards.

## Amendment (10 Nov 2026, ADR-0031): no waiting in the turn's queue

When small PUTs were staged on the event loop (ADR-0031), batches at concurrency 32 fell from about 16 writes to 3
to 10, and throughput to 500 to 1,700/s, with a p99 of 70 to 150 ms. Counters in `awaitPublished` showed why: a
request spent 10.8 ms of its 13.5 ms waiting for the commit turn.
- **The turn's queue mixed two kinds of request:** the next leader, and requests already in the batch being cut,
  which queued only to find that out. The turn's holder keeps it until its batch is written, and waiters take it in
  no fixed order. So a request in the batch in flight could wait behind the following leader, through a sync it did
  not need, and fall into a later batch. Clients then drifted into many small groups.
- **Two barriers by parity were reused too soon:** batch N + 2's leader could lock the barrier batch N's followers
  had not yet passed.

Before, each request's worker-thread steps spread the requests out enough that these orderings were rare. Now:
1. **The leader marks itself** (`S3App.leading`, `leadingBatch`) once it holds the turn and its batch's barrier, and
   a guard's drop clears the mark when it hands the turn on or its request is cancelled.
2. **A request that finds a leader marked waits on that leader's barrier,** not in the turn's queue. The barrier is
   released when the batch is published, or failed, and the request checks again. It waits once per batch number,
   so a leader that went away is not waited on twice.
3. **Eight barriers in turn,** not two.

At concurrency 32 a batch again holds about 16 writes (62.7 syncs per 1,000), and nothing waits for the turn.
