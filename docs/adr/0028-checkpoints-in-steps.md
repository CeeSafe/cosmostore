# ADR-0028: Checkpoints in steps

**Status:** accepted for M4 slice 9 (`src/metadata/version_index.cee`, `src/store/checkpoint.cee`,
`src/store/object_store.cee`, `src/s3/serve.cee`), 9 Nov 2026

## Context

- **T7 asks for no stalls,** and the scale run showed them: during a fill of 1M objects, p99 was 60 ms but the
  slowest PUT took 446 to 662 ms.
- **A checkpoint held the store's lock throughout** (ADR-0005): it encoded the whole state, wrote it, synced it and
  renamed it inside `maintain`, and every request waited. At 1M objects the checkpoint is 168 MB.
- **Most of that time is encoding, not I/O.** A probe timed a checkpoint at 1M objects at about 285 ms. With the
  syncs skipped it still took about 230 ms. So writing and syncing without the lock would not be enough: the
  encoding has to leave the lock too. But it needs the state as it was at the checkpoint's LSN, while requests keep
  changing it.

## Decision

1. **A checkpoint is a job of steps** (`CheckpointJob`).
   - **Begin, under the lock** (`beginCheckpoint`): commit the staged batch and seal the active segment, as before,
     giving L and S. Then create the temporary file with its header (counts at L), encode the buckets, encode the
     uploads (kept for the end), copy the bucket names by number, and begin a snapshot of the index.
   - **Steps, under the lock** (`checkpointStep`): encode the snapshot's next 4,096 object entries into the job's
     buffer. This is memory only, a millisecond or two.
   - **Flush, without the lock:** write the buffer to the file.
   - **Publish, without the lock:** write the uploads and the trailer, sync, rename and sync the directory, as
     ADR-0005 does. Then, under the lock, `checkpointPublished` records L and S, which lets compaction use them, and
     removes older checkpoints.
2. **The index keeps what a snapshot still needs** (`VersionIndex`).
   - While a snapshot is active, every change to the index (`put`, `remove`, `getMut`) first keeps the key's
     version at L, unless the snapshot has already given that key or kept it. A key that was not there at L is kept
     as absent.
   - The snapshot reads the index and the kept versions together in key order, after the last key it gave. A kept
     version wins over the index's, and a key kept as absent is skipped.
   - **Each key present at L is given exactly once, with its version at L.** A key changed before the walk reaches
     it is given from its kept version. A key changed after the walk passed it was already given. A key created
     after L is skipped if the walk has not reached it, and never visited if the walk has.
   - Kept versions are freed as the walk passes them. So the memory a checkpoint holds is bounded by the keys
     changed ahead of the walk while it runs.
3. **A file is never published unless it holds what its header promises.** `publish` checks that it wrote exactly
   the entries counted at L. A mismatch would be a bug, and gives `CheckpointCorrupt` without publishing anything.
   If a version cannot be kept (out of memory), the snapshot is marked broken and its next step fails.
4. **Giving up is cheap.** An error in any step ends the snapshot and removes the temporary file. If the server stops
   part way, the next `beginCheckpoint` drops the snapshot, and the next open removes the temporary file (ADR-0005).
   The previous checkpoint stays valid throughout, and compaction keeps using its coverage.
5. **`ObjectStore.checkpoint()` runs the same steps in a row** for in-process callers (tests, `cosmostore soak`).
   The server runs them with the lock released between steps (`serve.cee`, `checkpointInSteps`), before the rest of
   its upkeep (`upkeep(false)`).
6. **Nothing on disk changes:** the format, the publication protocol and recovery are those of ADR-0005.

## Rejected

- **Encoding under the lock, writing without it.** That saves the sync, about a sixth of the time in the probe, and holds the whole
  168 MB file in memory at once.
- **A fuzzy checkpoint** (written from a changing state, with replay starting before L). Replay here is not
  idempotent for the space accounting (segment live bytes, object counts), and a checkpoint that is exactly the
  state at L keeps recovery as it is.
- **A copy of the whole index at L.** It would double the index's memory for the length of every checkpoint.

## Consequences

- **The store's lock is held for a step at a time:** about 4,096 entries encoded, never the whole state.
- **Compaction and lifecycle still run under the lock** in `upkeep`. Compaction's plan scans the whole index (about
  30 ms at 1M objects in the probe). That is a follow-up for T7.
- **Results** are in `docs/benchmarks/2026-11-09-stepped-checkpoints.md`.

## Tests

- **`steppedCheckpointHoldsTheStateAtItsLsn`** (`src/store/stepped_checkpoint_tests.cee`) writes a checkpoint in steps
  of three entries. Between steps it makes changes behind the walk and ahead of it:
  - overwrites, deletes and new keys;
  - a key deleted and put back;
  - a key created and deleted;
  - an inline object overwriting an extent-backed one;
  - a bucket deleted, and a bucket created and filled.

  It then decodes the file and compares it with the state captured at L, and recovery from it with the state at
  the end. It also checks that a job given up leaves no temporary file and that the next checkpoint is whole.
- **Fault sweeps** (once, sticky, torn, crash, and crash while opening) of a workload that checkpoints one entry a
  step, with writes and a delete between the steps, then compacts.
- **A mutant** that keeps nothing (`keep` returning at once) fails the snapshot test (the file differs from the
  state at L). Its workload's checkpoint is refused by the entry-count check.
- The checkpoint tests of ADR-0005 now run through the steps: `ceesafec test` (123), `tools/s3_smoke.sh`,
  `tools/tls_smoke.sh`, the s3-tests subset, the SDK checks, and `tools/scale.sh` at 1M objects.
