# ADR-0128: Clusters as `serve` (M31)

**Status:** accepted, 25 Nov 2026, as built below (the owner: "Accept and close", after M31's exit review). Proposed the
same day, with the owner's choices made:
- a request sees the buckets it made, for its writes ("Bucket existence");
- asks kept as records beside the queue ("Record + queue");
- compactions bounded per node, default 2 ("Bounded, default 2").

M31 is ADR-0127's item A (the owner: "A: clusters as serve").

## Context

- **A shard does not see its own request's writes** (ADR-0058).
  - A leader stages a request's records in its journal (`commitOne` returns at `stageIn` when `raft`). The front
    proposes them after the handler returns (`proposeStaged`). They are applied to the store's state only when Raft
    commits them, or cut off by `truncateEntries` when the write fails (`abandonStaged`).
  - Every write path checks `state.hasBucket` at staging time, so a write into a bucket made in the same request is
    refused: NoSuchBucket.
  - M30 met it twice:
    - CreateTableBucket's config record. Fixed by writing none for a plain create, and refusing a configured create
      on a cluster (M30's B1, accepted).
    - A create's first metadata file, sealed by reading back its config. Fixed by passing the encryption, not reading
      it back.
  - `ensureBucket` (the IAM bucket) works around it with a write of its own, before the request that needs it.
- **One request holds the shard's gate** from `stepReady` to `stepCommit`, so a shard's requests do not interleave
  their staged entries.
- **Maintenance asks** (`maintenance-run`, ADR-0110 §5):
  - kept in the node's in-memory queue `slot.asked`, taken by `tablesMaintenanceClusterForever` within a second;
  - lost if the shard's leader changes, or the node restarts, before the loop takes it (M22's B2). The day's pass
    still runs every job within the hour.
- **One loop serves every shard a node leads, in turn** (M22's B3). A long compaction on one shard holds up the
  others' asks and passes. Each shard's writes are not held up.

## Decision

1. **Staged buckets** (slice 1):
   - A leader's store keeps the names of the buckets its staged, unapplied entries make (`stagedBuckets`, in memory).
   - A write's existence check (`putFinished…`, `putObject`, `deleteObject`, an upload's create) takes a staged
     bucket as there, with a new bucket's state: versioning off, no lock, no configuration.
   - **Reads do not see it:** `headObject`, `getObject`, listing and `bucketExists` read applied state, as now. A
     request reads only what is applied. The writes that read back what they wrote (M30's two) pass the value
     instead, and stay so.
   - **Cleared** when the entries apply (`applyEntries` past the bucket's entry), or are cut off (`truncateEntries`),
     or the replica stops leading (`setLeaderTerm(0)`).
   - **Not rebuilt at recovery.** A recovered leader's unapplied bucket is not taken for writes until it applies, as
     today: a refusal, never a wrong write.
   - **The ordering rule holds:** nothing is published or acknowledged before its batch is synced (ADR-0001). Entries
     apply in order on every replica, so the bucket's entry applies before the writes into it. A cut-off takes them
     all, as `truncateEntries` cuts every entry after its index.
2. **CreateTableBucket takes its settings on a cluster** (slice 1): M30's refusal is removed, and the config record is
   written after the bucket, in the same request, as `serve` writes it. `iceberg_check.py` drops its cluster fallback.
3. **Maintenance asks kept in replicated state** (slice 2):
   - an ask is also written as a record, `.s3tables/maintenance-asks/<kind>/<table id>`, in its table bucket's
     warehouse, a replicated write of the ask's request. It is answered 204 once committed, as other writes are;
   - the in-memory queue stays the fast path;
   - **a replica that becomes leader** lists its shard's asks once and queues them;
   - **an ask's record is deleted** in the gated step that writes its job's status, so an ask is run at least once
     and its record does not outlive its run;
   - an ask for a table dropped since is deleted with its warehouse.
4. **A loop per shard** (slice 3):
   - `tablesMaintenanceClusterForever` becomes one task per shard slot (group 0's excepted), each with its own
     timer, asks and pass;
   - **a node-wide bound on compactions at once:** each compaction holds a permit of `--tables-compactions` (default
     2), so shards' compactions run side by side without each one's memory at once. Snapshot management and
     unreferenced removal take none.
5. **Clean-up:** M30's `ObjectStore.isReplicated()` duplicates `isReplica()`; it goes.
6. **The checks** (slice 4):
   - **unit tests on replicas** (`src/cluster/replica_tests.cee`):
     - a bucket and a write into it, staged in one request, applied on each replica in order;
     - cut off together;
     - not taken after a step-down;
     - not read before they apply;
   - **a fault and crash sweep** (ADR-0004) of a staged bucket and its writes, at every I/O point;
   - **the cluster smoke:** `iceberg_check.py`'s configured creates as on `serve`, with no fallback;
   - **the cluster maintenance smoke:** a leader killed after an ask, the ask still run by the new leader; a long
     compaction (`--tables-copy-pause-ms`) on one shard while another shard's ask runs within its second;
   - **CI,** as now.
7. **The exit review** (slice 5).

## For the owner to decide

- **How much of its own writes a shard's request sees:**
  - **bucket existence only, for writes (recommended):** the case met. It is a set of names, consulted by writes'
    existence checks, so a write is never wrong and at worst refused;
  - **read-your-writes:** reads see staged versions too. It is wider: an overlay of the index, its extents not yet
    replicated (ADR-0058 §10), and every read path. It would take away the class of bug M30 met in its other form
    (reading back a record), which is today avoided by passing values.
- **Maintenance asks:**
  - **a record beside the in-memory queue, read by a new leader (recommended);**
  - **records only,** each loop listing its shard's asks every second: simpler, but a listing of every table
    bucket's warehouse each second.
- **Compactions at once, per node:**
  - **a node-wide bound, default 2 (recommended);**
  - **unbounded,** one per shard led;
  - **one,** as today, with only the asks and the other jobs no longer behind it.

## Consequences

- **A cluster takes the calls `serve` takes in one request,** and keeps its asks through a change of leader.
- **A request still does not read its own staged writes,** if the first choice is taken: code that needs a value it
  wrote passes it.

## As built (M31's slices and exit review, `docs/m31-exit-review.md`)

- **§1, the writes that take a staged bucket:** `checkPut` (every put), an upload's create, and `setBucketConfig`
  (the exit review's A1: S3's CreateBucket with an ACL or object lock).
  - A staged bucket keeps the versioning its request staged, which a lock needs.
  - Deletes and other setters see applied buckets only.
- **§3, asks:**
  - the key is `.s3tables/maintenance/asks/<table id>/<kind>`;
  - any run of the table's kind clears the ask, in a gated step when one exists. A status write clears it too;
  - a dropped table's asks go with its maintenance records;
  - a leader lists kept asks once per term, once caught up.
- **§4, loops:** `tablesMaintenanceShardForever` per slot. The permit is an atomic count, waited on in 200 ms steps.
