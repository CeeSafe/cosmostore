# ADR-0006: Space reserve and fsck

**Status:** accepted (implemented in `ObjectStore.admit/usedBytes/verify` and `cosmostore fsck`), 6 Nov 2026

## Context

ROADMAP M2 asks for two things:
- a disk-space reserve that rejects writes before the disk is full, so that "disk-full never deadlocks";
- an `fsck` that verifies every locator and checksum.

Neither existed. A store that fills its volume cannot write the delete records or the compaction copies that would
free space. Its journal then fails on `ENOSPC` and stops accepting writes (ADR-0001's fail-stop rule).

## Decision

### Space

1. **The store knows what it occupies.** `usedBytes()` is every journal segment's bytes plus every live version's
   extent files, headers included.
   - The extent part is `StoreState.extentBytes`. `applyRecord` adds to it when a version is published and `retire`
     subtracts from it. Loading a checkpoint adds each version's extents.
   - So the count comes from the same code as recovery, and a reopen gives the same number (tested, with and without
     a checkpoint).
   - A retired version's extents are removed as soon as its record commits, so they are never counted.
2. **Writes are admitted against a capacity.** With `capacityBytes > 0`, a write of `n` object bytes is refused with
   `InsufficientStorage` when `used + n + 4 KiB + reserveBytes > capacityBytes`.
   - `writeAll` checks before any byte reaches an extent.
   - `checkPut` checks again for a streamed object (`putFinished`, `stageObject`). A refused object's extents are
     removed.
3. **The reserve keeps the store recoverable.** Deletes, bucket changes, checkpoints and compaction never ask for
   admission. So a store that refuses writes can still delete, checkpoint and compact its way back under the limit
   (tested). The default reserve is 256 MiB: room for a checkpoint of a few million keys and the default compaction
   budget (64 MiB).
4. **The capacity is configured, not measured.** CeeSafe has no free-space query (`statvfs`,
   `GetDiskFreeSpaceExW`; CEESAFE_GAPS G24). The operator sets `capacityBytes` below the volume's free space.
   - If the volume is shared and fills anyway, the journal fails on `ENOSPC`, and a restart recovers.
   - The default, 0, is no limit, as before.
   - *Amended by ADR-0040:* CeeSafe has had the query since 0.21.0. The store measures the volume at open and each
     upkeep round, and admission also keeps the write and the reserve within what the volume has left.

### fsck

5. **`ObjectStore.verify()` reads every live object** through the normal reader. That checks each inline journal
   record (header and body CRC) and each extent's data against its CRC, and finds short or missing extents. It then
   compares the bytes' size and MD5 with the version's metadata.
   - It reports each object that fails as `Corrupt`, `Missing`, `Mismatch` (size or MD5) or `Unreadable`.
   - It also counts extent files that no live version references, and changes nothing.
6. **`cosmostore fsck <dir>`** opens the store (recovery runs), verifies it, prints one line per damaged object and
   a summary, and exits 1 if anything is wrong. Because opening a store sweeps orphan extents, the CLI's orphan count
   is normally 0; `verify()` on a running store reports the orphans that failed writes left.

## Measured (macOS laptop)

`cosmostore fsck` checked 20,000 objects (83 MB, inline and extents) in 0.34 s, and named the one object whose extent
had a flipped bit.

## Consequences and limits

- Admission is per write. Objects staged in an uncommitted batch are not yet counted, but a batch is at most
  `maxBatchBytes`, well inside the reserve.
- Streamed writers do not reserve space while they write; the store is single-threaded today. The HTTP layer will
  admit on the declared `Content-Length` before streaming.
- fsck reads every byte: about 250 MB/s on this laptop, single-threaded.
- The 24-hour churn soak passed with a 1.2 GB capacity (ROADMAP, 7 Nov 2026). Over 186 SIGKILLs, used space
  peaked at 1.046 GB, and no restart found an fsck problem.
- Reaping now waits for in-flight readers (ADR-0007). Extents that wait count as used space.
