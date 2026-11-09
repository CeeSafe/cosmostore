# ADR-0026: An ordered index

**Status:** accepted for M4 slice 7 (`src/metadata/version_index.cee`, `src/store/object_store.cee`,
`src/metadata/model.cee`, `src/store/checkpoint.cee`, `src/s3/server.cee`), 9 Nov 2026

## Context

- **The scale run (ADR-0021 amendment) measured listing at 1M keys:** 164 ms (p50) for the first page of 1,000,
  against T10's 20 ms. The index was a hash map, so every page scanned all of it, collected the keys after the marker,
  and sorted them: about 160 ns for each key after the marker.
- **Listing also left memory behind:** each page built an 8 MB list of positions at 1M keys, and the footprint kept
  30 to 135 MiB after 60 pages (T9 asks for no growth after the load ends).
- **ROADMAP M1 planned the v0 index as an ordered map** ("v0 in-memory ordered index"). CeeSafe's lib/std has one (ADR 0075):
  `OrderedMap<K, V>`, a B-tree of up to 31 entries a node in one arena, with cursors (`seek`, `seekAfter`, `next`).

## Decision

1. **The index is a `VersionIndex`** (`src/metadata/version_index.cee`), ordered by bucket, then key, bytewise.
   That is S3's listing order (UTF-8 binary), so a bucket's keys are one run of it.
   - Its keys are in an `OrderedMap<IndexKey, u32>`, each with a slot number. The versions are in one dense
     `Vector<ObjectVersion>`, and a removed version's slot goes on a free list for the next put.
   - It has the hash map's methods (`get`, `getMut`, `put`, `remove`, `contains`, `length`) and cursors (`first`,
     `next`, `seek`, `seekAfter`, `keyAt`, `valueAt`). A point lookup costs a B-tree descent instead of a hash.
   - A failed put leaves it as it was: the slot is taken first, and the B-tree's put is the last step that can
     fail.
2. **A listing reads only its page.**
   - It seeks to the later of two points: the first key at or after the prefix, and the point past the marker.
   - "Past the marker" is the first key after it. If the marker is a common prefix, it is the first key after every
     key that starts with the marker: a seek to the marker with its last byte incremented, after dropping trailing
     0xFF bytes. That can come after the prefix's start even when the marker sorts before it: marker `a` with prefix
     `a/` skips everything.
   - It reads on until a key leaves the bucket or the prefix, or the page is full.
   - A common prefix skips the keys under it with one more seek, so a page costs at most its 1,000 entries and 1,000
     seeks, whatever the bucket holds.
3. **Everything else that walks the index** (recovery's segment accounting, fsck, orphan detection, compaction's
   plan, lifecycle expiry, checkpoint writing) walks it with a cursor, in key order. None of them changes the map
   while it walks.
4. **Listing runs on the event loop,** like the other memory-only reads (ADR-0023). ADR-0023 kept it on a worker
   thread because it scanned the whole index. Now it is bounded by its page.
5. **The on-disk formats do not change.** A checkpoint lists the same entries, now in key order, and recovery inserts
   them in any order.

## Rejected

- **The versions in the B-tree's nodes** (`OrderedMap<IndexKey, ObjectVersion>`), the first version. lib/std's
  `OrderedMap` gives each node room for 32 entries, and keys inserted in order leave nodes about half full
  (CEESAFE_GAPS G29). The fill and recovery both insert in order. With a ~200-byte version in every slot, the
  footprint at 1M objects was 575 MiB after the fill and 688 MiB after recovery, against 350 MiB for the hash map.

- **A sorted side index next to the hash map.** It would keep a second copy of every key: about 60 to 80 more
  bytes per object, against T9's 400.
- **An LSM or a paged B+tree** (ROADMAP M4's "index v1"). The scale run puts memory at 362 bytes per object, within
  T9. A v1 index is for a key count that does not fit memory, which no target asks for yet.

## Consequences

- **A listing's cost follows its page,** not the bucket.
- **Point lookups** do a B-tree descent of about 5 levels at 1M keys, each a binary search in a node.
- **Memory is 423 bytes per object** at 1M objects, over T9's 400; the hash map took 362. The keys still sit in
  half-empty nodes (G29), and each key carries its own copy of the bucket name. Both are follow-ups.
  - **Amended by ADR-0027 (M4 slice 8):** index keys hold a bucket number instead of the name, and memory is 376
    bytes per object.
- **Recovery** builds a B-tree instead of a hash map: 1.54 s at 1M objects, from 0.87 s (T11 asks for 3).
- **Results** are in `docs/benchmarks/2026-11-09-ordered-index.md`.

## Tests

- **`listingMatchesTheReference`** (`src/store/listing_tests.cee`) checks the new listing against the old scan,
  written as a reference (sort, filter, roll up).
  - It covers 3,168 cases: 9 prefixes, 4 delimiters (including `b` and `//`), 11 markers each as a key and as a common
    prefix, and page sizes 1, 2, 3 and 1,000.
  - The keys include prefixes of other keys, empty path segments and non-ASCII keys, in a bucket between two
    neighbours with similar names.
  - Paging one entry at a time by each page's marker visits the whole listing once, in order.
  - It caught a first version that dropped a common-prefix marker sorting before the prefix.
- `storeListingWithDelimiterAndPages`, the s3-tests subset (its listing cases) and the SDK checks (`aws s3 ls`,
  rclone).
- `versionIndexOrdersAndReusesSlots`: order, replacing a version, removal, slot reuse, `seek` and `seekAfter`.
- `ceesafec test` (115), `tools/s3_smoke.sh`, `tools/tls_smoke.sh`, and `tools/scale.sh` at 1M objects.
