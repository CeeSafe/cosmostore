# CeeSafe Object Storage Server

## Research, architecture and implementation plan

**Research date:** 5 November 2026\
**Working name:** CosmoStore (placeholder; choose the public name before
creating the repository)\
**Language:** CeeSafe\
**Primary interface:** Amazon S3-compatible REST API\
**Design objective:** A durable, horizontally scalable object store that
is especially efficient for small objects without sacrificing
large-object throughput, correctness, or S3 compatibility.

------------------------------------------------------------------------

## 1. Executive recommendation

Build a native CeeSafe object-storage system with four deliberately
separate planes:

1.  **S3 protocol plane** --- HTTP parsing, SigV4 authentication,
    authorization, XML/HTTP compatibility, streaming request and
    response bodies.
2.  **Metadata plane** --- bucket configuration, object/version records,
    ordered listing indexes, policies, multipart state, lifecycle state
    and transaction coordination.
3.  **Data plane** --- append-only packed segments for small objects,
    streamed extents for large objects, checksums, replication and
    erasure coding.
4.  **Control/repair plane** --- placement, health, replication,
    compaction, garbage collection, rebalance, scrub, metrics and
    administration.

The most important design choice is a **hybrid object layout**:

-   Small objects are appended to shared pack/journal segments. Do not
    create one OS file, inode, directory entry, or independently synced
    data file per S3 object.
-   Large objects are streamed into multi-megabyte extents/segments and
    are never buffered in full in RAM.
-   Both paths publish through the same transactional metadata model and
    therefore have the same visibility, versioning, conditional-write
    and durability semantics.

This borrows the useful small-file ideas demonstrated by SeaweedFS's
append-only volume design and Ceph RGW's inline-head optimization, but
combines them with an explicit transactional commit protocol, a sorted
metadata index, and a CeeSafe-native implementation. SeaweedFS describes
packed small files, compact per-object indexes and a master that is not
in the read path; Ceph documents inline object data in the head object
and a separate, shardable bucket index. These are proven patterns, not a
reason to copy either project's implementation wholesale.

**Do not start by implementing every S3 endpoint.** First prove the
storage engine, crash recovery, concurrency semantics and small-object
benchmarks. Then implement S3 features on top of a stable object model.

## 2. What "full S3 support" should mean

There is no single finite feature switch called "all of S3". AWS S3
includes general-purpose buckets, directory buckets/S3 Express, S3
Control, access points, Object Lambda, Tables, IAM/STS integrations and
other AWS-managed capabilities. Some are separate APIs or services, and
some depend on AWS infrastructure that a self-hosted server cannot
reproduce exactly.

I recommend defining the compatibility contract in tiers.

### Tier A --- General-purpose S3 compatibility (required)

**Bucket operations** - Create, delete, head and list buckets; bucket
location and bucket existence. - Bucket versioning configuration and
status. - Bucket policy get/put/delete; ACL get/put where ACL
compatibility is enabled. - CORS get/put/delete. - Lifecycle
get/put/delete, including expiration, noncurrent-version expiration and
abort-incomplete-multipart rules. - Encryption configuration; ownership
controls; public-access block. - Bucket tagging; request-payment
configuration where applicable. - Object Lock configuration and
bucket-level defaults. - Replication configuration and status. - Website
configuration if website hosting is in scope. - Logging, metrics,
inventory and analytics configuration, implemented after the core data
path. - Bucket notification configuration and event delivery. - List
multipart uploads.

**Object operations** - PUT, GET, HEAD, DELETE, multi-delete and COPY. -
ListObjects/ListObjectsV2, ListObjectVersions. - Range GET, conditional
GET, conditional PUT/COPY, If-Match/If-None-Match and date validators. -
User metadata, content headers, tags, ACLs and legal-hold/retention
metadata. - Version IDs, delete markers, version-specific
GET/HEAD/DELETE. - Object attributes and checksum retrieval. -
Select/restore/append-style features only when their semantics are fully
specified and tested; do not claim support based on a superficial HTTP
response.

**Multipart** - CreateMultipartUpload, UploadPart, UploadPartCopy,
ListParts, ListMultipartUploads, CompleteMultipartUpload and
AbortMultipartUpload. - Out-of-order and parallel part uploads, retries,
idempotent completion handling and cleanup of abandoned uploads. -
AWS-compatible part numbering and size limits.

