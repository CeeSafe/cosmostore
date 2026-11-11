# CosmoStore

An object storage server written in [CeeSafe](https://ceesafe.github.io/CeeSafe/), a memory-safe systems language
that compiles to C. The goal is an Amazon S3-compatible store that is especially efficient for small objects without
giving up large-object throughput or crash correctness.

**Status: early.** The single-node storage engine works and is crash-tested: the journal, large-object extents,
checkpoints, compaction, the space reserve and `fsck`. It is used as an embedded library and through a small command
line. **There is no HTTP or S3 API yet**; that is milestone M3 in the [roadmap](ROADMAP.md).

The code is pure CeeSafe, with no C and no `unsafe` blocks.

- [Features](#features)
- [How it is built](#how-it-is-built)
- [Building](#building)
- [Command line](#command-line)
- [Using the engine](#using-the-engine)
- [Configuration](#configuration)
- [Testing](#testing)
- [Status and roadmap](#status-and-roadmap)
- [License](#license)

---

## Features

### One journal, one order ([ADR-0001](docs/adr/0001-unified-journal-record-format.md))

- **A single write-ahead journal per shard** holds every change: inline PUTs, extent PUTs, deletes, bucket changes,
  relocations and checkpoint markers. There is one LSN order and one group-commit sync, so a small PUT and a large
  PUT to the same key can never be replayed out of order.
- **Small objects live in the journal itself.** Objects up to 128 KiB are stored inline in their record; sealed
  segments are the packs, and there is no second copy.
- **Versioned record format:** a format version, record types, a checksum algorithm id, and slots reserved for an
  encryption envelope and a future consensus `(term, index)`, so those features need no on-disk migration.
- **Group commit:** callers stage several PUTs and commit them with one sync.
- **Recovery** truncates a torn tail, but tells a torn tail apart from corruption in an acknowledged record and
  refuses to open on the latter. Replaying twice gives an identical state.
- **Fail-stop:** after a journal I/O error, every mutation is refused rather than acknowledged and lost on restart.

### Large objects ([ADR-0003](docs/adr/0003-extents-for-large-objects.md))

- One streaming write path (`ObjectWriter`): inline up to 128 KiB, otherwise 64 MiB extent files, each synced (and
  its directory) **before** the journal record that points at it is appended. Metadata never points at data that
  is not durable.
- Byte-range reads across extents, with a CRC check on whole-extent reads.
- Extents of overwritten or deleted objects are removed once the retiring record is durable; orphans left by a
  crash are swept at open; an abandoned writer removes its own extents.
- PUTs are limited to 5 GiB, as in S3.

### Object model

- Buckets with S3's naming rules; PUT, GET, HEAD and DELETE; range reads.
- **Versions from day one:** an unversioned bucket uses the `null` version, so S3 versioning can be enabled later
  without migration.
- **Conditional PUT:** `IfAbsent` (`If-None-Match: *`) and `IfGeneration` (`If-Match` on the generation).
- **ListObjectsV2 semantics:** prefix, delimiter (common prefixes), start-after and pagination.
- MD5 (the S3 ETag) and CRC32C computed while streaming.

### Checkpoints and compaction ([ADR-0005](docs/adr/0005-checkpoints-and-compaction.md))

- **Checkpoints** publish the whole index after LSN *L* (temp file, sync, rename, directory sync). Recovery loads the
  newest one and replays only later segments: 1M objects recover in about 0.5 s instead of 2.5 s.
- **Compaction** rewrites the live records of sparse segments (under 50% live by default) as `Relocate` records,
  which keep the generation, then deletes the old segments once the copies are durable.
- **Per-segment live-byte accounting** finds compaction candidates without scanning the index.
- `maintain()` runs both on a schedule set by the configuration.

### Space safety and fsck ([ADR-0006](docs/adr/0006-space-reserve-and-fsck.md))

- **Space reserve:** with a configured capacity, a write that would eat into the reserve is refused with
  `InsufficientStorage` before any byte is written. Deletes, checkpoints and compaction never need admission, so a
  full store can always free itself.
- **`fsck`** reads every live object and checks record CRCs, extent CRCs, missing or short extents, size and MD5. It
  reports problems and changes nothing (20,000 objects in about 0.34 s).

### Durability on every platform it runs on ([ADR-0002](docs/adr/0002-durability-primitives.md))

- Positional reads and writes, `fdatasync` on Linux and **`F_FULLFSYNC`** on macOS (plain `fsync` does not reach the
  disk there), directory syncs after creating or renaming files, and atomic renames.
- Windows is not supported yet; its semantics will be specified before it is.

### Fault injection and a crash model ([ADR-0004](docs/adr/0004-fault-injection-and-crash-model.md))

- Every `DurableFile` and `Fs` operation has a failpoint that fails once, sticks, or tears a write.
- A crash model keeps only synced bytes and only directory entries whose directory was synced.
- Sweeps fail every I/O operation in turn across journal, store, checkpoint and compaction workloads, and check each
  key against a model of what it must or may hold. Deliberately broken builds (a missing sync, a missing directory
  sync, wrong rename order) fail these sweeps.

---

## How it is built

| Path | What it is |
|---|---|
| `src/main.cee` | The command line: `bench`, `fsck`, `soak`. |
| `src/soak.cee` | The long churn test run by `tools/soak.sh`. |
| `src/storage/io/` | `DurableFile` and `Fs` (`durable.cee`), and the fault-injecting layer and crash model (`faults.cee`). |
| `src/storage/checksums/` | CRC32C and MD5 wrappers over CeeSafe's standard library, with RFC test vectors. |
| `src/storage/journal/` | The record codec, segments, rotation, group commit and recovery. |
| `src/storage/extent/` | Extent files, the manifest codec, `ObjectWriter` and `ExtentReader`. |
| `src/metadata/model.cee` | The version-first object model, its codecs, and S3 bucket-name rules. |
| `src/store/` | `ObjectStore` (buckets, objects, listing, space, verify), checkpoints and compaction, and their tests. |
| `docs/adr/` | The design decisions, ADR-0001 to ADR-0006. |
| `tools/soak.sh` | Runs `cosmostore soak` for hours, killing it with SIGKILL every 1 to 15 minutes. |

**Documents:**
- [CeeSafe_Object_Storage_Architecture.md](CeeSafe_Object_Storage_Architecture.md): the original research and
  architecture (four planes, packed small objects, replication and erasure coding, the compatibility tiers).
- [ROADMAP.md](ROADMAP.md): a review of that architecture, the milestones M0 to M7 with exit criteria, and a dated
  progress log with benchmarks.
- [CEESAFE_GAPS.md](CEESAFE_GAPS.md): what CeeSafe lacked for a storage engine (G1 to G25) and which gaps are closed.

There are no dependencies beyond CeeSafe's standard library.

---

## Building

You need `ceesafec` 0.36.0 or later (`ceesafe.toml` requires it) and a C compiler.

```sh
git clone https://github.com/CeeSafe/cosmostore.git
cd cosmostore
ceesafec check
ceesafec build -o out/cosmostore --cflag -O2
```

It is developed on macOS and tested on Linux (Debian 12, x86_64).

---

## Command line

```text
cosmostore bench <dir> <objects> <size-bytes> <batch>
cosmostore fsck  <dir>
cosmostore soak  <dir> <seconds> <keys> <capacity-bytes>
```

- **`bench`** writes `<objects>` objects of `<size-bytes>` each into a bucket named `bench`, committing `<batch>`
  per sync (1 means one sync per PUT). It then reopens the store, which runs recovery, and reads back and verifies
  every byte. It prints PUT, recovery and GET rates.

  ```sh
  out/cosmostore bench /tmp/cs-bench 100000 1024 256     # 100k x 1 KiB, 256 per sync
  out/cosmostore bench /tmp/cs-large 8 134217728 1       # 8 x 128 MiB
  ```

- **`fsck`** opens the store and verifies every live object (see [Space safety and fsck](#space-safety-and-fsck-adr-0006)).
  It exits with status 1 if anything is wrong.

- **`soak`** is the churn test: overwrites, deletes and verified reads against `<keys>` keys under a capacity,
  with `maintain` on its schedule. Each start rebuilds its model from an intent/ack log in `<dir>` and checks every
  key against the store before going on. Run it through `tools/soak.sh`, which kills and restarts it:

  ```sh
  tools/soak.sh out/cosmostore /data/soak 24 5000 1200000000    # 24 hours; output in /data/soak.out
  ```

---

## Using the engine

There is no network API yet; the store is used in-process. A sketch of the API in `src/store/object_store.cee`:

```cee
var store = ObjectStore.open("/var/lib/cosmostore", StoreConfig.defaults())?;
store.createBucket("photos")?;

// One PUT, synced before it returns
store.putObject("photos", "2026/cat.jpg", "image/jpeg", bytes, PutCondition.None)?;

// Only if the key does not exist yet
store.putObject("photos", "2026/dog.jpg", "image/jpeg", other, PutCondition.IfAbsent)?;

let info = store.headObject("photos", "2026/cat.jpg")?;
let data = store.getObject("photos", "2026/cat.jpg")?;

// ListObjectsV2: prefix, delimiter, start-after, start-after-is-a-prefix, max keys
let page = store.listObjects("photos", "2026/", "/", start, false, 1000)?;

store.deleteObject("photos", "2026/cat.jpg")?;

// Checkpoint and compact when due
store.maintain()?;
```

Other entry points:
- **group commit:** `stagePut` / `stageObject`, then `commitStaged` (one sync for the batch);
- **streaming large objects:** `newWriter` → `putFinished`, and `openReader` / `getObjectRange` for reads;
- **checks and numbers:** `verify`, `usedBytes`, `objectCount`, `segmentUsage`, `journalSyncs`.

---

## Configuration

`StoreConfig.defaults()`:

| Field | Default | Meaning |
|---|---|---|
| `inlineMaxBytes` | 128 KiB | Objects up to this size are stored inline in the journal. |
| `extentMaxBytes` | 64 MiB | The largest extent file. |
| `maxObjectBytes` | 5 GiB | The largest object one PUT may store. |
| `checkpointEveryBytes` | 64 MiB | `maintain` checkpoints after this many journal bytes (0: never). |
| `compactBelowLivePercent` | 50 | Compact a covered segment whose live bytes are below this percentage. |
| `compactMaxCopyBytes` | 64 MiB | The most live bytes one `compact` call copies. |
| `capacityBytes` | 0 (no limit) | The most the store may occupy. Set it below the volume's free space: CeeSafe has no free-space query yet (CEESAFE_GAPS G24). |
| `reserveBytes` | 256 MiB | Kept free below `capacityBytes` for deletes, checkpoints and compaction. |
| `journal.segmentTargetBytes` | 128 MiB | A segment is sealed and a new one started at this size. |
| `journal.maxBatchBytes` | 32 MiB | The largest group-commit batch. |

---

## Testing

```sh
ceesafec test                 # unit, crash and fault-injection tests (about 40 s)
ceesafec test --sweep alloc   # the same tests, failing each allocation in turn
ceesafec fmt --check
```

The tests include:
- the record codec against every bit flip and every torn prefix;
- recovery after truncating the journal at every byte, for the journal and for the whole store;
- the fault sweeps of [ADR-0004](docs/adr/0004-fault-injection-and-crash-model.md), each operation failed once,
  sticky or torn, with the crash model;
- large objects: boundaries, ranges, reaping, orphans, abandoned writers and corruption;
- checkpoints, compaction and an 80-round churn;
- the space reserve and `fsck` against flipped bits and missing extents.

The 24-hour soak (`tools/soak.sh`, above) is the exit test for milestone M2.

---

## Status and roadmap

**Benchmarks** from the development laptop (macOS, SSD, one thread, `F_FULLFSYNC`; details in the ROADMAP log):

| Workload | PUT | GET + verify |
|---|---|---|
| 100k × 1 KiB, 256 per sync | 32,916/s | 452k/s |
| 2,000 × 1 MiB, 16 per sync | 70 MiB/s | 420 MiB/s |
| 8 × 128 MiB | 161 MiB/s | 548 MiB/s |

**Done:** M0's design records and durability layer, M1's single-node storage core, and most of M2 (checkpoints,
compaction, the space reserve, `fsck`).

**Next:**
- finish M2: the 24-hour soak and reaping that waits for in-flight readers;
- M3, the first alpha: HTTP, SigV4 (including aws-chunked bodies and trailing checksums), buckets, objects,
  ListObjects, multipart uploads, and a CI matrix of AWS CLI, boto3 and other SDKs;
- M4 to M7: performance hardening, production features (versioning, lifecycle, policies, encryption, Object Lock),
  a Raft-based cluster, and advanced S3 features.

**Known limits:**
- one thread; concurrent group commit waits on async file I/O in CeeSafe (CEESAFE_GAPS G6);
- the index is an in-memory map, and LIST costs O(objects) (G8);
- medium objects (128 KiB to a few MiB) are bound by syncs, about 14 ms per PUT on macOS;
- one file descriptor per sealed segment, and each checkpoint rewrites the whole index.

## License

CosmoStore is licensed under the GNU General Public License, version 2 only ([COPYING](COPYING)).
