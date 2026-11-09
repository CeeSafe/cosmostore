# Bucket numbers in index keys at 1M objects, 9 Nov 2026 (M4 slice 8)

`tools/scale.sh` at 1M objects with bucket numbers in index keys (ADR-0027), compared with the ordered index
(`2026-11-09-ordered-index.md`) and the hash map (`2026-11-09-scale-1m.md`).

## Environment

| | |
|---|---|
| What | `tools/scale.sh`: 1,000,000 objects of 128 B in one bucket, written by 128 clients; ceesafec 0.24.2, default StoreConfig |
| Host | Apple M1, darwin 27.0.0 (macOS laptop, internal SSD, `F_FULLFSYNC`) |
| Memory | The server's physical footprint (`footprint -p`) |
| Checks | Every listing page checked for the 1,000 keys that follow, in order; fsck clean afterwards |
| Raw data | `2026-11-09-bucket-numbers.json` |
| Load | **Loud.** The load average was 4.4 at the start and 50 (1 minute) at the end, from another session. The fill (2,903/s) and the recovery in the run (3.37 s) are not a reference. Recovery was timed again on the same store afterwards, three times, at a 1-minute load average of 5.8. Memory does not depend on load. |

## Findings

1. **T9, memory: 376 bytes per object, within 400 again.**

   | Footprint at 1M objects | Hash map | Ordered index | Bucket numbers |
   |---|---:|---:|---:|
   | After the fill, idle | 350 MiB (362 B) | 408 MiB (423 B) | 363 MiB (376 B) |
   | After listing | 379 MiB | 409 MiB | 363 MiB |
   | After recovery | 349 MiB (361 B) | 438 MiB (454 B) | 383 MiB (396 B) |

   An `IndexKey` went from 48 to 32 bytes, in B-tree nodes about half full (G29), and lost one heap allocation:
   about 47 bytes per object. Recovery still lands about 20 MiB higher than the fill, since it inserts in exact key
   order.
2. **T10, listing: about 1 ms a page** (p99 1.5 to 2.2 ms during the load), unchanged.
3. **T11, recovery: 1.43 to 1.55 s** in three launches on the same store, at a load of 5.8. The run's own
   measurement, 3.37 s, was taken at a load of about 50.

## Against the targets (`docs/targets.md`)

| # | Target | At 1M objects | |
|---|---|---|---|
| T9 | ≤ 400 bytes per object, no growth after the load ends | 376 B idle, 396 B recovered; no growth after listing | met |
| T10 | Page of 1,000 ≤ 20 ms p99, independent of the key count | 1.5 to 2.2 ms (loaded machine) | met |
| T11 | ≤ 3 s to serving | 1.43 to 1.55 s | met |

## Next

1. **T7:** checkpoints that do not hold the store's lock (the fill's worst PUT is 0.5 to 0.7 s).
2. **T9's margin after recovery is small** (396 B). Moving the version's rarely used fields out of line would give
   back about 70 bytes per object.