**Security and request compatibility** - AWS Signature Version 4 header
and query-string authentication. - Presigned GET/PUT URLs and browser
POST policies. - Canonical path/query/header handling, payload hash
modes and streaming/chunked SigV4 where supported by clients. -
Path-style and virtual-hosted-style addressing. - TLS, secure credential
storage, bucket policies and a documented local identity/credential
model. - AWS XML error shapes, headers, status codes, pagination markers
and edge-case behavior.

### Tier B --- Production storage features (required for a serious server)

-   Versioning and Object Lock with governance/compliance retention and
    legal holds.
-   SSE-S3, SSE-KMS and SSE-C, with key rotation and key-provider
    abstraction.
-   Replication between nodes and clusters, with resumable catch-up.
-   Lifecycle transitions, expiration and background tiering.
-   Event notifications with durable delivery/retry semantics.
-   Audit logs, metrics, tracing, quotas, rate limits and per-tenant
    accounting.
-   Admin API/CLI, health endpoints, online repair and scrub.
-   Multi-site replication and disaster recovery.
-   Strong read-after-write and list consistency.

### Tier C --- AWS ecosystem extensions (later, explicitly scoped)

-   S3 Access Points and Multi-Region Access Points.
-   S3 Control operations.
-   IAM and STS API compatibility, including role/session credentials.
-   Directory buckets and S3 Express-style zonal endpoints/session
    tokens.
-   S3 Tables/Iceberg catalog and related integrations.
-   S3 Select, Object Lambda, Storage Lens and other specialized
    features.

Treat Tier C as independent projects with their own compatibility
matrices. For example, AWS directory buckets intentionally do not
support a number of general-purpose bucket features, including
versioning, Object Lock, lifecycle transitions, notifications and
replication. A directory-bucket implementation is therefore not simply
"general-purpose S3 but faster".

**Compatibility rule:** a feature is supported only when its semantics,
authorization, error behavior, persistence and failure cases pass tests.
A route that returns HTTP 200 but does not implement the behavior is not
compatibility.

## 3. Research findings and lessons

### 3.1 AWS S3 performance is not simply "slow for small files"

AWS documents strong read-after-write consistency, atomic updates to a
single key, horizontal request scaling and high request rates per
prefix. It also offers S3 Express One Zone/directory buckets for
latency-sensitive workloads. Those are important capabilities and should
be treated as compatibility targets.

The opportunity for a self-hosted store is different: eliminate
avoidable local overhead and optimize the cost of storing and serving
millions of tiny objects. Small objects magnify fixed costs: - One
filesystem file and inode per object. - One metadata transaction and
index update per object. - One or more synchronous flushes per object. -
Excessive allocation, copying, parsing and task creation. - Poor cache
locality and random I/O. - Listing that scans too much metadata. -
Replication/erasure-coding overhead that is too expensive at object
granularity.

AWS's service economics and internal architecture are not directly
comparable to a local cluster. Benchmark AWS as a remote baseline from
the same region/network, but compare self-hosted engines on identical
hardware.

### 3.2 Small-object storage patterns worth adopting

**SeaweedFS** - Packs small files consecutively into append-only volume
files. - Uses compact in-memory index entries and avoids per-file inode
operations. - Keeps its master out of the normal read path. - Replicates
hot data and can erasure-code colder data in the background. - Its
published benchmark figures are project-reported results, not
independent guarantees; use them as a design clue and reproduce tests on
our hardware.

**Ceph RGW** - Separates object metadata, bucket indexes and payload
data. - Can inline small object data in the head object. - Uses a
separate bucket index for ListObjects and version listing. - Shards
bucket indexes to increase parallelism. - Writes the object head last as
the visibility/commit point in its documented layout.

**Apache Ozone** - Separates metadata services from data nodes. -
Supports replication and erasure coding as different durability
strategies.

**Design conclusion:** pack tiny payloads, separate metadata from
payload placement, shard the index, keep the request path away from
global placement services, and use replication for the hot write path
with background erasure coding for sealed/cold data.

### 3.3 Multipart upload is not the small-object solution

Multipart upload is intended for large objects, parallel throughput and
resumable transfer. AWS recommends considering it at around 100 MB.
Current documented limits include 10,000 parts, 5 MiB minimum for
non-final parts, 5 GiB maximum part size, and a 48.8 TiB maximum object
size. The final part can be smaller than 5 MiB.

Do not force tiny objects through multipart. Implement ordinary PUT as
an efficient single streaming transaction. Multipart should use the same
underlying extent and commit machinery, not a second object model.

------------------------------------------------------------------------

## 4. Proposed system architecture

