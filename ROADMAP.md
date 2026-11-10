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
  URLs **done** (slice 4, ADR-0011); POST policy **done** (slice 11, ADR-0018).
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
  so does the s3-tests subset (slice 7, ADR-0014); Java (slice 14) and .NET (slice 15) pass too.

**Exit:** the Tier A subset in the matrix passes the s3-tests subset and the SDK matrix.
The compatibility matrix is published. **Passed** (9 Nov 2026): the AWS CLI, rclone, boto3, Go,
JavaScript, Java and .NET SDK checks and the s3-tests subset of 252 all pass; the matrix is `docs/compatibility.md`.

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

### 8 Nov 2026: M3 slice 10, upkeep, upload expiry, tags, copy conditions (ADR-0017)

- **The server never ran its upkeep.** `cosmostore serve` did not call `maintain`, so a long-running server never
  checkpointed or compacted: its journal and its recovery time grew without bound.
  - It now runs `maintain` every 10 s, raced beside the HTTP server. The store's mutex is shared through an `Arc`.
  - By hand: after 72 MB of small objects, the server checkpointed on its own within 7 s, and fsck was clean after
    a SIGKILL.
- **Upload expiry:** `maintain` aborts uploads older than `uploadExpiryMillis` (7 days), with ordinary UploadAbort
  records.
- **Object tags:**
  - they live in the version's metadata as the canonical, key-sorted `x-amz-tagging` field, so there is no
    checkpoint change;
  - one new record, `SetTags` (code 13), changes them in place, if the version is still current, keeping the ETag
    and generation;
  - S3's limits are enforced; GetObjectTagging, PutObjectTagging and DeleteObjectTagging work, and so do
    `x-amz-tagging-directive` and `x-amz-tagging-count`;
  - the multipart fault sweeps set tags.
- **CopyObject destination conditions:** If-Match and If-None-Match, through PUT's resolver.
- **Tests:**
  - `ceesafec test`: 95;
  - smoke 115, up from 103;
  - TLS smoke;
  - rclone, boto3, Go and JS;
  - the s3-tests subset of 246, up from 235, now with the tagging marker included. 11 tagging tests pass, and none
    was lost.
- **M3 left:**
  - POST policy;
  - certificate reload, and configuring the upkeep from the command line;
  - bucket tags and lifecycle rules (beyond upload expiry);
  - the Java and .NET SDKs.

### 9 Nov 2026: M3 slice 11, POST object (ADR-0018)

Browser form uploads with a SigV4 POST policy.
- **Streaming:** a POST to a bucket whose body is `multipart/form-data` is read by a streaming form reader. Fields
  arrive whole, and the file streams into a writer as a PUT body does. A 100 MB POST took 0.85 s, and server memory
  stayed at 6 to 8 MB.
- **Checks:**
  - the policy (base64 JSON) is signed with the credential's signing key;
  - expiration, `eq`, `starts-with` and `content-length-range` are enforced;
  - every field must be covered; `${filename}` is replaced in the key;
  - `success_action_status` and `success_action_redirect` are honoured;
  - metadata and tagging fields are stored.
- **SigV2 forms** get the SigV2 refusal. Every s3-tests POST test signs with SigV2, so they pass or fail on that
  refusal, not on POST object. The subset leaves them all out: 238, down from 246, the 8 removed having passed only
  because form POSTs used to fail header auth. Nothing else was lost.
- **Tests:**
  - the form reader split at every byte;
  - policy parsing and checks;
  - boto3 `generate_presigned_post` (9 checks: 204, 201, redirect, and five refusals);
  - JS `createPresignedPost` (3 checks);
  - `ceesafec test`: 97;
  - smoke 115, TLS smoke, the SDK matrix, and the s3-tests subset of 238 all pass.
- **M3 left:**
  - certificate reload, and configuring the upkeep from the command line;
  - bucket tags and lifecycle rules (beyond upload expiry);
  - the Java and .NET SDKs.

### 9 Nov 2026: M3 slice 12, certificate reload and upkeep options (ADR-0019)

