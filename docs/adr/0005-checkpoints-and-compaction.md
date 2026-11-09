# ADR-0005: Checkpoints and segment compaction

**Status:** accepted (implemented in `src/store/checkpoint.cee` and `ObjectStore.checkpoint/compact/maintain`),
6 Nov 2026

## Context

Before this change, recovery replayed every journal segment ever written, and no segment was ever deleted.
Recovery time and disk use therefore grew with everything ever written, not with what is live (ROADMAP M2).

## Decision

### Checkpoints

1. **A checkpoint is a file holding the whole in-memory state after LSN L.** That is buckets, plus the current
   version of every key with its locator or extent manifest (format in `checkpoint.cee`).
2. **It covers whole segments.** `checkpoint()` commits the staged batch and then seals the active segment
   (`Journal.sealActive`). Every record up to L is then in a segment before S, where S is the new active
   segment, and the checkpoint records both L and S.
3. **It is published atomically.** It is written to `ckpt-<L>.tmp`, synced, renamed to `ckpt-<L>.ck`, and
   then the directory is synced. Only after that sync are older checkpoints removed, and only then may
   segments before S be compacted.
4. **Recovery** loads the newest `.ck` and opens the journal with `JournalStart { segment: S, lsn: L }`:
   - segments before S are not scanned. Their sizes go into the space accounting, and read handles are kept;
   - segment S must exist (otherwise `MissingSegment`), and its records must follow L.

   Leftover `.tmp` files are removed. A `.ck` that fails any check (header CRC, entry kinds, entry CRC, count,
   length) fails the open with `CheckpointCorrupt`. Recovery does not fall back to an older checkpoint,
   because segments the bad one covered may already be gone.
5. `maintain()` checkpoints once `checkpointEveryBytes` of journal (64 MiB by default) has been committed since
   the last checkpoint.
   - **Amended by ADR-0028 (M4 slice 9):** a checkpoint is written in steps from a snapshot of the index, and the
     server releases the store's lock between steps. The file, its publication and recovery are unchanged.

### Compaction

6. **Live bytes now mean inline payloads only.** Once a checkpoint covers a segment, its records are no longer
   needed for replay: buckets, extent manifests and deletes are all in the checkpoint. The only thing still
   needed is the payload of inline versions that are current. `SegmentUsage.liveBytes` now counts exactly the
   records that hold such payloads.
7. **`compact(maxCopyBytes)` chooses covered segments** (id < S) that have nothing live, or whose live bytes
   are below `compactBelowLivePercent` (50%) of their size. It takes the fewest-live first, up to the copy
   budget, but always takes the empty ones.
8. **Each live payload is read back and verified, then copied** into a new `Relocate` record (type 8). Its meta
   names (bucket, key, version id, generation). If the read fails verification, compaction stops with
   `DataCorrupt` and removes nothing. A corrupt payload is never copied under a fresh checksum.
9. **Applying a `Relocate` record moves the version's locator only if that version is still current** (same
   generation and version id). The generation, which conditional writes use, does not change. If the version
   is no longer current, the copy is garbage from the start.
10. **Segments are deleted only after the copies are durable and applied**, and only if their live bytes are
    then zero. One directory sync follows. Recovery from the checkpoint never reads a deleted segment: the
    checkpoint's locators into it are always moved by `Relocate` records with LSN > L, which recovery replays.
    No new checkpoint is needed before the delete.

### Reads

11. **A GET of an inline object reads and verifies the whole record** (`Journal.readRecord`) before serving any
    range of it. Before checkpoints, recovery verified every record at each open. Now it skips covered
    segments, so verification has to happen on the read path.
12. **The journal keeps a read handle for every sealed segment**, so an inline GET opens no file. The handles
    are only a cache: if a sealed handle can't be opened, the read falls back to opening the file.

## Crash safety

The crash model (ADR-0004) now tracks `rename`. A renamed file's entry is durable only after its directory is
synced. If a crash comes first, the model drops the file under both names. That is harsher than a real crash,
and safe here because only temporary files are renamed. The fault sweeps run a workload with two checkpoints
and two compactions (`checkpoint_tests.cee`) in every mode, both writing and opening.

Each of these mutants fails the sweeps:
- no directory sync after the rename;
- no sync of the checkpoint file;
- deleting segments before the relocations are committed.

A fourth mutant, deleting before the commit but keeping the live-bytes check, is caught by that check
instead: compaction then simply doesn't delete.

## Measured (macOS laptop, `F_FULLFSYNC`, 1 KiB objects, 256 per batch)

| Objects | Full replay | Checkpoint write | Recovery from checkpoint | GET + verify |
|---|---|---|---|---|
| 100k | 254 ms | 44 ms | 44 ms | 398k/s |
| 1M | 2,546 ms | 273 ms | 485 ms | 381k/s |

- Recovery from a checkpoint costs about 0.5 µs per object, no matter how much history the journal holds.
- PUT throughput is unchanged (about 24k/s on the same machine and day, for both this and the previous commit).
- In the churn test, 80 rounds of overwrites kept the journal under 64 KiB while about 800 KB was written.

## Consequences and limits

- One open file descriptor per sealed segment: a 1 TiB journal at 128 MiB per segment is 8k descriptors. An
  LRU of handles is needed before stores get that large.
- A checkpoint holds the whole index, and so does memory (v0). It is rewritten in full each time. Incremental
  checkpoints arrive with the ordered on-disk index (M4).
- Inline GETs pay a CRC over the whole record (at most 128 KiB). GET on 1 KiB objects went from 452k/s to
  about 400k/s.
- Not done yet from M2: a disk-space reserve with write rejection, an `fsck` tool, the 24h churn soak, and
  making reaping wait for in-flight readers.

## Amendment (6 Nov 2026): a removed segment still accounted for after recovery

The 24-hour soak (ROADMAP M2) failed on its first restart, with `maintain: unlink`.
- **What happened:**
  1. A checkpoint named inline versions in segment N.
  2. Compaction relocated them and removed N.
  3. The process was killed before the next checkpoint.
  4. On recovery, loading the checkpoint accounted for N because of those versions. Replaying the `Relocate` records
     moved them out, so N was left accounted for with nothing in it and no file.
  5. The first compaction after the restart chose N and failed to remove its file.
- **No data was at risk.** The restart's check of every key and fsck both passed.
- **The fix.** After replay, `ObjectStore.open` drops the accounting of any segment before the checkpoint's first
  replayed segment that the journal does not hold. Unscanned segments are now counted as records only, without
  their 64-byte header, as the live store counts them. Before, recovery could make a segment at exactly 50% live look
  like a compaction candidate.
- **Why the sweeps missed it.** They checked the recovered data, not maintenance on the recovered store. Now:
  - each sweep, after recovery, checks that every accounted segment has its file, then compacts, checkpoints and
    compacts again;
  - `compactionRelocatesAndKeepsGenerations` compacts after its reopen.

  With the fix disabled, four of the six checkpoint sweeps fail.