``` text
                       S3 clients / SDKs / CLI / rclone
                                    |
                         TLS + S3 HTTP endpoints
                                    |
                  +-----------------v------------------+
                  | S3 Frontend (stateless gateways)   |
                  | routing, XML, SigV4, streaming     |
                  +-----------------+------------------+
                                    |
                  +-----------------v------------------+
                  | Request / policy execution         |
                  | authn -> authz -> quota -> limits   |
                  +-----------------+------------------+
                                    |
              +---------------------+----------------------+
              |                                            |
    +---------v----------+                       +---------v----------+
    | Metadata service   |                       | Object data service|
    | MVCC + WAL + LSM   |                       | packs + extents    |
    | ordered key index  |                       | checksums          |
    | version/index state|                       | replication / EC   |
    +---------+----------+                       +---------+----------+
              |                                            |
              +----------------------+---------------------+
                                     |
                         +-----------v-----------+
                         | Background workers   |
                         | compaction, repair,   |
                         | GC, lifecycle, scrub, |
                         | rebalance, events     |
                         +-----------------------+
```

### 4.1 S3 frontend

Keep the gateway stateless so it can scale horizontally behind a load
balancer.

Responsibilities: - Parse the HTTP request without buffering the entire
body. - Resolve bucket/key from path-style or virtual-hosted-style
hostnames. - Verify SigV4 before accepting expensive body work where
possible. - Enforce request size, header count, timeout, concurrency and
per-tenant limits. - Parse XML configuration bodies with strict
size/depth limits and safe entity handling. - Stream request bodies into
the data engine with bounded buffers and backpressure. - Stream GET
responses from data extents or pack offsets. - Produce exact
S3-compatible headers, error codes and XML bodies. - Keep protocol
concerns out of the storage engine.

Use the CeeSafe web framework as the HTTP/TLS integration point after
verifying its current public API and streaming-body behavior. Do not
couple storage correctness to a particular router or UI implementation.
The UI framework belongs in the administration console, not in the
storage data path.

### 4.2 Metadata engine

Recommended first implementation: a CeeSafe-native, append-only WAL plus
an LSM-style sorted index, with clear storage interfaces.

Core records: - Tenant/account and credentials. - Bucket configuration
and policy generation. - Object key and current-version pointer. -
Object version metadata and delete markers. - Payload locator (pack
ID/offset/length or extent manifest). - Checksums, ETag, content headers
and user metadata. - Tags, ACL/ownership, retention and legal hold. -
Multipart upload state and uploaded part manifests. - Replication state
and durable event outbox. - Lifecycle and notification configuration.

Index requirements: - Hash lookup for fast HEAD/GET by bucket+key. -
Ordered index for prefix/range listing and version listing. - Bloom
filters and sparse block indexes for disk-resident tables. -
Shard/partition by bucket and key range; split hot ranges. - Bounded
caches with admission/eviction policy. - No full-bucket in-memory object
map as the only source of truth.

Use a single atomic metadata batch for a committed write: add version
row, update current pointer, update bucket accounting and append the
event-outbox record. Listing must observe the same committed state as
GET/HEAD.

### 4.3 Small-object data engine

**Recommended default strategy: append-only packed records.**

-   Each disk owns a set of append-only pack/journal segments.
-   Each record contains a fixed header, object payload, checksums,
    transaction identity and a commit trailer.
-   An object locator is
    `(disk/node, segment_id, offset, length, record_generation)`.
-   The metadata index maps object versions to locators.
-   A small object never creates its own OS file.
-   Sealed segments are immutable and can be compacted, replicated,
    scrubbed or erasure-coded as units.

Suggested starting thresholds (benchmark-tuned, not protocol limits): -
Inline/packed path: objects up to 64--128 KiB. - Larger objects:
streamed extents, initially 8--64 MiB chunks. - Pack target: 64--256 MiB
before sealing/rotation. - Group-commit window: configurable, initially
around 1--5 ms under load.

The threshold and segment size must be selected by measured latency,
write amplification, memory use and recovery time on the target disks.
Do not hard-code them into the S3 API.

**One-sync small-object commit idea**

For the small-object path, make the append journal itself the durable
source of truth: 1. Validate request, calculate checksum and reserve a
per-key generation. 2. Append one complete record containing metadata
plus the small payload. 3. Batch multiple concurrent records and perform
one `fdatasync`/equivalent for the batch. 4. Only after the durable
flush, publish the records into the in-memory metadata/index view and
acknowledge success. 5. Flush metadata into sorted tables and compact
old journal segments in the background.

A record is valid after restart only if its complete header, declared
length, payload checksum and commit trailer validate. A torn tail is
ignored/truncated. This avoids a separate data-file create and a
separate metadata commit sync for every tiny object.

