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
  M8 Directory buckets ◄── M7 Advanced S3 ◄── M6 Cluster ◄── M5 Production features
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

**Closed 17 Nov 2026** (`docs/m7-exit-review.md`): the six items on `serve` and on a cluster (ADR-0071 to
ADR-0078); directory buckets and Tables were left out (ADR-0071 §3).

### M8: Directory buckets

ADR-0079 (accepted 18 Nov 2026) proposed directory buckets (CreateBucket with a directory
configuration, CreateSession and `s3express` signing, S3's limits for them), then S3 Tables (the `s3tables` catalog
API and the Iceberg REST calls an engine needs, commits as a compare-and-set).
The owner chose directory buckets only, with S3's limits enforced (18 Nov 2026); their design is ADR-0080 (accepted 18 Nov 2026), in three slices.

**Closed 18 Nov 2026** (`docs/m8-exit-review.md`): directory buckets on `serve` and on a cluster (ADR-0080), with
the exit review's findings closed and RenameObject (ADR-0081); S3 Tables wait until Iceberg engines are meant to run
against CosmoStore (ADR-0079).

### M9: S3 Tables

The owner: "Next we need s3 tables iceberg" (19 Nov 2026). ADR-0083 (accepted 19 Nov 2026) designs it.
- **Table buckets:** each is a hidden bucket. Its catalog is objects, with conditional writes as the compare-and-set.
- **The APIs:** the S3 Tables API (signed for `s3tables`), and the Iceberg REST catalog, which writes the metadata
  files itself.
- **Done when** PyIceberg can create a table, append to it and read it back, on `serve` and on a cluster.

**Closed 19 Nov 2026** (`docs/m9-exit-review.md`): S3 Tables and the Iceberg REST catalog on `serve` and on a cluster
(ADR-0083), with the exit review's findings closed, and table bucket and table policies (ADR-0084).

### M13: A cluster as `serve`

The owner chose ADR-0091's item A (19 Nov 2026), each node watching its own files. ADR-0092 (proposed) designs it:
- **Reloads:** each node reloads its credentials and users files as `serve` does, so a revocation needs no
  restart.
- **SSE:** `node --sse-key-file` and `--kms-key-file`, so SSE-S3 and SSE-KMS work on a cluster.
- **Done when** a key or user removed from every node's files is refused through every node without a restart, and
  SSE-S3 and SSE-KMS objects put through one node read through the others.

### M12: The long tail

**Closed 19 Nov 2026** (the owner: "Accept and close"; `docs/m12-exit-review.md`).

The owner chose ADR-0089's item A (19 Nov 2026), with archive classes refused. ADR-0090 (accepted 19 Nov 2026)
designs it:
- **Storage classes:** recorded on the object and answered, or refused, never dropped (a fix: they are dropped
  today).
- **Lifecycle transitions** to the classes kept here, recorded, not moved.
- **ListMultipartUploads' `delimiter`.**
- **SHA-1 checksums.**
- **A POST form's object lock fields.**
- **SSE-KMS's encryption context.**
- **Done when** each item, refused today, is taken and tested in the SDK matrix, on `serve` and on a cluster.

### M11: Identities

**Closed 19 Nov 2026** (the owner: "Accept and close"; `docs/m11-exit-review.md`).

The owner chose ADR-0087's item A (19 Nov 2026). ADR-0088 (accepted 19 Nov 2026) designs it:
- **The users file:** `account` lines name the account's keys; each user's name and id, its access keys and an
  identity policy; reloaded with the credentials file. With a users file, a key it names neither way is refused.
- **The decision, as IAM's in one account:** a Deny anywhere refuses; an identity or resource Allow allows; otherwise
  the request is refused.
- **AssumeRole sessions** are taken by S3 Tables.
- **Done when** a key restricted to one bucket's reads is refused everything else, through every SDK, on `serve` and
  on a cluster.

### M10: Table maintenance

The owner chose ADR-0085's item A, "and write the decoder here first" (19 Nov 2026). ADR-0086 (accepted 19 Nov 2026)
designs it:
- **Snapshot management:** snapshots are expired by age, keeping refs' heads and the newest few.
- **Unreferenced file removal:** files no snapshot references are noted, then deleted after
  `unreferencedDays + nonCurrentDays`. A run that cannot read a manifest deletes nothing.
- **The readers:** an inflate decoder and an Avro reader, with no C.
- **Done when** a PyIceberg table appended to many times keeps its warehouse bounded and still reads back, on `serve`
  and on a cluster.

**Closed 19 Nov 2026** (`docs/m10-exit-review.md`): snapshot management and unreferenced file removal on `serve` and on
a cluster (ADR-0086), with an inflate decoder and an Avro reader. The exit review's findings are closed: removal
deletes only what no reference names.

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

### 10 Nov 2026: large GETs (ADR-0034, `docs/benchmarks/2026-11-10-large-gets.md`)

- **Profile of 1 MiB GETs:** 28% `Crc32c.update` (the extent's check), 26% worker threads (three `Async.blocking`
  per GET, G28), 18% the socket, 12% zeroing a new 1 MiB buffer.
- **Changes:** the read loop stops at the planned length (no last read to find the end); an extent reader is taken
  without a worker thread (`takeReady`); 1 MiB body buffers are reused from a pool of 4.
- **A pool of 32 raised the p99 of 1 MiB GETs at concurrency 32 by half** on the Debian server: first in, first out,
  32 MiB cycled through an 8 MiB cache. Five variants, 5 rounds each, separated the three changes.
- **Results on the Debian server:** 1 MiB GETs 1.20 times at concurrency 1, unchanged at 32; PUTs 1.06 and 1.00.
  On the M1, 1 MiB GETs went from 394 to 508/s to 701 to 761/s (under load).
- **What bounds large GETs is the CRC32C:** lib/std's software CRC runs at 1.5 GB/s against 7 GB/s for the CPU's
  instruction. New gap G31; the comparison's gap stays until CeeSafe can use it.
- **Next:**
  - a quiet reference run on the M1, for T1 at 4 KiB and T7;
  - a profile at concurrency 128 (G30's wake-ups remain at staging);
  - the CRC32C instruction when CeeSafe has it (G31), then the comparison run again for large objects.


### 11 Nov 2026: small requests, the profile at concurrency 128 (ADR-0035, `docs/benchmarks/2026-11-11-c128-profile.md`)

- **Profile** (Debian server, `gdb` stack samples, 4 KiB PUTs at concurrency 128): G30's wake-pipe write is not in
  a single sample. The event loop spent 13% zeroing a 20 KiB body buffer (16 KiB of slack) and 6% deriving the
  SigV4 signing key.
- **Changes:** body-buffer slack 1 KiB; the signing key cached per credential for its date and region (a sequence
  lock over atomics).
- **Results on the Debian server:** 4 KiB PUTs 1.07 and 1.04 times with the slack; the cache adds 8 to 13% in four
  of six groups, in two runs. Small reads' p50 fell 15 to 28%, but their p99 (a stall of 20 to 30 ms, against a p50
  of 1 to 5 ms) rose 7 to 18%. Gates passed.
- **Local builds:** the shared CeeSafe.Web checkout moved to a commit needing ceesafec 0.27; checks ran against a
  clone at CI's pinned `0f7290c`.
- **Next:**
  - a quiet reference run on the M1, for T1 at 4 KiB and T7;
  - the CRC32C instruction when CeeSafe has it (G31), then the comparison run again for large objects.

### 11 Nov 2026: small reads' tail was the CPU quota

- **The 20 to 30 ms tail of small reads** on the Debian server came from `--cpus 2`: the container (client and server)
  used its 200 ms per 100 ms period early, on several of the host's threads, and stalled for the rest of it, in 10
  of 11 periods. On 2 pinned cores: 0-byte GETs' p99 7.7 ms at concurrency 32 (30 ms) and 15.2 ms at 128 (39 ms).
- **The signing-key cache on pinned cores:** small reads' p99 0.86 and 0.87 times, writes' 0.98 to 1.00,
  throughput 1.00 to 1.08 (ADR-0035, amended).
- **The comparison run's p99 columns** may hold such stalls too (its servers ran under the quota, its client
  outside): noted in its caveats. `tools/compare/compare.sh` takes `CPUSET` to pin cores instead.
- **Next:**
  - a quiet reference run on the M1, for T1 at 4 KiB and T7;
  - the comparison run again on pinned cores, when large objects change (G31).

### 11 Nov 2026: ceesafec 0.30.0 and CeeSafe.Web `82a3a73`

- **CeeSafe 0.30.0** fixes G31 (its ADR 0089): `Crc32c` uses the CPU's CRC-32C instruction where the CPU has it,
  asked at run time, and the tables elsewhere; 1,652 to 8,147 MB/s on the M1, one chain. `ceesafe.toml` now
  requires 0.30.0, so no build checksums at the old speed.
- **CeeSafe.Web `82a3a73`** (its toolchain 0.27 move, CeeSafe ADR 0084): route handlers are `Send + Share`. The one
  change in CosmoStore is `s3Handler`'s type in `src/s3/serve.cee`.
- **Checks on 0.30.0:** check, fmt, the 136 tests (no leaks), S3 and TLS smoke, the 252 s3-tests, boto3, Go, JS and
  rclone, all passed.
- **CI** pins v0.30.0 and `82a3a73`. The perf gate's base now builds with its own commit's pins (`CEESAFE_VERSION`,
  `CEESAFE_WEB_REF` in its `ci.yml`), so a toolchain move is measured, and a base the new CeeSafe.Web no longer
  compiles still builds.
