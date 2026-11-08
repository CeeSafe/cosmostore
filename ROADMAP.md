# CosmoStore: Architecture Review and Implementation Roadmap

**Input:** `CeeSafe_Object_Storage_Architecture.md` (research dated 5 Nov 2026)
**Prepared:** 6 Nov 2026

---

## Part 1: Evaluation

### Verdict

The architecture is sound and well scoped. The four-plane split, packed small objects,
streamed large-object extents, "data durable before metadata visible", replication
for hot data and EC only on sealed packs, and a tiered compatibility contract all
reflect mainstream practice (SeaweedFS, Ceph RGW, Bitcask/WiscKey-style value logs).
The emphasis on crash correctness before API breadth is the right call.

The weaknesses are in how the pieces fit together and in phase ordering, not in the
overall direction. Ten issues below need resolving before code is written. The first
four matter most.

### What the document gets right

- Hybrid layout with a single shared commit/visibility model for small and large objects.
- A clear non-negotiable invariant: never publish metadata that points at non-durable data.
- Tiered compatibility (A/B/C) and the rule that "HTTP 200 is not support".
- A crash-injection-first testing culture, plus allocation-failure and cancellation sweeps.
- Honest benchmarking rules: same hardware, raw data published, no "beats AWS" claims.
- Spotting the CeeSafe stdlib durability gap (fsync, dir sync, rename, pread/pwrite).
- A narrow first vertical slice (section 12).

### Issues and recommended changes

#### 1. There are two commit logs with no defined shared order (critical)

Small objects commit through the *pack journal*, where the record holds metadata plus
payload. Large objects commit through a separate *metadata WAL*. Take a large PUT to
`k` followed by a small PUT to `k`. On recovery, nothing in the design says which one
wins, and replaying the two logs independently can bring an older generation back.

**Fix:** use **one per-shard journal as the only WAL**. It would have these record types:

| Record | Payload |
|---|---|
| `PutInline` | metadata + payload (≤ inline threshold) |
| `PutExtent` | metadata + extent manifest (extent fsynced *before* the record is appended) |
| `DeleteMarker` / `DeleteVersion` | metadata |
| `MpuCreate` / `MpuPart` / `MpuComplete` / `MpuAbort` | metadata |
| `BucketConfig` | metadata |
| `Checkpoint` | LSN of the last flushed index state |