For large objects: 1. Stream into a temporary/append-only extent with
bounded buffers. 2. Calculate full-object and part checksums while
streaming. 3. Make the extent durable. 4. Commit a metadata WAL
transaction that references the durable extent. 5. Publish the metadata
generation and acknowledge. 6. Reclaim orphan extents after crash
recovery/GC.

The ordering is non-negotiable: **never publish metadata that references
data that has not reached the promised durability level.**

### 4.4 Large-object path

-   Stream request bytes directly from the HTTP body to extents.
-   Avoid whole-object allocation; use a bounded pool of reusable
    buffers.
-   Use vectored I/O where it reduces syscalls and copies.
-   Support byte-range reads without loading the whole object.
-   Keep extent manifests compact and independently checksummed.
-   Use multipart parts as durable extents; CompleteMultipartUpload
    atomically publishes the final manifest.
-   Allow parallel part uploads and retry without re-uploading
    successful parts.
-   Use sendfile/TransmitFile only where encryption, checksums and
    response semantics permit it; otherwise use bounded streaming.

### 4.5 Metadata ordering and strong consistency

The store should promise S3-like strong read-after-write and list
consistency within a defined consistency domain.

Single-node transaction: - Serialize conflicting updates to one
`(bucket,key)` through a generation/CAS mechanism. - Commit data first,
then metadata. - Atomically update the current-version pointer and
ordered listing index in one metadata transaction. - GET/HEAD after
successful PUT sees the committed generation. - LIST after successful
PUT sees the same committed object. - Concurrent PUTs produce a
well-defined total order; clients never see a partially written object.

For a cluster, do not use one global consensus group for every object.
Partition metadata into many independently replicated shards. Each shard
needs a clear leader/epoch and linearizable commit order. A request is
acknowledged only after the configured data durability quorum and
metadata commit are both satisfied.

### 4.6 Durability, replication and erasure coding

Offer explicit durability policies: - **Single-node:** local durable
journal/segments; document that node or device loss is outside this
policy. - **Replicated:** default production policy, typically three
copies across independent nodes/failure domains. - **Erasure-coded:**
for sealed/cold data, e.g. 4+2 or 8+3 layouts, selected by cluster size
and failure-domain topology.

Recommended hot/cold lifecycle: 1. Small/hot data is replicated, not
erasure-coded per object. 2. Seal packs after a threshold or age. 3.
Verify all replicas and checksums. 4. Erasure-code the sealed
pack/stripe in the background. 5. Atomically switch metadata placement
to the EC representation. 6. Retain replicas until the EC representation
is verified. 7. Garbage-collect old copies only after a safe grace
period.

Do not erasure-code each 1 KiB object independently. The parity and
metadata overhead would defeat the small-object design. Encode packed
segments/stripes containing many objects.

### 4.7 Cluster layout

Start with a single-node server but design stable interfaces for a
future cluster:

-   **Gateway nodes:** stateless HTTP/S3 endpoints.
-   **Metadata shard groups:** replicated consensus groups, each owning
    a key range/partition.
-   **Storage nodes:** append-only packs and large extents.
-   **Placement map:** virtual shards assigned to failure domains;
    clients/gateways cache versioned placement maps.
-   **Background workers:** repair, rebalance, scrub, compaction,
    replication and tiering.

Keep the placement coordinator out of the normal GET data path. Gateways
should resolve a key to a metadata shard and a storage location using
cached routing information.

------------------------------------------------------------------------

## 5. CeeSafe-specific implementation assessment

I inspected the public `CeeSafe/CeeSafe` repository and its current
README, roadmap, async guide and standard-library documentation.

The current language is materially better suited to this project than
the earlier CeeSafe snapshots: - Ownership and borrowing provide
deterministic destruction and prevent use-after-free, double-free and
conflicting access in safe code. - Explicit allocators include heap,
arena, pool, fixed-buffer and scratch-region patterns. - Structured
async tasks, bounded task sets, cancellation, timeouts and channels are
available. - Async TCP listeners/streams, vectored writes, file sending
and async file operations exist. - The runtime has epoll, kqueue,
io_uring and IOCP backends. - The compiler has built-in tests,
allocation-failure sweeps, cancellation sweeps, sanitizers and a
self-hosted C11 backend.

The CeeSafe roadmap also records real HTTP/2 workload feedback from
CeeSafe.Web: fixes to wake handling and scoped cancellation materially
improved measured request throughput in its `h2load` tests. This is
useful evidence that the language runtime is being exercised by a real
server, not just toy async examples.

