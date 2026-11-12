# ADR-0040: The volume's free space in admission

**Status:** accepted for M4 (`src/store/object_store.cee`, `src/storage/io/durable.cee`), 12 Nov 2026; amends
ADR-0006 §4

## Context

- **ADR-0006 admits writes against a configured capacity** (`StoreConfig.capacityBytes`, 0 by default: no limit)
  and keeps a reserve below it (`reserveBytes`, 256 MiB) for deletes, checkpoints and compaction, so a full store
  can free itself. It took a configured capacity because CeeSafe had no free-space query (CEESAFE_GAPS G24).
- **CeeSafe 0.21.0 added one** (its ADR 0077: `Directory.space`, `statvfs` on POSIX, `GetDiskFreeSpaceExA` on
  Windows), and G24 was marked fixed, but CosmoStore never used it. The code, ADR-0006 and the README still said the
  query was missing.
- **So with the default configuration, nothing stopped writes before the volume filled.** The journal then failed
  on `ENOSPC` (ADR-0001's fail-stop), and a restart was needed, with no room for the deletes that would free space.
- **`admit` runs on every write,** under the store's lock and, for small PUTs, on the event loop (ADR-0031). A
  `statvfs` there would be a blocking system call per write, which N0295 refuses on the event loop.

## Decision

1. **The store measures the volume at open and at the start of each upkeep round** (`ObjectStore.measureVolume`,
   every `--maintain-seconds`, 10 by default, inside `Async.blocking`), through `Fs.space`. Like every file
   operation it has a failpoint (`IoOp.Space`, ADR-0004).
2. **Admission counts the volume too.** The measurement records the bytes available to the process and what the
   store occupied then (`usedBytes`). A write of `n` bytes is refused with `InsufficientStorage` (507) when
   `n + 4 KiB + reserveBytes` exceeds the estimate: the available bytes, less what the store has grown since.
   What it shrank is not credited until the next measurement.
3. **The capacity still applies** when it is set; a write must fit both. Deletes, checkpoints and compaction still
   never ask, so the reserve on the volume lets a full store free itself, as ADR-0006's did under the capacity.
4. **A failed measurement keeps the last one.** Upkeep goes on, and the next round asks again. A store never
   measured (the interpreter answers `Unsupported`) has no volume limit, as before.
5. **The stats show it:** `volumeBytes` and `volumeAvailableBytes` (the estimate).

## Rejected

- **A `statvfs` per write:** a blocking call on the event loop (N0295), and a few microseconds on every PUT.
- **Measuring on a timer of its own:** upkeep already runs every round under the store's lock; one more cheap call
  there costs nothing measurable.
- **Crediting deletes at once:** a removed extent's space is free once unlinked, but the journal's bytes only come
  back with compaction. Counting only growth is conservative and simple; the next measurement corrects it.

## Consequences

- **Other writers on the same volume** are seen at the next measurement, up to `--maintain-seconds` later. Between
  measurements they eat into the reserve first; if they take all of it, the journal fails on `ENOSPC` as before.
- **A volume with less than `reserveBytes` available** (256 MiB by default) refuses every write from the start.
  Lower `reserveBytes` for a small test volume.
- **ADR-0006 §4 ("the capacity is configured, not measured") is amended:** the capacity is optional, and the volume
  is measured.

## Tests

- `space_tests.cee`:
  - `theVolumeIsMeasuredAtOpen`: a size, and an available count within it;
  - `aFullVolumeRefusesWritesButNotDeletes`: with no capacity, a measurement leaving the reserve and 100 KiB admits
    one 60 KiB write, counts it, refuses the next; deletes work; a real measurement admits again;
  - `aFailedMeasurementKeepsTheLastOne`: the measurement's failpoint fires in upkeep, admission keeps the last
    figure, and the next round admits.
- Breaking the fix in a copy is caught: without the volume check in `admit`, or with a failed measurement
  forgetting the last one, those tests fail.
- The fault sweeps of ADR-0004 pass: the measurement is one more operation they fail in turn.
