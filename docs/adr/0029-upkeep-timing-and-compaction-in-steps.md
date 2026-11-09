# ADR-0029: Upkeep timing, and compaction in steps

**Status:** accepted for M4 slice 10 (`src/store/object_store.cee`, `src/store/checkpoint.cee`, `src/s3/serve.cee`,
`src/s3/stats.cee`, `tools/bench`), 9 Nov 2026

## Context

- **After checkpoints in steps (ADR-0028), T7 was close:** at concurrency 8, 28 of 30 phases had a p99.9 within
  50 ms. One spike of 109 ms could not be told apart from noise on a shared machine.
- **Nothing measured the store's upkeep.** It runs every 10 s under the store's lock: reaping, checkpoints,
  compaction and lifecycle. A request that waits behind it shows only as latency.
- **Compaction still held the lock throughout** (ADR-0005). It scans the whole index for live versions in the chosen
  segments. Then it reads each one's record, stages its Relocate copy, commits, and removes the segments.

## Decision

1. **Upkeep's holds of the store are timed** (`ObjectStore.upkeepHeld`).
   - Each checkpoint step, each compaction step and each `upkeep` call counts as one hold. Its time goes into the
     store's counters: `upkeepHolds`, `upkeepSlowHolds` (10 ms or more, `UPKEEP_SLOW_MICROS`) and
     `upkeepLongestMicros`, on the stats endpoint.
   - `MaintenanceReport` gives the time of each part: reaping, checkpoint, compaction and lifecycle.
   - **The server logs** each checkpoint (its LSN, its entries and steps, and the longest hold), each compaction that
     did something, and each upkeep hold of 10 ms or more, with its parts.
   - **`tools/bench`** records each phase's slow holds (`upkeepSlowHolds`, a "slow upkeep" column), so a latency spike
     can be matched to upkeep or ruled out.
2. **The first run with timing found the spike's cause.** At concurrency 8 (`benchmarks/2026-11-09-upkeep-timing-c8.json`),
   29 of 30 phases had a p99.9 of 27 ms or less. The one over, 64 KiB PUT at 126 ms, was the only phase with a slow
   hold. The log named it: "upkeep held the store 111 ms (… compaction 111: 1 segments removed, 576 copied …)". The
   checkpoint in the same run held the store for less than a millisecond.
3. **Compaction runs in steps** (`CompactionJob`).
   - **Begin, under the lock** (`beginCompaction`): choose the segments as before, from the segment table, which is
     small, and note their files' paths.
   - **Plan, under the lock** (`compactionPlanStep`): 4,096 index entries a step. It resumes after the last key
     planned, and collects the live inline versions in the chosen segments.
   - **Read, without the lock** (`readBatch`): read and verify about 1 MiB of the planned records from the segments'
     files. Only compaction removes segments, and it has not yet.
   - **Copy, under the lock** (`compactionCopyStep`): commit what other requests staged, then stage the batch's
     Relocate copies and commit them. That is one write and one sync per hold. On a failure only the copies are
     discarded, since nothing else is staged.
   - **Finish, under the lock** (`finishCompaction`): remove the chosen segments that hold nothing live and no reader
     pins, then sync the directory.
   - **The index may change between steps.** A version overwritten or deleted after it was planned makes its copy
     garbage when the copy is applied (ADR-0005 §9), and its segment's live bytes are already lower. Every unchanged
     version is copied before its segment is considered for removal.
4. **`compact()` runs the same steps in a row,** for `maintain` and in-process callers. The server runs checkpoint
   steps, then compaction steps, then the rest of upkeep (`upkeep(false)`: reaping, expiry, lifecycle), releasing the
   lock between steps.
5. **Staging a Relocate copy checks `needsRotation`** as well as `wouldOverflow`, as PUTs do (ADR-0022): a full
   segment is committed and rotated before more is staged into it.

## Rejected

- **Reading the copies under the lock,** as before. The reads were most of the 111 ms.
- **A reverse map from segments to the versions in them,** to plan without scanning the index. It would cost memory
  per object (T9). The plan's steps keep each hold short instead.

## Consequences

- **Upkeep's holds are bounded** by a step: 4,096 entries planned or encoded, or about 1 MiB copied and synced.
- **Lifecycle expiry and reaping still run in one hold** (`upkeep(false)`). Expiry seeks to its bucket's keys
  (ADR-0027) and deletes in batches of LIFECYCLE_BATCH. The timing would show a slow one.
- **Results** are in `docs/benchmarks/2026-11-09-upkeep-in-steps.md`.

## Tests

- **`upkeepHoldsAreCounted`:** checkpoint steps and `upkeep` are counted, the longest is kept, and `upkeep(false)`
  leaves checkpoints to the steps.
- **`steppedCompactionAllowsChangesBetweenSteps`:** a compaction planned 3 entries a step and copied one record a
  step, with an overwrite and a delete of planned keys after the plan, and a write between every copy.
  - The changed keys keep their changes, and the others their bytes and generations.
  - The segments are removed, and the segment files match the table.
  - Recovery and fsck agree.
- **Fault sweeps** (once, sticky, torn, crash) of a workload that compacts one entry and one copy a step, with a delete
  between the copies.
- The compaction tests of ADR-0005 and ADR-0024 now run through the steps: `ceesafec test` (130), the smokes, the
  s3-tests subset, and the SDK checks.