**Important storage gap to close before production:** the currently
documented standard file API exposes open/create/read/write/remove, but
the public API material inspected does not establish a complete
durable-storage surface such as `fdatasync`/`fsync`, directory sync,
atomic rename, pread/pwrite, file sizing/stat, directory creation, and
safe open flags. These are essential for a crash-safe storage engine.
Add a specified CeeSafe standard-library/runtime API for them (with
POSIX and Windows semantics), or use a very small audited C adapter
temporarily. Do not implement durability by assuming `File.write` means
data is on stable media.

Other likely prerequisites: - A stable binary codec and bounded
byte-reader/writer API. - Hashing and checksum APIs: CRC32C, CRC64/NVME,
SHA-256 and MD5 compatibility where required. - Ordered index
implementation and durable LSM/WAL primitives. - Secure random IDs and
credential/key handling. - A robust HTTP streaming body contract in
CeeSafe.Web. - TLS/mTLS and certificate lifecycle integration. -
Backpressure between network, storage and replication tasks. - Explicit
limits for task counts, buffer pools, open files and per-tenant memory.

CeeSafe's structured task model is a good fit for one task per
connection and bounded child tasks per connection/stream. Avoid spawning
an unbounded task for every object or every multipart part. Use
admission control and bounded queues.

### Suggested package boundaries

``` text
cosmostore/
  ceesafe.toml
  src/
    app/
    config/
    s3/
      routing/
      auth/
      sigv4/
      xml/
      errors/
      bucket_api/
      object_api/
      multipart/
      versioning/
      policy/
    metadata/
      model/
      transactions/
      wal/
      lsm/
      listing/
    storage/
      pack/
      extent/
      checksums/
      cache/
      io/
    cluster/
      placement/
      replication/
      consensus/
      repair/
    workers/
      compaction/
      gc/
      lifecycle/
      notifications/
      scrub/
    observability/
    admin/
  tests/
    protocol/
    crash/
    concurrency/
    small_objects/
    multipart/
    durability/
    cluster/
```

These are conceptual package boundaries. Confirm CeeSafe's
package/dependency and link model before splitting into multiple
packages; do not assume subdirectories are independent compilation
units.

------------------------------------------------------------------------

## 6. S3 protocol implementation details that commonly cause compatibility bugs

1.  **SigV4 canonicalization:** header whitespace, duplicate headers,
    URI encoding, query sorting, host/port handling, signed headers and
    payload hash modes must match AWS rules exactly.
2.  **Object keys:** preserve key bytes and case; do not normalize
    Unicode, collapse slashes, interpret `.`/`..`, or treat keys as
    filesystem paths.
3.  **ETag:** do not assume every ETag is an MD5 digest. Multipart ETags
    and encryption behavior differ. Implement ETag semantics separately
    from checksum APIs.
4.  **Checksums:** distinguish full-object checksums from composite/part
    checksums. Verify client-provided checksums and return the correct
    checksum headers.
5.  **XML:** namespace-aware parsing, escaping, empty values, malformed
    XML, pagination markers and exact error structures matter.
6.  **List pagination:** correctly implement `continuation-token`,
    `start-after`, delimiter/common-prefix behavior, encoding type,
    max-keys and stable ordering.
7.  **Conditional writes:** use metadata generation/CAS; never implement
    If-Match as a racy HEAD followed by PUT.
8.  **Multipart completion:** validate part ordering, ETags/checksums,
    minimum part sizes, upload ownership and races with Abort/Complete.
    Completion must be atomic from the object's perspective.
9.  **Versioning:** distinguish a null version, suspended versioning,
    delete markers and permanent version deletion.
10. **Range responses:** handle suffix ranges, invalid/multiple ranges
    according to the chosen compatibility contract, If-Range and exact
    Content-Range/Content-Length.
11. **Presigned URLs:** enforce expiry, signed headers, query parameter
    canonicalization and clock-skew policy.
12. **Virtual-host addressing:** support configured wildcard
    DNS/certificates and avoid confusing bucket names with endpoint
    names.
13. **Retries and idempotency:** client retries after a lost response
    must not create inconsistent metadata or duplicate multipart
    completion effects.
14. **Clock behavior:** persist UTC timestamps, use monotonic time for
    deadlines, and make clock skew visible in SigV4 diagnostics without
    leaking secrets.

------------------------------------------------------------------------

## 7. Security model

-   TLS 1.2/1.3; optional mTLS for internal cluster traffic.
-   Access key IDs identify credentials; secret keys are stored only as
    salted/derived verifiers where feasible, not returned by admin APIs.
