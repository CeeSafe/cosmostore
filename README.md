# CosmoStore

An object storage server written in [CeeSafe](https://ceesafe.github.io/CeeSafe/), a memory-safe systems language
that compiles to C. The goal is an Amazon S3-compatible store that is especially efficient for small objects without
giving up large-object throughput or crash correctness.

**Status: a single-node alpha.** `cosmostore serve` speaks the S3 API over HTTP/1.1 and TLS, on a crash-tested
storage engine (journal, large-object extents, checkpoints, compaction, the space reserve and `fsck`). The AWS CLI,
rclone, the boto3, Go, JavaScript, Java and .NET SDKs and a subset of 252 Ceph s3-tests pass against it
([compatibility](docs/compatibility.md)). Milestones M0 to M3 of the [roadmap](ROADMAP.md) are done; M4, performance,
is under way. There is no replication or clustering yet, and no versioning, policies or ACLs.

CosmoStore's own code is pure CeeSafe, with no C and no `unsafe` blocks. The one C below it is OpenSSL 3, for TLS,
through CeeSafe.Web's `web_tls` ([ADR-0016](docs/adr/0016-listen-address-and-tls.md)).

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

### The S3 server ([ADR-0008](docs/adr/0008-s3-http-layer.md) to [ADR-0020](docs/adr/0020-bucket-tags-and-lifecycle.md))

- **Built on [CeeSafe.Web](https://github.com/CeeSafe/CeeSafe.Web)**, async HTTP/1.1, with TLS 1.2 and 1.3 whose
  certificate is reloaded when its files change.
- **Auth:** SigV4 headers and presigned URLs, aws-chunked bodies (signed and unsigned, with trailing checksums), and
  POST object with a SigV4 policy. A credentials file holds the access keys.
- **Objects:** PUT, GET, HEAD, DELETE, ranges, conditional requests, CopyObject, DeleteObjects, user metadata, object
  tags, GetObjectAttributes, and checksums (CRC32, CRC32C, CRC64NVME, SHA-256) checked, stored and returned.
- **Multipart uploads**, including UploadPartCopy, ListParts and ListMultipartUploads; abandoned uploads expire.
- **Buckets:** create, list, delete, tags and lifecycle rules (expiration, aborting incomplete uploads);
  ListObjects v1 and v2; path-style and virtual-host addressing.
- **Upkeep in the background:** checkpoints and compaction in steps, upload expiry and lifecycle rules.
- **Performance work** (ADR-0021 to ADR-0038): group commit across requests, reads and small PUTs on the event loop,
  an ordered index, and a statistics endpoint (`GET /_cosmostore/stats`) with latencies, syncs and upkeep debt.
- Anything not supported gets S3's `NotImplemented` error; [docs/compatibility.md](docs/compatibility.md) lists what
  is and is not.

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
| `src/main.cee` | The command line: `serve`, `fsck`, `bench`, `soak`. |
| `src/s3/` | The S3 layer: routing, SigV4, aws-chunked, objects, multipart, copies, POST, tags, lifecycle, stats. |
| `src/soak.cee` | The long churn test run by `tools/soak.sh`. |
| `src/storage/io/` | `DurableFile` and `Fs` (`durable.cee`), and the fault-injecting layer and crash model (`faults.cee`). |
| `src/storage/checksums/` | CRC32C, CRC32 and MD5 over CeeSafe's standard library, with RFC test vectors. |
| `src/storage/journal/` | The record codec, segments, rotation, group commit and recovery. |
| `src/storage/extent/` | Extent files, the manifest codec, `ObjectWriter` and `ExtentReader`. |
| `src/metadata/` | The version-first object model, its codecs, S3 bucket-name rules, and the ordered index. |
| `src/store/` | `ObjectStore` (buckets, objects, listing, uploads, space, verify), checkpoints and compaction, and their tests. |
| `docs/adr/` | The design decisions, ADR-0001 to ADR-0038. |
| `docs/benchmarks/` | Dated benchmark reports, with their raw data. |
| `tools/` | The S3 smoke and TLS tests, the SDK checks (`sdk/`), the s3-tests runner (`s3tests/`), the load generator (`bench/`), the p99 gate (`perf_gate.sh`), the comparison run (`compare/`) and the soak. |

**Documents:**
- [CeeSafe_Object_Storage_Architecture.md](CeeSafe_Object_Storage_Architecture.md): the original research and
  architecture (four planes, packed small objects, replication and erasure coding, the compatibility tiers).
- [ROADMAP.md](ROADMAP.md): a review of that architecture, the milestones M0 to M7 with exit criteria, and a dated
  progress log with benchmarks.
- [CEESAFE_GAPS.md](CEESAFE_GAPS.md): what CeeSafe lacked for a storage engine and a server (G1 to G31) and which
  gaps are closed.
- [docs/compatibility.md](docs/compatibility.md): the S3 operations supported and the clients tested.
- [docs/targets.md](docs/targets.md): the M4 performance targets.

The dependencies are CeeSafe's standard library and CeeSafe.Web's packages (`ceesafe.toml`), with OpenSSL 3 for TLS.

---

## Building

You need `ceesafec` 0.36.0 or later (`ceesafe.toml` requires it), a C compiler and OpenSSL 3 (Homebrew `openssl@3`
on macOS). CeeSafe.Web is used by path, from a checkout two directories up; CI pins the commit it was last built
against (`CEESAFE_WEB_REF` in `.github/workflows/ci.yml`).

```sh
mkdir -p CeeSafeApps && cd CeeSafeApps
git clone https://github.com/CeeSafe/cosmostore.git
git clone https://github.com/CeeSafe/CeeSafe.Web.git ../CeeSafe.Web
cd cosmostore
ceesafec check
ceesafec build
```

It is developed on macOS (CI runs on macOS 15) and benchmarked on Linux (Debian 13, x86_64).

---

## Command line

```text
cosmostore serve <dir> <[address:]port> <credentials-file> [domain] [--tls-cert <pem> --tls-key <pem>]
                 [--maintain-seconds <n>] [--upload-expiry-hours <n>]
cosmostore fsck  <dir>
cosmostore bench <dir> <objects> <size-bytes> <batch>
cosmostore soak  <dir> <seconds> <keys> <capacity-bytes>
```

- **`serve`** serves the store in `<dir>` over the S3 API, on 127.0.0.1 unless an address is given (`0.0.0.0:9000`,
  `[::]:9000`). The credentials file has one `access-key secret-key` pair per line. With a domain, `<bucket>.<domain>`
  addresses a bucket as well as `/<bucket>/` paths. With `--tls-cert` and `--tls-key` it serves TLS, and reloads the
  files when they change. `--maintain-seconds` (10) sets the upkeep round, and `--upload-expiry-hours` (168; 0 never)
  when unfinished multipart uploads are aborted.

  ```sh
  echo "mykey mysecret" > creds
  out/cosmostore serve /var/lib/cosmostore 0.0.0.0:9000 creds &
  export AWS_ACCESS_KEY_ID=mykey AWS_SECRET_ACCESS_KEY=mysecret AWS_REGION=us-east-1
  aws --endpoint-url http://127.0.0.1:9000 s3 mb s3://photos
  aws --endpoint-url http://127.0.0.1:9000 s3 cp file.txt s3://photos/
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

The server is a layer over `ObjectStore`, which can also be used in-process. A sketch of the API in `src/store/object_store.cee`:

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
| `minPartBytes` | 5 MiB | The smallest multipart part, except the last. |
| `uploadExpiryMillis` | 7 days | Unfinished multipart uploads older than this are aborted (`serve --upload-expiry-hours`). |

---

## Testing

```sh
ceesafec test                 # unit, crash and fault-injection tests (136)
ceesafec test --sweep alloc   # the same tests, failing each allocation in turn
ceesafec fmt --check
ceesafec build && tools/s3_smoke.sh   # the server through the AWS CLI v2
tools/tls_smoke.sh                    # TLS and certificate reload
tools/s3tests/run.sh                  # the Ceph s3-tests subset (S3TESTS_DIR, S3TESTS_PYTHON)
tools/sdk/boto3.sh                    # and go.sh, js.sh, java.sh, dotnet.sh, rclone.sh
tools/perf_gate.sh BASE HEAD          # the p99 regression gate between two builds (ADR-0030)
```

The tests include:
- the record codec against every bit flip and every torn prefix;
- recovery after truncating the journal at every byte, for the journal and for the whole store;
- the fault sweeps of [ADR-0004](docs/adr/0004-fault-injection-and-crash-model.md), each operation failed once,
  sticky or torn, with the crash model;
- large objects: boundaries, ranges, reaping, orphans, abandoned writers and corruption;
- checkpoints, compaction and an 80-round churn;
- the space reserve and `fsck` against flipped bits and missing extents.

- the S3 layer's unit tests: SigV4 against AWS's examples, aws-chunked split at every byte, form uploads and POST
  policies, request bodies, tags and lifecycle XML.

The 24-hour soak (`tools/soak.sh`, above) was the exit test for milestone M2. CI (`.github/workflows/ci.yml`) runs
the checks, the tests and the S3 and TLS smoke tests on every change, and the p99 gate against the change's base.
The s3-tests subset and the SDK checks are run before each change is committed.

---

## Status and roadmap

**Benchmarks:** a comparison with SeaweedFS 4.53, Garage v2.5.0 and RustFS 1.0.4 on the same server (Debian 13, Xeon
E3-1245 V2, a SATA SSD with power-loss protection), each on two pinned cores, 12 Nov 2026
([report and raw data](docs/benchmarks/2026-11-12-comparison-pinned.md)). Operations per second, CosmoStore with
every write synced, against the fastest durable other server:

| Workload | CosmoStore | Next durable server |
|---|---:|---:|
| 4 KiB PUT, concurrency 32 | 11,363 | 1,215 (SeaweedFS, fsync) |
| 4 KiB GET, concurrency 32 | 26,737 | 7,727 (RustFS) |
| HEAD, concurrency 32 | 32,681 | 13,248 (RustFS) |
| 1 MiB PUT, concurrency 128 | 265 | 243 (RustFS) |
| 1 MiB GET, concurrency 32 | 1,539 | 1,020 (SeaweedFS, fsync) |

CosmoStore leads the durable servers in 59 of the 60 cells (sizes 0 B to 1 MiB, concurrency 1 to 128). Servers
that do not sync are ahead of it on some single-client writes. One run per configuration; the report has the
limits.

**Done:**
- M0 and M1: the design records, the durability layer and the single-node storage core;
- M2: checkpoints, compaction, the space reserve, `fsck`, and the 24-hour soak;
- M3, the first alpha: the S3 API and the compatibility matrix.

**Now, M4 (performance):** most of it is done, from group commit across requests to the comparison runs and the p99
gates in CI. Left: the M4 targets ([docs/targets.md](docs/targets.md)) on the reference machine.

**Later:** M5 production features (versioning, policies, encryption, Object Lock), M6 a Raft-based cluster, and M7
advanced S3 features.

**Known limits:**
- a single node: no replication or erasure coding yet;
- no versioning, bucket policies, ACLs, CORS or Object Lock, and no SigV2 or session tokens;
- HTTP/1.1 only;
- a capacity must be configured for the space reserve: CeeSafe has no free-space query yet (CEESAFE_GAPS G24);
- Windows is not supported.

## License

CosmoStore is licensed under the GNU General Public License, version 2 only ([COPYING](COPYING)).