There is one LSN order and one group-commit fsync. The index stores locators into
journal segments. Sealed journal segments *are* the packs, so no second copy is
needed. This is the WiscKey value-log model, and it also maps cleanly onto a Raft log
later (see #6).

#### 2. Building an LSM is underestimated and should not gate the first release (high)

A correct LSM with compaction, bloom filters, crash-safe manifests and iterators takes
person-months on its own. It also sits on the critical path ahead of every S3 feature.

**Fix:** phase the index.
- **v0:** an in-memory ordered map (B-tree or skiplist) rebuilt from the latest checkpoint
  snapshot plus a journal tail. Budget about 100 to 200 B per key, which puts 10M keys
  at roughly 2 GB RAM.
  This is enough for M1 to M4.
- **v1:** an LSM (or a paged B+tree) behind the same `Index` trait, when the 100M-key
  target or bounded-memory goal requires it.

Record "index bytes per object" as a metric from day one so that the switch to v1 is
driven by data.

#### 3. Space reclamation is scheduled too late (high)

GC and compaction sit in Phase 3. Until then, every overwrite and delete leaks disk.
The design also lacks:
- **Per-segment live-byte accounting.** A discard table should be updated inside the
  same commit that supersedes a version. Without it, finding GC candidates means
  scanning the index.
- **A disk-full plan.** Compaction needs free space to run. Reserve headroom and reject
  writes with `507`/`SlowDown` before reaching the reserve, so the store cannot
  deadlock at 100% full.

**Fix:** move basic segment GC and the discard table into M1/M2.

#### 4. SDK defaults make aws-chunked and trailing checksums a Tier A requirement (high)

Current AWS SDKs and CLI v2 send `aws-chunked` bodies with trailing CRC32/CRC64NVME
checksums by default, including `STREAMING-UNSIGNED-PAYLOAD-TRAILER`. The document
treats chunked SigV4 as "where supported". Without it, stock boto3 and AWS CLI PUTs
fail.

**Fix:** put streaming SigV4 and trailing checksums in M3's first slice.

#### 5. Format decisions are deferred that cannot be added later without migration (medium)

Encryption (Phase 4), versioning (Phase 4) and the cluster (Phase 5) all change the
on-disk record and the metadata model. **Fix:** freeze these in the M1 record format:
- format version and record-type fields, plus the checksum algorithm ID
- an encryption envelope slot (key ID, nonce, DEK wrap ref), empty until SSE ships
- **versions modeled from day one**: an unversioned bucket uses the `null` version ID,
  so enabling versioning later needs no migration
- `(term, index)` alongside the LSN, reserved for the future consensus log

#### 6. The path from single node to cluster is not described (medium)

"Design interfaces for a future cluster" is too vague. With fix #1 in place, the
cluster becomes concrete. Each metadata shard is a Raft group whose log *is* the
journal. Small payloads replicate inline in that log, so one consensus round both
commits and replicates them. Large extents replicate to N storage nodes before the
`PutExtent` entry is proposed. Write this down as an ADR in M0, even though it is
built in M6.

#### 7. A timer-based group commit window adds idle latency (medium)

A fixed 1 to 5 ms window adds that delay to every PUT at low concurrency. **Fix:** use
leader/follower group commit, as Postgres and InnoDB do. The first waiter fsyncs
immediately, and anyone who arrives during that fsync joins the next batch. Batching
then scales with load and costs nothing when the store is idle.

#### 8. Platform durability details are missing (medium)

On macOS, `fsync` does not flush the drive cache, so `F_FULLFSYNC` is required. On
Windows the equivalent is `FlushFileBuffers`, and directory sync semantics differ.
Linux also has `fdatasync` and the question of when `O_DIRECT` is appropriate. Because
development happens on macOS, the durability ADR must name the exact primitive for
each OS. Crash tests on a dev Mac otherwise prove nothing.

#### 9. CeeSafe maturity is the largest unquantified risk (medium)

The language assessment comes from the README and roadmap. The real questions are
compiler and runtime stability under a long-running, I/O-heavy server, plus profiler,
debugger and FFI quality. **Fix:** M0 includes a time-boxed soak spike: an echo/blob
server on CeeSafe.Web running for 24h under load with no leak and no stall. That spike
decides whether the C adapter fallback is needed.

#### 10. Smaller gaps

- **ETag/MD5 cost.** A plain PUT still needs MD5 for the ETag, and clients check it.
  Compute it while streaming and budget its CPU cost in benchmarks.
- **Same-key ordering within a batch.** Two PUTs to the same key in one group-commit
  batch must take their journal order as their generation order. Assign the generation
  at append time, not when the request arrives.
- **Operability.** Add an export/backup tool, an `fsck`/verify tool, and an on-disk
  format upgrade policy.
- **Benchmark peers.** MinIO's open-source edition is now source-only and in
  maintenance. Consider Garage alongside SeaweedFS, Ceph RGW and RustFS.

---

## Part 2: Roadmap

Milestones are sequential gates, and each one has measurable exit criteria. Sizes are
**rough** and assume 2 to 3 engineers who know CeeSafe. Revisit them after M0.

```text
M0 Foundations ──► M1 Storage core ──► M2 Index+GC ──► M3 S3 core ──► M4 Perf hardening
   (4–6 wk)          (6–8 wk)            (4–6 wk)        (8–10 wk)      (4–6 wk)
                                                                            │
                         M7 Advanced S3 ◄── M6 Cluster ◄── M5 Production features
                          (ongoing)        (16–24 wk)        (12–16 wk)
```

The first alpha, a single node usable with stock AWS CLI and boto3, lands at the end
of M3, about 5 to 7 months in.

### M0: Foundations and de-risking (4–6 wk)

| Deliverable | Notes |
|---|---|
| ADR-001 Unified journal / record format | Fixes #1, #5. Byte-level spec, versioned. |
| ADR-002 Durability primitives per OS | `fsync`/`F_FULLFSYNC`/`FlushFileBuffers`, dir sync, atomic rename, pread/pwrite, fallocate, open flags (#8) |
| ADR-003 Consistency and crash model | What "acknowledged" means per durability mode |
| ADR-004 Single-node → cluster path | Raft-log-as-journal sketch (#6) |
| CeeSafe stdlib: durable file API | Native, or a tiny audited C shim behind a trait |
| Primitives | Binary codec, CRC32C, CRC64NVME, SHA-256, MD5, secure random IDs, metrics counters/histograms |
| CeeSafe.Web spike | Streaming request/response bodies, backpressure, cancellation, TLS, keep-alive; **24h soak** (#9) |
| Compatibility matrix v0 | Spreadsheet of Tier A operations, each marked planned/M-number |
| Fault-injection FS layer | **Done** (ADR-0004): failpoints (once, sticky, torn) on every `DurableFile`/`Fs` op, plus a crash model that keeps only synced data; used by every later test |

**Exit:** soak passes, durability API is tested on Linux and macOS, ADRs are approved,
and no storage code depends on undocumented FS behavior.

### M1: Single-node storage core (6–8 wk)

- Journal segment writer and reader: `PutInline`, `PutExtent`, deletes, checkpoint records.
- Leader/follower group commit (#7).
- Large-object extent writer: bounded buffer pool, streaming checksums, fsync before
  the journal record is appended.
- Recovery scanner: torn-tail truncation and idempotent replay.
- v0 in-memory ordered index plus a checkpoint snapshot (#2).
- Version-first object model with per-key generation/CAS (#5).
- Embedded API (no HTTP yet): `put / get / head / delete / list(prefix, start_after, limit)`.
- Benchmark harness (fixed seeds, byte verification) running in CI from now on.

**Exit:**
- Crash injection at every write/sync boundary yields old-or-new, never partial.
- No acknowledged write is lost.
- No locator points at unverified data.
- Recovery run twice gives an identical state.
- A first 1/4/64 KiB throughput baseline is recorded.

### M2: Index durability, GC and space safety (4–6 wk)

- A discard table updated in the same commit that supersedes or deletes a version (#3).
- A segment compactor that rewrites live records and atomically swaps locators, then
  retires old segments after a grace period.
- Orphan extent sweeper. **Done** (at open, ADR-0003).
- Disk-space reserve with write rejection before it is reached. **Done** (ADR-0006; the capacity is configured until
  CeeSafe has a free-space query, CEESAFE_GAPS G24).
- Checkpoint rotation so recovery time stays bounded. **Done** (ADR-0005).
- Segment compaction with locator swaps (`Relocate` records). **Done** (ADR-0005).
- An `fsck` tool that verifies every locator and checksum. **Done** (`cosmostore fsck`, ADR-0006).
- Reaping that waits for in-flight readers. **Done** (ADR-0007).

**Exit:** a 24h overwrite/delete churn test keeps disk usage within 1.5× live bytes,
crashes during compaction are safe, recovery time stays bounded, and disk-full never
deadlocks. **Passed** (7 Nov 2026: 186 SIGKILLs, used/live at most 119%, recovery at most 191 ms).

### M3: S3 core compatibility, the first alpha (8–10 wk)

- HTTP on CeeSafe.Web with path-style and virtual-host addressing. **Done** (slice 1, ADR-0008; virtual-host in
  slice 4, ADR-0011).
- SigV4 header/query auth, presigned URLs, **aws-chunked and trailing checksums** (#4),
  and POST policy. Header auth, aws-chunked and trailing checksums **done** (slice 1); query auth and presigned
  URLs **done** (slice 4, ADR-0011). POST policy left.
- Bucket CRUD, ListBuckets, GetBucketLocation. **Done** (slice 1).
- PUT/GET/HEAD/DELETE, DeleteObjects, CopyObject, Range, conditional GET/PUT via CAS. **Done** (slices 1 and 3).
- ListObjects v1/v2 with delimiter, continuation-token, start-after and encoding-type. **Done** (slice 1).
- ETag semantics, checksum headers, exact XML errors. Checksums stored and returned **done** (slice 8, ADR-0015).
- Multipart: create, upload, upload-copy, list, complete, abort, sharing the extent
  machinery. **Done** (slice 2, ADR-0009; upload-copy in slice 3, ADR-0010).
- Static credentials file and a minimal bucket policy (owner-only), with private buckets
  by default.
- CI matrix: AWS CLI v2, boto3, Go/Java/.NET SDKs, rclone, plus the relevant subset of
  Ceph s3-tests. CLI, rclone, boto3, Go and JavaScript **pass** (slice 6, ADR-0013, `docs/compatibility.md`), and
  so does the s3-tests subset of 218 (slice 7, ADR-0014). Java and .NET left.

**Exit:** the Tier A subset in the matrix passes the s3-tests subset and the SDK matrix.
The compatibility matrix is published.

### M4: Small-object performance hardening (4–6 wk)

- Multiple journal shards per disk and per-core appenders.
- Read path: an index cache and a pack-block cache with admission, plus read coalescing.
- Profile allocation and copies on the hot path, using arenas per request.
- Full p50/p99/p99.9 dashboards, fsyncs per 1k PUTs, write amplification, and compaction debt.
- A comparison run against SeaweedFS, Garage and RustFS on identical hardware, with
  raw data published.
- Index v1 (LSM or B+tree) **only if** M1 metrics show the v0 memory budget is breached
  at target scale.

**Exit:** documented targets are met, memory stays bounded under mixed load, there are
no compaction stalls, and p99 regression gates run in CI.

### M5: Production features (12–16 wk)

Suggested order, each feature with its own compatibility, security and crash tests:
1. Versioning, delete markers and ListObjectVersions. The model already exists, so
   this is mostly API work.
2. Lifecycle (expiration, noncurrent versions, abort-incomplete-MPU) on a scheduler.
3. Tagging, full bucket policy evaluation, ACL compatibility mode, and the
   public-access block.
4. SSE-S3 and SSE-C (envelope slot reserved in M1), then SSE-KMS behind a provider trait.
5. Object Lock and legal hold, enforced inside the commit.
6. Notifications through a durable outbox with retry.
7. CORS, quotas, rate limits, audit log, admin API/CLI, and credential rotation.

**Exit:** a beta that can be run in production on a single node with operational runbooks.

### M6: Distributed cluster (16–24 wk)

- Raft per metadata shard, using the journal as the Raft log (ADR-004).
- Placement map with failure domains, plus a gateway routing cache.
- Extent replication quorum before the `PutExtent` proposal.
- Sealed-pack erasure coding with atomic placement switch and verified retirement.
- Membership and health, rebalance, scrub, repair, and rolling upgrades.
- Jepsen-style tests: partitions, leader kills, clock skew, disk loss.

**Exit:** under injected node, disk, rack and network failures, acknowledged writes
survive and no stale reads or lists occur.

### M7: Advanced S3 (ongoing, per-feature matrices)

This milestone covers bucket replication and multi-site, inventory, access logs,
website hosting, Access Points, STS, and possibly directory buckets or Tables. Each
item is an independent project with its own support matrix.

---

## Part 3: First four weeks (concrete backlog)

1. Write ADR-001 (record format) and ADR-002 (durability primitives). Review before
   writing any code.
2. Implement the `Io` trait with a real backend and a fault-injecting backend (crash at
   op N, short write, EIO).
3. Add the durable file primitives to CeeSafe, or a C shim, with tests on Linux and macOS.
4. Start the CeeSafe.Web streaming and soak spike, running in parallel and owned by one
   engineer.
5. Build the codec and checksum primitives, with property tests and CRC/SHA/MD5 test
   vectors.
6. Write the journal record encoder/decoder and the recovery scanner, plus a
   crash-injection test loop.

## Top risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| CeeSafe runtime/compiler instability under soak | Med | High | M0 soak spike; C shim fallback; upstream fixes |
| Index memory blows past the budget before v1 exists | Med | Med | Bytes-per-key metric from M1; trait boundary lets v1 drop in |
| S3 long-tail compatibility drags on | High | Med | Strict matrix; ship the Tier A subset; s3-tests in CI |
| Compaction write amplification hurts p99 | Med | Med | Discard-table targeting, I/O rate limiting, measured in M2/M4 |
| Raft implementation correctness | Med | High | Deferred to M6; Jepsen-style tests; consider a proven design (etcd/raft-style) port |

---

## Progress log

### 6 Nov 2026: M0/M1 storage-core slice

Done (`ceesafec test`: 21 passed, 0 failed, no leaks; `--sweep alloc` shows no leaks or crashes, only the
tests' own `!` unwraps, see CEESAFE_GAPS.md G15):
- **ADR-0001** (unified journal, record format, recovery rules) and **ADR-0002** (durability primitives), in `docs/adr/`.
- `src/storage/io/`: `DurableFile`/`Fs` over a documented POSIX shim (`F_FULLFSYNC` on macOS).
- `src/storage/checksums/`: CRC32C (slicing-by-8, RFC 3720 vectors) and MD5 (RFC 1321 vectors).
- `src/storage/journal/`: the record codec (every bit flip and torn prefix rejected), segments, rotation,
  group commit, fail-stop on I/O errors, and recovery with torn-tail truncation versus acknowledged-corruption
  detection. Tested by truncating at every byte.
- `src/metadata/model.cee`: a version-first object model, meta codecs, and S3 bucket-name rules.
- `src/store/object_store.cee`: buckets; PUT/GET/HEAD/DELETE; range reads; conditional PUT (IfAbsent /
  IfGeneration); ListObjectsV2 semantics (prefix, delimiter, pagination); staged group commit; and per-segment
  live-byte accounting. The store-level crash-at-every-byte test checks consistency and MD5s.
- `cosmostore bench <dir> <n> <size> <batch>`: writes, reopens, and verifies every byte.

Measured on a macOS laptop SSD (release not tuned, one thread):

| Workload | PUT/s | Syncs | Recovery | GET+verify |
|---|---|---|---|---|
| 2,000 × 1 KiB, 1 per sync | 216 | 2,000 | — | — |
| 100k × 1 KiB, 16 per sync | 3,381 | 6,250 | 417k rec/s | 299k/s |
| 100k × 1 KiB, 256 per sync | 28,441 | 391 | 483k rec/s | 290k/s |
| 20k × 64 KiB, 64 per sync | 1,691 (bench generator-bound) | 313 | 16k rec/s | 5.3k/s |

Not done yet / next:
1. ~~Large objects~~ (done below).
2. Concurrent leader/follower group commit (needs threads or async plus async file I/O, CEESAFE_GAPS.md G6).
3. A fault-injecting I/O layer (short write, EIO, failed sync) behind `DurableFile`.
4. Checkpoints, plus M2's compaction and GC using `SegmentUsage`.
5. The CeeSafe.Web streaming spike and 24h soak, then the S3 HTTP layer (M3).
6. The ordered index, since LIST is O(objects) in v0 (CEESAFE_GAPS.md G8).

### 6 Nov 2026: large objects (ADR-0003)

Done (`ceesafec test`: 28 passed, 0 failed):
- `src/storage/extent/extent.cee`:
  - extent files with random ids;
  - the manifest codec;
  - `ObjectWriter` (one streaming write path: inline up to 128 KiB, otherwise 64 MiB extents, each synced,
    then a directory sync), whose `drop` removes an abandoned writer's extents;
  - `ExtentReader` (byte ranges across extents; CRC check on whole-extent reads).
- Store:
  - `PutExtent` records;
  - `newWriter` / `putFinished` / `stageObject` / `openReader`;
  - extents reaped after the retiring record is durable;
  - an orphan sweep at open;
  - a 5 GiB PUT limit;
  - a new `DataCorrupt` error.
- Tests: boundaries, ranges, reaping, orphans, abandoned writers, corruption, and crash at every journal byte
  with every extent present.
- The bench streams every object through the writer and reader in 1 MiB chunks.

| Workload | PUT | GET + verify |
|---|---|---|
| 100k × 1 KiB, 256 per sync | 32,916/s | 452k/s |
| 2,000 × 1 MiB, 16 per sync | 70/s (70 MiB/s) | 420 MiB/s |
| 200 × 8 MiB | 149 MiB/s | 539 MiB/s |
| 8 × 128 MiB | 161 MiB/s | 548 MiB/s |

Findings to act on:
- **Medium objects (128 KiB to a few MiB) are sync-bound**: about 14 ms of `F_FULLFSYNC` per PUT, for the
  extent and the directory. Candidate fixes for M4: a pre-synced extent-file pool, shared medium-object packs
  committed per batch, or a higher inline threshold.
- **Large PUTs** are probably limited by software MD5 and CRC32C on one thread. This is a hypothesis; profile
  it first.
- **Reaping does not yet wait for in-flight readers.** It must before concurrent GETs exist (M2/M3).

Next: fault-injecting I/O layer → checkpoints + compaction (M2) → CeeSafe.Web spike → S3 HTTP layer (M3), with
multipart built on the extent manifest.

### 6 Nov 2026: fault-injecting I/O layer (ADR-0004)

Done (`ceesafec test`: 42 passed, 0 failed, about 32 s):
- `src/storage/io/faults.cee`:
  - failpoints on every `DurableFile`/`Fs` operation, failing once, sticky, or with a torn write;
  - a crash model: only synced bytes survive, and only entries whose directory was synced. Writes below a
    synced length are counted as violations;
  - `elideSyncs`, which keeps sweeps fast.

  No new C.
- Sweeps that fail every I/O operation in turn:
  - journal writes, in all four modes;
  - journal recovery from a torn tail;
  - store workloads (buckets, inline and extent PUTs, a staged batch, overwrites that reap, a delete, a GET),
    in all four modes;
  - store open with a torn tail and an orphan extent.

  The store sweeps check each key against a model of what it must or may hold, and check the extent directory
  for orphans and missing files.
- The crash sweeps were run against four mutants (no extent sync, no extent directory sync, no parent sync after
  `mkdir`, no journal sync), and each one failed them.

Bugs found and fixed (details in ADR-0004):
1. One read error during recovery could wipe the newest journal segment, because it was treated as a torn header.
2. After a journal failure, `deleteObject` could acknowledge a DELETE that a restart would undo. All mutations
   now refuse once the journal has failed.
3. The `extents/` directory entry was never synced into its parent, so a power cut could lose every extent.
4. A failed segment rotation after a durable batch reported failure, and the store dropped the batch from memory.

CeeSafe: G21, no safe process-wide table (the registry needs `static mut`).

Next: checkpoints + compaction (M2), whose renames the crash model must learn first → CeeSafe.Web spike → S3
HTTP layer (M3), with multipart built on the extent manifest.

### 6 Nov 2026: checkpoints and compaction (ADR-0005)

Done (`ceesafec test`: 54 passed, 0 failed, about 39 s):
- **Checkpoints** (`src/store/checkpoint.cee`):
  - the whole state after LSN L is published by temp file, sync, rename, then directory sync;
  - the journal is sealed first, so a checkpoint covers whole segments;
  - recovery loads the newest one and scans only later segments (`Journal.openFrom`);
  - a damaged checkpoint fails the open, and a missing replay segment is `MissingSegment`.
- **Compaction** (`ObjectStore.compact`, and `maintain` for scheduling): only covered segments that are empty
  or less than 50% live are compacted. Live inline payloads are verified and copied into `Relocate` records,
  which keep the generation, and the segments are deleted once the copies are durable.
- **Live bytes now mean inline payloads only.** Extent manifests and buckets are in the checkpoint.
- **Inline GETs verify the whole record**, because recovery no longer reads covered segments. A read handle is
  cached for each sealed segment.
- **The crash model tracks `rename`.** The fault sweeps cover a workload with checkpoints and compaction (6 new
  sweeps), and three ordering mutants fail them.

| Objects (1 KiB) | Full replay | Checkpoint | Recovery from checkpoint |
|---|---|---|---|
| 100k | 254 ms | 44 ms | 44 ms |
| 1M | 2,546 ms | 273 ms | 485 ms |

The churn test (80 rounds of overwrites, `maintain` after each) keeps the journal under 64 KiB while about
800 KB is written.

Limits:
- one file descriptor per sealed segment (needs an LRU later);
- each checkpoint rewrites the whole index;
- inline GETs pay a record CRC (452k/s → about 400k/s).

CeeSafe: G22, no explicit dereference.

Still open in M2: a disk-space reserve with write rejection, an `fsck` tool, the 24h churn soak, and reaping
that waits for readers.

Next: the rest of M2 (space reserve, fsck), or the CeeSafe.Web spike → S3 HTTP layer (M3).

### 6 Nov 2026: on CeeSafe 0.19 (its ADR 0075, from this repo's CEESAFE_GAPS.md)

- **Removed:**
  - the C shim (`durable_shim.c`/`.h`) and the manifest's `c`/`include-dirs`, so CosmoStore is pure CeeSafe;
  - every `unsafe` block, along with the `static mut` fault registry (now arrays of atomics);
  - the error adapters (now `@from` variants);
  - the CRC32C/MD5 implementations and `tools/gen_crc32c.py`, replaced by lib/std's;
  - the copies in `ObjectWriter` (now `replace`).
- **Unchanged:** the I/O failure codes. `IoFailure` keeps its errno values, mapped from `IoError`, so the fault
  model and messages read as before.
- **Tests:** 53 pass. `md5StreamingMatchesOneShot` is gone because lib/std tests MD5 streaming; the RFC vectors stay
  as a format guard.
- **Toolchain:** ceesafec 0.19.1 or later (released 6 Nov 2026), whose `File.readAt` and the others take `borrow this`.
  With the released 0.19.1 on PATH, check, fmt and the 53 tests pass; 0.19.0 reports 12 errors in `durable.cee`.

### 6 Nov 2026: pinned to ceesafec 0.20.0

`ceesafe.toml` says `ceesafec = ">=0.20.0"`, using CeeSafe 0.20.0's new field (its ADR 0076, from CEESAFE_GAPS G23).
- **ceesafec 0.20.0** (installed from the release, checksum and signature checked): check, fmt and the 53 tests pass.
- **0.19.1 and 0.19.0:** both stop at that line of the manifest (`unknown field 'ceesafec'`), rather than at 12 type
  errors in `durable.cee`.
- **A later compiler** that does not satisfy the field names both versions.

### 6 Nov 2026: space reserve and fsck (ADR-0006)

- **Space accounting:** `usedBytes()` is the journal plus the live extent files, counted by the same apply/retire code
  recovery replays. It is equal after a reopen, with or without a checkpoint.
- **Admission:** with `capacityBytes`, a write that would take the store into `reserveBytes` is refused with
  `InsufficientStorage`. It is checked before any extent byte is written, and again for streamed objects. Deletes,
  checkpoints and compaction never need admission, so a full store can always free itself (tested).
- **fsck:** `ObjectStore.verify()` and `cosmostore fsck <dir>` read every live object, checking the record CRCs, the
  extent CRCs, missing or short extents, and size and MD5. They report Corrupt, Missing, Mismatch or Unreadable, and
  change nothing.
  - Tests: a clean store; a flipped extent byte; a deleted extent; a rotted inline record in a segment the
    checkpoint covers.
  - By hand: 20,000 objects in 0.34 s, and one flipped bit found.
- **Gap:** CEESAFE_GAPS G24, no free-space query, so the capacity is configured.
- **Tests:** 57 pass.
- **M2 left:** the 24h churn soak (the exit test), and reaping that waits for in-flight readers.

### 6 Nov 2026: the 24-hour soak (M2 exit test)

`cosmostore soak` (`src/soak.cee`) and `tools/soak.sh` run a 24-hour churn with SIGKILL every 1-15 minutes.
- **Workload:** 5,000 keys; 60% overwrites (sizes up to 1.5 MiB), 25% deletes, 15% verified reads; maintenance on
  its schedule; a 1.2 GB capacity.
- **Each restart** checks every key against the soak's intent/ack log, then runs fsck.
- **Where:** a Debian 12 box (x86_64, NVMe), with ceesafec 0.20.0.
- **The first run failed** on its first restart (`maintain: unlink`: a removed segment still accounted for after
  recovery; ADR-0005's amendment). Fixed, with stronger sweeps.
- **The second run passed** (16:20 UTC 6 Nov to 16:20 UTC 7 Nov):
  - 186 SIGKILLs and 187 starts. Every start's model check agreed with the store, and every start's fsck found 0
    problems. No operation failed.
  - The final fsck found 3,457 objects (884 MB), 0 problems and 0 orphan extents.
  - Recovery took at most 191 ms, and the model check (5,000 keys) at most 4.9 s.
  - Space: used peaked at 1.046 GB against the 1.2 GB capacity. Used/live stayed between 100% and 119%. Admission
    refused writes near the limit, and deletes, checkpoints and compaction brought the store back under it.
- **M2 exit test: passed.** M2 left: reaping that waits for in-flight readers.

### 7 Nov 2026: reaping waits for readers (ADR-0007); M2 complete

- **The problem:** a reader opened before an overwrite or delete failed when it reached an extent it had not yet
  opened, because reaping had already unlinked it.
- **The fix:** `openReader` pins the version's extents (`src/store/pins.cee`, a count per extent id behind an
  `Arc<Mutex<…>>`), and dropping the reader releases them.
  - Reaping moves a pinned extent to a deferred list instead of unlinking it. The next commit or `maintain` after
    its last reader is dropped removes it.
  - Deferred extents count in `usedBytes`, and fsck does not report them as orphans.
  - A crash forgets the list, and the orphan sweep at open removes the files.
- **Tests** (`src/store/pin_tests.cee`):
  - readers across an overwrite and across a delete;
  - an abandoned reader, and two readers of one version;
  - deferred extents swept at reopen.
  - With the pin check removed, all three tests fail.
- **Tests:** 60 pass.
- **M2 is complete.** Next: M3, the S3 HTTP layer. It must drop a reader when its client disconnects.

### 7 Nov 2026: M3 slice 1, the S3 HTTP layer (ADR-0008)

`cosmostore serve <dir> <port> <credentials-file>` serves the store over S3 on CeeSafe.Web (`web_server` 0.3.1,
HTTP/1.1, path-style addressing). Stock AWS CLI v2 works against it.
- **Concurrency:** one `AsyncMutex<ObjectStore>`, with every store call inside `Async.blocking`. Bodies stream on
  worker threads without the lock, and only the commit takes it.
- **Authentication:**
  - SigV4 header auth against a static credentials file;
  - `x-amz-content-sha256` as a hex digest, `UNSIGNED-PAYLOAD`, signed aws-chunked (each chunk's signature checked)
    and unsigned aws-chunked with a trailer;
  - `Content-MD5` and `x-amz-checksum-{crc32,crc32c,crc64nvme,sha256}` are all checked before the commit.
- **Operations:**
  - buckets: ListBuckets, CreateBucket, HeadBucket, DeleteBucket, GetBucketLocation;
  - objects: PutObject (`If-None-Match: *`, `If-Match` as a CAS), GetObject and HeadObject (Range, the four
    conditionals, `response-*`), DeleteObject;
  - listing: ListObjects v1 and v2 (delimiter, pagination, `encoding-type=url`);
  - errors: S3's XML.
- **Store changes:**
  - reader pins are atomic counts, and an abandoned writer queues its extents for the store. Neither drop blocks,
    which the compiler (N0295) enforced (ADR-0007 amendment);
  - `ListPage` carries ETags and modification times.
- **Tests:**
  - 7 unit tests, including AWS's published SigV4 and chunked-upload signatures;
  - `tools/s3_smoke.sh`, 42 checks with the AWS CLI and `tools/s3_raw.py`, ending in a clean fsck;
  - `ceesafec test`: 67 pass.
- **Gap:** CEESAFE_GAPS G26, no CRC-32 (IEEE) in lib/std, so it is plain CeeSafe in `src/s3/crc32.cee`.
- **M3 left:**
  - multipart (`aws s3 cp` over 8 MB needs it), CopyObject, DeleteObjects;
  - presigned URLs, POST policy, virtual-host addressing;
  - user metadata, bucket creation dates, response checksums;
  - binding beyond loopback, and TLS;
  - the SDK matrix (boto3, Go, Java, .NET, rclone) and the s3-tests subset.

### 8 Nov 2026: M3 slice 2, multipart upload (ADR-0009)

Create, UploadPart, Complete, Abort, ListParts and ListMultipartUploads, in the store and over S3. `aws s3 cp` of
files over 8 MB now works.
- **Store:**
  - four journal records (codes 9 to 12): upload create, part, abort, and complete;
  - `StoreState.uploads`, rebuilt by `applyRecord` like everything else (`src/store/uploads.cee`);
  - parts are always extents, durable before their record. Complete writes one self-contained record with the
    named parts' manifest, so the parts' extents become the object's without a copy;
  - parts that are replaced, left out of the completion, aborted, or in a deleted bucket are reaped once the record
    that drops them is durable. Part extents are live for the orphan sweep and fsck, and count in `usedBytes`.
- **Checkpoint format 2:** an upload count in the header, a part count on each object, and upload entries. Format 1
  still loads, checked with a store written by the previous build.
- **ETags:** a multipart object's ETag is `"<md5 of the part md5s>-N"`, in PUT, GET/HEAD, listings and `If-Match`.
  fsck checks a multipart object's size and extent CRCs, since its stored MD5 is the ETag's.
- **S3:** UploadPart shares PutObject's body path (aws-chunked, `Content-MD5`, `x-amz-checksum-*`), and Complete's
  body is checked against `x-amz-content-sha256`. New errors: `NoSuchUpload`, `InvalidPart`, `InvalidPartOrder`,
  `EntityTooSmall` and `MalformedXML`.
- **Tests:**
  - 5 store tests (`upload_tests.cee`): completion, refusals, abort and bucket delete, restart and checkpoints, and
    listings;
  - fault sweeps of a multipart workload: once, sticky, torn, crash, and crash during open. The sweeps now also
    check that the extent directory holds exactly the versions' and the uploads' extents. With upload parts left out
    of the orphan sweep's live set, six tests fail;
  - 2 S3 unit tests: the Complete body parser, and multipart ETags and upload ids;
  - `tools/s3_smoke.sh`: 62 checks, up from 42. They include `aws s3 cp` of 20 MB both ways with the exact `-3`
    ETag, a range across parts, and every multipart call and refusal by hand;
  - `ceesafec test`: 81 pass.
- **Measured** (macOS laptop, loopback): `aws s3 cp` of 256 MiB (32 parts) takes 1.6 s up and 0.75 s down.
- **M3 left:**
  - CopyObject and UploadPartCopy, DeleteObjects;
  - presigned URLs, POST policy, virtual-host addressing;
  - user metadata, bucket creation dates, response checksums;
  - expiring abandoned uploads;
  - binding beyond loopback, and TLS;
  - the SDK matrix (boto3, Go, Java, .NET, rclone) and the s3-tests subset.

### 8 Nov 2026: M3 slice 3, copies and batch deletes (ADR-0010)

CopyObject, UploadPartCopy and DeleteObjects. With them, `aws s3 cp` between S3 paths works at any size, and
`aws s3 rm --recursive` deletes up to 1,000 keys per sync.
- **Copies** read the source through a pinned reader and write new extents, a step at a time on worker threads
  without the lock, then commit as a PUT or a part. No format changes: an extent still has one owner. Shared extents
  for zero-copy copies wait for evidence that they matter.
  - `x-amz-copy-source-if-*` conditions, COPY and REPLACE metadata directives, and `x-amz-copy-source-range` are
    handled.
  - GetObjectTagging returns an empty set, which is true, since tags cannot be set yet. The CLI reads it before
    every multipart copy, and the smoke test found that.
- **DeleteObjects** stages one DeleteVersion per existing key and commits once: one journal write and one sync.
  - Its body is checked against `Content-MD5` and `x-amz-checksum-*`, and so is the multipart Complete body now.
  - Keys keep their spaces, and XML entities are decoded.
- **Tests:**
  - a store test of the one-sync batch and its recovery;
  - the multipart fault sweeps now end with a batch delete;
  - 2 unit tests (the delete body parser, copy ranges);
  - `tools/s3_smoke.sh`: 78 checks, up from 62, with a 20 MB S3-to-S3 copy through UploadPartCopy;
  - `ceesafec test`: 84 pass.
- **M3 left:**
  - presigned URLs, POST policy, virtual-host addressing;
  - user metadata, tags, bucket creation dates, response checksums;
  - CopyObject destination conditions;
  - expiring abandoned uploads;
  - binding beyond loopback, and TLS;
  - the SDK matrix (boto3, Go, Java, .NET, rclone) and the s3-tests subset.

### 8 Nov 2026: M3 slice 4, presigned URLs and virtual hosts (ADR-0011)

- **Presigned URLs:** SigV4 in the query (`X-Amz-Algorithm`, `-Credential`, `-Date`, `-Expires`, `-SignedHeaders`,
  `-Signature`).
  - Header and query auth now share one verification.
  - Expiry and future dates are checked, and session tokens are refused (`InvalidToken`).
  - AWS's published presigned example gives its documented signature exactly.
- **Virtual-host addressing:** `cosmostore serve … [domain]`. A Host of `<bucket>.<domain>` names the bucket, and
  path-style still works.
- **ListBuckets** reports real creation dates. The store always had them, in `BucketCreate` and checkpoints.
- **Tests:**
  - 2 unit tests (the presigned example, virtual-host parsing);
  - `tools/s3_smoke.sh`: 88 checks, up from 78. They cover `aws s3 presign` with curl, a presigned PUT from
    `tools/s3_raw.py presign`, changed, expired and unsigned URLs, and the CLI in `addressing_style = virtual`
    against `smoke.localhost`;
  - `ceesafec test`: 86 pass.
- **M3 left:**
  - POST policy;
  - user metadata, tags, response checksums;
  - CopyObject destination conditions;
  - expiring abandoned uploads;
  - binding beyond loopback, and TLS;
  - the SDK matrix (boto3, Go, Java, .NET, rclone) and the s3-tests subset.

### 8 Nov 2026: M3 slice 5, object metadata (ADR-0012)

`x-amz-meta-*` user metadata, and the headers S3 keeps (Content-Encoding, Content-Disposition, Cache-Control,
Content-Language, Expires), are stored with each version and returned on GET and HEAD. rclone's modification times
need this.
- **No journal format change:** put meta v1 always had a section for these pairs, and it was empty until now.
  UploadCreate meta gains the section at its end, and older records decode as having none.
- **Checkpoint format 3** ends each object and upload entry with the section. Format 2 still loads, checked with a
  store written by the previous build.
- **Semantics:**
  - PUT, multipart create and REPLACE copies take the request's fields, and COPY keeps the source's;
  - `aws-chunked` is not stored as a Content-Encoding;
  - user metadata over 2 KiB is `MetadataTooLarge`, refused before the body is read;
  - a `response-*` override replaces the stored header.
- **Tests:**
  - a store test through the journal, checkpoints and multipart;
  - meta round-trip tests, including UploadCreate records from before the section existed;
  - `tools/s3_smoke.sh`: 96 checks, up from 88;
  - `ceesafec test`: 87 pass.
- **M3 left:**
  - POST policy;
  - tags, response checksums;
  - CopyObject destination conditions;
  - expiring abandoned uploads;
  - binding beyond loopback, and TLS;
  - the SDK matrix (boto3, Go, Java, .NET, rclone) and the s3-tests subset.

### 8 Nov 2026: M3 slice 6, the SDK matrix (ADR-0013)

`tools/sdk/`: one script per client, each against a fresh server and ending in fsck. All pass:
- rclone 1.73.2: 20 checks;
- boto3 1.42.97: 43 checks;
- the Go SDK v2: 22 checks;
- the JavaScript SDK v3: 25 checks.

The matrix is published in `docs/compatibility.md`. What the clients found:
- **Hoisted headers in presigned URLs.** The JS presigner puts `x-amz-checksum-*`, `x-amz-checksum-mode` and
  `x-amz-sdk-checksum-algorithm` in the signed query. For presigned requests these are now read as headers. So a
  hoisted checksum is checked, as S3 checks it, and the JS SDK's empty-body CRC32 gets BadDigest on S3 and here
  alike.
- **SigV2.** boto3 presigns with it for custom endpoints. It is refused with S3's own "Please use
  AWS4-HMAC-SHA256" `InvalidRequest`, not a bare AccessDenied. It is not built: it is deprecated, and lib/std has no
  SHA-1 (G26).
- **GetBucketVersioning** is now answered (never enabled), because rclone's purge reads it.
- Every other operation the four clients used already worked.

M3 left:
- the Java and .NET SDKs (no Maven, Gradle or .NET here), and the Ceph s3-tests subset;
- POST policy;
- tags, response checksums;
- CopyObject destination conditions;
- expiring abandoned uploads;
- binding beyond loopback, and TLS.

### 8 Nov 2026: M3 slice 7, the Ceph s3-tests subset (ADR-0014)

`tools/s3tests/run.sh` runs the subset, 218 tests at s3-tests commit `5b39871`, against a fresh server, then fsck.
All 218 pass.
- **The subset:**
  - start from `test_s3.py` and `test_headers.py`;
  - leave out the markers outside M3 (SigV2, policies, encryption, IAM/STS, lifecycle, object lock, versioning,
    tagging, websites, Select, SNS, storage classes, `fails_on_aws`). That leaves 440 tests;
  - the 218 of them that pass are pinned by name (`subset.txt`).
  - ADR-0014 accounts for the 222 that do not. 198 test unbuilt features (ACLs, object lock, versioning, POST
    object, CORS, policies…). 15 need response checksums and 3 need GET `?partNumber`. The rest are decided one by
    one, and 1 is skipped.
- **What it changed:**
  - **ListObjectVersions** for unversioned buckets, and `versionId=null`. The suite's cleanup lists versions, so at
    first no test ran;
  - **listing:** `max-keys=0`, empty and echoed continuation tokens, StartAfter, `fetch-owner`, v1's Prefix, and
    ListBuckets pagination;
  - **304s** carry the ETag;
  - **Content-Encoding** spacing;
  - **copy-range errors;**
  - **presigned expiry** out of range gets AccessDenied;
  - **retried CompleteMultipartUpload** gets its first answer. The last 1,024 completions are rebuilt from the
    journal, with no format change;
  - **conditional Complete** (If-Match, If-None-Match), If-None-Match with ETags on PUT, and If-Match on a missing
    key gets NoSuchKey.
- **Tests:** `ceesafec test` 88; smoke 96; the SDK matrix, rclone 20, boto3 43, Go 22 and JS 25, all pass on this
  build.
- **M3 left:**
  - response checksums (with GetObjectAttributes), and GET `?partNumber`;
  - POST policy;
  - tags;
  - CopyObject destination conditions;
  - expiring abandoned uploads;
  - binding beyond loopback, and TLS;
  - the Java and .NET SDKs.

### 8 Nov 2026: M3 slice 8, stored checksums and part layouts (ADR-0015)

Every version keeps its checksum and, if it is multipart, its part layout: an extras blob beside its metadata.
- **Formats:**
  - put, complete, upload-create and part records each gain an optional trailing section, so older records decode
    as having none;
  - checkpoint format 4 (1 to 3 still load).
- **Which checksum:**
  - a PUT or copy stores the client's checksum, else a CRC64NVME computed as the body streams, as S3 does;
  - uploads take `x-amz-checksum-algorithm` and `x-amz-checksum-type` with S3's defaults, and defaulted uploads
    are CRC64NVME FULL_OBJECT;
  - a multipart checksum is COMPOSITE (the checksum of the part checksums, `-N`) or FULL_OBJECT. A FULL_OBJECT CRC
    combines the parts' CRCs with zlib's GF(2) method, generalised to 64 bits, so no byte is read again;
  - SHA-1 stays NotImplemented (G26).
- **Served:**
  - `x-amz-checksum-mode: ENABLED` on GET and HEAD;
  - GET/HEAD `?partNumber` (206 and `x-amz-mp-parts-count`);
  - GetObjectAttributes (ETag, Checksum, ObjectParts paged, StorageClass, ObjectSize);
  - checksums in Create, UploadPart, ListParts, Complete and the copy results.
- **Checked:** at Complete, a named object checksum must match (BadDigest), and so must each part's named
  checksum (InvalidPart).
- **Tests:**
  - the combine equals the whole CRC at every cut, for all three CRCs;
  - s3-tests' three-part reference values;
  - store tests through the journal and checkpoints;
  - `ceesafec test`: 92;
  - smoke 103, including CRC64NVME recomputed bit by bit in Python;
  - s3-tests subset 235, up from 218, with nothing dropped;
  - rclone, boto3, Go and JS pass.
- **Throughput:** the stored checksum costs nothing measurable. A 256 MiB `aws s3 cp` up takes 1.7 to 1.9 s on
  this build and on the one before it, in alternating runs.
- **Found while measuring:** `cosmostore serve … 2>/dev/null` exited at once. Its startup notice to the async
  console failed, and that failure was fatal. The notice is now best effort, and CEESAFE_GAPS G27 has the repro
  (`AsyncConsole.writeError` fails on `/dev/null` on macOS).
- **M3 left:**
  - POST policy;
  - tags;
  - CopyObject destination conditions;
  - expiring abandoned uploads;
  - binding beyond loopback, and TLS;
  - the Java and .NET SDKs.

### 8 Nov 2026: M3 slice 9, listen address and TLS (ADR-0016)

- **The listen address:** `serve <dir> <[address:]port> …`. A bare port is still 127.0.0.1; `0.0.0.0:9000`,
  `[::]:9000` (dual-stack) or a single interface's address work too.
- **Native TLS:**
  - `--tls-cert <pem> --tls-key <pem>` uses CeeSafe.Web's `web_tls`, OpenSSL 3 through its C shim, as chosen over a
    reverse proxy;
  - CosmoStore's own code still has no C and no `unsafe`, and AGENTS.md records the dependency;
  - a bad certificate, a mismatched key or a missing file stops the server before the store opens.
- **Tests:** `tools/tls_smoke.sh`, 18 checks:
  - a throwaway CA and certificate;
  - the AWS CLI (multipart both ways), curl (presigned GET, handshake checks) and rclone over verified TLS;
  - refusals: plain HTTP to the TLS port, and clients without the CA;
  - the refused setups;
  - fsck.
- **Measured:** 256 MiB over TLS takes the same time as over plain HTTP, in alternating runs.
- **M3 left:**
  - POST policy;
  - tags;
  - CopyObject destination conditions;
  - expiring abandoned uploads;
  - certificate reload;
  - the Java and .NET SDKs.