-   SigV4 verification uses constant-time comparisons for MACs and
    strict canonicalization.
-   Separate authentication from authorization.
-   Evaluate identity policy, bucket policy, ACL (if enabled),
    public-access block and explicit deny using a documented policy
    precedence model.
-   Default private buckets; no anonymous access unless explicitly
    granted.
-   Support credential rotation and revocation without restarting
    gateways.
-   Encrypt at rest with envelope encryption; separate data-encryption
    keys from master/key-encryption keys.
-   SSE-C keys must never be persisted or logged; derive/use them only
    for the request and verify key MD5 behavior required by S3.
-   KMS calls must be bounded, cached safely and observable; key
    unavailability must fail closed.
-   Audit administrative actions and data access according to
    configurable policy.
-   Protect XML parsers, multipart uploads, decompression, request
    headers and object metadata from resource exhaustion.
-   Enforce per-tenant quotas for bytes, objects, multipart parts,
    requests, connections and background work.
-   Make Object Lock and retention enforcement part of the metadata
    transaction, not a best-effort API check.

------------------------------------------------------------------------

## 8. Implementation roadmap

### Phase 0 --- Requirements and runtime prerequisites

Deliverables: - A written S3 compatibility matrix with
operation-by-operation status. - CeeSafe.Web integration spike proving
streaming request bodies, streaming responses, TLS, keep-alive,
cancellation and backpressure. - CeeSafe filesystem durability ADR/API:
sync file, sync directory, atomic rename, positional I/O, stat/size,
mkdir, unlink and open flags. - Binary codec, checksums, secure IDs and
metrics primitives. - A threat model and crash-consistency
specification.

Exit criteria: no storage code depends on undocumented filesystem
durability behavior.

### Phase 1 --- Single-node storage core

Implement: - Append-only journal/pack segments and record format. -
Recovery scanner, torn-write detection and truncation. - Small-object
append path and bounded group commit. - Large-object streamed extents. -
Metadata WAL and ordered index. - Atomic object publication and
generation/CAS. - GET/HEAD/PUT/DELETE, range reads and conditional
operations. - Crash injection at every write/sync/commit boundary.

Exit criteria: - After every injected crash, recovery yields either the
old committed object or the new committed object, never a partial
object. - No successful PUT is lost under the documented durability
mode. - No metadata entry points to missing or unverified data. - Strong
read-after-write and list-after-write tests pass.

### Phase 2 --- S3 core compatibility

Implement: - SigV4, path/virtual-host addressing and presigned URLs. -
Bucket CRUD and configuration. - Object CRUD, copy, multi-delete,
listing and pagination. - ETag/checksum behavior and XML errors. -
Multipart upload. - AWS CLI, SDK and rclone interoperability.

Exit criteria: automated S3 compatibility suite and SDK matrix pass for
the supported Tier A subset.

### Phase 3 --- Small-object performance and operations

Implement: - Group commit tuning and multi-shard appenders. - Metadata
cache and sorted-index tuning. - Pack compaction, garbage collection and
orphan recovery. - Read coalescing, cache admission and bounded
prefetch. - Metrics for p50/p95/p99 latency, fsync batches, write
amplification, pack utilization, index/cache hit rates and compaction
debt.

Exit criteria: benchmark targets are met on documented hardware, with no
unbounded memory growth or compaction stalls.

### Phase 4 --- Production features

Implement: - Versioning and delete markers. - Bucket/object tagging and
ACL/policy support. - SSE-S3, SSE-KMS and SSE-C. - Object Lock and legal
holds. - Lifecycle and incomplete multipart cleanup. - Notifications
with durable outbox and retry. - Audit logs, quotas, rate limits and
admin CLI/UI.

Exit criteria: feature-specific compatibility, security and crash tests
pass.

### Phase 5 --- Distributed cluster

Implement: - Metadata partitioning and consensus groups. -
Failure-domain-aware placement. - Replication quorum and node
recovery. - Sealed-pack erasure coding. - Online rebalance, scrub and
repair. - Gateway routing cache and membership/health service. - Cluster
upgrade and rolling restart protocol.

Exit criteria: node, disk, rack and network failures are injected;
committed objects remain readable within the configured durability
policy.

### Phase 6 --- Advanced S3 and ecosystem

Implement selectively: - Replication rules and multi-site replication. -
Inventory, metrics, analytics, website hosting and access logging. -
Access Points and S3 Control. - IAM/STS integration. - Directory
buckets/session APIs if justified. - Iceberg/S3 Tables and specialized
data services.

