# The ordered index at 1M objects, 9 Nov 2026 (M4 slice 7)

`tools/scale.sh` at 1M objects with the ordered index (ADR-0026), compared with the hash map
(`2026-11-09-scale-1m.md`).

## Environment

| | |
|---|---|
| What | `tools/scale.sh`: 1,000,000 objects of 128 B in one bucket, written by 128 clients; ceesafec 0.24.2, default StoreConfig |
| Host | Apple M1, darwin 27.0.0 (macOS laptop, internal SSD, `F_FULLFSYNC`) |
| Memory | The server's physical footprint (`footprint -p`) |
| Checks | Every listing page checked for the 1,000 keys that follow, in order; fsck clean afterwards |
| Raw data | `2026-11-09-ordered-index.json`, with the first (discarded) version's run under `inlineBTree` |
| Load | 1-minute load average 4 to 5, but the 5-minute one fell from 13 to 9 during the run. The first version's run was at 28 to 38. |

## Findings

1. **T10, listing: about 1 ms a page, wherever it starts.**

   | ListObjectsV2, max-keys 1000, p50 / p99 | Hash map | Ordered index |
   |---|---|---|
   | First page | 164 / 175 ms | 0.74 / 1.19 ms |
   | Middle (after key 500,000) | 87 / 102 ms | 0.65 / 0.94 ms |
   | Last 1,000 keys | 9.3 / 11.8 ms | 0.65 / 0.81 ms |
   | After recovery, first page | 156 / 173 ms | 0.83 / 1.27 ms |

   Listing no longer leaves memory behind: the footprint was 408 MiB before 60 pages and 409 MiB after (the hash map
   kept 30 to 135 MiB).
2. **T9, memory: 423 bytes per object, over the 400 target.**

   | Footprint at 1M objects | Hash map | Ordered, versions in the B-tree (discarded) | Ordered, `VersionIndex` |
   |---|---:|---:|---:|
   | After the fill, idle | 350 MiB (362 B per object) | 575 MiB (598 B) | 408 MiB (423 B) |
   | After recovery | 349 MiB (361 B) | 688 MiB (716 B) | 438 MiB (454 B) |

   - **The first version** kept each ~200-byte `ObjectVersion` in the B-tree's nodes. lib/std's `OrderedMap` gives
     every node room for 32 entries, and keys inserted in order leave nodes about half full. This fill writes keys in
     order, and recovery inserts a checkpoint's entries in key order. A probe measured the same thing on its own: 1M
     entries of 72 bytes take 184 MB inserted in order and 128 MB scrambled (CEESAFE_GAPS G29).
   - **`VersionIndex`** keeps only the key and a 4-byte slot in the B-tree, and the versions in one dense vector.
     That took back most of it, but each key (about 50 bytes inline, plus its bucket and key bytes on the heap) still
     sits in half-empty nodes.
   - **After recovery** the footprint is about 30 MiB higher than after the fill: recovery inserts in exact key
     order, the worst case for the B-tree.
3. **T11, recovery: 1.54 s** to serving after a SIGKILL, from 0.87 s. Recovery now builds a B-tree of 1M keys
   where it built a hash map, and part of the difference may be this run's load. Still within 3 s.
4. **The fill:** 4,865 PUTs/s, p99 65 ms, but a worst case of 662 ms. Checkpoints under the lock (T7) are still to
   do.

## Against the targets (`docs/targets.md`)

| # | Target | At 1M objects | |
|---|---|---|---|
| T9 | ≤ 400 bytes per object, no growth after the load ends | 423 B idle, 454 B recovered; no growth after listing | growth met; bytes not met (they were 362 with the hash map) |
| T10 | Page of 1,000 ≤ 20 ms p99, independent of the key count | 0.8 to 1.3 ms at every position | met |
| T11 | ≤ 3 s to serving | 1.54 s | met |

## Next

1. **T9:**
   - each index key carries its own copy of the bucket name: a bucket number would save about 40 bytes per object;
   - an `ObjectVersion` has three vectors that most objects leave empty (extents, metadata, extras): about 72 bytes;
   - G29, upstream: B-tree nodes that stay full when keys arrive in order.
2. **T7:** checkpoints that do not hold the store's lock.