- **Certificate reload:** the TLS server's upkeep watches the certificate's and the key's modified times. On a change
  it reloads both (`TlsConfig.reload`), for new connections. A failed reload keeps the old certificate, is logged,
  and is retried next round. There are no signals in lib/std, and watching the files also suits ACME clients that
  only replace them.
- **N0295 refused** the first version, which stat'ed and read the files in async code. They now run on a worker
  thread.
- **`serve` options:** `--maintain-seconds <n>` (1 to 86,400; default 10) and `--upload-expiry-hours <n>` (default
  168; 0 for never).
- **Tests:**
  - `tools/tls_smoke.sh`, 23 checks: a new certificate is served (by fingerprint), and a broken key keeps the
    working one;
  - the option refusals, by hand;
  - `ceesafec test`: 97;
  - smoke 115; the SDK matrix; the s3-tests subset of 238.
- **M3 left:**
  - bucket tags and lifecycle rules (beyond upload expiry);
  - the Java and .NET SDKs (no Maven, Gradle or .NET SDK on this machine).

### 9 Nov 2026: M3 slice 13, bucket tags and lifecycle rules (ADR-0020)

- **Store:**
  - buckets keep their tags and lifecycle rules; one new record, `BucketConfig` (code 14), sets or clears them;
  - checkpoint format 5 (1 to 4 still load); deleting a bucket drops both, and a recreated bucket starts bare;
  - `applyLifecycle` (from `maintain`, at most hourly) expires objects by days, rounded up to midnight UTC as S3 does,
    or by date. Rules filter by prefix, tags and size. Deletes are batched per bucket, up to 1,000 a run, and old
    uploads are aborted.
- **S3:**
  - Get, Put and DeleteBucketTagging (50 tags);
  - Get, Put and DeleteBucketLifecycleConfiguration, with S3's checks;
  - rules come back in the form given (a legacy Prefix stays one);
  - ExpiredObjectDeleteMarker is accepted as the no-op it is without versioning;
  - transitions and noncurrent-version rules are NotImplemented.
- **Tests:**
  - unit tests for rule blobs, matching, rounding and the XML;
  - store tests through the journal and checkpoints, and expiry at now plus 0, 3, 5 and 32 days;
  - the multipart fault sweeps set bucket tags;
  - smoke 122, up from 115;
  - the s3-tests subset of 252, up from 238, with the `lifecycle` marker in: 13 lifecycle configuration tests and
    bucket tagging pass, and nothing was lost;
  - `ceesafec test`: 101; the SDK matrix and TLS smoke pass.
- **M3 left:**
  - the Java and .NET SDKs (no Maven, Gradle or .NET SDK on this machine). Everything else on M3's list is done.

### 9 Nov 2026: M3 slice 14, the Java SDK in the matrix

- **`tools/sdk/java.sh`:** the AWS SDK for Java v2 (2.57.11, with aws-crt), 25 checks, all passing. They cover:
  - every checksum algorithm, and the checksum returned on GET;
  - typed errors and paginators;
  - the async multipart client (upload, download and copy of 13 MiB);
  - the presigner, through the JDK's HTTP client;
  - virtual hosts, tags and batch delete.