Exit criteria: each extension has a separate support matrix and
end-to-end compatibility tests.

------------------------------------------------------------------------

## 9. Benchmark plan --- small objects are the first-class workload

Benchmark against at least: - CeeSafe server. - SeaweedFS. - Ceph RGW. -
A current maintained S3-compatible alternative such as RustFS, after
validating its release and feature state. - AWS S3 as a remote baseline,
with region, client location and network path documented.

Use identical local hardware, filesystem, disk configuration, network
and client placement for self-hosted comparisons. Do not compare a local
NVMe deployment to remote AWS latency without clearly separating the
results.

### Workload matrix

  -----------------------------------------------------------------------
  Workload                Object sizes            Operations
  ----------------------- ----------------------- -----------------------
  Tiny                    0 B, 128 B, 1 KiB, 4    PUT, GET, HEAD, DELETE
                          KiB                     

  Small                   16 KiB, 64 KiB, 128     PUT, GET, overwrite
                          KiB, 256 KiB            

  Medium                  1 MiB, 8 MiB, 32 MiB    PUT, GET, range GET

  Large                   128 MiB, 1 GiB,         streaming PUT/GET,
                          multi-GiB               multipart

  Metadata-heavy          1M, 10M, 100M keys      LIST, prefix LIST, HEAD

  Contention              hot single key, hot     concurrent
                          prefix, uniform keys    PUT/GET/DELETE

  Recovery                crash during PUT, sync, recovery and
                          compaction, multipart   verification
                          complete                
  -----------------------------------------------------------------------

Concurrency levels: 1, 8, 32, 128, 512 and higher where hardware
permits. Test both warm and cold caches. Include realistic mixed
workloads rather than only maximum-throughput PUTs.

### Required measurements

-   Operations/sec and MiB/sec.
-   p50, p95, p99 and p99.9 latency.
-   CPU per operation and per GiB.
-   RAM and metadata bytes per object.
-   Disk bytes written per payload byte (write amplification).
-   Number of sync calls per 1,000 successful PUTs.
-   Pack utilization and fragmentation.
-   Index/cache hit rate.
-   Listing latency at 1M/10M/100M objects.
-   Recovery time and amount of orphan data.
-   Replication/EC overhead and degraded-mode behavior.

Use repeatable tools such as Warp where appropriate, plus an in-house
workload generator with fixed seeds and correctness verification. Run S3
protocol tests separately from performance tests. Every benchmark run
should record exact commit, compiler version, build flags, hardware,
filesystem, kernel, disk model, client version, dataset and
configuration.

### Proposed engineering targets (hypotheses, not promises)

For a single NVMe node, establish a baseline first, then aim for: -
Tiny-object PUT/GET throughput that scales with concurrency until the
disk or CPU is saturated. - No per-object filesystem inode or per-object
fsync on the packed path. - Bounded memory independent of total object
count. - Predictable p99 latency under mixed small/large workloads. -
Listing cost proportional to the returned range, not total bucket
size. - Recovery bounded by journal/segment scan and metadata checkpoint
size.

Do not publish a "beats AWS" claim from a single benchmark. Publish raw
data, scripts and repeatable instructions.

------------------------------------------------------------------------

## 10. Testing and correctness strategy

**Protocol tests** - AWS SDK for .NET, Go, Java and Python/boto3. - AWS
CLI v2, rclone, s3cmd and common backup tools. - Path-style and
virtual-hosted-style endpoints. - SigV4 header auth, presigned URLs,
payload signing and streaming cases. - Ceph's S3 compatibility tests
(now maintained in the Ceph repository) as one input, not the only
oracle.

**Storage tests** - Property tests for record encoding, checksums,
offsets and segment indexes. - Model-based tests for object versions,
delete markers and concurrent conditional writes. - Crash/fault
injection after every write, sync, metadata commit and rename. -
Allocation-failure and cancellation sweeps. - Corrupt/truncated record
and checksum mismatch tests. - Disk-full, permission, slow disk, short
write, partial read and I/O error tests. - Recovery idempotence:
repeated recovery must produce the same logical state. - Scrub and
repair tests for bit rot and missing replicas.

**Distributed tests** - Kill a node before/after data quorum and
before/after metadata commit. - Partition network links, delay
replication and restart leaders. - Verify that acknowledged writes
survive the promised failure model. - Verify no stale read/list after a
committed write. - Verify repair does not overwrite a newer version. -
Verify GC cannot delete a live version, locked object or replication
source.

