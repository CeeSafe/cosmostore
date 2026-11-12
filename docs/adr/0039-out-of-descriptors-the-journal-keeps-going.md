# ADR-0039: Out of descriptors, the journal keeps going

**Status:** accepted for M4 (`src/storage/journal/journal.cee`, `src/s3/`), 12 Nov 2026; amends ADR-0001's rotation
rule and ADR-0004's bug 4

## Context

- **The Mac mini run** (`docs/benchmarks/2026-11-12-mac-mini-intel.md`) used macOS's default limit of 256 open
  files. Under 128 concurrent 256 KiB PUTs the server needed more (128 sockets, an extent file per upload in progress,
  segments, the listener), and an open failed with `EMFILE`. The journal fail-stopped, every later write got 503 until
  a restart (25 phases of the run), and the log said only `journal error`. Nothing acknowledged was lost.
- **Two opens fail-stopped the journal without having written anything:**
  - `Journal.writeStaged` (ADR-0022) opens a second handle of the active segment for the sync ticket, before it
    writes the batch. A failed open called `fail`.
  - `rotate` creates the next segment once the active one is full. ADR-0001 and ADR-0004 (bug 4) made any failed
    rotation fail the journal: the batch that filled the segment stays acknowledged, and the next commit reports the
    error.
- **Fail-stop is right after a failed write or sync** (ADR-0001 §4): the batch may or may not be on disk. It is not
  needed when nothing was written, and an out-of-descriptors failure is a shortage that passes.
- **CeeSafe cannot raise the open-file limit** (CEESAFE_GAPS G32), so `serve` cannot lift its soft limit to the hard
  one at start, as servers usually do.

## Decision

1. **A failed open of the sync ticket's handle is not a journal failure.** `writeStaged` opens it before writing, so
   nothing was written: it returns no ticket and leaves the batch staged. The leader's existing fallback
   (`writeBatch` in `src/s3/group_commit.cee`) then commits the batch under the store's lock with the journal's own
   handle (`commitStaged`). The LSNs and positions already handed out stay valid; nothing is rewound. Counted as
   `journalSyncHandleFallbacks` in the stats.
2. **A failed rotation leaves the journal running when nothing it created is left behind.** The active segment then
   grows past its target, and the next commit tries again. Counted as `journalRotationFailures`.
   - **Creating the file failed:** nothing exists; go on. (If the file already exists, it is not this rotation's,
     and the journal fails, as before.)
   - **The file was created, and its header's write, its sync or the directory's sync failed:** the file is removed
     and the directory synced *before* the active segment takes another record. A crash could otherwise find the new
     file as the newest segment, with the active one sealed behind it, and a torn batch there would read as
     corruption at open (ADR-0001's recovery rules).
   - **The removal or its directory sync failed:** the journal fails, as before.
3. **"Too many open files" is a 503.** `StoreError.Io` with `EMFILE` or `ENFILE` maps to `ServiceUnavailable`
   ("Please reduce your request rate"), which SDKs retry, not to a 500. Other I/O failures stay 500, and journal
   errors stay 503.
4. **The cause is logged.** The journal keeps the I/O failure that failed it. The upkeep round logs it once:
   `cosmostore: the journal failed (open failed, errno 24); writes are refused until a restart`. A failed
   maintenance round names the operation and errno too, not just "journal error".

## Rejected

- **Rewinding the batch on a failed ticket open** (`discardPending` and an error to every writer in it): writers
  waiting on the batch hold its LSNs, and later records would reuse them, so a waiter could take another write's
  publication for its own.
- **Keeping one spare sync handle** instead of opening one per group commit: fewer opens, but the ticket owns its
  handle across the unlocked sync, so the spare needs returning on every path, cancellation included. The fallback
  above is enough while the open is cheap; revisit if the open shows in a profile.
- **Raising the soft limit in `serve`:** needs `setrlimit`, which CeeSafe lacks (G32). Until then, the operator raises
  it (`ulimit -n`), as the README's `serve` section says.

## Consequences

- **The Mac mini again**, at 256 open files, 256 KiB PUTs, GETs and overwrites at concurrency 128 and 8, then 4 KiB:
  84 of the first 1,000 PUTs and 9 overwrites got 503, and every later phase ran without errors. The journal never
  failed, and fsck was clean (3,995 objects). Before, the store refused every write from the first failure on.
- **A failed rotation now costs a create, and a remove with a directory sync, on each commit until it succeeds.** The
  active segment may exceed `segmentTargetBytes` meanwhile; nothing depends on that bound.
- **ADR-0001's "a rotation that fails after its batch was synced … the journal is failed" and ADR-0004's bug 4 fix
  are amended:** the batch still stays acknowledged, and the journal fails only when the rotation's file cannot be
  removed.

## Tests

- `journal_fault_tests.cee`:
  - `journalRotationFailureStillAcknowledges` (rewritten): creating the next segment fails, the journal keeps
    going, and the next commit rotates;
  - `journalRotationFailsAtTheHeaderWrite`, `…HeaderSync`, `…DirectorySync`: the file is gone, also after the
    crash model cuts the tree, with an unsynced batch in the active segment, and recovery finds every record;
  - `journalRotationThatCannotBeUndoneFailsTheJournal`: with the removal failing too, the journal fails and keeps
    the cause;
  - `journalSyncHandleFailureFallsBackToCommit`: no ticket, no failure, and `commit` makes the batch durable.
- `group_tests.cee`, `groupSyncWithoutAHandleCommitsUnderTheLock`: the store's view, the write published by
  `commitStaged` and found after a reopen.
- `s3_unit_tests.cee`, `outOfDescriptorsIsServiceUnavailable`.
- Breaking the fix in a copy is caught: without the removal the three rotation tests fail (2 segment files); with the
  ticket's open still failing the journal, the fallback test fails.
- The fault sweeps of ADR-0004 and ADR-0022 (journal, store, group commit; once, sticky, torn and crash) pass
  unchanged.
