# ADR-0004: Fault injection and a crash model in the I/O layer

**Status:** accepted (implemented in `src/storage/io/faults.cee`), 6 Nov 2026

## Context

The crash tests of ADR-0001 and ADR-0003 cut the journal at every byte, but they never fail an I/O call, and
they keep every extent file. So three questions were untested:
- Does the store behave when a write, sync, open, read or unlink fails?
- Does recovery behave when its own I/O fails?
- Does the code sync everything that an acknowledgement depends on, in the right order? This includes
  directory entries.

## Decision

1. **Every operation of `DurableFile` and `Fs` passes a failpoint.** This covers open, read, write, sync,
   directory sync, size, truncate, rename, unlink and mkdir. A test arms a plan that fails the n-th operation
   from now with `EIO`. The plan can fail it **once**, or **sticky** (every later operation fails too: a dead
   disk, or the moment of a power cut). A failing write can be **torn**, which writes the first half first.
   The state lives in process-wide atomics. `ceesafec test` runs each test in its own process, and the store
   has a single I/O thread. Unarmed, each hook costs one atomic load.
2. **A crash model.** While tracking, the layer records, keyed by path hash:
   - each file's length at its last successful `syncData`;
   - whether each new file's or directory's entry has been covered by a successful sync of its parent directory.

   `Faults.crash(root)` then simulates a power cut:
   - it removes entries whose creation was never made durable;
   - it truncates files to their synced length.

   This rests on one assumption: between syncs, files are only appended to, which is how the journal and
   extents are written. A write below a file's synced length counts as a *violation*, and the sweeps require
   zero violations. An unlink whose directory was never synced might come back after a real crash. The model
   ignores this, and the orphan sweep would remove such an extent anyway.
3. **Sweeps.** Each sweep runs a workload once with counting on, to learn its N operations. It then runs the
   workload N more times, failing operation 1, 2, …, N in turn. The modes are once, sticky, sticky-torn, and
   sticky followed by the crash model. Sweeps call `Faults.elideSyncs(true)`. The OS sync calls are then
   skipped, but they still count, can fail, and mark data synced in the model. This keeps the 12 sweeps at
   about 2 s in total.

## Invariants checked

- **Journal** (`journal_fault_tests.cee`):
  - recovery yields LSNs 1..k with no gaps, where every acknowledged record is included and k is at most the
    number of records staged;
  - after any failure the journal refuses records;
  - a recovered journal accepts writes again;
  - faults *during recovery* (the newest segment ends in a torn batch) never lose an acknowledged record.
- **Store** (`fault_tests.cee`):
  - a model holds, for each key, the version it must have and the one it may have instead. The second is set
    only by a journal I/O error, because only then can an unacknowledged write be on disk;
  - after a reopen, every key holds an allowed version byte for byte;
  - the extent directory holds exactly the live versions' extents;
  - the store is writable again;
  - the same holds for faults while opening a store that has a torn tail and an orphan extent.
- **The checks catch ordering bugs:** each of these mutants fails the crash sweeps:
  - no extent `syncData`;
  - no directory sync after the extents are written;
  - no parent sync after `mkdir`;
  - no journal `syncData`.

## Bugs found

1. **One read error during recovery could wipe the newest segment.** `readSegmentHeader` treated a failed read
   as an invalid header, and recovery reinitialises a newest segment whose header is invalid. A single EIO
   while opening could therefore truncate every acknowledged record in that segment. Read errors now fail the
   open.
2. **A false DELETE after a journal failure.** A batch whose sync fails may be on disk but is not applied in
   memory. `deleteObject` on a key from that batch saw no such key and returned Ok without writing, so after
   a restart the key was back. Every mutation now first checks that the journal has not failed
   (`ObjectStore.checkWritable`).
3. **The `extents/` directory entry was never made durable.** Its parent was never synced after the `mkdir`,
   so a power cut could lose the directory, and every synced extent in it, while the journal still referred
   to them. `Fs.ensureDirectory` now syncs the parent when it creates a directory. The journal directory gets
   the same fix.
4. **A rotation failure discarded a durable batch.** If creating the next segment failed after a batch was
   synced, `commit` reported an error and the store did not apply that batch. Later reads were stale, and the
   batch reappeared after a restart. Now `commit` is Ok because the batch is durable, and the failed rotation
   fails the journal, so the next commit reports it.

## Consequences

- New I/O must go through `DurableFile`/`Fs`. Anything else escapes both the failpoints and the crash model.
- The registry is a `static mut` table behind a few accessor functions that use `unsafe`. CeeSafe has no
  arrays of atomics and no constant `Mutex` (CEESAFE_GAPS G21).
- The model does not cover reordering *within* a file between syncs, which is harmless for append-only files,
  or `rename` (which is not used yet). Checkpoints (M2) will rename. Before then the model must track renames
  as "durable once the directory is synced".