**Performance regression** - Store benchmark baselines by commit. - Fail
CI on significant p99 or throughput regressions using noise-tolerant
thresholds. - Keep small-object and large-object suites separate so one
cannot hide regressions in the other.

------------------------------------------------------------------------

## 11. Critical design decisions to settle before implementation

1.  **Single-node first or cluster-first?** Recommendation: single-node
    engine first, with interfaces that permit sharding/replication
    later.
2.  **Metadata engine:** recommendation: CeeSafe-native WAL + LSM, with
    a small, explicit transaction API. Avoid making an external SQL
    server a hard runtime dependency.
3.  **Small-object durability:** recommendation: append-only journal
    records containing payload and metadata, group-committed with one
    durable sync batch.
4.  **Hot data durability:** recommendation: replication first; EC only
    after pack sealing and verification.
5.  **Object-lock semantics:** implement before claiming compliance
    suitability; compliance claims require independent assessment.
6.  **Filesystem portability:** specify and test POSIX and Windows
    durability semantics. Do not silently downgrade guarantees on a
    platform.
7.  **S3 scope:** general-purpose bucket compatibility first; S3
    Control, directory buckets and Tables are separate later tracks.
8.  **Licensing/dependencies:** keep the storage engine native CeeSafe;
    audit any C libraries and their licenses, FFI boundaries and failure
    semantics.

------------------------------------------------------------------------

## 12. First implementation increment

I would start with a deliberately narrow but technically demanding
vertical slice:

1.  Add the CeeSafe durable-file primitives and tests.
2.  Implement a pack segment writer/reader with checksummed records and
    recovery.
3.  Implement group commit and prove that a successful write survives
    process termination.
4.  Implement a minimal metadata WAL/index for
    `(bucket,key) -> locator`.
5.  Implement a small S3-compatible PUT/GET/HEAD/DELETE/LIST server on
    CeeSafe.Web.
6.  Run 1 KiB, 4 KiB and 64 KiB workloads against the same server and
    validate every byte.
7.  Add overwrite races, conditional writes, crash injection and list
    consistency before adding more S3 APIs.

This vertical slice will answer the highest-risk questions early:
whether CeeSafe's I/O and async runtime can sustain the workload,
whether packed records are actually faster, whether group commit behaves
correctly, and whether the metadata model can deliver strong
consistency.

## 13. Source material

### CeeSafe repository and language

-   CeeSafe repository: https://github.com/CeeSafe/CeeSafe
-   CeeSafe README:
    https://github.com/CeeSafe/CeeSafe/blob/main/README.md
-   Async task guide:
    https://github.com/CeeSafe/CeeSafe/blob/main/guide/async.md
-   Built-in and file APIs:
    https://github.com/CeeSafe/CeeSafe/blob/main/guide/builtins.md
-   CeeSafe roadmap:
    https://github.com/CeeSafe/CeeSafe/blob/main/ROADMAP.md

### AWS S3

-   S3 documentation overview:
    https://aws.amazon.com/documentation-overview/s3/
-   S3 API operation reference:
    https://docs.aws.amazon.com/AmazonS3/latest/API/API_Operations_Amazon_Simple_Storage_Service.html
-   S3 performance guidelines:
    https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-guidelines.html
-   S3 performance design patterns:
    https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-design-patterns.html
-   S3 consistency model: https://aws.amazon.com/s3/consistency/
-   Multipart upload overview:
    https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html
-   Multipart limits:
    https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html
-   Object integrity/checksums:
    https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity-upload.html
-   Directory bucket differences:
    https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-differences.html
-   Object Lock:
    https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html

### Storage architecture

-   SeaweedFS architecture and small-file design:
    https://github.com/seaweedfs/seaweedfs
-   Ceph RGW data layout:
    https://docs.ceph.com/en/latest/radosgw/layout/
-   Ceph RGW bucket index and consistency:
    https://docs.ceph.com/en/latest/dev/radosgw/bucket_index/
-   Apache Ozone architecture: https://ozone.apache.org/docs/next/
-   Ceph S3 compatibility tests:
    https://github.com/ceph/ceph/tree/main/src/test/rgw

------------------------------------------------------------------------

## Final recommendation

The strongest differentiator is not merely "S3 written in CeeSafe". It
is:

**A strongly consistent S3 object store whose small-object path is built
around packed append-only storage, transactional metadata, group commit
and background compaction --- while large objects use efficient
streaming extents.**

Build and benchmark that core before pursuing the long tail of S3 APIs.
If the storage engine is correct, measurable and recoverable, the S3
feature surface can grow without repeatedly redesigning the foundation.