- **Speed:** a 1 MiB A/B on the M1 was inconclusive (load average 3 to 4.7; noise 2.56 against the gate's 2.00), and
  its writes wait on `fsync`. Measured next on the Debian server's pinned cores.
- **On the Debian server's pinned cores** (perf gate, 5 rounds): 1 MiB GETs 1.19 and 1.20 times, PUTs and overwrites
  1.05 and 1.06, small requests unchanged; noise 1.01 to 1.60, gate passed.

### 11 Nov 2026: the comparison run on pinned cores (`docs/benchmarks/2026-11-11-comparison-pinned.md`)

- **Setup:** each server on cores 2 and 3 (no quota), `tools/bench` on 0, 1, 4 and 5. CosmoStore `d509388`
  (ceesafec 0.30.0). A first run with the client on 4 to 7 was discarded: cpu N and N+4 are one core's two threads,
  so the client shared the servers' cores. `compare.sh` takes `CLIENT_CPUSET` now.
- **CosmoStore against 10 Nov:** 1.17 times the throughput and 0.82 times the p99 (geometric means over 60 phases);
  the other servers moved 2 to 9%.
- **Where it stands:**
  - small writes, durable: 3.5 to 8.0 times the next durable server;
  - small reads: 1.5 to 3.7 times;
  - 64 KiB PUTs: 2.1 times;
  - 1 MiB PUTs: in the middle.
- **Behind:**
  - 1 MiB GETs at concurrency 32 and 128: 582 to 632/s against 930 to 1,050 for SeaweedFS and RustFS (0.59 to
    0.67 times; up from 459 to 465);
  - 64 KiB GETs: 0.78 to 0.87 times RustFS.
- **Builds on pinned cores** (64 KiB and 1 MiB GETs, two rounds): `1aa265d`, `d98531b`, `f7a52bd` and `d509388`. No
  regression between them. ADR-0034 gives 9% on 1 MiB GETs at concurrency 32, the CRC32C instruction 7 to 14%.
- **Next:**
  - profile 1 MiB GETs at concurrency 32 on pinned cores: what bounds them at 60% of SeaweedFS and RustFS;
  - a quiet reference run on the M1, for T1 at 4 KiB and T7.

### 11 Nov 2026: 1 MiB GETs, the profile and a pool of 32 (ADR-0036, `docs/benchmarks/2026-11-11-get-1mib-profile.md`)

- **Profile** (Debian server, server on two pinned cores, 60 `gdb` samples, GETs at concurrency 32): the event
  loop is never idle. Its time:
  - 52% `sendmsg` of responses;
  - 15% zeroing fresh 1 MiB buffers (the pool of 4 ran dry);
  - 15% starting a thread per `Async.blocking` read (G28).
- **Change:** the body-buffer pool keeps 32 buffers. Gate on pinned cores: 1 MiB GETs at concurrency 32 1.13 times
  the throughput, p99 0.90; nothing else moved. With the client on other cores, 819 to 859/s from 664 to 715.
  Idle RSS after load about 220 MiB, from 100. ADR-0034's p99 rise with 32 did not come back.
- **Next:**
  - G28 in CeeSafe: a thread pool for `Async.blocking` (an ADR there, then a release);
  - a quiet reference run on the M1, for T1 at 4 KiB and T7.

### 11 Nov 2026: ceesafec 0.36.0, a thread pool for `Async.blocking` (G28 fixed)

- **CeeSafe 0.36.0** fixes G28 (its ADR 0094, raised from this repo's profile): each `Async.run` keeps a pool of
  worker threads for its `Async.blocking` calls, reused from call to call; idle ones leave after 10 seconds, and the
  rest are joined when the run ends. A call on Linux goes from 20–27 to 7–9 µs.
- **What it gives CosmoStore** (b712ef8 without and with the pool, server on two pinned cores, `tools/perf_gate.sh`,
  5 alternating rounds, passed): small GETs at concurrency 32 1.43 times the throughput, 1 MiB PUTs at 32 1.28 times
  (p99 0.82 times), small writes 1.07 to 1.10 times, the rest within noise. 1 MiB GETs at 32: about 839 to 1,073 a
  second; at 128 unchanged (about 740).
- **The move:** `ceesafe.toml` requires `>=0.36.0`; CI pins v0.36.0. CeeSafe.Web stays at `82a3a73` (its later
  commits are fuzzing, docs and plans).
- **Checks on 0.36.0:** check, fmt, the 136 tests (no leaks), S3 and TLS smoke, the 252 s3-tests, boto3, Go, JS and
  rclone, all passed.
- **Next:**
  - profile 1 MiB GETs again on 0.36.0, where `sendmsg` (52% before) is the largest share left;
  - a quiet reference run on the M1, for T1 at 4 KiB and T7.

### 11 Nov 2026: 1 MiB GETs on 0.36.0 and a write buffer of 64 KiB (ADR-0037, `docs/benchmarks/2026-11-11-get-1mib-profile-0.36.md`)

- **Profile on 0.36.0** (Debian server, server on two pinned cores, 60 `gdb` samples, GETs at concurrency 32): no
  thread starts and no zeroing are left. The event loop, still never idle:
  - 58% `sendmsg`;
  - 15% copying the body into CeeSafe.Web's 16 KiB write buffer (`Exchange.write`);
  - 10% waking a pooled worker for each read.
- **The pool alone** (A/B, client on other cores): 1 MiB GETs at concurrency 32 from 839–847/s to 1,012–1,079/s.
- **Change:** `Limits.writeBufferBytes` 64 KiB, from 16 KiB: 1,290–1,322 GETs/s at concurrency 32, 911–1,011 at
  128 (712–838 before). The gate passed: large GETs 1.11–1.12 times, p99 0.84–0.92; the rest within noise. About
  9 MiB more RSS after a load at 128; 256 KiB gained little more for 57 MiB.
- **Next:**
  - a CeeSafe.Web ADR: `Exchange.write` sending a large slice without copying it into the write buffer;
  - the pinned comparison again, on 0.36.0 with ADR-0037;
  - a quiet reference run on the M1, for T1 at 4 KiB and T7.

### 12 Nov 2026: CeeSafe.Web `c799f14` and back to a 16 KiB write buffer (ADR-0038)

- **CeeSafe.Web** (its ADR 0013 amendment 4, PR #12 from this repo's profile): over HTTP/1.1, `Exchange.write`
  sends a slice at least as large as its write buffer straight to the socket, without copying it into the buffer.
  CI pins `c799f14`, from `82a3a73`.
- **Change:** `s3Server` drops ADR-0037's 64 KiB `Limits.writeBufferBytes`; the default, 16 KiB, is back, and each
  HTTP/1.1 connection holds 32 KiB of write buffers, not 128.
- **1 MiB GETs** (Debian server, server on two pinned cores, client on others, 3 alternating rounds, against
  `fe50ca3`, 5 rounds): about the same at concurrency 32; 1,237–1,294/s at 128 (875–964 before), median latency
  87–96 ms from 128–144, p99 within noise (180–222 against 175–195 ms), p99.9 192–253 from 180–201.
- **Gate** (`tools/perf_gate.sh` against `fe50ca3`, 5 rounds, pinned cores): passed; large GETs 1.06–1.08 times,
  p99 0.98–1.00; the rest within noise.
- **Checks:** check, fmt, the 136 tests (no leaks), S3 and TLS smoke, the 252 s3-tests, boto3, Go, JS and rclone,
  all passed.
- **Next:**
  - the pinned comparison again, on 0.36.0 and `c799f14`;
  - a quiet reference run on the M1, for T1 at 4 KiB and T7.

### 12 Nov 2026: the pinned comparison again (`docs/benchmarks/2026-11-12-comparison-pinned.md`)

- **The 11 Nov run again**, same server, images, matrix and pinning; CosmoStore `56cc1d2` (ceesafec 0.36.0, CeeSafe.Web
  `c799f14`) instead of `d509388`. The other servers moved 0 to 2%; CosmoStore 1.20 times the throughput (geometric
  mean over its 60 phases), p99 0.84 times.
- **CosmoStore leads the durable servers in 59 of 60 cells;** the exception is 1 MiB deletes at concurrency 128
  (0.87 times SeaweedFS with fsync).
- **1 MiB GETs:** 1,539/s at concurrency 32 and 1,231/s at 128, 1.21 to 1.51 times SeaweedFS and RustFS (0.59 to 0.67
  times on 11 Nov). 4 KiB and 64 KiB GETs 2.1 to 2.2 times 11 Nov.
- **Behind the servers without fsync** only at concurrency 1 (small writes and deletes, 1 MiB writes and deletes)
  and for 1 MiB PUTs and overwrites at 32 (0.87 to 0.91 times). Peak RSS 279 MiB.
- **Next:**
  - a quiet reference run on the M1, for T1 at 4 KiB and T7.

### 12 Nov 2026: the M4 matrix on an Intel Mac mini (`docs/benchmarks/2026-11-12-mac-mini-intel.md`)

- **A second machine, not the reference:** a 2018 Mac mini (Intel Core i7-8700B, Apple SSD), `805464a` on
  ceesafec 0.36.0's `osx-x64` build, the reference run's matrix. One sync costs 22 ms there, 4.3 times the M1's.
- **Counted in syncs, it matches the M1:** 64 syncs per 1,000 tiny PUTs at concurrency 32 (T2) on both, so T1 runs
  at 688 to 694/s, 0.23 times the M1 as the sync rate; T3's p99 is 2.1 to 2.3 syncs on both. T5, T6 and T12 are
  met outright; reads are 1.1 to 1.3 times the M1, 1 MiB GETs 2.95 times. T7: 13 of 30 phases over 50 ms, the worst
  140.6 ms (6.3 syncs; the M1's 50 ms is 9.6). 64 KiB deletes at concurrency 8 are slower even in syncs: compaction's
  steps each wait on a 22 ms sync.
- **Found:** with the default 256 open files, 128 concurrent 256 KiB PUTs ran out of descriptors; the journal
  fail-stopped on a failed open (a group commit's sync handle, before anything was written) and refused every write
  until a restart, logging only `journal error`. Nothing acknowledged was lost (fsck clean). With `ulimit -n 10240`
  the run was clean. CeeSafe cannot raise the limit: CEESAFE_GAPS G32.
- **Next:**
  - an ADR: a failed open before any write does not fail the journal, a failed rotation is retried, and the cause is
    logged (with a fault sweep);
  - a quiet reference run on the M1, for T1 at 4 KiB and T7.

### 12 Nov 2026: out of descriptors, the journal keeps going (ADR-0039)

- **The Mac mini's failure, fixed:** a group commit whose sync handle cannot be opened gives no ticket, and the
  leader commits the batch under the store's lock instead; nothing was written, so nothing is failed or rewound. A
  failed rotation leaves the journal running when nothing it created is left behind: the file is removed and the
  directory synced before the active segment takes another record, or the journal fails as before.
- **"Too many open files" is a 503**, which SDKs retry; the journal's failure is logged once with its cause, and
  maintenance errors name the operation and errno. The stats count `journalRotationFailures` and
  `journalSyncHandleFallbacks`.
- **On the mini at 256 open files:** 84 of 1,000 concurrent 256 KiB PUTs and 9 overwrites got 503, then every later
  phase ran without errors; fsck clean. Before, the store refused every write until a restart.
- **Tests:** five journal fault tests (each rotation step, the crash model with an unsynced batch, a removal that
  fails, the ticket's open), one for the store, one for the 503. Breaking the fix in a copy is caught. The fault
  sweeps pass unchanged.
- **Next:**
  - a quiet reference run on the M1, for T1 at 4 KiB and T7;
  - `serve` raising its own open-file limit once CeeSafe can (G32).

### 12 Nov 2026: ceesafec 0.38.0

- **CeeSafe 0.37.0 and 0.38.0** (released by other sessions): a plain static of scalar data is C's `const`
  (ADR 0098); `resize` takes zeroed memory (ADR 0099); check elimination for equality tests, binary searches and
  resized vectors (ADR 0100); the system allocator's inline path (ADR 0101).
- **The move:** `ceesafe.toml` requires `>=0.38.0`; CI pins v0.38.0. CeeSafe.Web stays at `c799f14` (nothing newer).
- **Gate** (`70396d5` built with 0.36.0 and with 0.38.0, Debian, pinned cores, 5 rounds): passed, every group
  within noise (throughput 0.98 to 1.02, p99 0.98 to 1.01).
- **1 MiB GETs** (client on other cores, 3 rounds): at concurrency 128, 1,451–1,506/s from 1,182–1,250 (1.2 times),
  median 77–81 ms from 88–101, p99 within noise; at 32 unchanged.
- **Checks on 0.38.0:** check, fmt, the 143 tests (no leaks), S3 and TLS smoke, the 252 s3-tests, boto3, Go, JS and
  rclone, all passed.
- **Next:**
  - a quiet reference run on the M1, for T1 at 4 KiB and T7 (this Mac was busy: a VM at a full core, load average 44);
  - `serve` raising its own open-file limit once CeeSafe can (G32).

### 12 Nov 2026: the volume's free space in admission (ADR-0040)

- **G24 had been fixed in CeeSafe 0.21.0** (`Directory.space`), but CosmoStore never used it: with the default
  configuration (no `capacityBytes`), nothing stopped writes before the volume filled, and the journal then failed on
  `ENOSPC`.
- **Change:** the store measures the volume at open and at the start of each upkeep round (through `Fs.space`, with
  a failpoint), and admission keeps each write and the reserve (256 MiB) within the measured available bytes, less
  what the store has grown since. Deletes, checkpoints and compaction still never ask. A failed measurement keeps the
  last one. The stats show `volumeBytes` and `volumeAvailableBytes`.
- **Tests:** measured at open; a nearly full volume admits one write, counts it and refuses the next, deletes work,
  and a new measurement admits again; a failed measurement keeps the last figure. Breaking the fix in a copy is
  caught.
- **Next:**
  - a quiet reference run on the M1, for T1 at 4 KiB and T7;
  - CeeSafe ADR 0102 for G32 (the open-file limit), for the owner's decision.

### 13 Nov 2026: ceesafec 0.41.0, and `serve` raises its open-file limit (G32 fixed)

- **CeeSafe 0.41.0** (its ADR 0104, from G32, accepted by the owner as proposed; 0.39.0 and 0.40.0 went to other
  sessions' ADRs 0102 and 0103 the same day): `ProcessLimits.openFiles()` and `raiseOpenFiles(to)`, and the built-in
  `IoError.TooManyOpenFiles` (`EMFILE`, `ENFILE`).
- **Change:** `serve` raises its soft open-file limit at start as far as the system allows and logs it (ADR-0039
  amendment). `IoFailure` maps the new variant to `EMFILE`, so ADR-0039's 503 holds; a unit test checks it.
- **The move:** `ceesafe.toml` requires `>=0.41.0`; CI pins v0.41.0; CeeSafe.Web stays at `c799f14`.
- **Next:**
  - a quiet reference run on the M1, for T1 at 4 KiB and T7.

### 13 Nov 2026: the second M1 reference run (`docs/benchmarks/2026-11-13-m1-reference.md`)

- **The quiet run, at last:** the matrix and the 1M scale run at `48709f4` (ceesafec 0.41.0, CeeSafe.Web `c799f14`)
  on the M1 at a load average of 2.2 to 3.2, then 8 repeats of the tiny phases. No errors; fsck clean.
- **It does not settle T1 or T7; it shows what they are:**
  - T1 is short at every size in the matrix (2,580 to 2,991/s), not only at 4 KiB. Every phase costs 64 syncs per
    1,000 PUTs, so 3,000/s needs a sync of 5.2 ms; the device's median was 5.6 ms (168 to 202 syncs a second over 28
    phases). Over 36 phases at concurrency 32, 11 reached 3,000 (2,260 to 3,262). The store's part has not moved
    since slice 2.
  - T7: 29 of 30 again, the same phase as the first reference (4 KiB PUT, 51.2 ms, no upkeep hold), but not a fixed
    cause: three more runs of the same sequence gave 19 to 42 ms, and none of 120 phases in the repeats passed
    50 ms.
  - T4 at 128 B (174/s against the baseline's 196) and T5's p99 at 4 KiB in one phase (6.0 ms; 1.6 to 3.5 in the
    repeats) are short by the gate's rules in this run.
- **Met:** T2, T3, T6, T8 to T12 (386 bytes per object, pages in 0.85 ms, recovery in 1.48 s, amplification 1.02).
- **Since the first reference:** tiny PUTs at concurrency 128 at 9,200 to 11,100/s from 4,800 to 5,600; 1 MiB GETs
  at 1,769 MiB/s from 856; GETs 1.35 times and HEADs 1.24 times at the median; the 1M fill at 11,094/s from 5,030.
- **On the Intel Mac mini** (same commit, `osx-x64`, started at 256 open files): `serve` raised its limit to
  122,880 and the matrix ran without an error where the journal had fail-stopped (G32's fix confirmed); the 146
  tests pass. Its timings are not recorded: another session's tests loaded it.
- **The mini's footprint at 1M objects** was 543 bytes per object (466 after recovery), over T9's figure. It is the
  system's allocator, not the store: the same store recovers into the same 3.2 million blocks and 376 MB on both
  machines, and macOS 15 keeps freed large blocks as reusable pages in the footprint (156 MB after a fill, 78 MB
  after recovery; `vmmap --summary`). Live memory is 355 to 376 bytes per object on both.
- **T1 restated** (the user's decision): tiny PUT at concurrency 32 ≥ 12 times the same run's rate at concurrency
  1, where a PUT costs one sync; it was ≥ 3,000 ops/s. 64 syncs per 1,000 give 15.6 times; the floor allows for a
  phase of 64 syncs (12.4 to 18.0 times in 28 phases) and fails at two syncs a batch (7.8). `gate -targets` has the
  rule (`minTimesConcurrency1`); both M1 references and the mini's run meet it, the baseline does not (1.0 times).
- **M4's targets:** all met on the reference machine but for single phases of this run: T4 at 128 B, T5's p99 at
  4 KiB and T7, none of which repeated.
- **Next:**
  - M4's exit, for the user's word: the targets above, memory bounded, no compaction stalls, and the gates in CI
    are in place; journal shards stay for devices that sync in parallel. Then M5.

### 13 Nov 2026: M4 closed; M5 item 1, the versions of a key, in the store (ADR-0041, slices 1 and 2)

- **M4 is closed** (the user: continue): its targets are met on the reference machine but for single phases that
  did not repeat, memory is bounded, compaction and checkpoints run in steps, and the gates are in CI. Journal
  shards stay for devices that sync in parallel.
- **The formats had versions; the state did not.** Records have carried a version id since M1, but the index held
  one version per key, a `DeleteVersion` removed the key whatever its id, and a `DeleteMarker` applied as nothing.
- **The index holds chains** (`src/metadata/version_index.cee`): the B-tree gives a key's newest version, and a
  vector of links gives each version the next older one. The links are empty until a key has two versions, so an
  unversioned store pays nothing.
- **A record means one thing, whatever the bucket's state at replay:** a put or delete marker with the null id
  replaces the key's null version, wherever it is in the chain, and is the newest; with another id it only adds;
  `DeleteVersion` removes the version with its id. Every journal written so far replays as before.
- **Buckets have a versioning state** (a `BucketConfig` record of kind 3: enabled or suspended, never off again).
  Enabled, a put gets a new random id and a delete writes a marker; suspended, both write the null version.
- **Checkpoint format 6:** every version, a key's versions together and oldest first, a kind byte per version and
  the versioning byte per bucket; formats 1 to 5 still load. The snapshot of ADR-0028 keeps a changed key's whole
  chain.
- **The walks follow the chains:** compaction copies noncurrent inline versions, `verify` reads every version, the
  orphan sweep and the live-byte accounting count them, and a bucket is empty only without versions. HEAD, GET,
  ListObjects and "if absent" see no object under a marker. Lifecycle expires nothing in a versioned bucket until
  M5's item 2.
- **The store's API:** `deleteCurrent` (the marker's id), `deleteVersion`, `headVersion`, `prepareVersionReader`,
  `getObjectVersion`, `versionsOf`; a put's outcome and an object's info carry the version id. The S3 layer does not
  use them yet.
- **Tests (10 new, 156 in all, no leaks):** enabled and suspended behaviour; recovery from the journal, from a
  format 6 checkpoint and after compaction, with the live-byte invariant; a checkpoint written in steps while
  chains change behind and ahead of it; a crash at every byte of a versioned sequence; and fault sweeps of a
  versioned workload in the four modes (once, sticky, torn, crash), each followed by compaction and a checkpoint.
  Ten ways of breaking the change in a copy are each caught (two only after the tests were tightened: live bytes
  after a reopen, and a marker's record counted live).
- **Regression gate** (`tools/perf_gate.sh`, `0c85983`'s build against this one, on the M1 at load 1.8 to 2.2 with
  no build running): passed. p99 of this build over the base's by group, 0.91 to 1.01 (the one 1 MiB GET phase at
  concurrency 1 at 0.76, inside its noise of 3.24); operations per second 0.95 to 1.07; 64 syncs per 1,000 tiny
  PUTs at concurrency 32 in both. A first run, made while another session was building, was too noisy to give a
  verdict (noise 2.65) and is not counted.

### 13 Nov 2026: M5 item 1, versions in the S3 API (ADR-0041, slice 3)

- **The bucket's versioning:** PutBucketVersioning (`Enabled`, `Suspended`; MFA delete is NotImplemented) and
  GetBucketVersioning, over the store's `BucketConfig` kind 3.
- **A version id is 32 hex digits, `null` for the null id** (`src/s3/versions.cee`). Other text is InvalidArgument;
  an id the key lacks is NoSuchVersion (new) on a read.
- **Reads by version:** GET, HEAD, GetObjectAttributes, GetObjectTagging and a copy's source take `versionId`, and
  name the version in `x-amz-version-id` (`x-amz-copy-source-version-id`) when the bucket has versioning. A read
  that meets a delete marker says so: 404 with `x-amz-delete-marker: true` and the marker's id for a key under one,
  405 for the marker by its id.
- **Writes:** PUT, CopyObject, CompleteMultipartUpload and POST object return the new version's id.
  PutObjectTagging and DeleteObjectTagging take `versionId` (`setTagsOf`).
- **Deletes:** DELETE stays staged and acknowledged with its batch (`deleteDeferred`): without an id it returns the
  marker it wrote, with one it removes the version and says whether it was a marker. DeleteObjects takes version
  ids and reports markers, still in one commit (`deleteMany`); an entry whose id is no version id gets a
  NoSuchVersion error and the rest go on.
- **ListObjectVersions** (`listVersions`): versions and delete markers in key order, newest first, `IsLatest`,
  prefix and delimiter; `max-keys` counts versions, markers and common prefixes; a page may end inside a key's
  versions and the next starts after `key-marker` and `version-id-marker`. A marker whose version was removed in
  between passes the key.
- **A retried CompleteMultipartUpload finds its version under later ones** (`repeatedCompletion` walked only the
  current version): in a bucket with versioning a PUT after the completion no longer turns the retry into
  NoSuchUpload.
- **Tests (5 new in the store and the S3 layer, 161 in all, no leaks; six ways of breaking the new store code in a copy are each caught; 34 new checks in `tools/s3_smoke.sh`, 157 in all,
  with the AWS CLI):** pages of every size give the same listing; batches of deletes with and without ids, in
  buckets with and without versioning; tags by id; version ids as text; the versioning configuration. The fault
  sweep's permanent delete now goes through `deleteMany`.
- **Docs:** ADR-0041 §10, README, `docs/compatibility.md`.
- **Not done:** slice 4. The s3-tests subset and the SDK scripts have not been run against versioning; the smoke
  test with the AWS CLI is the only client check so far. Lifecycle rules still expire nothing in a bucket with
  versioning (M5 item 2).
- **Next:** slice 4 (the s3-tests versioning tests into the subset, the SDK matrix), then M5 item 2, lifecycle
  rules for noncurrent versions and expired delete markers.

### 13 Nov 2026: M5 item 1, the compatibility matrix with versioning (ADR-0041, slice 4)

- **s3-tests** (`5b39871`, boto3 1.42.97 with the CRT): with the `versioning` and `delete_marker` markers in scope,
  472 tests, 297 pass. The 33 new ones that are not `test_post_object*` join the subset, now 285, and all are
  versioning tests (create, read and remove by version; suspend; null version overwrite and removal; multi-object
  delete with markers; copies of versions; multipart version ids; the list marker; concurrent create and remove;
  conditional writes on the current version). The subset passes whole.
- **The suite's python needs the CRT.** A first run without it failed two date-header tests of the old subset and
  passed five tests outside it; with it the results are those of 9 Nov. `tools/s3tests/run.sh` now says so.
- **Versioning tests left out:** one expects `x-amz-delete-marker: false` on a plain 404 (S3 sends it only when
  true), one creates its bucket twice and expects success (BucketAlreadyOwnedByYou here), the rest need ACLs or
  Object Lock.
- **SDK matrix, all against this build:** boto3 72 checks (20 new: version ids on PUT, multipart and copy, reads by
  id, the marker's 404 fields, the paginator over versions, DeleteObjects with versions, suspended, and
  `object_versions.all().delete()`); rclone 20, Go 22, JavaScript 28 (client-s3 3.1168.0), Java 25, .NET 22 pass as
  before and do not exercise versioning.
- **Next:** M5 item 2, lifecycle rules for noncurrent versions and expired delete markers.

### 13 Nov 2026: M5 item 2, lifecycle rules and versions (ADR-0042)

- **Rules did nothing in a bucket with versioning** (ADR-0041 §9): a delete there writes a marker and frees nothing,
  `NoncurrentVersionExpiration` was NotImplemented and `ExpiredObjectDeleteMarker` was stored and ignored.
- **A rule has `noncurrentDays` and `newerNoncurrent`** (`src/store/bucket_config.cee`). The rules blob is version 2
  only when a rule uses them, so every blob written so far is unchanged; both versions load.
- **One pass per bucket decides per key from its chain** (`applyLifecycle`, `lifecycleTakes`):
  - the current object past its `Expiration` is deleted as a DELETE without an id does it: gone without versioning,
    under a delete marker with it;
  - a noncurrent version, markers too, goes `noncurrentDays` after the next newer version was written, if
    `newerNoncurrent` newer noncurrent versions stay;
  - a delete marker that is all its key has goes by `ExpiredObjectDeleteMarker`, or by an `Expiration` once the
    marker is that old.
  A marker has no size and no tags, so a rule filtering by either never takes one.
- **One commit per bucket and run** through `deleteManyAt`, the batch path of DeleteObjects with the run's time on
  its records. A run acts on the state it finds: the marker in one run, the object under it in a later one, then
  the marker.
- **S3:** `NoncurrentVersionExpiration` with `NoncurrentDays` (1 or more) and `NewerNoncurrentVersions` (1 to 100)
  is parsed and written back; `ExpiredObjectDeleteMarker` with a tag filter is InvalidRequest. Transitions stay
  NotImplemented.
- **A bug found on rereading the pass, before it was committed:** with versioning suspended, a key whose current
  object expired and whose old null version was due too got both deletes in one batch; the second, by the null id,
  removed the null marker the first had just written, and the object was current again, every run. The pass now
  leaves the null version to the marker that replaces it (ADR-0042 §7).
- **Tests (5 new, 166 in all, no leaks):** a bucket with versions through eleven runs of five rule sets, to empty,
  with recovery and fsck; the suspended case beside the same key in an enabled bucket; the blob's two versions and
  the marker filter; the cutoffs against the rules at every hour of ten days; the XML. Twenty ways of breaking the
  change in a copy are each caught (five only after the tests got a case for them: a lone marker's age, the enabled
  bucket beside the suspended one, and three wrong cutoffs).
- **Clients:** `tools/s3_smoke.sh` 159 checks, boto3 74, both with the new rules set and read back; the s3-tests
  subset is 286 with `test_lifecycle_set_noncurrent`, and passes whole (472 in scope, 298 pass).
- **No fault sweep of its own:** the pass writes no new kind of record. Its deletes are `DeleteVersion` and
  `DeleteMarker` records staged by `deleteManyAt`, which the versioned sweeps (once, sticky, torn, crash) go through.
- **The pass's hold of the store, measured** (the first upkeep after a restart, on copies of one store, builds that
  log every upkeep; the M1 under other sessions' load, so the spread is wide):
  - **The first version of the new pass was slower** on a bucket without versioning, 400,000 objects of 128 B and
    one `Expiration` rule that takes nothing yet: 9 to 18 ms (median 13) against 6 to 14 ms (median 10) for
    `48709f4` and 7 to 13 ms (median 9.5) for `a902b87`, ten restarts each at a load average of 4 to 6. Reading the
    tags later did not change that.
  - **With the cutoffs (ADR-0042 §9)** a version no rule can take yet costs one comparison. Ten more restarts each,
    with the 1-minute load average near 5 and the 5-minute one at 18 to 29: 9 to 37 ms (median 19.5) for the new pass, 9 to 43 ms (median 28.5) for
    `48709f4`, 14 to 37 ms (median 28) for `a902b87`; the new pass was at or under `48709f4` in 7 rounds of 10.
    That run was too loaded to say more than that the new pass is no longer the slower one.
  - **400,000 versions over 200,000 keys** (versioning enabled, one `NoncurrentVersionExpiration` rule): 6 to 13 ms
    in nine restarts of ten (one at 28 ms), the same before the cutoffs.
  - **Still one hold, not steps:** at these sizes the pass is at ADR-0029's 10 ms line, as it was before this change.
    It runs once an hour by default. Putting it in steps, as checkpoints and compaction are, is open.
- **The p99 gate was not run:** no bucket in it has rules, and the pass does not run for a bucket without them.
- **Not shown anywhere:** what a run did (`LifecycleReport`) is not in the stats or the log, as before.
- **Next:** M5 item 3 (bucket policies, an ACL compatibility mode, the public-access block). Object tagging is done
  (ADR-0017).

### 13 Nov 2026: M5 item 3, slice 1: bucket policies (ADR-0043)

- **Principals, chosen with the user** (continue, after the question of 13 Nov): the access keys of the credentials
  file, as `arn:aws:iam:::user/<access-key-id>`, and `*` for anyone. No users or accounts: every key is of the one
  account that owns every bucket, may do what no policy denies it, and is never refused the policy calls. A request
  with no credentials at all is *anonymous*, and may do only what a policy allows.
- **Stored as put** (`BucketConfig` kind 4, at most 20 KiB; checkpoint format 7) and parsed when used. Put-, Get- and
  DeleteBucketPolicy; MalformedPolicy and NoSuchBucketPolicy.
- **The language** (`src/s3/policy.cee`): Allow and Deny; `Principal`, `Action`, `Resource` and their `Not` forms
  (`NotPrincipal` with Deny only, as S3); wildcards; conditions with the string, IP (v4, v6, mapped v4), numeric,
  `Bool` and `Null` operators on `aws:SecureTransport`, `aws:SourceIp`, `aws:Referer`, `aws:UserAgent`, `s3:prefix`,
  `s3:delimiter` and `s3:max-keys`. What it cannot evaluate exactly (other keys and operators, `IfExists`,
  `ForAllValues`, policy variables, principals other than keys) is refused when put, never stored and ignored.
- **Every call is checked before it runs** (`serveS3`), with S3's action names; a copy's source by its bucket's
  policy, DeleteObjects key by key (a refused key gets AccessDenied in the result), POST object as its form's key.
- **No cost without policies:** two counts in the app (buckets with a policy, and with a Deny) are made at start and
  again after each policy change and bucket delete, before the response. A key's request reads its bucket's policy
  only when some policy has a Deny; an anonymous one only when some bucket has a policy, and is refused at once
  otherwise, as before.
- **Tests (9 new, 175 in all, no leaks; 18 ways of breaking the policy code in a copy are each caught, one only
  after a prefix ending inside a byte got its case):** the policy language (wildcards, addresses, a public-read policy, Deny and
  the Not forms, every condition operator with present and absent keys, 23 malformed documents, 9 refused as
  NotImplemented, 4 accepted, a stored policy without the credentials, the counts), the request's facts and the
  anonymous body modes; in the store, a policy through recovery, a format 7 checkpoint and the bucket's deletion.
- **Clients:** `tools/s3_smoke.sh` 187 checks (28 new: anonymous reads and writes by a policy, a key denied, a Deny of
  everything that leaves the policy calls open, `aws:SourceIp` in and out of range, DeleteObjects with a denied key,
  the refusals); boto3 86 checks (12 new, with an unsigned client); the s3-tests subset 296 (496 in scope, 308 pass) with the `bucket_policy` marker in scope
  (10 new: `test_bucket_policy`, `test_bucketv2_policy`, both `*_another_bucket`, `test_set_get_del_bucket_policy`,
  `test_bucket_policy_allow_notprincipal`, `test_multipart_upload_on_a_bucket_with_policy`, and three tag tests on a
  public bucket).
- **The p99 gate gave no verdict, twice** (`tools/perf_gate.sh`, `94fe87e`'s build against this one): other sessions'
  builds loaded the M1 during both runs (group noise 1.8 to 7.5, and 1.1 to 8.8; the limit is 2). No group failed in
  either, and the p99 ratios point both ways (small writes at concurrency 1: 1.26 in the first run, 0.77 in the
  second). What the change adds to a request without policies is two atomic loads and three header and parameter
  lookups; that it costs nothing measurable is not shown yet. The gate has to be run again on a quiet machine.
- **Ceph policy tests still failing, and why:** most use the `alt` user as a second account refused by default (every
  key here is of one account); the rest need ACLs, GetBucketPolicyStatus, the public-access block, tenants, or
  condition keys refused here (`s3:x-amz-copy-source`, `s3:ExistingObjectTag`, `...IfExists`).
- **Next:** slice 2, the public-access block and GetBucketPolicyStatus; then an ACL compatibility mode.


### 13 Nov 2026: M5 item 3, slice 2: the public-access block and a policy's status (ADR-0044)

- **Stored with the bucket** (`BucketConfig` kind 5, one byte of four settings; checkpoint format 8, formats 1 to 7
  load). Put-, Get- and DeletePublicAccessBlock; NoSuchPublicAccessBlockConfiguration. A block with every setting
  off is still a block.
- **A policy is public** when an Allow is for anyone and is not kept to fixed addresses (an `IpAddress` test on
  `aws:SourceIp`, every range no wider than /8, or /32 for IPv6). Deny statements are not counted: the answer errs
  towards public. GetBucketPolicyStatus says it, and answers `false` for a bucket without a policy, as RGW does (S3
  answers NoSuchBucketPolicy).
- **`BlockPublicPolicy`** refuses a public policy when it is put (AccessDenied); the one a bucket has stays.
  **`RestrictPublicBuckets`** refuses every anonymous request to a bucket whose policy is public; keys are not
  touched. **`BlockPublicAcls` and `IgnorePublicAcls`** are stored and do nothing until there are ACLs.
- **No new cost:** the block is read only by an anonymous request to a bucket with a policy, under the lock it
  already takes, and by a PutBucketPolicy whose policy is public. The two counts of ADR-0043 §8 are as they were.
- **Tests (3 new, 178 in all, no leaks):** what is public (principals, the widths of ranges, the other conditions,
  one public statement among others), the block's document, and in the store a block through recovery, a format 8
  checkpoint, clearing and the bucket's deletion.
- **Clients:** `tools/s3_smoke.sh` 203 checks (16 new), boto3 95 (9 new), the s3-tests subset 305 (496 in scope,
  317 pass; 9 new: `test_get_bucket_policy_status`, the two `*policy_acl_bucket_policy_status`,
  `test_get_undefined_public_block`, `test_get_public_block_deny_bucket_policy`, `test_put_public_block`,
  `test_block_public_policy`, `test_block_public_restrict_public_buckets`, `test_put_get_delete_public_block`). Of
  the 16 tests of this area, 5 need ACLs and 2 name a tenant's root as principal.
- **Not run:** the p99 gate (still owed from slice 1, on a quiet machine), the other SDK scripts (they do not use
  these calls) and `tools/tls_smoke.sh` (how `serve` listens did not change).
- **The toolchain on this machine:** the installed `ceesafec` is 0.40.0 and CeeSafe's `out/ceesafec` is 0.42.0, which
  CeeSafe.Web's pinned commit does not compile with (`AsyncError.Closed` is not matched in `web_core`). This slice
  was checked, tested and built with the 0.41.0 build kept as `out/ceesafec.good3`.
- **Next:** slice 3, an ACL compatibility mode, which gives the two ACL settings their meaning.

### 13 Nov 2026: M5 item 3, slice 3: an ACL compatibility mode (ADR-0045); item 3 done

- **Chosen with the user** (yes, 13 Nov, to the proposal after slice 2): canned ACLs and grants are stored and
  enforced, not accepted and ignored.
- **An ACL is three sets of permissions:** the owner's (`cosmostore`), everyone's and every authenticated
  requester's, stored as three characters; the private one as nothing. A bucket's is `BucketConfig` kind 6
  (checkpoint format 9, formats 1 to 8 load). A version's is the `x-amz-acl` field of its metadata, beside its tags,
  changed in place by a SetTags record of a second format: no new record type, and no new version.
- **Given three ways:** `x-amz-acl` (the four canned ACLs with a meaning here; the two `bucket-owner` ones are
  private), the `x-amz-grant-*` fields, and the `<AccessControlPolicy>` document. Another canonical user or group
  is InvalidArgument, a grantee by email UnresolvableGrantByEmailAddress.
- **Calls:** Get- and PutBucketAcl, Get- and PutObjectAcl (with `versionId`), and the ACL fields on CreateBucket,
  PutObject, CopyObject, CreateMultipartUpload and POST object. A copy never has its source's ACL.
- **What it opens:** an anonymous request the bucket's policy neither refuses nor allows may do what the ACL
  grants everyone (the table of ADR-0045 §4). A policy's Deny wins. Keys are never refused by an ACL.
- **The block's ACL settings work:** `BlockPublicAcls` refuses a request that gives a public ACL,
  `IgnorePublicAcls` makes stored ones open nothing. GetBucketPolicyStatus is `true` for a public bucket ACL too.
- **The cost, changed for anonymous requests only:** one was refused at once while no bucket had a policy; it now
  takes the store's lock once for the bucket's policy, block and ACL, and once more for the object's ACL when those
  decide nothing. A key's request is as before.
- **Tests (6 new, 184 in all, no leaks):** canned ACLs and the stored form, grant fields, the document (what GetAcl
  writes PutAcl reads; 13 refused), the permissions of every action; in the store, a version's ACL changed in
  place through recovery and a checkpoint with its tags kept, and a bucket's through a format 9 checkpoint.
- **Clients:** `tools/s3_smoke.sh` 243 checks (40 new), boto3 114 (19 new: versions and multipart too), the
  s3-tests subset 325 (496 in scope, 337 pass; 20 new).
- **Ceph ACL tests still failing, and why:** the `test_access_bucket_*` matrix and the grant tests use the `alt`
  user as a second account; `test_bucket_acl_default`, the `*_acl_canned*` tests and others compare the owner's id
  and display name with their configuration's (a configurable owner would pass them; ADR-0045, rejected for now).
- **Not run:** the p99 gate (owed since slice 1; this slice adds nothing to a key's request), the rclone, Go,
  JavaScript, Java and .NET scripts, `tools/tls_smoke.sh`, and a fault sweep: the new record is a SetTags record
  through the same commit, and the new config kind a BucketConfig record.
- **The toolchain:** as in slice 2, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **Next:** M5 item 4, SSE-S3 and SSE-C. Before it, on a quiet machine: the p99 gate for item 3.

### 13 Nov 2026: M5 item 4, server-side encryption: the design, and what needs no cipher (ADR-0046, G33)

- **Blocked on a cipher.** lib/std has SHA-256, HMAC and the system's random source, and no cipher; CosmoStore
  calls no C. Asked where the cipher should come from, the user chose AES-256-GCM in lib/std over one in
  CosmoStore's own code (13 Nov). Logged as G33 in `CEESAFE_GAPS.md`, with the API CosmoStore would call.
- **The master key, chosen with the user** (yes, 13 Nov, to the proposal after slice 3 of item 3): a key file named
  when `serve` starts, wrapping a data key per object.
- **The design (ADR-0046, proposed):** encryption is above the store, which carries ciphertext as any bytes. An
  object is sealed in 64 KiB chunks under its own data key, the nonce the part number and the chunk's index, so a
  range opens only the chunks it touches and CompleteMultipartUpload still joins manifests without rewriting. The
  envelope (the data key sealed under a master key, or under the request's for SSE-C) is a field of the version's
  metadata, beside its tags and ACL. The record flag ADR-0001 reserved cannot carry it: `Journal.stage` writes
  flags 0, Relocate restages, and checkpoints keep no flags.
- **Built, since it needs no cipher** (`src/s3/sse.cee`): the chunk arithmetic (stored length, the chunks and
  stored bytes of a range, nonces), the envelope's text form, the key file's parser, and the request's fields
  (SSE-S3's, and SSE-C's key with its MD5 checked). None of it is reached by a request yet.
- **A fix on the way:** a request with an `x-amz-server-side-encryption*` field (a copy source's and a POST form's
  too) was ignored and its object stored in the clear under a 200. It is NotImplemented now (ADR-0046 §7).
- **Tests (4 new, 188 in all, no leaks):** the geometry (every span is whole chunks; boundaries; an empty part),
  the envelope read back and 13 texts that are not one, the key file (order, comments, 8 refusals), the fields.
- **Clients:** `tools/s3_smoke.sh` 247 checks (4 new: both kinds refused, a read with a key refused, nothing
  stored); boto3 114 and the s3-tests subset 325, as before: nothing in them sends the fields.
- **Not built:** `serve --sse-key-file`, sealing and opening, the reader over stored offsets, bucket default
  encryption, the response fields. All after G33.
- **Next:** when lib/std has the cipher, the rest of ADR-0046. Meanwhile M5 item 5 (Object Lock and legal hold)
  does not depend on it; and the p99 gate for item 3 is still owed, on a quiet machine.

### 13 Nov 2026: M5 item 5, object lock and legal hold (ADR-0047)

- **Chosen with the user** (yes, 13 Nov, to starting it while G33 holds item 4).
- **A bucket's configuration** is `BucketConfig` kind 7 (`E`, or `E.G.d30`, `E.C.y2` with a default retention;
  checkpoint format 10, formats 1 to 9 load). It needs versioning enabled, keeps it enabled and is never taken
  off: the store refuses, whoever asks (InvalidBucketState).
- **A version's lock** is the `x-amz-object-lock` field of its metadata (mode, legal hold, the time the retention
  ends), given by the request's fields or the bucket's default as the store stages the version, and changed in
  place by a SetTags record of a third format. Compliance only grows; governance grows in its own mode, and
  changes otherwise only with the bypass.
- **Enforced where a version's removal is staged** (`stageTarget`, `deleteVersion`): a delete that names a locked
  version is not staged (AccessDenied; an entry of DeleteObjects, the others going on), a lifecycle rule leaves it
  until its retention ends, a delete without an id writes a marker over it. Why staging is the place: ADR-0047 §4.
- **Calls:** Get- and PutObjectLockConfiguration, Get- and PutObjectRetention, Get- and PutObjectLegalHold,
  `x-amz-bucket-object-lock-enabled` on CreateBucket, the `x-amz-object-lock-*` fields on PutObject, CopyObject
  and CreateMultipartUpload, `x-amz-bypass-governance-retention` (with `s3:BypassGovernanceRetention`), and the
  lock in GET and HEAD. Seven policy actions.
- **Two things the Ceph tests found:** an error entry of DeleteObjects did not name the version it was asked to
  remove (their cleanup reads it, and one failure had taken 56 later tests with it); and changing a governance
  retention to compliance needs the bypass, which the first rule let through.
- **Tests (6 new, 194 in all, no leaks):** in the store, the configuration and its refusals through recovery and
  a format 10 checkpoint; a locked version by all three delete paths, the bypass, every change of a retention,
  the hold, recovery; lifecycle leaving a locked noncurrent version until its retention ends; the lock's text
  form and the field found in a blob cut at every byte. Over S3, the request's fields and the three documents.
- **Clients:** `tools/s3_smoke.sh` 273 checks (26 new), boto3 131 (17 new: a copy, a multipart upload,
  DeleteObjects), the s3-tests subset 364 (496 in scope, 376 pass): all 39 `test_object_lock_*` tests. They were
  in scope all along, since the tests carry no `object_lock` marker; the name is gone from the script's list.
- **Not done:** the object lock fields of a POST form. Compliance retention is in the unit tests only: a client
  script that made one could not clean up after itself.
- **Not run:** the p99 gate (owed since item 3; a PUT now looks up its bucket's lock configuration, one more
  lookup of the kind versioning already makes), the rclone, Go, JavaScript, Java and .NET scripts,
  `tools/tls_smoke.sh`, and a fault sweep (the new records go through the commits that were swept).
- **The toolchain:** as before, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **Next:** M5 item 6, notifications through a durable outbox; item 4's rest when G33 is fixed.

### 13 Nov 2026: M5 item 6, event notifications through a durable outbox (ADR-0048)

- **Chosen with the user** (yes, 13 Nov): HTTP webhooks first, a POST of S3's event document.
- **The journal is the outbox.** A write's record is its event: when a record is applied (PutInline, PutExtent,
  UploadComplete, DeleteVersion that removes something, DeleteMarker) and its bucket has a rule for it, the event is
  queued in memory in LSN order. Nothing more is written, so the event is durable in the write's own sync.
- **What keeps it over a restart:** the journal for records after the newest checkpoint; the checkpoint for older
  ones (format 11: the waiting events after the uploads, their count in the header's unused word; a bucket's rules
  in its entry; formats 1 to 10 load); and a cursor file, `outbox.cursor` (the LSN delivered and a CRC), written
  atomically after each batch delivered, which recovery reads first. No event pins a segment.
- **Rules** are `BucketConfig` kind 8, read and written as S3's queue configurations; a target is a webhook of
  the file `serve --notify-targets` names, as `arn:cosmostore:sqs::<id>:webhook`. Created and removed events, with
  prefix and suffix; `:Post` and `:Copy` are NotImplemented, since a PUT, a POST and a copy write one kind of
  record.
- **Delivery** is a third task beside the server and the upkeep, over CeeSafe.Web's `web_client` (a new
  dependency): oldest first, 64 at a time, each event to each of its targets; a failure waits 1 s doubling to
  60 s, and the events behind wait with it. At least once. The outbox holds 100,000 events, then drops the oldest
  and counts it. Five counts in the stats.
- **Tests (9 new, 203 in all, no leaks):** rules and events encoded and cut at every byte; the outbox through
  recovery from the journal, the cursor, a checkpoint, and a checkpoint with records after it; versions (a marker
  written, a version removed); rules taken off; a cursor file missing or damaged; the limit. Over S3, the targets
  file, the document (12 bodies, what Get writes Put reads) and the event's JSON byte for byte.
- **A fault sweep of the outbox** (three tests: a fault at every operation of a workload with rules, three writes,
  a delivery, a checkpoint and a fourth write; once, sticky and torn, and with a crash): after recovery the event of
  every acknowledged write is waiting unless it was delivered, and a delivery made durable is not sent again. **It
  found one fault:** `eventsDelivered` dropped the events from memory before it wrote the cursor, so a cursor write
  that failed, then a checkpoint, left the event out of the checkpoint while the disk still asked for it. The
  cursor is written first now; if that fails the events stay and are delivered again.
- **Clients:** `tools/s3_smoke.sh` 288 checks (15 new) with a webhook of its own, `tools/webhook.py`: events
  arrive, only the rule's keys; with the webhook down an event waits, the server is killed with SIGKILL and
  started again and it still waits, the webhook comes back and it arrives; fsck passes with the cursor file there.
  boto3 135 (4 new, the configuration only). The s3-tests subset 364, as before (its SNS tests are out of scope).
- **Not done:** a queue per target, so one target down does not hold the others; reloading the targets file;
  an https webhook in a test (the connector verifies against the system's roots; the checks use http).
- **Not run:** the p99 gate (owed since item 3; applying a record now costs one comparison while no bucket has
  rules), the rclone, Go, JavaScript, Java and .NET scripts, and `tools/tls_smoke.sh`.
- **CI:** the smoke script now starts `tools/webhook.py` with `python3`, and uses the port after the server's.
- **The toolchain:** as before, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **Next:** M5 item 7 (CORS, quotas, rate limits, audit log, admin API, credential rotation); item 4's rest when
  G33 is fixed; the p99 gate for items 3 to 6 on a quiet machine.

### 13 Nov 2026: M5 item 7, first part: CORS (ADR-0049)

- **Chosen with the user** (yes, 13 Nov): CORS first of item 7's parts, then credential rotation.
- **Rules** are `BucketConfig` kind 9 in a compact form (checkpoint format 12, formats 1 to 11 load): Put-, Get-
  and DeleteBucketCors; up to 100 rules of origins, methods, headers, exposed headers and an age; patterns with
  one `*`.
- **A preflight** (OPTIONS, routed to the S3 handler now; the web server answered it itself before) is answered
  unsigned: 200 with the rule's fields when a rule allows the origin, the method and every header asked for; 403
  AccessForbidden otherwise; 400 without the origin or the method.
- **A request that names an `Origin`** gets the first matching rule's fields on whatever its answer is, an error
  too. No rule: no fields, and the request is served as before; CORS never refuses a request that is not a
  preflight.
- **The cost:** a count of buckets with CORS rules in the app, as for policies; while it is 0 an `Origin` is not
  looked at. Otherwise such a request reads its bucket's rules, one lock round.
- **A fault in ADR-0045, found by the Ceph CORS test:** an anonymous GET of a key that is not there was
  AccessDenied even for a requester who may list the bucket; S3 answers NoSuchKey there. Fixed: with nothing to
  have an ACL, the request goes on if it may do `s3:ListBucket`, and is refused if not.
- **Tests (2 new, 205 in all, no leaks):** the document (what Get writes Put reads, 8 refusals, 101 rules), the
  stored rules cut at every byte, patterns, the first rule for an origin and a method, a preflight's headers.
- **Clients:** `tools/s3_smoke.sh` 310 checks (22 new: 20 for CORS with curl, 2 for the missing key); boto3 139
  (4 new); the s3-tests subset 377 (496 in scope, 389 pass; 13 new). The four `*_v2` presigned CORS tests sign
  with SigV2.
- **Not run:** the p99 gate (owed since item 3), the rclone, Go, JavaScript, Java and .NET scripts,
  `tools/tls_smoke.sh`, and a fault sweep (a BucketConfig record through the commits that were swept).
- **The toolchain:** as before, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **Next:** credential rotation (the credentials file reloaded when it changes, as certificates are), then the
  rest of item 7.

### 14 Nov 2026: M5 item 7, second part: credential rotation (ADR-0050)

- **Chosen with the user** (yes, 13 Nov): after CORS.
- **The upkeep reloads the credentials file** when its modification time changes, as it reloads certificates: a
  key is added, rotated or revoked within one round, with no restart. A file that does not read or has no key
  changes nothing, is reported once and tried again each round.
- **A key keeps its place.** A reload builds the next set from the current one: kept keys in place with the
  file's secret, keys the file dropped in place and revoked, new keys after. A request remembers its key by its
  place (a policy's decision uses it), so a place must mean one key across a reload.
- **No lock on the request path.** lib/std has no reader-writer lock and no atomic swap of an owner, and a
  blocking `Mutex` is not for async code. The sets live in 4,096 `OnceLock` cells made at start; a reload writes
  the next cell and stores its number; a request reads the number and the cell. After 4,095 reloads a reload is
  refused and reported.
- **Tests (2 new, 207 in all, no leaks):** the set after a reload (a secret changed, a key gone, a key new, a
  revoked key back, a key twice in the file), and the cells: a set read before a reload stays as it was, and the
  last cell refuses the next.
- **Clients:** `tools/s3_smoke.sh` 318 checks (8 new): a key added to the file works, its old secret fails and
  its new one works after a change, an empty file changes nothing, a key taken out is InvalidAccessKeyId, and the
  log has three reloads and one failure. The script's server now runs its upkeep every 2 s
  (`--maintain-seconds 2`) so the reloads are seen; the other 310 checks pass with it. boto3 139 and the s3-tests
  subset 377, as before.
- **Not run:** the p99 gate (owed since item 3; a request now reads its credentials through an `Arc`, an atomic
  and a cell where it read a vector), the rclone, Go, JavaScript, Java and .NET scripts and `tools/tls_smoke.sh`.
- **The toolchain:** as before, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **Next:** the rest of item 7 (quotas, rate limits, an audit log, an admin API and CLI); item 4's rest when G33
  is fixed; the p99 gate for items 3 to 7 on a quiet machine.

### 14 Nov 2026: the p99 gate for M5 items 3 to 7 (ADR-0030), on the Intel Mac mini

- **Why there:** the gate gave no verdict twice on the M1 on 13 Nov (other sessions' builds), and nine slices went
  in after it. Chosen with the user (yes, 14 Nov). Base `94fe87e` (before bucket policies), head `70cd5f8`
  (credential rotation), both built there with ceesafec 0.41.0; the default matrix (0 B, 1 KiB, 4 KiB and 1 MiB
  at concurrency 1 and 32, 3 rounds); the bench and the gate are the binaries cross-built for it (it has no Go).
- **First run: failed in one group of ten.** Large GETs at concurrency 32: p99 × 2.09, ops/s × 0.61, and the 1 MiB
  HEAD phase beside it at half its rate. Nine groups were within tolerance (p99 0.89 to 1.11). By round: head was
  slow in rounds 1 and 3 (GET 1,557 and 1,258 ops/s, HEAD 16,515 and 17,180) and as the base in round 2 (2,670 and
  36,860; the base's three rounds 2,371 to 2,638 and 35,333 to 39,216). The load log has two bursts in the whole
  run (to 9.6 at 00:36 and to 5.7 at 01:04), at the ends of those two runs.
- **That group alone, 5 rounds: passed.** Head 2,281 to 2,402 GETs/s and 36,644 to 37,967 HEADs/s against the
  base's 2,323 to 2,396 and 36,250 to 38,716.
- **Second full run, with the busiest processes sampled every 10 s: passed, every group.** p99 0.95 to 1.02,
  ops/s 0.99 to 1.01, noise 1.00 to 1.19; no load above 3.2 in its 940 samples.
- **What it shows:** M5 items 3 to 7 cost nothing the gate can see at these sizes and concurrencies. The first
  run's failure sat on the machine's only two load bursts and did not come back in 8 more runs of those phases;
  what made the bursts was not found (not the malware scanner's or Spotlight's processes by their start times).
  Those phases last under a second each, so one burst halves them: a longer 1 MiB phase would make the gate
  steadier there.
- **Not shown:** anything in ms or ops/s for the M1 (the mini's sync is about 22 ms), requests with policies,
  ACLs, CORS rules or notification rules in place (the bench uses none), or anonymous requests, which now take a
  lock round (ADR-0045 §6).
- Results: `~/cosmo-ref/run-gate-m5`, `run-gate-m5b` and `run-gate-m5c` on the mini.

### 14 Nov 2026: M5 item 7, third part: the audit log (ADR-0051)

- **Chosen with the user** (yes, 14 Nov): the audit log first of what is left of item 7.
- **`serve --audit-log <file>`** appends a line of JSON for every request the S3 handler answers: the time, the
  request id, the peer's address, the requester (the access key, `anonymous`, or `-` when it was not
  authenticated), the method and path, the names of the query's parameters, the result (`ok`, an S3 code with its
  status, or `aborted`) and the time it took.
- **A query's values are never logged:** a presigned URL's are its credentials while it lasts.
- **Written after the response, by a task beside the server:** the handler queues the line (8,192 lines; a full
  queue drops it and counts it, `auditLinesDropped`); the task appends what is waiting with one write and one sync
  on a worker thread, opening the file for each batch so a rotated log begins again. No request waits for it.
- **What it is not** (ADR-0051, Consequences): a record that loses nothing. A crash loses the queue; that would
  need the line before the response.
- **Tests (2 new, 209 in all, no leaks):** a line byte for byte (an address of each family, a path that needs
  escaping, a query's names and no value, an error's status, an aborted request) and the file (made, appended,
  begun again after a rename, a directory that is not there).
- **Clients:** `tools/s3_smoke.sh` 329 checks (11 new): its server now logs every request, and at the end the
  log's 482 lines are all JSON with every field; the key that signed, the second key while it was accepted,
  anonymous requests refused and not, preflights, a delete's `versionId` by name, no `X-Amz-Signature=` anywhere,
  and no line dropped. Three of the checks were wrong at first (a count, a path, and a body signature that fails
  after its key is known); the log was right.
- **Not run:** the p99 gate with the log on (it is off unless asked for), the rclone, Go, JavaScript, Java and
  .NET scripts and `tools/tls_smoke.sh`.
- **The toolchain:** as before, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **Next:** the rest of item 7 (quotas, rate limits, an admin API and CLI); item 4's rest when G33 is fixed.

### 14 Nov 2026: M5 item 7, fourth part: bucket quotas (ADR-0052)

- **Chosen with the user** (yes, 14 Nov): a limit per bucket on bytes and objects, checked at admission.
- **A bucket's use** is now two numbers with the bucket: the bytes of its versions beside the count of them it
  already had. Both follow the index as records are applied (a version installed, removed, or replaced in place),
  and are counted again from a checkpoint's objects; neither is stored.
- **A quota** is `BucketConfig` kind 10 (the most bytes and the most versions, 0 for none; checkpoint format 13,
  formats 1 to 12 load). `checkQuota` sits with the store's other admissions (`checkPut`, and the completion of a
  multipart upload): QuotaExceeded (403). An overwrite is counted without the version it replaces; a delete is
  never refused.
- **The calls are not S3's:** `PUT`, `GET` and `DELETE /<bucket>?quota`, with a small XML document; GET gives
  the limits and the use, with or without a quota. `s3:GetBucketQuota` and `s3:PutBucketQuota`.
- **Counted against what is published:** writes in flight are not in the total yet, so the limit can be passed
  by at most what was in flight.
- **Tests (3 new, 212 in all, no leaks):** a bucket's use through puts, an overwrite, deletes, versions and a
  marker, recovery and a checkpoint; the quota (the bytes exactly, an overwrite that fits and one that does not,
  the count, a multipart upload refused at completion and completed once there is room, versions, recovery, a
  format 13 checkpoint, taken off); the document.
- **Clients:** `tools/s3_smoke.sh` 343 checks (14 new), the quota calls presigned by `tools/s3_raw.py` (which can
  now sign a subresource) and sent with curl, the writes with the AWS CLI. boto3 139 and the s3-tests subset 377,
  as before.
- **Not run:** the p99 gate (every version installed now also adds to its bucket's bytes, where it added to its
  count), the rclone, Go, JavaScript, Java and .NET scripts and `tools/tls_smoke.sh`.
- **The toolchain:** as before, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **Next:** the rest of item 7 (rate limits, an admin API and CLI); item 4's rest when G33 is fixed.

### 14 Nov 2026: the p99 gate again, after the audit log and quotas (ADR-0030), on the Intel Mac mini

- Base `94fe87e` (before bucket policies), head `c40a7e6` (bucket quotas): M5 items 3 to 7 as far as they are
  built. Chosen with the user (yes, 14 Nov). The default matrix, 3 rounds, both builds made there with ceesafec
  0.41.0, as in the run of earlier today.
- **Passed, every group, in one run:** p99 1.00 to 1.01, ops/s 0.99 to 1.05, noise 1.00 to 1.19; the load between
  1.0 and 2.6 in all its 163 samples, no burst.
- **What it covers that the earlier run did not:** the audit log's hook in the handler (the log itself off), the
  credentials read through their sets, the count of a bucket's bytes as versions are installed and removed, and
  the quota lookup at admission.
- **Not shown,** as before: the M1's ms and ops/s, requests with policies, ACLs, CORS rules, notification rules, a
  quota or the audit log in use, and anonymous requests.
- Results: `~/cosmo-ref/run-gate-m5d` on the mini.

### 14 Nov 2026: M5 item 7, fifth part: rate limits (ADR-0053)

- **Chosen with the user** (yes, 14 Nov): a limit per key and per address, answered with 503 SlowDown.
- **`serve --rate-limit-address <n>` and `--rate-limit-key <n>`:** the most requests a second from one address
  (counted before the request is parsed; an IPv6 address by its first 64 bits) and by one access key (once its
  signature has checked). Past either: SlowDown with `Retry-After: 1`, counted in the stats (`rateLimited`).
- **Windows of a second in atomics:** two tables of 4,096 slots (a count, its second, whose it is), found by the
  address's hash or the key's place in the credentials; no lock and no allocation. A client may send its limit at
  the end of one second and again at the start of the next; two holders that meet in a slot are slowed together,
  never let through together.
- **Tests (2 new, 214 in all, no leaks):** the window (the limit, the next second, a slot shared, a slot taken
  over), what an address is counted as (its port ignored, an IPv6 /64), and the limiter with and without limits.
- **Clients:** `tools/s3_smoke.sh` 347 checks (4 new) against a second server started with both limits, so the
  script's own requests are not held back: of 60 quick anonymous requests 20 to 40 are slowed at 20 a second, a
  slowed one carries `Retry-After`, the next second is its own, and of 15 by one key 5 to 10 are slowed at 5 a
  second. boto3 139 and the s3-tests subset 377, as before.
- **Not run:** the p99 gate with a limit on (off, the request path has two more comparisons), the rclone, Go,
  JavaScript, Java and .NET scripts and `tools/tls_smoke.sh`.
- **The toolchain:** as before, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **Next:** the last part of item 7, an admin API and CLI; item 4's rest when G33 is fixed.

### 14 Nov 2026: M5 item 7, last part: an admin API and CLI (ADR-0054); item 7 done

- **Chosen with the user** (yes, 14 Nov): start small, the stats and a few signed calls.
- **`GET /_cosmostore/buckets`** beside the stats, for a signed key: every bucket with the versions and bytes it
  holds, its quota, its versioning and which configurations it has. The buckets' entries only; no object is read.
- **`cosmostore admin <endpoint> <credentials-file> stats | buckets | quota <bucket> [<max-bytes> <max-objects> |
  off]`:** one request signed with the file's first key, the answer on stdout; exit 0 for a 2xx, 1 otherwise
  (the answer on stderr), 2 for a command there is not. It signs with the server's own `canonicalRequest`,
  `signingKey` and `seedSignature`, and sends with CeeSafe.Web's client; https is verified against the system's
  roots. It is a client like any other: no access to the store's directory, and under the policies, rate limits
  and audit log as every request.
- **Tests (2 new, 216 in all, no leaks):** the request of each command and 7 that are none; an endpoint's host,
  the `x-amz-date` of a time, the `Authorization` header's shape, the same request signing the same and a query
  signing otherwise.
- **Clients:** `tools/s3_smoke.sh` 358 checks (11 new): the CLI's stats and buckets read as JSON, a quota read,
  set and seen by the raw call, a bucket that is not there, a wrong secret (SignatureDoesNotMatch, exit 1), a
  command there is not (exit 2), no server (exit 1). boto3 139 and the s3-tests subset 377, as before.
- **The rate-limit checks of ADR-0053 were made over** in the same script: the first ones assumed 60 requests in
  about a second, and failed once on a slower run (16 slowed where 20 to 40 were expected). They now use a limit
  of 3 a second for an address and 2 for a key, on a server each, with bounds that hold however slowly the
  requests go; and check that an address is not slowed without its limit.
- **Not done:** forcing a credentials reload or an upkeep round, the outbox beyond its counts, changing the
  server's options while it runs.
- **Not run:** the rclone, Go, JavaScript, Java and .NET scripts, `tools/tls_smoke.sh`, and the CLI against an
  https endpoint.
- **The toolchain:** as before, the 0.41.0 build `out/ceesafec.good3` of the CeeSafe checkout.
- **M5 now:** items 1 to 3 and 5 to 7 are built; item 4 (SSE-S3, SSE-C) is designed (ADR-0046) and waits for
  AES-256-GCM in lib/std (G33). **Next:** G33 in the CeeSafe repo, then item 4; and M5's exit, the runbooks.

### 14 Nov 2026: runbooks for a single node (`docs/runbooks.md`)

- **Chosen with the user** (yes, 14 Nov): M5's exit asks for operational runbooks; written from what is built.
- **What is in them:** starting and stopping, what to watch in the stats and on stderr, access keys (add,
  rotate, revoke), certificates, space and quotas, who can read a bucket and how to close one, Object Lock,
  event notifications (a webhook down, events dropped), the audit log (questions to ask it, rotation), rate
  limits, CORS, integrity (fsck, a failed journal), upgrades and going back, backup, and what is not there yet.
- **Checked against the code as they were written:** which error a full store, a failed journal and a corrupt
  read give; that a snapshot or a stopped copy is the only backup; that a block closes public policies and ACLs
  but not a policy for fixed addresses; what deleting `outbox.cursor` does. Two first drafts overstated
  (anonymous access under a full block; the cursor) and were corrected.
- **Not exercised as written:** the procedures are those of the smoke script and the unit tests, but the
  runbook's own command lines were not run end to end against a TLS server, and backup by volume snapshot rests
  on the crash model (ADR-0004), not on a test of a snapshot.
- **M5's exit:** every item but 4 is built; the runbooks exist; a beta without encryption at rest. Item 4 waits
  for G33.

### 14 Nov 2026: M5 item 4 begun, SSE-S3 on PutObject, GetObject and HeadObject (ADR-0046)

- **G33 fixed** in ceesafec 0.45.0 (CeeSafe ADR 0135, `Aes256Gcm`), released from this session; `ceesafe.toml`,
  CI and the docs now require 0.45.0.
- **Chosen with the user** (yes, 14 Nov): a multipart part's nonce is to take the part's index (1 to N), not its
  number; ADR-0046 §2 now lists what that leaves open (parts are sealed before their index is known, and a part
  uploaded twice under one number must not reuse a nonce), to settle before multipart is sealed.
- **Built:** `serve --sse-key-file` (read once, wiped, a bad file stops `serve`); PutObject with
  `x-amz-server-side-encryption: AES256` seals the body in 64 KiB chunks under a random data key wrapped by the
  first master key (on the event loop for an inline object, else on the worker thread with the write); GetObject
  reads the whole chunks under a range and opens each before any byte of it is sent; HEAD and GET answer `AES256`
  in place of the envelope. The store reads stored offsets (a sealed version is longer than its size), and `fsck`
  checks a sealed version's length against its chunks instead of an MD5 it cannot compute without the key.
- **Refused, not stored in the clear:** SSE-C, SSE-KMS, multipart and POST with encryption, and a copy whose source
  is sealed (its ciphertext would otherwise be copied as the object): NotImplemented. SSE-S3 without a key file is
  InvalidRequest.
- **Tests (221 passed, 0 failed, no leaks):** `sseManagedKeysRotate` (a data key per object, rotation, an unknown id, a wrong key, an SSE-C
  envelope) and `sseSealedVersionsAreReadAndVerifiedAsStored` (inline, extents and empty; a range opened from the
  store; a sealed version of the wrong length is a mismatch), beside the three sealing tests.
- **Clients:** `tools/s3_smoke.sh` 369 checks, all passed (13 new: put, head, get inline and from extents, a range
  across chunks and at the end, an empty object, no plaintext in the store's files, and the refusals); its `fsck`
  passes with the sealed objects in the store.
- **Not done:** multipart, copies, POST, bucket default encryption (Put-/Get-/DeleteBucketEncryption) and SSE-C;
  a chunk that fails to open in the middle of a GET ends the response short (the status was sent), as a corrupt
  extent does, and is not tested end to end.
- **The toolchain:** `~/dev/CeeSafe-wt-0135/out/ceesafec`, the 0.45.0 build of the release branch.

### 14 Nov 2026: M5 item 4, SSE-S3 for multipart uploads (ADR-0046 §2)

- **Chosen with the user** (yes, 14 Nov, "go with your multipart nonce design"), over the part's index chosen
  earlier the same day, which could not work: a part is sealed before its place among the completed parts is
  known, and a part uploaded twice under one number would have reused nonces under one key.
- **The design:** CreateMultipartUpload makes the data key and keeps its envelope in the upload's metadata. Each
  UploadPart draws a random 16-byte salt, seals the part under HMAC-SHA256 of the salt under the data key, and
  stores the salt before the part's chunks. A part uploaded again gets another key. No format changes: the salts
  are in the stored bytes, the part sizes already in the extras. This refines the design proposed earlier (a
  random value kept with the part, and the part numbers kept), which would have changed three formats.
- **Reads:** a range is planned across the parts (`sseRange`) and read under one reader, opened by `SseStream`,
  which takes each part's salt as it comes; a range that starts after its first part's first chunk reads that
  part's salt apart. `?partNumber=N` works. `fsck` counts each part's header and chunks.
- **Refused:** UploadPartCopy into a sealed upload (NotImplemented), as a copy from a sealed source already is.
- **Tests:** `sseMultipartPartsOpenInAnyRange` (parts of 70000, 100, 131077 and 1 bytes; ten ranges: whole, in a
  part, across parts, after a part's first chunk, the last byte; a changed salt or chunk, a wrong data key; a part
  uploaded twice seals differently). `tools/s3_smoke.sh` 378 checks, all passed (9 new: parts 1 and 3 with part 3
  uploaded twice, a copy into the upload refused, the object whole, a range across parts, a range inside a part
  after its first chunk, `--part-number`, HEAD, and `aws s3 cp --sse AES256` of 20 MB both ways); `fsck` passes
  with them stored.
- **Known:** nothing ties a part to its place, so whoever can write the disk can swap two parts with their salts,
  as ADR-0046 already accepts for moving a sealed object; the parts are admitted at their plaintext size.
- **Next:** SSE-C, copies (open and seal again), POST, and bucket default encryption.

### 14 Nov 2026: M5 item 4 done, SSE-C, copies, POST forms and bucket default encryption (ADR-0046)

- **Asked by the user** (14 Nov: "Commit and go-ahead implementing copies, POST forms, bucket default encryption
  and SSE-C").
- **SSE-C:** the customer key fields on Put, Get, Head, GetObjectAttributes, POST, CreateMultipartUpload,
  UploadPart and Complete, and a copy source's; only over TLS. The data key is wrapped under the request's key;
  without it a read is InvalidRequest, with another key 400. Its ETag is HMAC-SHA256 of the plaintext's MD5 under
  the key (16 bytes), so a part uploaded again keeps its ETag.
- **Copies:** a sealed source (SSE-S3 or SSE-C, one PUT or multipart, any range) is opened and the copy sealed as
  the request or the destination bucket asks, or stored in the clear; UploadPartCopy into a sealed upload seals
  the part under its own salt. A copy onto itself that asks for encryption is allowed: re-sealing under the newest
  master key after a rotation. A copy never takes its source's envelope.
- **POST forms:** the form's SSE-S3 or SSE-C fields, else the bucket's default. The sealer now holds a full chunk
  until more plaintext comes, so it marks the last chunk without knowing the size.
- **Bucket default encryption:** Put-, Get- and DeleteBucketEncryption (`AES256`; `aws:kms` NotImplemented;
  refused without a key file), `BucketConfig` kind 11, checkpoint format 14 (formats 1 to 13 load). A write
  without fields reads the default only while some bucket has one (`encryptedBuckets`, as `corsBuckets`), so the
  inline PUT's lock-free start (ADR-0032) is kept. Every checkpoint this build writes is format 14, which an
  older build does not open, as with each format before it.
- **Refusals:** SSE-S3's field on a read, UploadPart or Complete is InvalidArgument (was NotImplemented), as S3
  answers; SSE-KMS's fields stay NotImplemented.
- **Tests (226 passed, 0 failed):** `sseCustomerEnvelopesNeedTheirKey` (the envelope, the key, the ETag),
  `sseSealsWithoutKnowingTheSize`, `sseBucketEncryptionXml`, `defaultEncryptionSurvivesReplayAndCheckpoints`.
- **Clients:** `tools/s3_smoke.sh` 394 checks, all passed (copies both ways, sealed again onto itself, a sealed
  multipart object copied whole and by parts whose ranges start inside and cross its parts, the default on PUT,
  copy and multipart, no plaintext on disk; SSE-C over HTTP refused). `tools/tls_smoke.sh` 41 (SSE-C: put, get, a
  range, HEAD and attributes with and without the key, another key, no key stored on disk, multipart with
  `aws s3 cp --sse-c`, copies to the clear, to SSE-S3 and under a new key). boto3 145 (POST sealed by its field and
  by the default, POST with SSE-KMS refused). The s3-tests subset 377, as before.
- **s3-tests' encryption tests** (`encryption`, `sse_s3`, `bucket_encryption`; outside the subset), over TLS:
  81 passed, 65 failed, 1 skipped. Of the failures, 59 are SSE-KMS, 4 put bucket policies with the condition keys
  `s3:x-amz-server-side-encryption*` (refused when a policy is put), and 2 are POST tests that sign with SigV2 or
  do not trust the test certificate. They drove three changes above: the SSE-C ETag, 400 for another key, and the
  key on Complete.
- **No fault sweep of its own:** the new record is a BucketConfig record, through the commits that were swept (as
  for kinds 8 to 10); the store's fault tests pass.
- **Not done:** SSE-KMS; the policy condition keys for encryption; wiping every copy of an SSE-C key in memory
  (the request's buffer is not wiped).

### 14 Nov 2026: M5 item 4 closed, SSE-KMS, the policy keys, wiping SSE-C keys (ADR-0055, ADR-0046 accepted)

- **Asked by the user** (14 Nov, "Continue to those remaining": SSE-KMS, the policy condition keys, the SSE-C key
  copies, ADR-0046's status).
- **SSE-KMS** (ADR-0055, accepted by the owner as recommended, 14 Nov): `serve --kms-key-file`, named keys in the key file's format, apart from SSE-S3's
  master keys. `aws:kms` with a key id (or an ARN ending in it), else the file's first key; envelope mode `kms`;
  answers name the key; the ETag is a digest of the plaintext's MD5 under the data key. On PutObject, POST,
  CopyObject (both ways), CreateMultipartUpload, UploadPart, UploadPartCopy and Complete; a bucket default of
  `aws:kms`, with or without `KMSMasterKeyID` (kind 11's value, no format change). An unknown key is
  InvalidArgument; an encryption context and `aws:kms:dsse` NotImplemented; without the file, NotImplemented as
  before. No KMS service: the keys are a file.
- **UploadPart and Complete** may repeat the upload's SSE-S3 or SSE-KMS fields (the upload's key governs), as
  s3-tests has S3 do; into an upload in the clear or under SSE-C they are InvalidArgument.
- **Policy condition keys:** `s3:x-amz-server-side-encryption`, `...-aws-kms-key-id` and `...-customer-algorithm`,
  from the request's fields, with the string operators and `Null`.
- **SSE-C keys wiped:** a request's key fields (its own and a copy source's) when the request is dropped, a POST
  form's, and the sealer's copy for the ETag. Not reached: CeeSafe.Web's receive buffer, 32-byte copies on the
  stack, and `HmacSha256`'s key state, logged as G34 for CeeSafe.
- **ADR-0046** is accepted as built.
- **Tests (228 passed, 0 failed):** `sseKmsSealsUnderNamedKeys`, `policyEncryptionKeys`, SSE-KMS's fields in
  `sseRequestFields`, KMS defaults in `sseBucketEncryptionXml` and `defaultEncryptionSurvivesReplayAndCheckpoints`.
- **Clients:** `tools/s3_smoke.sh` 409 checks, all passed (15 new: SSE-KMS by default and by name, HEAD, GET, a
  range, its ETag, an unknown key, DSSE refused, multipart both ways, copies out of and into SSE-KMS, a bucket
  default of SSE-KMS). `tools/tls_smoke.sh` 41, boto3 145, the s3-tests subset 377, as before.
- **s3-tests' encryption tests over TLS:** 141 passed, 5 failed, 1 skipped (from 81 passed). The five: four POST
  tests that sign with SigV2 or do not trust the test certificate, and `test_sse_kms_no_key`, which expects
  `aws:kms` without a key id to be refused (RGW); AWS uses its default key, and so does CosmoStore.
- **M5 item 4 is done.** Left of it: a KMS service behind ADR-0055's keys, if one is wanted.

### 14 Nov 2026: the p99 gate on a quiet machine, for the 0.41.0 move and for M5

- **Why:** CI's gate failed on 12 Nov for the 0.41.0 move (run 43321032635: large writes at concurrency 32, p99
  1.31, ops/s 0.76), and nobody had looked; M5's own changes had not been through a gate together.
- **Where:** binfadel (the user's Linux host, given 14 Nov when the Mac mini was off the network): Xeon E-2236,
  server on CPUs 2,3, generator on 4,5,10,11; each commit with its own pins (`docs/benchmarks/2026-11-14-binfadel-gates.md`).
- **The 0.41.0 move** (`b8a794e` → `48709f4`): passed; large writes at concurrency 32 0.98 (p99) and 1.02 (ops/s).
  CI's failure was the shared runner's noise.
- **M5** (`48709f4` → `67947c6`, with ceesafec 0.45.0 and CeeSafe.Web `9592f2d`): passed; p99 0.99 to 1.04 but large
  GETs at concurrency 32 (1.12, within its noise of 1.15); ops/s 0.92 to 1.03, every group within its noise. The
  matrix asks for no encryption: SSE's own cost is not measured here.
- **CI on 0.45.0:** the run on `ec5cac2` (the CeeSafe.Web pin) passed `check`; its `perf` job could not build its
  base, `9e08dc6`, whose pins (0.45.0 with `c799f14`) do not compile. Bases from `ec5cac2` on build: run
  43615465567 (`ec5cac2` → `442dde8`, SSE-KMS) passed both `check` and `perf`.

### 14 Nov 2026: M5 closed

- **Exit met:** a beta that can be run in production on a single node with operational runbooks. Items 1 to 7 are
  built (ADRs 0041 to 0055); `docs/runbooks.md` covers them, encryption keys included; CI is green on 0.45.0; the
  p99 gate passes for all of M5 on a quiet machine (above).
- **Left by choice:** a KMS service behind ADR-0055's keys; G34 (`HmacSha256` does not wipe its key) for CeeSafe.
- **Next:** M6, the distributed cluster, when the owner says so.

### 14 Nov 2026: M6 begun; item 1, the Raft core and its simulation (ADR-0056, ADR-0057)

- **Asked by the owner** (14 Nov, "Go ahead with M6").
- **The plan** (ADR-0056, accepted by the owner as recommended, 14 Nov): a Raft group per shard with the journal as its log; shards by bucket (a hash of
  the name over a shard count fixed at creation, 16 by default), so a listing is one leader's; any node takes S3
  requests and forwards to the leader; linearizable reads by ReadIndex, no leases; extents synced on a majority before
  `PutExtent`; peers over HTTP/1.1 on a port of their own, signed with a cluster secret; nine items, each with its own
  ADR, simulation first. The cluster ADR that ROADMAP issue #6 asked for in M0 was never written: this is it.
- **Item 1** (ADR-0057, accepted as recommended, built): `src/cluster/raft.cee`, a Raft core without I/O (pre-vote, leader
  stickiness, check-quorum, commit only in the leader's term, ReadIndex, refusal hints, snapshots; static voters),
  driven by its host through `ready()` and `advance()`.
- **The simulation** (`src/cluster/raft_tests.cee`): 300 seeds of 3 replicas and 100 of 5, 1500 ticks each, under
  message loss, duplicates, delays up to 30 ticks, partitions (the leader alone, two sides), crashes that lose all but
  the disk, pauses, and snapshots; then healed, it must elect, converge and hold everything ever applied. The checker:
  one leader a term, one entry an index across replicas and snapshots, in-order application, terms and votes never
  going back on disk, no stale read. Plus directed tests of a conflicting suffix, a stale leader, a stale snapshot and
  a read's quorum.
- **Mutants** (`tools/raft_mutants.sh`, eight): the first simulation killed 2 of 9. It needed late messages, the leader
  partitioned alone and smaller appends to kill Raft's Figure 8 (an earlier term's entry committed by counting), a
  vote without the up-to-date check and a follower's commit past what was sent; pauses to kill reads released
  without confirmation (with clocks all running, check-quorum hid it); and directed tests for a read confirmed by one
  peer of five and a snapshot that drops a log it matches. Two of the nine were no faults under the host's contract
  (ADR-0057 §5).

### 14 Nov 2026: M6 item 2, slices a and b: the core keeps terms, the journal becomes a Raft log (ADR-0058)

- **Asked by the owner** (14 Nov, "go ahead with item 2"). **ADR-0058** (accepted by the owner as recommended, 14 Nov): in a cluster shard every journal
  record is a Raft entry and its LSN is its index, since a version's generation is its LSN and must be the same on
  every replica; so no local records (compaction's `Relocate` becomes the leader's, replicated); a checkpoint need not
  seal; a segment is sealed only at a committed entry, so an uncommitted suffix is in the active segment; the hard
  state is a file of its own; the leader decides and replicas apply; extents wait for item 5. Four slices.
- **Slice a:** the Raft core keeps only each entry's term. Entries leave it in the ready; an append names how many
  entries the host attaches from its log; committed entries are a range the host applies from its log. ADR-0057's
  simulation and all eight mutants pass as before.
- **Slice b:** the journal in Raft-log mode (`JournalConfig.raftLog`): segment flag bit 0, and opening refuses the
  other kind; `stageEntry` (a leader's, with its term) and `appendEncoded` (a follower's, the leader's record byte for
  byte); recovery refuses a term of 0 or one that goes down; `entryBytes(lsn)` from a position kept every 64 entries;
  `markCommitted` seals a full segment only once all its entries are committed; `truncateAfter(lsn)` cuts the
  active segment and syncs before anything follows; `JournalStart` skips the records up to the checkpoint's LSN in
  its segment and counts their bytes. Single-node journals are unchanged: their tests, sweeps and `tools/s3_smoke.sh`
  pass.
- **The hard state** (`src/cluster/hard_state.cee`): term and vote appended to one of two files, the highest sequence
  wins, switching files at 4 KiB. Two designs failed the crash sweep first: two slots overwritten in place (the model
  assumes appends only) and a rewrite through a rename (the model drops a renamed file whose directory was not
  synced). The sweep fails without the sync of a save or the directory sync of a switch.
- **Tests (248 passed):** the Raft log's order, the other kind refused, a suffix cut, a checkpoint that does not seal,
  and fault sweeps in four modes in which the recovered log is a prefix of what was written, holds every acknowledged
  entry and never brings a cut-off one back; the hard state's sweeps in three modes.
- **Known limit:** the crash model treats a truncation as durable at once, so it cannot catch a missing sync after
  one; the code syncs, and recovery refuses a term that goes down along the log.
- **Next:** slice c, the replicated store: three replicas in one process over an in-memory network, under the sweeps.

### 14 Nov 2026: M6 item 2, slice c: the replicated store (ADR-0058)

- **Asked by the owner** (14 Nov, "Go ahead continue to slice c").
- **The store's Raft mode** (`StoreConfig.journal.raftLog`): records are staged as entries of the leader's term
  (`stageIn`; NotLeader without one; NotReplicated for what writes extents, until item 5), persisted by the store's
  own commits and not applied; `applyEntries(from, to)` applies committed entries from the journal, the same records
  on every replica; recovery keeps the unapplied entries' terms for the core. `persistEntries`, `appendEntry`,
  `appendNoop`, `truncateEntries`, `entryBytes` and `entryTerm` serve the replica. A `Noop` record (type 15) is a new
  leader's first entry. Single-node stores do not change.
- **The replica** (`src/cluster/replica.cee`): the core's host over the store and the hard state. It persists
  entries (skipping the leader's own, already in the journal; cutting a conflicting suffix), saves term and vote before
  sending, attaches entries to appends from the journal, applies committed ranges. A leader takes one write at a time
  (`beginWrite`, the store's own calls, `finishWrite`); it is acknowledged once applied, so the next write's checks
  see it. Pipelining is later work.
- **Tests** (`src/cluster/replica_tests.cee`): three replicas in one process over an in-memory network; a bucket and
  twelve puts and deletes, each acknowledged when the leader applied it; then reopened from disk, they must elect,
  apply the same index, agree on every key, hold every acknowledged write (a write in flight may land or not) and take
  another. Fault sweeps over every I/O operation of the three, once, sticky, torn, and with a power cut of all three
  (the crash model): all pass, in 100 s. Without the hard state saves, all four sweeps fail.
- **Found on the way:** a new leader's `Noop` is staged by the replica, not by a store write, so `persistEntries` must
  commit the journal itself rather than the store's pending batch, which skipped it.
- **Not yet:** checkpoints, the leader's compaction and snapshots (slice d; ADR-0058's slice table now says so), a
  checkpointed replica refuses to open until then; extents (item 5); the peer network (item 3).

### 15 Nov 2026: M6 item 2, slice d: checkpoints, the leader's compaction, snapshots (ADR-0058); item 2 done

- **Asked by the owner** (14 Nov, "push it and go ahead with slice d").
- **Checkpoints in a Raft log:** of the applied state, at index L; recovery starts in the segment holding entry L + 1
  and skips up to L, so nothing is sealed. Checkpoint format 15 adds the term of entry L (16 header bytes with their
  CRC32C); formats 1 to 14 still load, with term 0. Each replica checkpoints on its own, and its core then forgets the
  entries the checkpoint holds.
- **Compaction:** the leader's `Relocate` copies are a write like any other, proposed and applied on every replica; a
  follower removes the segments its checkpoint covers that hold nothing live (`ShardReplica.maintain`).
- **Snapshots** (`src/cluster/snapshot.cee`): a follower behind the leader's checkpoint gets the checkpoint file,
  the segments before the one recovery starts in, and that one up to entry L, byte for byte, so every locator holds.
  It writes them into its next store generation (`store-<16 hex>`), syncs them and the directory, switches with an
  append-only generation file (no rename), then removes the old directory; the next open removes whichever is stale.
  `Fs.removeDirectory` is new, a fault point like the rest.
- **Tests:** a follower cut off while the leader writes 31 times (200-byte values over five keys), checkpoints every
  KiB and compacts, then rejoins: it installs a snapshot, segments are compacted away and payloads relocated, and all
  three agree. Sweeps of every third I/O operation, once, torn and crash: after each they reopen, catch up, agree and
  hold every acknowledged write, and no replica comes back with a lower checkpoint than it had made durable.
- **Mutants:** without the syncs of a snapshot's files, the crash sweep fails (once it checked that a replica keeps
  the checkpoints and snapshots it made durable; before, a follower that lost its snapshot simply got another, which
  hid the loss). Without the directory sync after them it does not: opening the new store syncs the same directory
  when it makes its extents directory, so only a crash between the switch and the open would show it; the code keeps
  the sync. Starting recovery in the active segment instead of the one holding L + 1 changes nothing here, since the
  journal seals only at applied entries; the code keeps the general rule.
- **M6 item 2 is done:** the journal is the Raft log, under every fault sweep, for everything that lives in records.
  **Next:** item 3, the cluster file, the peer port and signed messages, so three `serve` processes replicate.

### 15 Nov 2026: M6 item 3: the cluster file, the peer port, signed messages (ADR-0059)

- **Asked by the owner** (15 Nov, "Yes. Go ahead", after item 2). **ADR-0059** (accepted by the owner as recommended, 15 Nov): a cluster file of words
  (name, shards, replicas, secret file, nodes with peer addresses and failure domains) whose canonical digest every
  request carries; rendezvous placement, one replica per domain while there are domains; the peer port plain HTTP/1.1
  for now, every request signed (HMAC-SHA256 over method, path, digest, sender, time, nonce and the body's SHA-256),
  60 s of skew and two minutes of nonces; Raft's messages in batches, replies as the receiver's own batches; a tick
  every 100 ms; a sender per peer, one request at a time.
- **Slice a:** `src/cluster/cluster_file.cee` (parsing, every refusal with its line, the digest, placement),
  `src/cluster/wire.cee` (batches, every length checked), `src/cluster/peer_auth.cee` (signing, checking, the nonce
  window). Tests: parsing and its seventeen refusals, placement (one per domain, spread, the same every time), round
  trips and every truncation, and each refusal of a request.
- **Slice b:** `src/cluster/node.cee`, the runtime: each replica behind its own lock, stepped on the event loop and
  drained on a worker; the tick (and upkeep every 50 ticks); the senders; the peer port's `/raft` and `/cluster/status`.
  `cosmostore node <dir> --cluster-file <file> --node <id>` runs a node (no S3 until item 4);
  `cosmostore cluster-status` asks one, signed as the operator (sender 0, taken for the status only).
- **`tools/cluster_smoke.sh`** (5 checks): three nodes on loopback elect one leader per shard and apply the same
  entries; the leader of shard 0 killed with `-9`, its shards get leaders in a later term and the survivors agree; it
  restarts and catches up, deposing no one (pre-vote); a request under another cluster file is refused. Passed three
  runs in a row.
- **The first run on real processes worked as the in-process tests said it would**: the only failure was the smoke
  script's own, expecting a new entry on shards whose leader had not been killed.
- **Runbooks:** "A cluster (preview, M6)": the file, the secret, starting and watching nodes, the plain peer port.
- **Next:** item 4, routing, forwarding and ReadIndex, so S3 works against any node of a cluster.

### 15 Nov 2026: M6 item 4: S3 on a cluster (ADR-0060)

- **Asked by the owner** (15 Nov, "Yes. Go ahead", after item 3). **ADR-0060** (accepted by the owner as recommended, 15 Nov): each shard's store gets
  an S3 server of its own inside the node, on loopback, the whole S3 layer unchanged; the node's S3 port is a front
  that routes a request by its bucket's shard to the leader, itself or another node (`POST /s3` on the peer port,
  signed); the leader takes writes one at a time per shard and holds each response until its entries are committed
  and applied in their term, and answers reads after a ReadIndex round; ListBuckets merges every shard's.
- **Slice a:** the store left the replica (`ShardReplica.open` returns both; every method takes the store), so a node
  keeps it behind the lock its S3 server takes. ADR-0058's sweeps and snapshot tests pass as before.
- **Slice b:** `src/cluster/front.cee` (the shards' S3 apps, routing, the write gate and commit wait, ReadIndex
  reads, forwarding, the ListBuckets merge, HEAD relays); `cosmostore node --listen <port> --credentials <file>`;
  in a Raft log group commit's published mark is durable, not applied; a cluster's S3 servers keep the bucket counts at
  "some" and read policies, CORS and encryption every time (they cannot be recounted after an apply they never see).
- **`tools/cluster_s3_smoke.sh`** (25 checks): buckets made through two nodes; ListBuckets merged and the same through
  all three; a PUT through one node read through another; If-None-Match through a third node seeing it; versioning,
  versions written through two nodes, tags, a copy within a bucket, a batch delete; a copy between two shards' buckets
  refused; the leader of a bucket's shard killed, writes and reads going on through the others with every
  acknowledged write there; the node restarted and serving what was written while it was down. Passed three runs.
- **Found on the way:** `Ascii.equalsIgnoringCase(a, lower)` wants its second argument lower case: with `"PUT"`
  every write was taken for a read and never proposed, though acknowledged. The status showed it: no shard's log had
  grown. Methods are compared as parsed `Method`s now.
- **Not yet:** large objects and multipart (item 5), copies across shards, TLS and the other `serve` options on a
  node's S3 port, pipelined writes. **Next:** item 5, extent replication.

### 15 Nov 2026: M6 item 5: extents on a cluster (ADR-0061)

- **Asked by the owner** (15 Nov, "Go ahead and start", after item 4). **ADR-0061** (accepted by the owner as recommended, 15 Nov): a record that names
  extents is proposed only once a majority holds them, the leader's front pushing them to every follower at once
  (`POST /extent`) after the shard's S3 server answered and cutting the write's entries off when no majority comes; a
  replica that lacks an extent its versions or uploads name fetches it every two seconds (`POST /extent-fetch`),
  checked against its manifest; no orphan sweep at open in a Raft log (the unapplied entries' extents would go), an
  upkeep sweep instead that spares the unapplied tail and files under ten minutes old.
- **Found before it bit:** the orphan sweep at open would have removed the extents of every committed-but-unapplied
  entry on a restart. The new test fails if it comes back.
- **Tests:** `raftStoreKeepsAndRepairsExtents`; `tools/cluster_s3_smoke.sh` now 33 checks: with a follower of the
  bucket's shard down, a 20 MB PUT and a 40 MB multipart upload through the two live nodes, read back through each
  (by ranges for the multipart one); the follower restarted fetches the six extents it missed; after the leader's
  loss both objects read whole. Passed three runs.
- **Not yet:** streaming past 64 MiB a request; copies between two shards' buckets. **Next:** item 6, group 0,
  membership changes, placement and rebalance.

### 15 Nov 2026: M6 item 6, slice a: membership changes in the Raft core (ADR-0062)

- **Started under the owner's standing go-ahead** (15 Nov: "From now on, I give you permission to commit and push, then
  start the next"). **ADR-0062** (proposed): single-server changes and learners in the core; a `Config` record;
  group 0 holding membership and placement; a rebalancer moving one replica at a time; three slices.
- **The core** (`raft.cee`): `RaftMembership` (voters, learners); the configuration of the snapshot and of each
  configuration entry after it, the latest in force, the one before restored when entries are cut off; learners are
  replicated to and count for nothing; only voters campaign, vote and make quorums; `proposeConfig` refuses while a
  change is uncommitted, before the leader's own-term commit, and for more than one voter at a time; a leader the
  committed configuration leaves out steps down; `noteConfig` and `installMembership` for the host.
- **The simulation:** a pool of five, three voters at first; the leader changes the group (adds a learner, promotes one
  that caught up, removes a voter, itself too) and now and then tries two voters at once, under every fault; snapshots
  carry their membership; restarts rebuild it from the disk. 200 seeds; at the end every member holds everything. A
  directed test of the change rules.
- **Mutants:** thirteen in `tools/raft_mutants.sh`, all killed. The first membership run killed two of four: two
  changes at once and two voters at once survived, the change generator being too polite (one voter, one change in
  thirty ticks). Proposing a change in one tick in six, trying two-voter changes, and the directed test killed them;
  two changes at once now fails the faulty simulation on a real safety violation.
- **Next:** slice b, the `Config` record, checkpoints and snapshots with their membership, a replica added and one
  removed in the in-process sweeps.

### 15 Nov 2026: M6 item 6, slice b: configurations in the journal, checkpoints and snapshots (ADR-0062)

- **The `Config` record** (type 16): its meta the membership. A leader's core makes a configuration entry; its host
  writes it as a Config record; a follower's host tells its core of a Config record when it persists it; recovery
  hands the core the Config records after the checkpoint, in order. The store keeps the last applied membership.
- **Checkpoint format 16:** the header extension's reserved u32 (always 0 in format 15) is the membership's length,
  which follows with its CRC32C, so a replica starting from a checkpoint, or installing a snapshot, starts in the
  group's configuration. Formats 1 to 15 load as before.
- **Tests** (`src/cluster/membership_tests.cee`): four replicas in one process, three the group, with checkpoints and
  compaction on: writes; node 4 added as a learner, caught up by a snapshot, promoted; a voter removed; writes. After
  a reopen the members agree with the leader's configuration (the committed one, or the one in flight) and on every
  key. Sweeps of every third I/O operation, once, torn, crash. Without telling a follower of Config records, the three
  sweeps fail; with checkpoints written without their membership, all four tests do. (The first run of that check did
  not compile, on `own`, a reserved word, which a filtered grep hid: the mutants' results only counted once they
  printed a pass count.)
- **Next:** slice c, group 0, the placement and the rebalancer, the commands, and a node added to and removed from a
  running cluster.

### 15 Nov 2026: M6 item 6, slice c: nodes join and leave a running cluster (ADR-0062); item 6 done

- **What it does:** `cosmostore cluster-join` and `cluster-leave` change which roster nodes are active, through group
  0 (a Raft group of its own whose store holds the active set); each shard's leader moves its shard toward the
  placement rule over the active nodes, one change at a time (a learner added, promoted once caught up, a voter the
  target leaves out removed). Every node holds a replica slot of every shard, idle until its group adds it.
- **Narrower than ADR-0062 §3 to §5** (its As built says so): the cluster file is the roster (nodes to add later
  marked `standby`), group 0 holds only the active set and stays on the first three nodes, no placement table (each
  shard's Raft configuration is its placement), a removed replica keeps its directory.
- **`tools/cluster_moves_smoke.sh`** (14 checks): four nodes; data and a 5 MB object written; node 4 joins and
  shards move onto it, all of it readable through node 4; node 1 leaves and every shard moves off it; node 1 killed,
  everything read back through the others, writes going on; a background prober (write through one node, read through
  the next) across both moves found no stale read. The S3 smoke, the cluster smoke and the cluster S3 smoke pass on the
  new layout (a slot per shard per node, group 0 on each).
- **Found on the way:** a bucket made and put into in one write of a Raft log fails, the bucket not yet applied, and
  the failed write left an entry persisted and unproposed that stopped every later write: group 0 writes twice now,
  and a failed write cuts what it staged off.
- **M6 item 6 is done** in that form. **Next:** item 7, health, scrub, repair and rolling upgrades.

### 15 Nov 2026: M6 item 7: scrub, repair from a replica, health, rolling restarts (ADR-0063)

- **Under the owner's standing go-ahead.** **ADR-0063** (proposed): each replica scrubs its live versions in steps (an
  inline record verified, an extent checked against its manifest); a damaged extent is removed and fetched again
  (ADR-0061 §3); a damaged record is asked of the shard's other replicas (`/record-fetch`) and written over the bad one
  at its place, the copy checked first (a valid record of that length whose payload has the version's MD5); the status
  gets a `# scrub` line; rolling restarts one node at a time.
- **The write in place** is the one write below a segment's synced end: a crash during it leaves the record as
  damaged as it was, or repaired. The crash model assumes appends and is not asked to judge it.
- **Tests:** `scrubFindsAndRepairsDamage` (a record damaged on disk found at its offset, a wrong copy refused, the
  right one repairing it; a damaged extent found and, once removed, listed missing). `tools/cluster_repair_smoke.sh`
  (13 checks): a byte flipped in a follower's copy of an inline object's record and one in its extent; its scrub finds
  both and repairs them, byte for byte the leader's; then a rolling restart of all three nodes, writes between, each
  caught up before the next, and everything read back. Passed three runs.
- **M6 item 7 is done.** **Next:** item 8, erasure coding of sealed packs and extents.

### 15 Nov 2026: M6 item 8: erasure-coded extents (ADR-0064)

- **Under the owner's standing go-ahead.** **ADR-0064** (proposed): a cold extent (older than `--code-after-seconds`,
  a day by default) of a shard with three voters or more becomes k+m Reed-Solomon pieces (2+1 for three voters, 3+2
  for five) through one committed `Coded` record (type 17); each replica writes its piece from its whole copy and only
  then removes the copy; a missing piece is rebuilt from k others (`POST /piece-fetch`); a read of a coded extent
  answers 503 while the node decodes it, and the retry reads it; scrub checks pieces. Segments stay replicated:
  coding sealed packs is later work.
- **The code:** `src/storage/erasure/rs.cee`, GF(2^8) under 0x11D, systematic, Cauchy parity, in CeeSafe only.
- **Checkpoint format 17:** the coded extents after the events.
- **Found by the fault sweep:** a whole copy that failed to read was taken for none, and removed with no piece
  written; an I/O error now stops the apply and keeps the copy. Also found on the way: a read of an object of several
  coded extents asked for one at a time (a retry each); every one is asked for at once now. `upkeepHoldsAreCounted`
  counts the new checkpoint entry.
- **Tests:** 277 pass (the codec's, the store's coding test, two fault sweeps); `tools/cluster_ec_smoke.sh` (14
  checks) passes, and so do the S3 smoke and the cluster, cluster S3 (33), moves (14) and repair (13) smokes.
- **M6 item 8 is done** for extents. **Next:** item 9, the chaos harness and its linearizability check.

### 15 Nov 2026: M6 item 9, slice a: the chaos harness and its linearizability check (ADR-0065)

- **Under the owner's standing go-ahead.** **ADR-0065** (proposed): `tools/cluster_chaos.py` (standard-library Python)
  runs real nodes behind a proxy of its own (the cluster file's peer addresses are its ports, `node --peer-listen`
  the nodes'), kills, pauses and partitions them (one isolated, the leader isolated, a split, a bridge) while clients
  race on a few keys with PUT, GET, DELETE and listings, heals, reads every key through every node, and checks each
  key's history for linearizability (Wing–Gong–Lowe search with memoization; unknown outcomes open-ended).
  `tools/cluster_chaos.sh` runs it; `tools/chaos_mutants.sh` checks it catches stale reads (a leader without
  ReadIndex, and any replica answering: both killed).
- **It found three bugs in its first runs**, each now fixed:
  - a forwarded write sent again when the leader's answer was lost, and so done twice, the second time after later
    writes (a deleted key came back): a write is sent again only when it was certainly not done;
  - a replica that stopped on "journal corrupt" when a new leader's entry came for the index of its own write still
    in group-commit flight: the journal reads what it wrote, synced or not, and a cut syncs the batch in flight
    first (`raftLogCutsABatchInFlight`);
  - a deposed leader stuck for over a minute after a heal: reads waiting on ReadIndex held the replica's lock across
    their pauses and starved the tick; no lock but the write gate is held across a pause or a send now.
- **And one of its own:** its pruning of unknown writes no GET saw hid ones a listing could have seen; it keeps them
  now, in two tiers to keep the search small.
- **Diagnostics:** `cluster-status`'s `# peer` line, a log of slow ticks, a stopped replica failing a run, and each
  node's status and thread sample saved when the cluster is slow to answer after a heal.
- **Next:** slice b, clock skew and disk loss (ADR-0065 §7).

### 15 Nov 2026: M6 item 9, slice b: clock skew and disk loss (ADR-0065 §7)

- **Clock skew:** a test-only `node --clock-skew-ms` moves a node's clock where the cluster uses one (the peer
  signatures' 60 s window; Raft runs on ticks), and the harness's `skew` fault restarts a node 20 to 100 s off for a
  few seconds. A minute of nothing but skews (−100 s to +95 s), and three 90 s runs with every fault: linearizable.
- **Disk loss**, recovered from as the runbook says: `--disk-loss` runs four nodes, the fourth joined from standby;
  `lose-disk` kills it, takes it out with `cluster-leave`, waits until no shard has it, wipes its directory, starts it
  and joins it again, and waits until it holds replicas again. Three to nine losses a run, each while the node held
  replicas, under every other fault: linearizable. Only nodes outside group 0 can be lost so; the runbook says never
  to start a node on an empty directory under its id (it would vote twice in a term).
- **Tests:** 278 pass; the S3 smoke and the cluster, cluster S3 (33), moves (14), repair (13) and EC (14) smokes pass.
- **Next:** longer runs on other machines (the Mac mini, binfadel), then M6's exit review.

### 15 Nov 2026: ADR-0062 to ADR-0065 accepted

- The owner: "I accept ADRS: ADR-0062 to ADR-0065 as recommended." Membership and placement (0062), scrub, repair
  and rolling restarts (0063), erasure-coded extents (0064) and the chaos harness (0065) are accepted as built.

### 15 Nov 2026: M6 item 9: long chaos runs on Linux (binfadel, alghobashi)

- **Where:** binfadel (Ubuntu 24.04, Xeon E-2236), built there with ceesafec 0.45.0; alghobashi (Debian 13, 8 cores,
  the owner's production services on it: our binary copied in, nothing installed, run at `nice 10` in a scratch
  directory). The Mac mini was not available.
- **First runs found a harness bug, not a cluster one:** every history linearizable, but after a few minutes the whole
  cluster stopped answering. The proxy never closed its sockets and each node start leaked a log handle; at Linux's
  1024 descriptors the harness's accept threads ended and its fault thread crashed with a node down. Fixed (it closes
  what it opens, keeps accepting through errors, fails a run when its fault thread crashes); under `ulimit -n 1024`
  on macOS the old harness fails the same way and the new one passes.
- **Then, of commit 9331752 (5 min a run, every fault):** binfadel 5 of 5 three-node runs and 2 of 2 five-node runs,
  alghobashi 4 of 4 three-node runs, and 4 disk-loss runs (up to nine losses each): every history linearizable,
  every key answered through every node after the heal; about 3,800 to 4,600 operations and 48 to 93 faults a run.
  One disk-loss run failed on a loss begun half a second before the run's end, which the harness gave up on: it now
  sees a loss through.
- **Next:** M6's exit review.

### 15 Nov 2026: M6's exit review (`docs/m6-exit-review.md`)

- **Rack faults and coded data added to the harness first:** `--racks 3` (six nodes, one replica a rack; `rack-kill`,
  `rack-isolate`) and `--code-after-seconds` (extents coded within seconds, two cold keys read throughout, decoded
  under the faults). Linearizable on macOS and in two 5-minute rack runs on binfadel (6 rack kills, 15 rack
  isolations).
- **The verdict:** for what M6 built, the exit holds: under node, disk, rack, network and clock failures, alone and
  together, on three machines and two operating systems, acknowledged writes survived and no read or listing was
  stale. Known gaps are written down there: group 0 fixed on the first three nodes, an empty-directory restart
  undetected, sealed packs not coded, listings checked per key, writes not idempotent across a lost answer, one
  machine per run.
- **Next:** the owner's call on closing M6 with those gaps, or taking the first two first.
- **The owner:** "Fix all those gaps before closing".

### 15 Nov 2026: M6 exit gaps A to C: empty directories, group 0, listings across keys (ADR-0066, ADR-0067)

- **A, an empty directory (ADR-0066, proposed):** a node's directory gets a `cosmo-node` marker (cluster, node, how it
  began); an empty one starts only with `--init` (formation) or `--join`, which first asks the peers and refuses while
  a shard (judged by its highest-term view) lists the node as a voter; a joined node opens what it holds nothing of
  outside the group. `cluster-join`/`cluster-leave` keep trying for 15 s (they gave up in milliseconds).
  `tools/cluster_identity_smoke.sh` (25 checks).
- **B, group 0 moves (ADR-0067, proposed):** three voters among the active nodes, every other node its learner; a
  leaving voter is made a learner. Found on the way: a leader never lowered a peer's match, so a learner whose disk was
  replaced was counted as caught up with an empty log; a refusal below the match now lowers it and the log is sent
  again (`raftALostLogIsSentAgain`; the 12 Raft mutants still killed). Disk loss in the harness now hits any node,
  group 0's included: five losses in a run, all recovered, linearizable.
- **C, listings across keys:** the checker also checks the whole history as one register per key, so a listing that
  is no single moment fails (self-test 20 of 20; about a second a run).
- **Tests:** 279 pass; every smoke passes (identity 25, EC 14, repair 13, moves 14, cluster S3 33, cluster 5, S3); the
  chaos mutants are killed; three 90 s chaos runs linearizable per key and across keys.
- **Next:** D, write sessions (ADR-0068): a forwarded write done once.

### 15 Nov 2026: M6 exit gaps D and E (first part): write sessions, a network that misbehaves (ADR-0068, ADR-0069)

- **D, a forwarded write done once (ADR-0068, proposed):** the node that takes a write gives it a request id (a
  client's `x-cosmo-*` headers taken off); the leader stages a `Session` record (type 18) with the id and its answer
  after the write's entries; every replica keeps the 16,384 most recent (checkpoint format 18); a write sent again
  with a known id gets the first answer and is not done. Forwarded writes are sent again whenever the exchange
  fails. Chaos runs show about a third of the unknown outcomes they did.
- **Its check:** `tools/cluster_sessions_check.py` (8 checks) sends a forwarded PUT, another PUT, then the first again
  with its id: answered with the first ETag, not done again. With the lookup off (a mutant), it finds the write done
  again; a chaos run rarely does (the front sends again within milliseconds, inside the client's operation). The
  check had a bug of its own: it signed as node 2, and node 2 refuses requests that say they are from itself.
- **E, first part (ADR-0069, proposed):** the proxy shapes links: `slow` (20 to 200 ms, jitter), `flaky` (connections
  reset at 1 to 5% of chunks), `throttle` (one node at 50 to 200 KB/s), among the default faults.
- **Tests:** 281 pass; every smoke; the sessions check; three chaos mutants killed; three 90 s chaos runs with the new
  faults linearizable per key and across keys.
- **Next:** E's second part (nodes on several machines), then F: coded pieces re-homed when a holder leaves (a hole
  in item 8 found while planning F), and sealed segments coded.

### 15 Nov 2026: M6 exit gaps E (second part) and F: nodes on several machines; coded segments, re-homed pieces (ADR-0069, ADR-0070)

- **E, second part (ADR-0069, proposed):** `tools/cluster_chaos.py --hosts` runs node i on the i-th host (`local` or
  `user@host:/path/to/cosmostore`), every node on its host's loopback, SSH tunnels carrying the peer and S3 ports to
  the harness and the proxy's ports to each host: nothing listens on any host's network. Two 300 s runs with a node
  each on this Mac, binfadel and alghobashi: linearizable per key and across keys.
- **F1, pieces re-homed (ADR-0070 §4, proposed):** a hole in item 8 found while planning F: a coded extent's piece left
  with a holder that left its shard. The coding loop now proposes the coding again with that holder replaced by a
  voter with no piece, which rebuilds it. `tools/cluster_ec_smoke.sh` (now 20 checks): node 4 rebuilds the piece node 1
  held, byte for byte, and the object decodes with nodes 1 and 2 down.
- **F2, sealed segments coded (ADR-0070 §1 to §3, proposed):** found first: a Raft log's segments were not the same on
  every replica (sealed after a batch, once committed), so coding "segment N" threw a follower's records away (a smoke
  test's reads failed). A Raft log now seals before the record that would start past the target, at the write of its
  batch, whatever is committed, its headers without a time, and `truncateAfter` cuts across segments
  (`raftLogSegmentsAreTheSameOnEveryReplica`, `raftLogCutsAcrossSegments`, the fault sweeps). Then sealed segments
  wholly before the checkpoint, mostly live and cold are coded as extents are; reads decode; compaction leaves them
  until dead. Also found: a segment's coding was told from an extent's by the key's top bit, which half of all random
  extent ids have; the record says which now. `node --segment-mb`; `tools/cluster_ec_segments_smoke.sh`.
- **Tests:** 284 pass; every smoke; the sessions check; the Raft and chaos mutants killed; chaos runs default, coded,
  disk-loss and racks linearizable. (Two of those runs once printed nothing, no summary, and passed when run again.)
- **Next:** the exit review brought up to date, and the owner's word on ADR-0066 to ADR-0070.

### 15 Nov 2026: M6 exit review brought up to date; the checker's last fixes

- **`docs/m6-exit-review.md`** now lists the six gaps, what closed each and its evidence, what was found while closing
  them, and what is still not covered (listings across shards, a client's own retries, system-wide clock skew, the
  proxy on one machine, the runbook's limits). Its verdict: the exit holds for what M6 built.
- **Two runs with coded data had printed nothing:** the check across keys found its search too large and raised,
  which the harness did not catch, and its cleanup then removed the evidence. It now tries the smallest search first
  (no unknown write no GET saw), reports a search too large as a failure, and a run that crashes keeps its directory.
  One run failed a key because the search let in unknown writes only near where it first stuck; it now widens
  step by step. The histories of the real double-write bug still fail.
- **Then:** two local runs and a 300 s run with nodes on this Mac, binfadel and alghobashi and coded data: linearizable
  per key and across keys.
- **Next:** the owner's word on ADR-0066 to ADR-0070, and closing M6.

### 15 Nov 2026: ADR-0066 to ADR-0070 accepted; M6 closed

- The owner: "Yes I accept ADR-0066 to ADR-0070 as recommended." Node identity and empty directories (0066), group
  0 moving (0067), write sessions (0068), network faults and many machines (0069), coded segments and re-homed pieces
  (0070) are accepted as built.
- **M6 (the distributed cluster) is closed:** its exit holds for what it built (`docs/m6-exit-review.md`), the gaps
  of the first review closed, ADR-0056 to ADR-0070 accepted. What is not covered is listed there.

### 16 Nov 2026: M7 started; item 1, server access logs (ADR-0071, ADR-0072)

- **The owner:** "Go ahead start M7". **ADR-0071** (proposed) plans it: access logs, website hosting, inventory, STS,
  Access Points, replication, in that order, each its own ADR with a support matrix, single node first; directory
  buckets and Tables not in M7.
- **Item 1, server access logs (ADR-0072, proposed):** `PutBucketLogging`/`GetBucketLogging` (a `BucketConfig` of kind
  12, checkpoint format 19); a line per request to a bucket that logs, in S3's access log format, with the query's
  names only (never a presigned URL's values); delivered every `--access-log-seconds` (300) or at 1 MiB as an object
  of the target bucket; grants and partitioned keys `NotImplemented`; a cluster's S3 port refuses it for now.
- **Toolchain:** `../../CeeSafe.Web` (a shared checkout) is now on a branch that needs ceesafec 0.53 or later, so the
  0.45 compiler no longer checks CosmoStore; the installed 0.54.0 does, and is used locally. CI's pins
  (`CEESAFE_WEB_REF`, ceesafec 0.45) are unchanged: the owner's call.
- **Tests:** `loggingConfigurationXml`, `accessLogLineFormat`; the S3 smoke delivers a log object with the PUT's line
  and a missing key's `NoSuchKey`.

### 16 Nov 2026: M7 item 2, static website hosting (ADR-0073)

- **Under the owner's standing go-ahead.** **ADR-0073** (proposed): Put/Get/DeleteBucketWebsite (a `BucketConfig` of
  kind 13, checkpoint format 20): index and error documents, `RedirectAllRequestsTo`, up to 50 routing rules (a key
  prefix or an error code; host, protocol, key or prefix replacement, redirect code). `serve --website-domain`
  makes `<bucket>.<domain>` a bucket's website on the S3 port: anonymous, GET and HEAD, HTML errors, index documents,
  the folder redirect, the error document, rules, and `x-amz-website-redirect-location` (now kept with an object).
  Not on a cluster yet.
- **Tests:** `websiteConfigurationXml`, `websiteHostNames`; the S3 smoke serves a site: index, folder redirect,
  folder index, error document, a routing rule, an object's redirect, 405, and no site after its deletion.

### 16 Nov 2026: M7 item 3, inventory reports (ADR-0074)

- **Under the owner's standing go-ahead.** **ADR-0074** (proposed): Put/Get/List/DeleteBucketInventoryConfiguration (a
  `BucketConfig` of kind 14, checkpoint format 21, up to 1,000); daily or weekly reports of current or all versions,
  filter prefix, optional `Size`, `LastModifiedDate`, `ETag`, `StorageClass`, `IsMultipartUploaded` (others, ORC and
  Parquet `NotImplemented`); gzip CSV data files and `manifest.json` with `manifest.checksum` under
  `<prefix>/<source>/<id>/`; due times read back from the destination, so a restart neither repeats nor skips one.
- **gzip of stored blocks:** lib/std has no deflate (CEESAFE_GAPS **G35**, logged): valid gzip, as large as its CSV.
- **Tests:** `inventoryConfigurationXml`, `gzipOfStoredBlocks`, `inventoryRows`; the S3 smoke opens a report with
  Python's `gzip` and finds a row per object.

### 16 Nov 2026: M7 item 4, STS (ADR-0075)

- **Under the owner's standing go-ahead.** **ADR-0075** (proposed): `GetSessionToken` and `AssumeRole` on the S3 port
  (STS's form body and XML, SigV4 for `sts` over the body's hash); session tokens are the session sealed with
  AES-256-GCM under `serve --sts-key-file` (rotatable, nothing stored); roles from `serve --roles-file` with identity
  policies (a bucket policy's grammar without `Principal`). A role session is its key narrowed: the role's policy and
  the session policy must allow each call, checked in `gateDecision`, ahead of the keys' fast path, and in front of
  `ListBuckets`, `CreateBucket` and the admin API. Not on a cluster yet.
- **Tests:** `stsTokens`, `stsRolesAndIdentityPolicies`, `stsFormBodies`; the S3 smoke signs with what `aws sts`
  returns: 23 checks, refusals of writes, deletes, batch deletes, copies, other buckets, `ListBuckets`,
  `CreateBucket`, STS and the admin API from sessions; presigned URLs; session policies.

### 16 Nov 2026: M7 item 5, Access Points (ADR-0076)

- **Under the owner's standing go-ahead.** **ADR-0076** (proposed): S3 Control's Create/Get/List/DeleteAccessPoint
  and Put/Get/DeleteAccessPointPolicy on the S3 port (a `BucketConfig` of kind 15, checkpoint format 22); requests by
  alias or by ARN (`<name>-<account>.<domain>`) resolve to the bucket before anything reads them; the access point's
  policy (its ARN's resources read as the bucket's) and public-access block are checked in `gateDecision` and ahead of
  the keys' fast path; through one only objects, listings, uploads and batch deletes. Not on a cluster yet.
- **Tests:** `accessPointsStoredAndFound`, `accessPointPolicies`; the S3 smoke drives `aws s3control` and reads,
  writes and lists by alias and ARN, with the access point's Deny, its block and its deletion.

### 16 Nov 2026: M7 item 6, replication, part 1: destinations on this server (ADR-0077)

- **Scope chosen by the owner** (16 Nov 2026): replicas that keep their source's version id and ETag, destinations on
  this server first, other S3 endpoints next. **ADR-0077** (proposed): Put/Get/DeleteBucketReplication (a
  `BucketConfig` of kind 16, checkpoint format 23); each matching rule is one more target of a write's outbox event
  (ADR-0048), so replication is as durable as the write; a replica is the source version's stored bytes, metadata and
  envelope, put by the new `ObjectStore.putReplica` with the source's version id, MD5 and part count (the part count
  after a put record's extras section), once however often it is delivered; delete markers too; status derived, not
  stored. Suspending a source's versioning is InvalidBucketState.
- **Tests:** `replicasKeepTheirSourcesIdAndEtag`, the fault sweep `replicaFaults{Once,Sticky,Torn,Crash}`,
  `replicationConfigurationXml`; the S3 smoke replicates a small, a multipart and an SSE-S3 object (ids, ETags,
  bytes, `REPLICA`, `COMPLETED`), a delete marker, both ways without echo.
- **Next:** part 2, destinations on other S3 endpoints.

### 16 Nov 2026: M7 item 6, replication, part 2: other S3 endpoints (ADR-0077 §6, §7)

- `serve --replication-targets` (`<id> <url> <access key> <secret key> [region]`, wiped once read); a rule's
  destination `arn:cosmostore:s3::<id>:<bucket>`. A replica is SigV4 requests with an unsigned payload streamed from
  the stored bytes (a `BodySource`): one PUT, or a multipart upload with the source's part sizes so the ETag is kept;
  SSE-S3 and SSE-KMS versions opened here and sealed there by SSE-S3; SSE-C refused; delete markers as DELETEs;
  `REPLICA` kept by a CosmoStore destination, so nothing echoes. Refusals noted as a `BucketConfig` of kind 17
  (checkpoint format 24): `FAILED` survives a restart.
- **Tests:** `replicationToOtherEndpoints`; the S3 smoke runs a second server as the endpoint. The smoke's inventory
  check no longer races a second report in the same minute's folder.
- **M7 is built** (items 1 to 6, ADR-0071 to ADR-0077 proposed); none of it on a cluster's S3 port yet.

### 16 Nov 2026: ADR-0071 to ADR-0077 accepted

- The owner: "Yes, accept ADR-0071 to 0077". M7 (access logs, website hosting, inventory, STS, Access Points,
  replication here and to other endpoints) is accepted as built; its cluster support is later work.

### 16 Nov 2026: M7 on a cluster, slice a: STS (ADR-0078)

- **On the owner's "continue".** **ADR-0078** (proposed) plans M7's features on a cluster's S3 port in four slices:
  STS; website hosting; the outbox delivered by each shard's leader (notifications, access logs, inventory,
  replication); Access Points (names unique across shards through group 0).
- **Slice a, STS:** `cosmostore node --sts-key-file --roles-file` (the same files on every node); every shard's S3
  server holds the keys and roles; the front routes STS's POST to shard 0's leader. The cluster smoke (39 checks)
  mints a session through one node, uses it through another, and narrows a role on every node.
- **Slice b, website hosting:** `cosmostore node --website-domain`; the front routes `<bucket>.<domain>` requests by
  their host to the bucket's shard, whose S3 server serves the website; PutBucketWebsite allowed on a cluster. The
  cluster smoke (44 checks) serves a site through every node.
- **Slice c, step 1 (the store):** an `OutboxDelivered` record (type 19, a Raft log only): a raft store's
  `eventsDelivered` stages it for the leader to propose, and its apply drops the events on every replica; a raft
  replica's cursor at open is derived from its checkpoint (before its first held event, or its LSN), so no format
  change. Tests: `outboxDeliveredOnEveryReplica` (three replicas agree, one reopened from a checkpoint, two from
  their logs) and `clusterOutboxFaults{Once,Sticky,Torn,Crash}`. Next: the delivery task on each shard's leader.
- **Slice c, step 2 (webhooks on a cluster):** `cosmostore node --notify-targets`; a delivery loop on every node
  delivers each shard it leads, then proposes `OutboxDelivered` behind the shard's gate and waits for it to apply
  (without that wait the first smoke run got each event two to four times). The cluster smoke (48 checks): events
  written through three nodes delivered once each, in order; the shard's leader killed, the next one delivers.
- **Slice c, step 3 (replication on a cluster):** `cosmostore node --replication-targets`; a replica into a bucket of
  the cluster goes through the node's own front as a signed PUT (or DELETE, for a marker) with
  `x-cosmo-replica-version`/`-md5`/`-parts`/`-extras`, which a shard's S3 server takes only signed by a long-term key,
  and writes with `putReplica`; another endpoint's as on `serve`. Found by the smoke: the S3 server's count of
  buckets with replication was taken before the configuration's record applied, so it was 0 on a cluster and hid
  every status; it now stays at "some", as the policy counts do. The cluster smoke (64 checks): replicas in another
  shard with their ids, ETags and part numbers, a delete marker, another endpoint, COMPLETED and FAILED through every
  node.
- **ADR-0078 accepted** by the owner (17 Nov 2026), with slices a and b and slice c's steps 1 to 3 built; access logs
  and inventory on a cluster, the chaos-harness run, and slice d (Access Points) are next.
- **Slice c, step 4 (access logs and inventory on a cluster):** every shard's S3 server queues access log lines on
  its node's queue; the node PUTs each target's object through its front with `x-cosmo-log-delivery`, which is not
  logged itself. Each shard's leader makes inventory reports (`InventoryScan`, shared with `serve`) and PUTs their
  files through the front; it finds the last report by listing the destination through the front. Found on the way:
  a shard's S3 server saw the front's address, not the client's (in access logs, and in policies' `aws:SourceIp`);
  the front now forwards it as `x-cosmo-peer`. And a multipart replica over the front's 64 MiB could not be sent as
  one PUT: it is now an upload with the source's parts, completed as the source's version (`completeUploadAs`).

- **Slice c, the chaos-harness run:** `tools/cluster_chaos.py --outbox` (and a `kill-leader` fault): the clients'
  bucket versioned, its events to a webhook of the harness's, replicated to a bucket of the other shard. After the
  heal: every acknowledged write's event delivered at least once, none of a write never made, first deliveries in
  sequencer order, the replicas exactly the source's versions and markers. Three runs passed (leader kills alone for
  60 s; every default fault for 90 s, twice), with 297, 17 and 67 events delivered again after a leader's change.
  Slice d (Access Points on a cluster) is next.
- **Slice d, Access Points on a cluster (ADR-0078 §5):** an access point's name is a claim in group 0 (the object
  `access-point/<name>` of its system bucket, `<bucket>\n<alias>`; no new record), taken and let go by group 0's
  leader on a peer path of its own. The front claims a name before the bucket's shard makes the access point (with the
  alias the front picked), routes S3 Control by the claims (ListAccessPoints merged across shards), and routes a
  request by alias or by `<name>-<account>` to the bucket's shard; `cosmostore node --domain` reads virtual-hosted
  requests, so ARNs work. A deleted bucket's names are let go. Tests: two new, 313 in all; the cluster smoke, 97
  checks. ADR-0078 is built.
- **ADR-0078 accepted as written** by the owner (17 Nov 2026), §5 (Access Points on a cluster) included.

### 17 Nov 2026: M7's exit review (`docs/m7-exit-review.md`)

- **The owner:** "Do the M7 exit review". Every item's "done when" holds on `serve` and on a cluster; six chaos runs
  with `--outbox` (three of 5 minutes) deliver every event at least once and in order and replicate every version.
- **Not closed yet:** two readers of the code found STS parameters taken and not done (`PolicyArns` among them),
  replication's `StorageClass` and `Priority`, inventory's and access points' accounts (A1 to A5), and six defects
  in ADR-0078's code, the worst an access point's claim let go while it exists (B1 to B6); CI runs no cluster smoke.
  The review recommends fixing them before closing M7. The M7 ADRs' "refused on a cluster" lines now point to
  ADR-0078; the chaos checker reports a per-key search too large instead of stopping.
- **The review's findings closed** (the owner: "continue"): STS refuses what it does not do (`PolicyArns` and the
  rest); replication's `Priority` decides as AWS's and `StorageClass` is refused; inventory's `AccountId` refused and
  `IsEnabled` strict; access points keep their account (v2). Access point claims are pending until made, confirmed
  or abandoned by their create's token; the front lets replica and log-delivery fields through only on its node's
  stamped requests (refused on `serve`); alias-shaped names cost no peer request; CI runs the cluster smoke. Tests:
  319; the cluster smoke 98 checks. M7 can close on the owner's word.

### 17 Nov 2026: M7 closed

- The owner: "Go ahead close M7". **M7 (advanced S3) is closed:** access logs, website hosting, inventory, STS,
  Access Points and replication, each with its support matrix, on `serve` and on a cluster's S3 port; the exit
  review's findings closed (`docs/m7-exit-review.md`); ADR-0071 to ADR-0078 accepted. What is not covered is listed
  in the review. Directory buckets and S3 Tables, left out of M7, are for a later milestone if wanted.
- CI's first cluster smoke failed 9 downloads: its AWS CLI's CRT client signs `content-length: 0` on a GET, which the
  front's HTTP client does not send on. SigV4 now reads a signed `content-length` that did not arrive as 0 when no
  `transfer-encoding` says a body follows (`sigv4MissingZeroLength`).

### 18 Nov 2026: M7's calls in the SDK matrix

- The exit review's "no client SDK test of M7's calls": boto3 (33 checks, `s3`, `s3control`, `sts`) and the Go SDK
  v2 (33, `tools/sdk/go/m7.go`) now run access logs, website hosting, inventory, STS, Access Points and
  replication; `tools/sdk/common.sh` starts serve with M7's options. boto3 178, Go 55, all pass; the JavaScript SDK v3 (33 more, `client-s3-control` and `client-sts`) 61; the .NET SDK (33 more, `AWSSDK.S3Control`, `AWSSDK.SecurityToken`) 55; the Java SDK v2 (33 more, `s3control`, `sts`) 58. Every SDK of the matrix now runs M7, which closes that gap of the exit review.
- **Go found two defects** the CLI and boto3 let pass: S3 Control's errors were S3's `<Error>` form, which Go's
  s3control client reads as UnknownError (now `<ErrorResponse><Error>`, ADR-0076 §1); and a replication rule with its
  `Status` after `DeleteMarkerReplication`, Go's alphabetical order, was MalformedXML (`replicationRuleInAnyOrder`,
  ADR-0077 §1). 321 tests; the S3, TLS and cluster smokes (CRT client) pass.
- **The outbox run across keys, settled:** the exit review's 5-minute `--outbox` runs on one Mac did not settle the
  check across keys (four at once). One alone on alghobashi (commit 2331f79, built on binfadel with ceesafec 0.56.0
  and CeeSafe.Web ccda03a): 3,549 operations, 48 faults, 1,992 events (506 again after a leader's change), every
  outbox check passed, every key linearizable and the check across keys settled.

### 18 Nov 2026: M8 proposed (ADR-0079)

- After M7, the item ADR-0071 §3 left for later: **ADR-0079 proposes M8**, directory buckets first, then S3 Tables,
  each with its own ADR and support matrix. Checked first: boto3 sends a `--x-s3` bucket's requests to a custom
  endpoint path-style, after a CreateSession (`GET /<bucket>?session`) signed for `s3express`, so CreateSession and
  that signing service are the entry fee. For the owner: accept it, and whether both items or directory buckets only.
- **The owner's choices:** directory buckets only (Tables wait), with S3's limits enforced. **ADR-0080 proposes
  directory buckets** from AWS's pages and from what boto3 sends a custom endpoint: every call on a `--x-s3` bucket,
  CreateBucket included, takes a session first and arrives with its token; CopyObject and ListDirectoryBuckets come
  signed for `s3express` with the long-term key, ListDirectoryBuckets as `GET /`. Three slices; for the owner to
  accept, with ADR-0079.
- **The owner: "accept ADR-0079 and ADR-0080".** M8 is directory buckets; slice 1 next.

### 18 Nov 2026: M8 slice 1, directory buckets made and listed (ADR-0080)

- **`serve --zone-id`** names the zone; **CreateBucket** with a directory configuration (this zone, AvailabilityZone,
  SingleAvailabilityZone, Directory; another zone or a Local Zone InvalidArgument; ACL, grant, lock and ownership
  headers InvalidArgument; without `--zone-id` NotImplemented) makes a directory bucket, answering `x-amz-bucket-arn`.
  Its BucketCreate record carries the zone after its time, so the bucket is never seen without it; checkpoint
  format 25 keeps it. A `--x-s3` name is never a general-purpose bucket's (InvalidBucketName).
- **ListDirectoryBuckets** (`GET /` signed for `s3express`), paged by `max-directory-buckets` and a token;
  ListBuckets leaves directory buckets out. **`s3express` signatures** are taken from long-term keys for directory
  buckets (and a CreateBucket of a `--x-s3` name); a general-purpose bucket refuses them
  (AuthorizationHeaderMalformed).
- Tests: `directoryBucketNamesAndZones`, `directoryBucketsKeepTheirZone` (the journal, a checkpoint, made again),
  the fault sweep `directoryFaults{Once,Sticky,Torn,Crash}`, `directoryBucketConfigurations`,
  `directoryRequestFields`; boto3 with sessions off makes, lists (two pages), writes and reads one. The AWS CLI 2.34
  cannot turn sessions off, so its checks and the smokes' come with slice 2 (CreateSession). 329 tests; the S3, TLS
  and cluster smokes and boto3 pass as before.

### 18 Nov 2026: M8 slice 2, CreateSession and the cluster (ADR-0080)

- **CreateSession** (`GET /<bucket>?session`): from a long-term key or a `GetSessionToken` session (not a role's,
  not another CreateSession's), for a directory bucket or a name of this zone's form not made yet (the SDKs take a
  session before CreateBucket and keep it); ReadWrite or ReadOnly; SSE-S3 only. Its token is sealed under STS's
  keys with its own version and additional data (STS's sealing made generic, `sealToken`/`openToken`), holding the
  key, the bucket, the mode and a 5-minute expiry.
- **`x-amz-s3session-token`:** signed for `s3express`, it opens as a session of its key with no role; the request
  must be for its bucket, and a ReadOnly session's one of S3's six reads (AccessDenied); with an STS token too,
  InvalidRequest.
- **On a cluster:** `node --zone-id`; ListDirectoryBuckets merged across shards by the front as ListBuckets is; a
  session made through one node opens on any other.
- Tests: `expressTokensAreTheirOwn`, `expressSessionsReachTheirBucketAndMode`; `tools/s3_raw.py express`. The S3
  smoke makes and uses a directory bucket with the AWS CLI's sessions (`s3 cp --recursive` too) and checks a
  ReadOnly session, another bucket, a changed token and an `s3express` signature on a general-purpose bucket; the
  cluster smoke (106) lists through every node and uses a session from node 1 through node 3. 331 tests.

### 18 Nov 2026: slice 2's CI, and M8 slice 3a, what a directory bucket refuses (ADR-0080)

- **CI failed slice 2's smoke** on its AWS CLI (2.39), whose CRT transfer client (1) names a directory bucket only in
  the host of its CreateSession, so through `http://127.0.0.1:…` it sends `GET /?session` with no bucket, and (2)
  signs its object calls for `s3`, not `s3express`, with the session token. A session token is now taken signed for
  either; for (1) a CRT client needs an endpoint by name (`<bucket>.<host>` resolving): the smokes' `s3 cp`s go
  through `localhost` and CI maps the two buckets in `/etc/hosts` (ADR-0080 §9, `docs/compatibility.md`).
- **Slice 3a:** a directory bucket refuses what S3 does not take on one (ADR-0080 §6): calls by their query
  (versioning, ACLs, tags, replication, logging, website, CORS, versions, object lock, retention, ListObjects v1,
  …) and features' headers (ACLs, tags, object lock, Requester Pays, SSE-C, website redirects) NotImplemented;
  `Content-MD5`, an encryption other than SSE-S3, a storage class other than `EXPRESS_ONEZONE`, `start-after`, a
  delimiter other than `/` and a prefix not ending in it InvalidArgument; a multipart upload's parts consecutive
  from 1 (InvalidPartOrder). Only `--x-s3` names are looked up. `directoryBucketsRefuseWhatS3Does`; the S3 smoke
  checks five refusals and a policy taken. 332 tests, the cluster smoke 106, the CRT client by hand (a 20 MB
  multipart upload and download).
- **Next (3b):** non-MD5 ETags, uploads' prefixes in listings, the SDK matrix.

### 18 Nov 2026: M8 slice 3b, S3's behaviours for directory buckets, and boto3 (ADR-0080)

- **ETags** of a directory bucket's objects are not MD5s: SHA-256 over a label, the stored MD5 and the part count,
  cut to 16 bytes, no `-N` (the store keeps the real MD5 for its verification and scrub, so the ETag is made where
  it is shown: GET, HEAD, PUT, copy, completion, POST, listings, and If-Match and its kin, including a copy
  source's). A part's ETag stays its MD5. `directoryEtagsAreNotMd5s`.
- **ListObjectsV2** with `/` names the prefixes of uploads in progress (within the page's range); a browser POST
  upload to a directory bucket is NotImplemented.
- **boto3** (201): a directory bucket made, listed, written, read with If-Match, a 12 MiB multipart upload
  (no `-N`), refusals and deletion, with sessions and with them off; `create_session`. The S3 smoke checks the
  ETags, a condition, a listing and an upload's directory. 333 tests, the cluster smoke 106.
- **The rest of the SDK matrix:** Go (73), JavaScript (77) and Java (74) check directory buckets with their sessions
  and without, .NET (63) without. Found: Go asks for a session for ListDirectoryBuckets, which has no bucket, and
  fails before sending; .NET's S3 Express pre-signer fails before sending on any non-AWS host; the JavaScript SDK
  writes `/<bucket>//<key>`, so a `--x-s3` bucket's path-style key loses one leading `/` here (ADR-0080 §9).
  333 tests and every smoke pass.
- **Next:** M8's exit review.

### 18 Nov 2026: M8's exit review (`docs/m8-exit-review.md`)

- ADR-0080's "done when" checked against the tests, the smokes and the SDK matrix, and two reviews of the code by
  readers who had not written it (the calls a directory bucket takes and refuses; CreateSession's sessions).
- **Verdict: not yet.** DeleteObjects is refused on a directory bucket (A1); a session reaches S3 Control (B1) and a
  copy's source in another bucket (B3), and bucket-less calls (B2); policies cannot name `s3express:` actions (B4);
  tags kept by a copy, inventory's MD5 ETags, the storage class, lifecycle and encryption rules taken that S3 does
  not take (A2–A8); RenameObject listed as taken and not built (A9).
- **Next:** fix the findings, each with a test, if the owner agrees.

### 18 Nov 2026: M8's exit review findings closed (the owner: "continue and fix them all")

- **Sessions:** no S3 Control, no bucket-less calls, no copy from another bucket, no unsigned token; a bucket's
  policy decides `s3express:CreateSession` on every use; policies take `s3express:` actions and ARNs; the logs name
  the session's key; a CreateBucket signed for `s3express` must name a directory bucket.
- **Directory buckets:** DeleteObjects; `versionId=null`; tags only empty (a tagged copy NotImplemented); lifecycle
  only expiration and aborts; always encrypted, a request naming only its bucket's encryption, and CreateSession
  answering it; `EXPRESS_ONEZONE`; inventory's directory ETags; HeadBucket's zone; no access points yet.
- 335 tests, the S3 and TLS smokes, the cluster smoke (110) and the whole SDK matrix pass.
- **RenameObject** (A9) needs a journal record: proposed as ADR-0081, for the owner to accept or leave out of M8.
- **Next:** the owner's word on M8 and ADR-0081.

### 18 Nov 2026: RenameObject (ADR-0081, accepted: "Take on with ADR-0081")

- **A `Rename` record** (record type 20): a directory bucket's object moves to another key if its current version is
  still the generation named, with its locator, metadata and dates; the destination's earlier object is retired as an
  overwrite's. No payload is copied; compaction copies a renamed inline object under its new key, and a copy planned
  before a rename is garbage, its record staying live. The checkpoint format does not change.
- **The S3 call:** `PUT /<key>?renameObject` with `x-amz-rename-source` as `/key`, `bucket/key` or `key`; the
  source's and destination's conditions under the same hold of the store as the commit; `x-amz-client-token`
  remembered in memory for 10 minutes (IdempotencyParameterMismatch for another rename); `s3:PutObject` on the
  destination and `s3:DeleteObject` on the source; ReadOnly sessions and general-purpose buckets refused.
- **Tests:** `renameMovesAnObject`, `renameAndCompaction`, `renameClientTokens`, `renameSourcesInEveryForm`, the
  fault sweep `renameFaults{Once,Sticky,Torn,Crash}`; S3 smoke (12 checks), cluster smoke (112), boto3 (with and
  without sessions). 343 tests.
- **Next:** the owner's word on closing M8.

### 18 Nov 2026: M8 closed

- The owner: "go ahead and close M8". **M8 (directory buckets) is closed:** CreateBucket with a directory
  configuration, CreateSession and `s3express` signing, ListDirectoryBuckets, S3's limits and behaviours for them,
  and RenameObject, on `serve` and on a cluster, through the AWS CLI and every SDK of the matrix (ADR-0080,
  ADR-0081; `docs/m8-exit-review.md`). Not done, and refused: access points of directory buckets. S3 Tables are
  left for when Iceberg engines are meant to run against CosmoStore (ADR-0079).

### 18 Nov 2026: access points of directory buckets, slice 1 on `serve` (ADR-0082, proposed)

- **The owner:** "Take on Access points on directory buckets next". **ADR-0082** (proposed) designs them, from AWS's
  pages and what boto3 sends to a custom endpoint (a CreateSession on the access point's name, then its calls, all
  signed for `s3express`; the S3 Control calls on their usual paths).
- **Built on `serve`:**
  - **Names and record:** names `<base>--<zone>--xa-s3`, which are their own aliases, with `arn:aws:s3express:`
    ARNs. They are kept in the bucket's access point record, whose encoding v3 adds the scope (v1 and v2 still read).
  - **S3 Control:** CreateAccessPoint with a `Scope`, Get/Put/DeleteAccessPointScope, and
    ListAccessPointsForDirectoryBuckets (paged); ListAccessPoints leaves them out. Tags on any access point are
    NotImplemented, not dropped.
  - **Requests through one:** checked against the scope (each call's permission, and its key or a listing's prefix
    in a prefix; DeleteObjects per key, and RenameObject's source). Anonymous requests are refused.
  - **Sessions:** a session made through an access point is that access point's, so no session goes around a scope
    or a policy.
  - **Policies:** an access point's policy names it by its `s3express` ARN.
  - **On a cluster:** CreateAccessPoint is NotImplemented until slice 2.
- **Tests:** `directoryAccessPointNames`, `directoryAccessPointScopes`, `directoryAccessPointPermissions`. The S3
  smoke's 23 checks, and boto3's 11.
- **Next:** slice 2, the cluster.

### 18 Nov 2026: access points of directory buckets, slice 2 on a cluster (ADR-0082 §5)

- **Claims and routing:**
  - A directory access point's name, its own alias, is claimed in group 0, and the front finds it by that claim:
    data requests and CreateSession through it go to its bucket's shard.
  - The `/scope` calls route as the policy calls do, and DeleteAccessPoint lets the name go (a scope's DELETE does
    not).
- **The listing:** ListAccessPointsForDirectoryBuckets of one bucket goes to its shard. Of every bucket, the front
  merges the shards' first `maxResults` by name and pages them, with a `NextToken` every shard reads.
- **Tests:** the cluster smoke's 10 checks. These are an access point on a shard-1 bucket and one on a shard-3
  bucket, the merged listing and its pages, a scope read and requests through other nodes, and a name let go and
  taken again for another bucket. 122 checks in all.
- **Next:** slice 3, the rest of the SDK matrix.

### 18 Nov 2026: access points of directory buckets, slice 3, the SDK matrix (ADR-0082)

- **Each SDK's check:** Go, JavaScript, Java and .NET make a directory access point with a scope, read the scope
  back, list it, write and read through it, and are refused outside its scope. Go, JavaScript and Java do this with
  their sessions, .NET with them off (as ADR-0080 §9). boto3 did so in slice 1.
- **Found:** the JavaScript SDK writes an access point's paths as `/<name>//<key>`, as it does a directory
  bucket's, so `--xa-s3` names lose the extra `/` too (`directoryNamed`).
- **All of ADR-0082 is built.** It is proposed: accepting it is the owner's decision.
- **CI's perf gate failed twice on slice 1** (`faa5596`), flagging other groups each time: small metadata reads
  and large writes at c32, then small GETs at c32. Slice 1 changes no step of an ordinary request, and the same
  gate on binfadel passed (base `5bd6d7d` against `faa5596`, 3 rounds, built with ceesafec 0.56.0). At c32, small
  metadata reads were p99 1.01 and ops/s 1.00, small GETs 0.98 and 1.02, and large writes 0.93 and 1.03. The CI
  failures were the runner's noise.

### 19 Nov 2026: ADR-0082 accepted

- The owner: "I accept the proposed ADR-0082". Access points of directory buckets are done: on `serve` and on a
  cluster, with their scopes, sessions and listing, through every SDK of the matrix.

### 19 Nov 2026: M9 proposed, S3 Tables (ADR-0083)

- **The owner:** "Next we need s3 tables iceberg". **ADR-0083** (proposed) is the design, from AWS's S3 Tables
  pages, the Iceberg REST catalog's spec, and what boto3's `s3tables` client sends to a custom endpoint. Its paths
  (`/buckets`, `/tables/…`) are an S3 bucket's too, so only the signature's service tells the two apart.
- **The design:** a table bucket is a hidden bucket `<name>--table-s3`, its warehouse. The catalog is JSON records
  under `.s3tables/`, the versionToken a record's generation, and the compare-and-set a conditional write. So there
  is no new journal record. The Iceberg REST catalog writes the metadata files.
- **Slices:** the S3 Tables API, the Iceberg catalog (PyIceberg end to end), the cluster, then the SDK matrix.

### 19 Nov 2026: M9 slice 1, the S3 Tables API on `serve` (ADR-0083)

- **Routing:** a request signed for `s3tables` is S3 Tables'. Its body is read and hashed first (its clients send
  no `x-amz-content-sha256`), and its path is URI-encoded once more in the canonical request, as SigV4 has it for
  every service but S3: the table bucket's ARN is one encoded segment. Errors are REST-JSON
  (`x-amzn-ErrorType`, `{"message"}`).
- **The calls:** create, get, list and delete table buckets, namespaces and tables. Also GetTable by ARN,
  RenameTable (the record moved by ADR-0081's Rename), and Get/UpdateTableMetadataLocation.
  - **Records:** each is a JSON object under `.s3tables/` in the hidden bucket `<hash>--table-s3`. A versionToken
    is its record's generation, and an update is an If-Match write.
  - **Drops:** DeleteTable empties the table's warehouse prefix after its answer's work, a page at a time.
  - **Not done:** policies, maintenance, encryption, tags and the rest are NotImplemented, as is a cluster (slice 3).
- **S3 in a warehouse:** an engine's object calls are taken. The catalog's keys are refused, and so are bucket
  calls (CreateBucket of a `--table-s3` name is InvalidBucketName) and a listing that could reach the catalog.
- **New:** a JSON value model (`src/s3/json.cee`): parse with a depth limit, edit and write, numbers kept as their
  text.
- **Tests:** `jsonModel`, `tableNamesAndArns`, `tableWarehouseCalls`. The S3 smoke's 22 checks
  (`aws s3tables`), and boto3's 10.
- **Next:** slice 2, the Iceberg REST catalog, and PyIceberg end to end.

### 19 Nov 2026: M9 slice 2, the Iceberg REST catalog, PyIceberg end to end (ADR-0083 §5)

- **The catalog:** `/iceberg/v1/…`, signed for `s3tables`.
  - **Config:** `GET /config?warehouse=<ARN>` gives the `prefix` (the ARN, URL-encoded) and its endpoints.
  - **Namespaces:** list, create (the `owner` property only), load, HEAD and drop.
  - **Tables:**
    - **Create:** writes metadata file 0 (format version 2) in the table's warehouse.
    - **Load and HEAD:** as the spec has them.
    - **Commit:** checks the requirements against the current file (409 CommitFailedException), applies the
      updates as PyIceberg's own `update_table_metadata` does, writes the next `<n>-<uuid>.metadata.json` and
      swaps the record by If-Match. A lost swap is 409 and its file is removed.
    - **Drop:** with `purgeRequested=true`, as S3 Tables.
    - **Rename.**
  - **Errors:** in Iceberg's `{"error":{…}}` shape.
- **Also:** CreateTable of the S3 Tables API takes AWS's `metadata.iceberg` schema, spec and order, and writes the
  first metadata file.
- **Found:** PyIceberg 0.12 retries an append whose commit got 409, on refreshed metadata. So a stale append ends
  committed, by design, and the check sends the stale commit itself to see the 409. It sends `purgeRequested=True`
  with a capital T, which is now read either way.
- **Tests:** `tools/iceberg_check.py` (16 checks: create, two appends read back, a stale commit, schema and partition
  spec from the S3 Tables API, properties, rename and purge), run by the S3 smoke when `ICEBERG_PYTHON` is set. CI
  installs PyIceberg for it. Also the unit tests `icebergNewTableMetadata` and `icebergRequirementsAndUpdates`.
- **Next:** slice 3, the cluster.

### 19 Nov 2026: M9 slice 3, S3 Tables on a cluster (ADR-0083 §7)

- **The front:** a request signed for `s3tables` goes to its table bucket's shard, the shard of `<name>--table-s3`.
  It finds the bucket in CreateTableBucket's body, the ARN in the path, GetTable's query, or the Iceberg
  `warehouse` or `prefix`. ListTableBuckets is merged across shards and paged.
- **A request cannot read its own writes on a shard:** its entries are applied once Raft commits them. So:
  - **A table bucket has no record:** it is the bucket `<name>--table-s3` (the store takes such a name up to 73
    characters), its id derived from its name and creation time, and CreateTableBucket one write. Slice 1 had named
    it by a hash, with a record; nothing was released with that.
  - **A drop's purge** walks the warehouse with a cursor.
  - **DeleteTableBucket** with objects left over answers ConflictException, and a retry deletes it.
- **Tests:** the cluster smoke's 9 checks:
  - two table buckets on different shards (5 and 7), the merged listing and its pages;
  - a table made and its metadata location swapped through other nodes, a stale token refused, its files purged;
  - PyIceberg end to end through node 2 (the check's 16).

  129 cluster checks in all.
- **Next:** slice 4, the rest of the SDK matrix.

### 19 Nov 2026: M9 slice 4, S3 Tables in the SDK matrix (ADR-0083)

- **Each SDK's check:** Go, JavaScript, Java and .NET each check the S3 Tables API with their own `s3tables`
  client: table buckets made, listed and deleted, a namespace, a table got by its ARN, its metadata location
  swapped, a stale versionToken refused (ConflictException), and a rename. boto3 and the CLI did so in slice 1.
  All pass.
- **CI:** the runner's Python is now 3.15, for which pyarrow has no wheels yet, so CI's first PyIceberg install
  failed. CI now makes PyIceberg's venv on Python 3.13 (`actions/setup-python`) and pins `pyiceberg[pyarrow]==0.12.0`,
  the version checked here.
- **All of M9 is built** (ADR-0083, proposed): accepting it, and closing M9, are the owner's decisions.
- **CI on `81aab62`:**
  - **The correctness job passed:** the tests, the smokes, and PyIceberg on `serve` and through a cluster node.
  - **The perf gate failed:** small GETs and large writes at c32, ops/s 0.51 and 0.70, the runner's noise at 1.80
    and 2.45.
  - **Why it is noise:** slices 3 and 4 change nothing on `serve`'s request path (the cluster front, CreateBucket's
    name check, a store accessor), and the same gate on binfadel passed (base `8f18b6e` against `81aab62`, 3
    rounds). At c32, small GETs were p99 1.02 and ops/s 0.99; large writes 1.03 and 1.01.
- **CI on `791b2bd`** (only `ROADMAP.md` changed, so base and head were the same code): the perf gate failed again,
  on large GETs at c32 (ops/s 0.78). That shows the gate is failing on the runner's noise, not on the code.
- **The perf gate now needs a failure to repeat** (ADR-0030 §8, the owner's choice): when the first pass fails, a
  second pass of fresh rounds runs. The gate fails only on a row that failed in both passes. A pass followed by a
  failure that does not repeat is a "not confirmed" warning, with both reports in the job summary. Tested locally
  by forcing a failure: the three phases that failed both passes were confirmed, and a group that failed only
  the first pass was left out.

### 19 Nov 2026: M9's exit review (`docs/m9-exit-review.md`)

- **How it was checked:**
  - **CI on `e5bb167`:** 351 tests, the smokes, the cluster smoke (130) and PyIceberg's 16 checks on `serve` and
    through a node, all passed.
  - Two reviews of the code by readers who had not written it: one of conformance (AWS's API, the Iceberg spec) and
    one of security, which reproduced its findings against a server.
- **Verdict: not yet.**
  - **B1, High:** a browser form POST writes forged catalog records into a table bucket, and DeleteTable of a forged
    record purged the whole catalog.
  - **Into and out of the catalog:** log and inventory delivery write into it (B2), and a copy reads it from
    another bucket (B3).
  - **One request stalls the server:** a commit with many properties is O(n²) under the store's lock (B4), and
    8 MiB is read before authentication (B5).
  - **Metadata an Iceberg reader may refuse:** `remove-snapshots` leaves refs dangling (C1), `last-updated-ms`
    (C2), the client's field ids unchecked (C4), `.gz` (C5). The catalog's errors are sometimes in S3 Tables' shape
    (C3).
  - **Smaller:** values silently ignored (C6), and more.
  - **B6:** no policy restricts S3 Tables. That is to be recorded as not done, or built (a design question).
- **Next:** fix the findings, each with a test, if the owner agrees.

### 19 Nov 2026: M9's exit review findings closed (the owner: "Fill all findings")

- **Into and out of the catalog:**
  - No form upload into a table bucket's warehouse, and a purge empties only a UUID's prefix (B1).
  - No access logs, inventory or access point on a warehouse (B2).
  - No copy or part copy whose source is a catalog record (B3).
- **Load:** properties set and removed in n log n, at most 1,000 changes a commit, and a 1 MiB body read only for one
  of the server's keys (B4, B5).
- **Iceberg metadata as PyIceberg applies it:** remove-snapshots' refs and log, `last-updated-ms`, `-1` as the last
  added, a create's ids checked, no `.gz`, no file for an empty commit, `owner` kept, errors in Iceberg's shape
  (C1 to C11).
- **A rename's destination must be absent** on the shard when staged (B8). GetTable is routed by `tableArn` first.
- **Recorded, not built:** no `s3tables:` policies (B6), and an upgrade note for `--table-s3` buckets made before M9
  (B9).
- **Found while fixing:** CreateTable's `metadata` read camelCase names where botocore sends `source-id`,
  `field-id`, `order-id`, `null-order` and `spec-id`, so every partition field's source was 0. Fixed, and the
  PyIceberg check now compares sources.
- **The reviewers' memory points** were checked against botocore's `s3tables` model and PyIceberg 0.12.0's update code,
  since web pages could not be fetched here.
- **Checks:** 357 tests; the S3 smoke with PyIceberg's 23 checks; the cluster smoke's 132; and the SDK matrix (boto3,
  Go, JavaScript, Java, .NET), all passing.
- **Next:** the owner's word on closing M9 and accepting ADR-0083.

### 19 Nov 2026: B6 and B9 built, policies for S3 Tables (ADR-0084, proposed)

- **The owner:** "Tackle those two findings you recorded." ADR-0084 is the design.
- **Policies (B6):** table bucket policies and table policies, the six calls of AWS's model. They hold a bucket
  policy's grammar, with `s3tables:` actions and `arn:aws:s3tables:` resources.
  - **Where they are kept:** catalog objects (`.s3tables/policy`, and `.s3tables/table-policies/<id>`, so a rename
    keeps a table's). No new record.
  - **Every call is checked:** each S3 Tables and Iceberg call is authorized as `s3tables:<Call>` on its table
    bucket or table. A Deny refuses a key, the policy calls are never refused to one, and a broken policy refuses.
  - **A table's data:** an engine's S3 calls are `s3tables:GetTableData`/`PutTableData` on the table. DeleteObjects
    asks once per table, and a copy's source is checked too.
  - **Keys:** an object of a warehouse must be under a table's id, and a listing must name one table's prefix.
- **Buckets made before M9 (B9):** `serve`, and each shard of a cluster node, refuse to start when a `--table-s3`
  bucket holds a key no table bucket can. The message names the bucket and says how to move it with the release
  before M9. The scan seeks past each table, so it reads a bucket's tables, not its objects.
- **Checks:**
  - Unit tests: 361, with `tablesPolicyGrammar`, `tablesPoliciesDecide`, `tableDataKeys` and
    `tableBucketsMadeBeforeM9`.
  - The S3 smoke covers both policies' Deny, a table's data refused, a malformed policy, the lockout guard and
    Iceberg's 403, with PyIceberg's 23 checks.
  - The cluster smoke's 133 include a policy put through one node deciding a call through another.
  - **An upgrade, end to end:** the release before M9 makes `legacy--table-s3` with an object, and today's server
    refuses to start, naming it. The old release moves the object out, and the server then starts; with a real
    table bucket holding data, it restarts.
- **Next:** the owner's word on ADR-0083 and ADR-0084, and on closing M9.

### 19 Nov 2026: ADR-0083 and ADR-0084 accepted

- The owner: "I accept ADR-0083 and ADR-0084". S3 Tables and the Iceberg REST catalog, with their policies, are done:
  on `serve` and on a cluster, through PyIceberg and every SDK of the matrix, M9's exit review's findings closed.
- **Next:** the owner's word on closing M9.

### 19 Nov 2026: M9 closed

- The owner: "close M9". **M9 (S3 Tables) is closed** (ADR-0083, ADR-0084; `docs/m9-exit-review.md`). It covers:
  - the S3 Tables API (table buckets, namespaces and tables, the metadata location's compare-and-set);
  - the Iceberg REST catalog, PyIceberg end to end;
  - table bucket and table policies, over every call and a table's data;
  - all of it on `serve` and on a cluster, through the AWS CLI and every SDK of the matrix.
- **Not done, and refused:** maintenance, encryption other than the server's, tags, replication, storage classes,
  metrics, record expiration, staged creates, nested namespaces, views, credential vending and AssumeRole sessions.

### 19 Nov 2026: M10 proposed (ADR-0085)

- **The owner:** "propose M10". ADR-0085 (proposed) gives three candidates, one to be M10:
  - **A, table maintenance:** snapshot management and unreferenced file removal; compaction stays refused.
  - **B, identities:** users and identity policies, and AssumeRole in S3 Tables.
  - **C, the long tail.**
- **Recommended: A.** It finishes M9, whose tables otherwise keep every file they ever wrote.
  - Its cost is an Avro reader and an inflate decoder. PyIceberg deflates its manifests by default, and lib/std has
    no decoder (checked).
  - Whether the decoder is asked of CeeSafe or written here first is the owner's choice too.
- **Next:** the owner's choice of item.

### 19 Nov 2026: M10 is table maintenance (ADR-0086, proposed)

- **The owner:** "A, and write the decoder here first". ADR-0086 designs it, in five slices:
  1. the inflate decoder and the Avro reader;
  2. the calls and snapshot management;
  3. unreferenced file removal;
  4. the cluster;
  5. PyIceberg end to end, and the exit review.
- **Next:** slice 1.

### 19 Nov 2026: M10 slice 1, the inflate decoder and the Avro reader (ADR-0086 §4)

- **Inflate** (`src/s3/inflate.cee`): RFC 1951's stored, fixed and dynamic blocks, as zlib's `puff` decodes them,
  with an output limit. It is here until lib/std has one (G35 notes it).
  - **Tested** with zlib's own streams: empty, stored, fixed, dynamic, mixed, and several blocks.
  - **Refused:** a limit passed, a bad stored length, the reserved block type, a stream cut short, and a distance
    before the start.
- **Avro** (`src/s3/avro.cee`): object container files, the codecs `null` and `deflate`, and every type of the binary
  encoding, named types included. Each record is read into the JSON model. Another codec is refused by its name.
  - **Tested** against PyIceberg 0.12.0's own manifest list and manifest (`avro_fixtures.cee`, made from a table
    appended twice). The paths each names are read exactly. A file damaged, cut short or not Avro is refused.
- 365 tests pass.
- **Next:** slice 2, the maintenance calls and snapshot management.

### 19 Nov 2026: M10 slices 2 and 3, maintenance calls, snapshot management, unreferenced file removal (ADR-0086)

- **The calls:** Put/Get of a table bucket's and a table's maintenance configurations, and
  GetTableMaintenanceJobStatus.
  - They are checked as AWS's model has them: positive settings, `enabled` or `disabled`, and NotImplemented for
    compaction enabled. AWS's defaults apply until a type is set.
  - Each is authorized under ADR-0084's policies, and kept as catalog objects (`.s3tables/maintenance/…`).
  - DeleteTable removes a table's.
- **Snapshot management:** expires snapshots past `maxSnapshotAgeHours`, keeping refs' heads and the newest of main's
  ancestry. It commits through the catalog's own path, `swapMetadata`, factored out of the Iceberg commit. A lost race
  waits for the next pass.
- **Unreferenced file removal:**
  - **What is referenced:** the metadata file, its log, statistics files, every snapshot's manifest list and its
    manifests (read with slice 1's Avro reader), and their data and delete files.
  - **The sweep:** other warehouse files are noted, and deleted once noted for `unreferencedDays + nonCurrentDays`. A
    note goes when its file is referenced again.
  - **Holding the store:** for each manifest read, and for the sweep.
  - **A manifest it cannot read** ends the run Failed, with nothing deleted.
- **The pass:** every hour of a day, beside inventory (`serve --tables-day-seconds` for tests).
- **Tests:**
  - Unit: `maintenanceConfigurations`, `snapshotsThatExpire`, `snapshotManagementCommits` and
    `unreferencedFilesNotedThenDeleted`; 369 in all.
  - **`tools/maintenance_check.py`** (14 checks), run by the S3 smoke on a server whose day is 12 s: a PyIceberg table
    appended six times is expired to its two newest snapshots, and an orphan and the expired manifest lists are
    removed. Every row reads back, and it takes appends after.
- **Next:** slice 4, the cluster.

### 19 Nov 2026: M10 slice 4, table maintenance on a cluster (ADR-0086 §5)

- **How it runs:** every hour of a day, a node lists the tables of each shard it leads. It asks for each table's two
  jobs through its own front, signed for `s3tables` (`tablesMaintenanceClusterForever`). Each job is then a shard's
  write, behind its gate and committed by Raft, as inventory's are on a cluster.
- **The call:** `POST /tables/<arn>/<ns>/<name>/maintenance-run?type=<job>`, CosmoStore's own. It is authorized as
  `s3tables:PutTableMaintenanceConfiguration`, runs one job a request, and is taken on `serve` too.
- **Per-job status:** each job's status is now an object of its own, since a shard's request does not read its own
  writes.
- **`node --tables-day-seconds`**, as on `serve`.
- **Tests:** the cluster smoke's 134 pass, with nodes on a 24 s day. They include the maintenance check through
  node 2 (15), whose DeleteTableBucket retries the ConflictException of leftovers, as ADR-0083 §7 has it.
- **Next:** slice 5, the SDK matrix and M10's exit review.

### 19 Nov 2026: M10 slice 5, maintenance in the SDK matrix

- **Each SDK's check:** Go, JavaScript, Java and .NET each put a table bucket's maintenance configuration and read it
  back. Each reads a table's (compaction off) and its job status. boto3 does all of maintenance through
  `maintenance_check.py`. All five pass.
- **Next:** M10's exit review.

### 19 Nov 2026: M10's exit review (`docs/m10-exit-review.md`)

- **How it was checked:** the tests, both smokes and the SDK matrix pass. Two reviews by readers who had not written
  the code: safety (reproducing three findings) and conformance (AWS's model, Avro 1.11, RFC 1951).
- **Verdict: not yet.**
  - **A1:** a reference unreferenced removal cannot place is skipped, and its files are then deleted: `s3a://`,
    `s3n://`, v1 inline manifests.
  - **B1:** a crafted manifest's count panics the server every hourly pass.
  - **Also:** other tables' paths (A2), encoded paths (A3), expiry's walk and other branches (A4, A5), and the
    decoder's memory (B2).
- **Until A1 and B1 are fixed,** unreferenced removal (enabled by default) should not run on real tables.
- **Next:** fix the findings, if the owner agrees.

### 19 Nov 2026: M10's exit review findings closed (the owner: "continue")

- **Unreferenced removal (A1 to A3, A6):** every reference is placed.
  - `s3://`, `s3a://` and `s3n://` of the hidden bucket read the same, and another bucket's are passed by.
  - Anything else ends the run Failed with nothing deleted: another scheme, a key of no table, metadata of format 3,
    or a snapshot with neither a manifest list nor format 1's inline manifests, which are read.
  - A reference into another table pins it, and a pinned table deletes nothing.
  - A key matching a reference percent-decoded, or with `//` collapsed, is kept.
  - The sweep does nothing if the table changed during the run.
- **Expiry (A4, A5):** every branch keeps its newest `minSnapshotsToKeep`, and those within its age, with the ref's
  own settings. The ancestry walk has a visited set of its own. `remove-snapshots` drops statistics entries (C1).
- **The Avro reader (B1, B2, C5):** i64's least is refused before it is negated, and counts are bounded by the bytes
  left. A file decodes to 64 MiB at most. Also inherited namespaces, a wrapped type, and 32-bit ints.
- **The rest:** failures are recorded, compaction's stored value echoed, and the codec named.
- **Checks:** 373 tests; the S3 smoke and the cluster smoke (134), with the maintenance check on both.
- **CI on `7ec6a93`:** the perf gate failed, on large writes at c32, with the runner's noise at 2.00. The next commit,
  `0a35dc0`, has the same server code (slice 5 changed only the SDK checks), and its perf gate passed, as did
  `22bdd44`'s. So that was the runner's noise.
- **Next:** the owner's word on ADR-0086 and on closing M10.

### 19 Nov 2026: ADR-0086 accepted; M10 closed

- **The owner:** "Accept and close". CI on `cd20007` passed: 373 tests, the smokes with the maintenance check and
  PyIceberg, and the perf gate. All five SDKs pass on the fixed build.
- **M10 (table maintenance) is closed** (ADR-0085, ADR-0086; `docs/m10-exit-review.md`). It covers:
  - the maintenance calls and job status;
  - snapshot management, as Iceberg's own expiry keeps;
  - unreferenced file removal that fails safe;
  - all of it on `serve` and on a cluster, through PyIceberg and every SDK of the matrix.
- **Not done, and refused:** compaction, and refs' `max-ref-age-ms`.
- **Next:** M11, when the owner proposes one; ADR-0085's item B (identities) was named the next candidate.

### 19 Nov 2026: M11 proposed (ADR-0087)

- **The owner:** "propose M11". ADR-0087 (proposed) gives three candidates, one to be M11:
  - **A, identities:** users, their keys and identity policies, decided with resource policies as IAM does in one
    account. AssumeRole in S3 Tables.
  - **B, the long tail:** lifecycle transitions, ListMultipartUploads' `delimiter`, SHA-1, the rest.
  - **C, compaction for S3 Tables:** Parquet.
- **Recommended: A.** Every deployment past one application needs a key that can do less than everything.
  - It stands on roles' identity policies, ADR-0043's and ADR-0084's resource policies, and ADR-0050's reloaded
    file.
  - An existing deployment changes nothing until it writes a users file.
- **For A, the owner's choice too:** a users file (recommended), users in the credentials file, or the IAM API.
- **Next:** the owner's choice.

### 19 Nov 2026: M11 is identities (ADR-0088, proposed)

- **The owner:** "A." Where users live was left open, so ADR-0088 takes ADR-0087's recommendation, a users file.
- **ADR-0088 designs it,** in four slices:
  1. the users file and S3's decision;
  2. S3 Tables and STS;
  3. the cluster;
  4. the SDK matrix and the exit review.
- **Next:** slice 1.

### 19 Nov 2026: M11 slice 1, users and S3's decision (ADR-0088 §1 to §3)

- **The users file** (`serve --users-file`): each user's name, its keys and its identity policy.
  - It is reloaded with the credentials file whenever either changes. A file that does not read, or names a key the
    credentials do not have, changes nothing and is reported.
  - Each key's place in the credential set carries its user and parsed policy. A key no user names is the
    account's, as before.
- **The decision for a user, as IAM's in one account:**
  - A Deny in its identity policy, or in the bucket's or access point's policy, refuses.
  - Otherwise an Allow in either allows: the resource policy's by the user's ARN, its key or `*`. Otherwise the
    request is refused.
  - **Calls with no resource policy** are decided by the identity policy alone: ListBuckets, CreateBucket,
    ListDirectoryBuckets, and S3 Control's access point calls (each its own action, the access point
    `s3ap:<name>`).
  - **The policy calls** are a user's only by an Allow. The stats endpoint and admin API refuse users.
- **The identity grammar** (roles' and users'):
  - Actions of `s3:`, `s3express:`, `s3tables:` and `sts:`.
  - Resources kept as `s3:`, `s3ap:`, `s3tables:` or `iam:` and their tail, any region and account.
  - Resource policies name users (`arn:aws:iam::<account>:user/<name>`).
- **Tests:** `usersFileAndKeys`, `identityPoliciesOfEveryService` and `resourcePoliciesNameUsers`; 376 in all.
  - **The S3 smoke's users server**, 12 checks: a reader refused another bucket, writes, ListBuckets, CreateBucket
    and policy calls. A bucket's Allow lets it write an inbox, and its Deny beats a user's Allow. The account's key
    is not narrowed, and a reload of the users file takes effect.
- **Next:** slice 2, S3 Tables and STS.

### 19 Nov 2026: M11 slice 2, S3 Tables and STS for users and roles (ADR-0088 §2, §4)

- **S3 Tables:** each call is decided with the requester's identity policies too.
  - A user needs its identity policy's Allow, or a table bucket's or table's naming it. A Deny in either refuses.
  - A role's session needs its role's and its session's Allow, so S3 Tables now takes AssumeRole sessions.
  - CreateTableBucket and ListTableBuckets are decided by the identity alone.
  - An engine's S3 calls into a warehouse, by a user or a role's session, are decided as the table's data
    (`s3tables:GetTableData`/`PutTableData`), not as S3's on a hidden bucket.
- **AssumeRole** by a user needs `sts:AssumeRole` on the role's ARN. The account's keys may assume any, and a user's
  GetSessionToken session is the user's.
- **Copies:** the checks that run on a worker thread take copies of the identity policies (`clonePolicy`).
- **Tests:** `tablesDecideUsersAndRoles`; 377 in all.
  - **The smoke's users server**, 8 more checks: an analyst reads table bucket `lake`, its table and its data, and is
    refused writes, drops and ListTableBuckets. In the role it assumes, reads are taken and drops refused. Another
    user may not assume the role.
- **Next:** slice 3, the cluster.

### 19 Nov 2026: M11 slice 3, users on a cluster (ADR-0088 §5)

- **`node --users-file`:** every node takes the same file, read with its credentials at start. The node does not
  reload its credentials yet, so neither does it reload its users.
- **Each shard decides** a user's request as `serve` does. The front's merged calls are decided by the shards that
  answer them.
- **Tests:** the cluster smoke's 140 pass. A user reads through node 2, and is refused writes through node 3,
  another bucket through node 1, and ListBuckets merged on the front. Another reads a table through node 3 and
  drops none through node 2.
- **CI on `6771a13`:** the perf gate failed on large writes at c32, confirmed in both passes, with the runner's noise
  at 2.00. A re-run of the same job on the same code passed, so that was the runner's noise.
- **Next:** slice 4, the SDK matrix and M11's exit review.

### 19 Nov 2026: M11 slice 4, users in the SDK matrix

- **The matrix's server** has a user, `sdkuser`, that may read the objects of `sdk-*-users` buckets.
- **Each SDK's check** (boto3, Go, JavaScript, Java, .NET): the user's key reads such an object, and its writes and
  ListBuckets are AccessDenied. All five pass.
- **Next:** M11's exit review.

### 19 Nov 2026: M11's exit review (`docs/m11-exit-review.md`)

- **How it was checked:** two reviews by readers who had not written the code, security (six findings reproduced
  against a server) and conformance with IAM.
- **Verdict: not yet.**
  - **A1:** a user writes into any bucket through its own bucket's replication. Also inventory and logging.
  - **A2:** deleting a user's line makes its keys the account's.
  - **A3:** a revocation is blocked while the users file names the key.
  - **A4:** ACL, tagging and object lock headers need only PutObject.
  - **A5:** an `s3express` ARN grants every bucket.
  - **A6:** access point policies, a Deny ignored and an Allow ignored.
  - **B:** directory buckets' `s3express:` actions, user principals never checked, and smaller points.
- **For the owner:** A2 and A3 need a rule. Either (a) the users file names the account's keys and any other key is
  refused, or (b) a reload that leaves a user's key unnamed is refused, and a removed key revoked.
- **Next:** the owner's rule, then the fixes.

### 19 Nov 2026: M11's exit review findings fixed (`docs/m11-exit-review.md`)

- **The owner's rule, (a):** the users file names the account's keys (`account` lines), and with a users file a key
  named neither way is refused. ADR-0088 §1 is amended.
- **Fixed:** A1 to A6, and B1, B2, B5 and B6, each with a test or a smoke check. B3 and B4 (Low) stay open.
- **Tests:** 378 unit tests, the S3 smoke, the cluster smoke (138) and the SDK matrix pass.
- **Next:** a second reading of the fixes by a fresh reviewer, then the owner's decisions on ADR-0088 and M11.

### 19 Nov 2026: M11, a second reading of the fixes

- **Seven more findings, all fixed:**
  - a destination is checked on its prefix, against every Deny that could reach it;
  - users and sessions may not replicate to another endpoint, and no one into a warehouse;
  - role sessions are decided on the access point's ARN too;
  - copied tags need the tagging actions;
  - a key revoked mid-request is never the account's;
  - a stored policy naming another account's user still reads.
- **Tests:** 379 unit tests; the S3 smoke, the cluster smoke (138) and the SDK matrix pass.
- **Next:** the owner's decisions on ADR-0088 and M11.

### 19 Nov 2026: M11, the Lows

- **User ids** (the owner's choice): `<name>:<id>` in the users file, and resource policies store the ids of the
  users they name, so a user made again with an old name has none of the old one's grants.
- **B3 and B4** are recorded as decided, unchanged, with the reasoning in `docs/m11-exit-review.md`.
- **Tests:** 380 unit tests; the S3 smoke, the cluster smoke (138) and the SDK matrix pass.

### 19 Nov 2026: M11 closed, ADR-0088 accepted

- **The owner:** "Accept and close", after both readings' findings were fixed and the Lows fixed or decided.
- **At closing (`490dd81`):** 380 unit tests, the S3 smoke, the cluster smoke (138) and the SDK matrix (boto3, Go,
  JavaScript, Java, .NET) pass.
- **Upgrade notes:**
  - a users file needs an `account` line naming the account's keys, and an id on every user line
    (`<name>:<id>`);
  - replication, inventory and logging configurations users set before the fixes should be put again.
- **Next:** M12, when the owner asks for one.

### 19 Nov 2026: M12 proposed (ADR-0089)

- **The owner:** "Continue to M12". ADR-0089 (proposed) gives three candidates, one to be M12:
  - **A, the long tail** (recommended): storage classes, lifecycle transitions, ListMultipartUploads' `delimiter`,
    SHA-1 checksums, a POST form's object lock fields, SSE-KMS's encryption context.
  - **B, configurations decided at delivery:** replication, inventory and logging writes authorized as whoever put
    them, at each write.
  - **C, compaction for S3 Tables.**
- **Found while writing it:** `x-amz-storage-class` on a general purpose bucket is accepted and dropped
  (`GLACIER` answers 200). ADR-0089 asks to fix it now, whatever M12 is.
- **CI:** `2a7fd1a`'s check failed in the S3 smoke's webhook retry section, which passed locally on the same code;
  `490dd81` and `e0fb06c` were still running.
- **Next:** the owner's choice.

### 19 Nov 2026: M12 is the long tail (ADR-0090, proposed)

- **The owner:** "A: the long tail", with GLACIER and DEEP_ARCHIVE refused.
- **ADR-0090 designs it, in five slices:**
  1. storage classes, recorded or refused, never dropped;
  2. lifecycle transitions;
  3. ListMultipartUploads' `delimiter` and SHA-1 checksums;
  4. a POST form's object lock fields and SSE-KMS's encryption context;
  5. the cluster, the SDK matrix and the exit review.
- **Next:** slice 1.

### 19 Nov 2026: M12 slice 1, storage classes (ADR-0090 §1)

- **Taken:** `x-amz-storage-class` on PutObject, CopyObject, CreateMultipartUpload and a POST form. It is recorded on
  the object (a stored field, absent for STANDARD), with its bytes where they are.
- **Answered:** in HeadObject and GetObject, ListObjects, ListObjectVersions, ListParts, ListMultipartUploads,
  GetObjectAttributes, inventory reports and replicas.
- **Refused (InvalidStorageClass):** GLACIER, DEEP_ARCHIVE and unknown names. Until now every class was taken and
  dropped.
- **A copy** takes the request's class, never the source's. A copy onto itself may change only its class.
- **Tests:** the S3 smoke's nine storage class checks; 380 unit tests, both smokes and the SDK matrix pass.

### 19 Nov 2026: M12 slice 2, lifecycle transitions (ADR-0090 §2)

- **Taken:** `Transition` (by days or date) and `NoncurrentVersionTransition` (by days, keeping
  `NewerNoncurrentVersions`), to STANDARD_IA, INTELLIGENT_TIERING, ONEZONE_IA, GLACIER_IR and REDUCED_REDUNDANCY;
  up to 8 of each a rule.
- **Refused:**
  - GLACIER and DEEP_ARCHIVE (InvalidStorageClass);
  - an infrequent access class before 30 days (InvalidArgument), as on S3.
- **The lifecycle pass** moves a version along S3's waterfall, never back. Of the transitions due, the furthest
  wins.
- **The change is one SetTags record** of a new format (4) that sets the class, so it is kept through recovery and
  checkpoints. The bytes do not move.
- **The rules' stored format** gains a version 3, written only when a rule has a transition.
- **Tests:**
  - `lifecycleTransitionsRecordClasses`;
  - `transitionCrashAtEveryByteIsConsistent`, the fault sweep for the new record format;
  - four S3 smoke checks;
  - 382 unit tests.

### 19 Nov 2026: M12 slice 3, ListMultipartUploads' delimiter and SHA-1 checksums (ADR-0090 §3, §4)

- **`delimiter`:**
  - keys are rolled up into CommonPrefixes, each once and in key order;
  - a common prefix counts toward `max-uploads` and is the next key marker;
  - a key marker that is one skips its keys.
- **SHA-1:**
  - `x-amz-checksum-sha1` and `x-amz-checksum-algorithm: SHA1` are taken, checked, stored and returned;
  - they are COMPOSITE for multipart, as SHA-256 is;
  - checksum code 5 is new in the version extras format.
- **SHA-1 is in plain CeeSafe** (`src/storage/checksums/sha1.cee`), as CRC-32 is. lib/std has none, even in 0.77.1
  (CEESAFE_GAPS G26, updated). It is checked against FIPS 180's four vectors.
- **Tests:** `uploadsGroupedByDelimiter`, `sha1MatchesFips180`, and four S3 smoke checks.
- **Checked together with slice 2:**
  - 384 unit tests;
  - the S3 smoke and the cluster smoke (138);
  - the SDK matrix, where boto3's and JavaScript's SHA-1 checks now expect it taken.
- **One combined run** (tests beside both smokes and five SDKs at once) had 3 unit tests fail that pass alone. That
  was contention on this machine, recorded here rather than dismissed.

### 19 Nov 2026: M12 slice 4, a POST form's object lock fields and SSE-KMS's encryption context (ADR-0090 §5, §6)

- **POST:**
  - the form's `x-amz-object-lock-mode`, `-retain-until-date` and `-legal-hold` act as PutObject's headers;
  - they are InvalidRequest in a bucket without object lock;
  - they are authorized as `s3:PutObjectRetention` and `s3:PutObjectLegalHold`.
- **SSE-KMS:**
  - `x-amz-server-side-encryption-context` is taken: base64 of a JSON object of strings, at most 4 KB;
  - it is kept in the envelope's sixth piece and authenticated by the data key's seal;
  - it is returned on PutObject, CopyObject and CreateMultipartUpload, as botocore models it, and on Head and Get.
- **Unchanged:** an envelope without a context keeps its five pieces, so older objects read as before.
- **Not added:** S3's default `aws:s3:arn` pair (ADR-0090 §6).
- **Tests:**
  - `kmsEncryptionContextIsSealed` (a changed context does not open);
  - `sseRequestFields` updated;
  - three S3 smoke checks;
  - boto3's POST form under a legal hold;
  - 385 unit tests, the cluster smoke (138) and the SDK matrix.

### 19 Nov 2026: M12 slice 5, the cluster and the SDK matrix (ADR-0090 §7)

- **The cluster smoke:** a long tail section, each item put through one node and read through another (storage
  class, listing, archive refused, transitions, the uploads' delimiter, SHA-1). 144 checks pass.
- **Not on a cluster:** SSE-KMS's context, since a node has no KMS key file (before M12).
- **The SDK matrix:** every SDK (boto3, Go, JavaScript, Java, .NET) records STANDARD_IA and is refused GLACIER.
  boto3 and JavaScript also put SHA-1 checksums, and boto3 a POST form under a legal hold. All pass.
- **Next:** M12's exit review.

### 19 Nov 2026: M12's exit review (`docs/m12-exit-review.md`)

- **Verdict: not yet.**
  - **A1:** one object near the metadata limit stops lifecycle for the whole server (reproduced).
  - **A3:** lifecycle never runs on a cluster, so a cluster takes transitions and expirations it never applies.
  - **Smaller:**
    - directory buckets take transitions;
    - transitions sync one by one;
    - the 128 KB transition floor and its header are ignored;
    - a POST form's checksum fields are ignored;
    - REDUCED_REDUNDANCY is taken as a transition target;
    - S3's checks between transitions are missing.
- **For the owner:** A3. Either (a) lifecycle on each shard's leader, or (b) refused on a cluster until then.
- **Next:** the fixes.

### 19 Nov 2026: M12's exit review findings fixed

- **The owner's choice for A3:** lifecycle on each shard's leader, as a write. Expirations run on a cluster now too;
  they did not before M12.
- **Fixed:**
  - A1, one version no longer stops lifecycle;
  - A2, A4, A5 (the 128 KB floor and its header) and A6 (a POST form's checksum fields);
  - B1, B2, B4, B5 and B7;
  - C1 confirmed (no downgrade past M12), C2 and C3.
- **Unchanged and recorded:** B3, B6, and SHA-1's speed.
- **Tests:** 387 unit tests, the S3 smoke, the cluster smoke (146, lifecycle applied on a cluster) and the SDK matrix pass.

### 19 Nov 2026: M12, the Lows

- **The owner:** "Fix the Lows first".
- **B3:** replication's `Destination/StorageClass` is taken (rules v2), and every delivery records the replica with
  it.
- **B6:** a write's class is checked after its bucket (NoSuchBucket first).
- **SHA-1:** whole blocks straight from the input.
- **Tests:** 387 unit tests, the S3 smoke, the cluster smoke (146) and the SDK matrix pass.

### 19 Nov 2026: M12 closed, ADR-0090 accepted

- **The owner:** "Accept and close", after the exit review's findings and its Lows were fixed.
- **At closing (`55c9c15`):** 387 unit tests, the S3 smoke, the cluster smoke (146) and the SDK matrix (boto3, Go,
  JavaScript, Java, .NET) pass.
- **No downgrade past M12:** a binary before it stops at SetTags format 4, lifecycle rules v3 and v4, replication
  rules v2 or checksum code 5 ("bad record meta").
- **Next:** M13, when the owner asks for one. ADR-0089's B (configurations decided at delivery) is the next
  candidate.

### 19 Nov 2026: M13 proposed (ADR-0091)

- **The owner:** "propose M13". ADR-0091 (proposed) gives three candidates, one to be M13:
  - **A, a cluster as `serve`** (recommended): nodes reload their credentials and users files, so a revocation needs
    no restart, and `node --kms-key-file` serves SSE-KMS.
  - **B, configurations decided at delivery:** replication, inventory and logging writes authorized as whoever put
    them.
  - **C, compaction for S3 Tables.**
- **Why A first:** revoking a key on a cluster takes every node's restart today.
- **Next:** the owner's choice.

### 19 Nov 2026: M13 is a cluster as `serve` (ADR-0092, proposed)

- **The owner:** "A. - Each node watches its own files".
- **Found while designing it:** a cluster serves no SSE-S3 either. A node has no SSE keys, so SSE-S3 is refused,
  and `docs/compatibility.md` did not say so.
- **ADR-0092's slices:** reloads on every node; `node --sse-key-file` and `--kms-key-file`; the exit review.
- **Next:** slice 1.