- **Maven** ran from the scratchpad (3.9.11, its SHA-512 checked against Apache's), with its repository there too.
  No system install was needed.
- **What the Java SDK showed:**
  - it sends a CRC32 with each PUT by default;
  - it names HEAD errors (NoSuchKey, NoSuchBucket) itself, from the status;
  - like boto3, it needs the CRT for CRC64NVME.
  - The server needed no change.
- **M3 left:** the .NET SDK. Downloading its tarball into the scratchpad was refused by this session's permission
  check, so it waits for the user.

### 9 Nov 2026: M3 slice 15, the .NET SDK; M3 complete

- **`tools/sdk/dotnet.sh`:** the AWS SDK for .NET (AWSSDK.S3 4.0.104.11 with CrtIntegration), 22 checks, all
  passing. They cover every checksum algorithm, typed errors, paginators, TransferUtility multipart, copy,
  presigned GET and PUT through HttpClient, virtual hosts, tags and batch delete.
- **Setup:** the .NET 10 SDK was already installed (`/usr/local/share/dotnet`); my earlier check had run
  `dotnet version`, which is not a command. The NuGet cache is kept in the scratchpad.
- **What .NET showed:** it needs the CRT integration for CRC32C and CRC64NVME, as boto3 and Java do. It reports a
  HEAD's 404 as `NotFound` (Java names it NoSuchBucket). The server needed no change.
- **M3 exit: passed.** Every client in the matrix passes, and so does the s3-tests subset:
  - the AWS CLI (122 checks), rclone (20), boto3 (52), Go (22), JavaScript (28), Java (25) and .NET (22);
  - TLS (23);
  - s3-tests (252);
  - the matrix is published in `docs/compatibility.md`.
- **Next: M4, small-object performance hardening.** Its list: journal shards, read caches, allocation profiling,
  latency dashboards, the comparison run. M3 also left some work to it:
  - checkpointing without the store's lock;
  - group commit across concurrent PUTs (ADR-0008 §4);
  - an ordered index for listing and lifecycle.

### 9 Nov 2026: M4 slice 1, the baseline (ADR-0021)

- **Instruments:**
  - the store counts its work (`StoreCounters`): payload bytes, and journal, extent and checkpoint bytes written;
  - `GET /_cosmostore/stats` returns those counters (SigV4-authenticated);
  - `tools/bench`, a Go load generator: fixed seeds, every GET verified, p50 to p99.9, and syncs per 1,000 writes
    and write amplification from the stats endpoint;
  - `tools/bench.sh` runs it against a fresh server and runs fsck afterwards.
- **Baseline** (`docs/benchmarks/2026-11-09-baseline.md`, Apple M1, sizes 0 B to 1 MiB, concurrency 1 to 128):
  1. **Writes are serialized:** one sync per write, and about 200 writes/s at any concurrency. A tiny PUT's p99 goes
     from 6 to 9 ms at concurrency 1 to 700 ms at 128.
  2. **Reads of stored bytes cap at about 2,300 ops/s,** because inline records are read under the store's lock.
  3. **Stalls of hundreds of ms in some phases.** The hypothesis is checkpoints under the lock.
  4. **1 MiB:** about 100 MiB/s PUT and 650 MiB/s GET. Write amplification is 1.00 to 1.04.
- **Targets proposed** (`docs/targets.md`, T1 to T12), awaiting confirmation. Among them:
  - tiny PUT ≥ 3,000 ops/s at concurrency 32, with ≤ 50 syncs per 1,000;
  - tiny GET ≥ 15,000 ops/s;
  - p99.9 ≤ 50 ms under upkeep;
  - ≤ 400 bytes per object at 1M objects;
  - listing independent of the key count;
  - recovery ≤ 3 s at 1M objects.
- **Next:** group commit across requests (T1 to T4), then reads without the lock (T5, T6), then checkpoints without
  the lock (T7).

### 9 Nov 2026: M4 slice 2, group commit across requests (ADR-0022)

- **Leader/follower group commit, without a timer** (issue 7):
  - the journal writes a batch, then syncs it on a worker thread without the store's lock, while the next batch
    stages;
  - the store publishes in LSN order;
  - `commitStaged`, which every other mutation calls, takes a batch in flight with it;
  - a PUT is acknowledged once its record is published;
  - per-batch barriers keep followers from waiting behind the next leader.
- **Body buffers sized to the body.** Every request used to zero a fresh 1 MiB buffer on the event loop's thread,
  and that, not the store's lock, was what capped small GETs.
- **Results** (`docs/benchmarks/2026-11-09-group-commit.md`):
  - tiny PUT at 3,300/s at concurrency 32 (from 200), p99 11 ms (from 190 to 550);
  - 5,000 to 5,600/s at 128;
  - concurrency 1 unchanged;
  - small GET at 11,000 to 15,700/s (from about 2,300).
  - Met: T1, T3, T4, T8, T12. Not yet: T2 (64 syncs per 1,000), T5 and T6.
- **Measured:** this SSD serializes `F_FULLFSYNC` (about 210/s from 1, 2 or 4 threads), so one batch in flight is
  enough.
- **CeeSafe:** `Async.blocking` starts a thread per call (CEESAFE_GAPS G28).
- **Tests:**
  - group-commit store tests;
  - fault sweeps (once, sticky, torn, crash) of a group workload;
  - s3-tests subset 252, the boto3, Go, JS and rclone checks, and both smokes.
- **Next:**
  - reads and HEAD without the store's lock (T5, T6);
  - deletes through group commit;
  - T2's definition.


### 9 Nov 2026: M4 slice 3, reads on the event loop (ADR-0023)

- **Store calls that only touch memory run on the event loop,** with no worker thread: `headObject`, `bucketExists`,
  `listBucketInfo` and the GET plan. The compiler's N0295 check proves they do no I/O, and fails the build if a later
  change adds some.
- **A GET with a body makes one worker-thread call** (the reader's open), and an inline body goes out in one write.
- **Results** (`docs/benchmarks/2026-11-09-reads.md`), at concurrency 32:
  - HEAD at 37,000 to 42,000/s (from 15,800 to 17,300), p99 1.2 to 2.1 ms;
  - 128 B to 4 KiB GET at 15,500 to 16,200/s (from 11,100 to 12,100), p99 about 3 ms;
  - met: T5 (with little margin) and T6.
- **Still open:** GET at concurrency 128 (about 9,000/s), since the inline record is read under the store's lock.
- **Tests:** s3-tests subset 252, the boto3, Go, JS and rclone checks, and both smokes.
- **Next:**
  - inline reads without the store's lock (segment pins);
  - deletes through group commit;
  - T2.

### 9 Nov 2026: M4 slice 4, inline reads without the store's lock (ADR-0024)

- **A GET holds the lock only for index work.** `prepareReader` (no I/O, on the event loop) looks the version up and
  pins its extents or its record's segment. `PreparedReader.open` reads and verifies the record on a worker thread
  after the lock is released.
- **Compaction skips a pinned segment,** and a later pass removes it. That is the state a crash between the
  relocation commit and the unlink already leaves, so recovery has nothing new to handle.
- **Results** (`docs/benchmarks/2026-11-09-unlocked-reads.md`):
  - 128 B to 4 KiB GET at 22,900 to 25,200/s at concurrency 32 (from 15,500 to 16,200), p99 2.2 to 2.6 ms;
  - 22,500 to 26,200/s at 128 (from about 9,000);
  - T5 met with margin. Large objects unchanged (checked back to back against slice 3).
- **Tests:** a reader across compaction, a segment left at stop and reopened, every I/O step of the read failed in
  turn, and rot detected on the new path. 112 tests, s3-tests subset 252, the SDK checks, both smokes.
- **Next:**
  - deletes through group commit;
  - T2.

### 9 Nov 2026: M4 slice 5, deletes through group commit (ADR-0025)

- **DeleteObject is staged and acknowledged once published** (`deleteObjectDeferred`, `awaitPublished`), so deletes
  share batches and syncs with PUTs, and no delete holds the store's lock across a sync.
- **A key missing from the index may still have a PUT staged or in flight.** The delete is then written anyway, so it
  applies after that PUT and wins. With nothing pending, a missing key needs no record, as before.
- **DeleteObjects (the batch) still commits at once,** so a failure cannot leave part of it durable (ADR-0010).
- **Results** (`docs/benchmarks/2026-11-09-group-deletes.md`, a loaded machine; only DELETE compared):
  - 2,300 to 3,200/s at concurrency 32 (from about 200), p99 11 to 28 ms (from 165 to 356);
  - 5,100 to 8,800/s at 128, with 16 syncs per 1,000;
  - concurrency 1 unchanged.
- **Tests:** deferred deletes after unpublished writes, and the group fault sweeps (once, sticky, torn, crash) with a
  delete staged during a sync. 113 tests, s3-tests subset 252, the SDK checks, both smokes.
- **Next:**
  - a quiet reference run of the whole matrix;
  - T2;
  - T7 and T9 to T11 (stalls, memory, listing and recovery at scale).

### 9 Nov 2026: M4 slice 6, the scale run (ADR-0021 amendment)

- **`tools/scale.sh`** fills a fresh server with 1M objects (`tools/bench -mode fill`), measures its memory, samples
  listing pages (`-mode list`, each page checked), kills and restarts it to time recovery, lists again, and runs fsck.
- **Memory is the physical footprint on macOS:** RSS dropped to 3 MiB while 1M keys sat idle in compressed pages.
- **First results** (`docs/benchmarks/2026-11-09-scale-1m.md`, a loaded machine), at 1M 128 B objects:
  - T9: 362 bytes per object, idle and after recovery. But listing leaves 30 to 135 MiB behind.
  - T10: a page of 1,000 takes 164 ms (p50) at the first key, since every page scans and sorts the whole index. Not
    met.
  - T11: 0.87 s from launch to serving after a SIGKILL. Met.
  - T7, seen in the fill: the slowest PUT took 446 ms, behind a 168 MB checkpoint written under the store's lock.
- **Next:**
  - an ordered index for listing (T10, and listing's memory);
  - checkpoints that do not hold the lock (T7);
  - quiet runs.

### 9 Nov 2026: M4 slice 7, the ordered index (ADR-0026)

- **The index is ordered:** `VersionIndex` keeps (bucket, key) in lib/std's `OrderedMap` with a slot number, and the
  versions in one dense vector.
- **A listing seeks to its first key** and reads only its page; a common prefix skips the keys under it with one
  seek. Listing now runs on the event loop.
- **Results at 1M objects** (`docs/benchmarks/2026-11-09-ordered-index.md`):
  - T10 met: about 1 ms a page at any position, from 164 ms;
  - listing leaves no memory behind;
  - T11 still met: 1.54 s, from 0.87 s;
  - T9 not met: 423 bytes per object, from 362. Keys inserted in order leave the B-tree's nodes half full
    (CEESAFE_GAPS G29). A first version with the versions in the nodes took 598.
- **Tests:** `listingMatchesTheReference`, 3,168 listings against the old scan as a reference, plus paging one entry
  at a time. It caught a bug in the first version. Also `versionIndexOrdersAndReusesSlots`. 115 tests, s3-tests
  subset 252, the SDK checks, both smokes.
- **Next:**
  - T9: a bucket number in index keys, and smaller versions;
  - T7: checkpoints without the lock.

### 9 Nov 2026: M4 slice 8, bucket numbers in index keys (ADR-0027)

- **An index key holds its bucket's number,** given in memory when the bucket is created or recovered, instead of a
  copy of the name. A key goes from 48 to 32 bytes, with one heap allocation instead of two. Nothing on disk changes.
- **Lookups for a missing bucket** use a number no bucket has, so they find nothing, as before.
- **Lifecycle expiry** seeks to its bucket's keys instead of walking the whole index.
- **Results at 1M objects** (`docs/benchmarks/2026-11-09-bucket-numbers.md`):
  - T9 met again: 376 bytes per object (from 423), 396 after recovery;
  - T10 and T11 still met (about 1 ms a page; 1.43 to 1.55 s to serving).
- **Tests:** `bucketNumbersSurviveRecreateAndReopen`, plus 115 others. s3-tests subset 252, the SDK checks, both
  smokes.
- **Next:**
  - T7: checkpoints without the store's lock;
  - T9's margin: the version's rarely used fields out of line.

### 9 Nov 2026: M4 slice 9, checkpoints in steps (ADR-0028)

- **A checkpoint is a job of steps:**
  - it begins under the store's lock (header, buckets, uploads, a snapshot of the index);
  - it encodes 4,096 index entries a step under the lock;
  - it writes, syncs and publishes without the lock.
- **The index keeps what the snapshot still needs.** A key changed before the walk reaches it keeps its version at
  the checkpoint's LSN. So the file is exactly the state at that LSN, and recovery is unchanged. A file is published
  only if it holds the entries its header counts.
- **Results** (`docs/benchmarks/2026-11-09-stepped-checkpoints.md`):
  - the 1M fill's slowest PUT went from 446 to 662 ms down to 72 ms, and p99 from about 60 to 36 ms;
  - T7 at concurrency 8: 28 of 30 phases within 50 ms; 128 B overwrite at 55 ms, and one 109 ms spike in 16 KiB
    delete. Not met yet.
- **Tests:** the checkpoint written in steps of three, with changes ahead of and behind the walk, decoded and
  compared with the state at its LSN. Fault sweeps (once, sticky, torn, crash, crash while opening) of a stepped
  workload. A no-keep mutant fails them. 123 tests, s3-tests subset 252, the SDK checks, both smokes.
- **Next:**
  - T7: time the upkeep's parts, then compaction's plan out from under the lock;
  - a quiet run.

### 9 Nov 2026: M4 slice 10, upkeep timing and compaction in steps (ADR-0029)

- **Upkeep's holds of the store are timed:**
  - the stats endpoint counts them, the slow ones (10 ms or more), and the longest;
  - the server logs each checkpoint, each compaction and each slow hold, with its parts;
  - `tools/bench` records each phase's slow holds.
- **That found T7's last stall:** compaction held the store for 111 ms while copying 576 records. Checkpoints in steps
  held it for under a millisecond.
- **Compaction runs in steps:**
  - it plans 4,096 index entries a step and reads the records to copy without the lock;
  - it commits the copies about 1 MiB a step;
  - a copy of a version changed meanwhile is garbage when applied, as before (ADR-0005 §9).
- **Results** (`docs/benchmarks/2026-11-09-upkeep-in-steps.md`): at concurrency 8, 29 of 30 phases within 50 ms. The
  30th was at 53 ms, with no upkeep hold during it. Two compactions of 800 to 900 copies ran with p99.9 at most 36 ms
  beside them.
- **Tests:** hold counting; a compaction with an overwrite, a delete and writes between its steps; fault sweeps
  (once, sticky, torn, crash) of a stepped compaction. 130 tests, s3-tests subset 252, the SDK checks, both smokes.
- **Next:**
  - a quiet reference run of the whole matrix;
  - T2.

### 9 Nov 2026: M4 reference run

- **The whole matrix and the 1M scale run at `7e99bb0`, on a quiet machine** (load average 1.8 to 4.4), against every
  target (`docs/benchmarks/2026-11-09-m4-reference.md`). This is the reference for M4's p99 regression gates.
- **T2 restated** with the user: ≤ 70 syncs per 1,000 tiny PUTs at concurrency 32, about 2 per client for closed-loop
  clients (`docs/targets.md`). It is met at 64.
- **Met:** T2 to T6 and T8 to T12.
- **Short:**
  - T1 at 4 KiB: 2,908/s against 3,000. 0 B to 1 KiB ran at 3,161 to 3,267, and 4 KiB ran at 3,300 in earlier runs.
  - T7 in one phase of 30: 4 KiB PUT at 53.1 ms p99.9, with no upkeep hold during it.
- **From the baseline,** at concurrency 32:
  - tiny PUT went from about 200 to 3,000/s, with p99 from up to 550 ms down to 16 ms;
  - small GET went from up to 2,300 to 21,000 to 27,000/s;
  - HEAD went from up to 14,600 to 34,000 to 42,000/s;
  - DELETE went from about 200 to 3,000/s.
- **Not done from M4's plan:**
  - journal shards and per-core appenders;
  - the comparison against SeaweedFS, Garage and RustFS;
  - p99 regression gates in CI.

### 9 Nov 2026: M4 p99 regression gates (ADR-0030)

- **CI** (`.github/workflows/ci.yml`, macOS 15, compiler and CeeSafe.Web pinned):
  - `check` runs `ceesafec check`, `fmt --check` and `test`, then the build and both smokes;
  - `perf` runs the p99 regression gate.
- **The gate compares builds, not numbers** (`tools/perf_gate.sh`, `tools/bench/gate`):
  - the base and the head run in turns on the same runner, 3 rounds, and every ratio is taken within a round;
  - a group of phases (writes, GETs or metadata reads; small or large; one concurrency) fails past p99 × 1.25 for
    writes or × 1.5 for reads, or ops/s × 0.80, and only beyond the base's own spread between rounds;
  - errors, and syncs per 1,000 writes, fail per phase;
  - a run too noisy to judge (median group noise above 2) is inconclusive: a warning in CI, not a pass or a failure.
- **Targets as data** (`tools/bench/targets.json`): `gate -targets` checks a matrix run and a `tools/scale.sh` run
  against T1 to T12. On the M4 reference it reports what the reference's report does (T1 at 4 KiB and T7 in one
  phase short; T12 1.09).
- **Trials** on this machine, under other sessions' load (average 3 to 50):
  - the same build against itself passed at normal load and was inconclusive when the machine was busy;
  - slice 3 (`767a811`) against now failed every time: deletes at 1,000 syncs per 1,000, and, at normal load,
    small writes (p99 × 2.62, ops/s × 0.34) and small GETs (ops/s × 0.58).
- `tools/bench -read-repeat`: small GET and HEAD phases go over their keys several times, so they last seconds.
- **Next:**
  - the first CI runs measure the runner's noise; the tolerances may move with them;
  - the rest of M4: journal shards and per-core appenders, and the comparison run.

### 10 Nov 2026: small PUTs on the event loop (ADR-0031)

- **Journal shards do not help this device.** A probe of parallel `F_FULLFSYNC`s on separate files: 221 syncs/s with
  one writer, 219 with two, 419 with eight at four times the latency each. The SSD flushes about one at a time, and
  at concurrency 8 and 32 the store already runs at that rate. Shards stay in the plan for devices with parallel
  flushes, measured with the same probe first.
- **What did limit it, at concurrency 128:** serial work on the event loop between syncs. A profile put 19% of the
  loop in `Async.blocking`'s thread per call (G28) and 20% in the `AsyncMutex` wake-up's `write` (new gap G30).
- **An inline object's PUT now runs on the event loop:** the writer's in-memory steps and `putInlineDeferred`, which
  stages without committing or gives null when the batch is full. N0295 proves no I/O on that path. Larger objects,
  conditional PUTs and full batches take the worker thread as before.
- **That exposed a group-commit ordering problem,** fixed in an ADR-0022 amendment. Requests already in the batch
  being cut queued for the commit turn behind the next leader, and two barriers by parity were reused too soon.
  Batches at concurrency 32 fell to 3 to 10 writes. Now a request waits on the leader's barrier, and eight barriers
  are used in turn.
- **Results** (`tools/perf_gate.sh`, `docs/benchmarks/2026-11-10-small-puts-on-the-loop.md`):
  - small writes at concurrency 128: 1.76 times the throughput, 0.56 times the p99 (0 B and 1 KiB PUTs 10,600 to
    11,800/s);
  - at concurrency 32: 1.09 and 0.89, 4 KiB PUT at 3,118/s;
  - the gate passed.
- **Tests:** `inlinePutsStageWithoutCommitting`; the group-commit fault sweeps stage through the new path. 131 tests,
  the s3-tests subset 252, the SDK checks, both smokes.
- **CI:** the S3 smoke's virtual-host checks need `smoke.localhost` in the runner's `/etc/hosts`. tls_smoke's test
  certificate needs `serverAuth` in its extended key usage: AWS CLI 2.39 uploads through its CRT client, which on
  macOS verifies with Apple's TLS. CI passed on `5c81a49`.

### 10 Nov 2026: inline PUTs start without the store's lock (ADR-0032)

- **An inline-sized PUT takes the store's lock once, to stage.** Its writer comes from a `WriterFactory` that `serve`
  takes from the store when it opens. The bucket check and admission run at staging (`checkPut`), after a body of at
  most 128 KiB. Larger PUTs and POST object still start under the lock, refused before the body.
- **Results** (`tools/perf_gate.sh` against `5c81a49`, `docs/benchmarks/2026-11-10-inline-puts-without-the-lock.md`):
  small writes at concurrency 128 at 1.03 times the throughput and 0.95 times the p99, mostly within the noise;
  overwrites gained most. The gate passed.
- **Tests:** `factoryWritersAreTheStores`; s3_smoke checks a small and a large PUT to a missing bucket. 132 tests, the
  s3-tests subset 252, the SDK checks, both smokes.

### 10 Nov 2026: allocations per request (`docs/benchmarks/2026-11-10-allocations.md`)

- **Counted with heaptrack** on Linux (a container on a Debian server, CosmoStore `47fb72e`), 128 B objects: 112
  allocations per PUT, 87 per GET, 74 per HEAD, 83 per DELETE. macOS's `malloc_history` sees only live blocks.
- **Where:** about 31 in `S3Request.of` (two vectors per header, names lowercased byte by byte), about 34 in SigV4
  (a vector per Authorization field, the canonical request and string to sign grown as built, hex), about 15 in the
  response headers, about 15 in the store.
- **What they cost: under 1% of the CPU samples** in the ADR-0031 profiles at concurrency 128. No change now; the
  document lists the changes (one buffer with offsets for the headers and the Authorization fields, buffers sized
  once) for hardware where the allocator shows.
- **Arenas per request do not fit CeeSafe as it is:** an `Arena` gives scoped slices, which struct fields cannot
  hold (N0246), and `Vector` cannot allocate from one. The M4 item is closed as measured.

### 10 Nov 2026: latencies and upkeep debt in the stats endpoint (ADR-0033)

- **The dashboards' figures, from the server:** `GET /_cosmostore/stats` now reports, besides the syncs and bytes
  written that give syncs per 1,000 PUTs and write amplification:
  - p50, p99 and p99.9 of PutObject, GetObject, HeadObject, DeleteObject and the other requests, from histograms of
    atomic counters (buckets at most 12.5% wide), timed to the end of each response;
  - compaction debt: the bytes the compactions due now would free and copy;
  - the journal bytes no checkpoint covers, which recovery replays.
- **No dashboard in the server:** the JSON is for whatever draws it. Percentiles cover the server's life; per-window
  ones wait for a dashboard that needs them.
- **Tests:** `latencyHistogramBuckets`, `upkeepDebtFollowsCheckpointAndCompaction`. 134 tests, the s3-tests subset
  252, the SDK checks, both smokes.
- **Cost:** none measurable. The CI gate showed small groups at concurrency 32 at 0.82 times; on a quiet Debian server
  (3 rounds, `tools/perf_gate.sh`) every group was within 0.96 to 1.01 times, so that was the runner's noise.

### 10 Nov 2026: the comparison run (`docs/benchmarks/2026-11-10-comparison.md`)

- **`tools/compare/compare.sh`** runs CosmoStore, SeaweedFS 4.53, Garage v2.5.0 or RustFS 1.0.4 in a container (same
  CPU limit, same filesystem, host network) and measures it with `tools/bench`; `report.py` makes the tables. Each
  server ran with every fsync option on (like for like) and as shipped; RustFS's default is already durable.
- **Host:** a Debian 13 server (Xeon E3-1245 V2, a data-center SATA SSD with power-loss protection), 2 CPUs per
  server, one run per configuration.
- **Small objects, durable:** CosmoStore's PUTs at 8,200 to 10,400/s at concurrency 32 and 128, 2.7 to 7.7 times
  the next (SeaweedFS with fsync), and ahead of SeaweedFS and Garage without fsync; p99 4.7 to 6.3 ms at concurrency
  32. GET 1.5 to 2.9 times the next, HEAD about twice RustFS, deletes about twice SeaweedFS.
- **1 MiB:** PUT in the middle (160/s against 145 to 252). **GET behind:** 460/s against 920 for SeaweedFS and 760
  for RustFS.
- **Memory:** 216 MiB peak, against 121 for Garage, 783 for RustFS and 1.8 GiB for SeaweedFS. No errors anywhere.
- **Garage's 4 KiB GETs** take 44 ms each at every concurrency (a delayed-ACK pattern, just above its inline size):
  noted as an anomaly, to report upstream.
- **Next:**
  - the 1 MiB GET path (half SeaweedFS's rate with 2 CPUs): a profile of large reads;
  - a quiet reference run on the M1, for T1 at 4 KiB and T7;
  - a profile at concurrency 128 (G30's wake-ups remain at staging).

