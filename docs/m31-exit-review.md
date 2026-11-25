# M31 exit review: clusters as `serve` (25 Nov 2026)

**M31 closed, 25 Nov 2026** (the owner: "Accept and close"), with ADR-0128 accepted and B1 to B6 recorded below.

**M31's exit (ADR-0127 item A; ADR-0128, with the owner's choices):**
- a shard's request writes into a bucket it made, so a configured CreateTableBucket is taken in one request on a
  cluster (M30's B1);
- a maintenance ask survives a change of leader (M22's B2);
- each shard has its own maintenance loop, with a node-wide bound on compactions (M22's B3);
- the store change is swept for faults and crashes.

## How it was checked

- **Unit tests on replicas** (`src/cluster/replica_tests.cee`):
  - `stagedBucketsAgreeWithoutFaults`: the cluster workload with its first write making the bucket and putting a
    value into it;
  - `stagedBucketsFaultsOnce` and `stagedBucketsFaultsCrash`: that workload swept at every I/O point;
  - `stagedBucketsAreForWritesOnly`: not read before it applies, made once, gone when cut off, and gone at a later
    term;
  - `stagedBucketsAreConfiguredAndApplied`: a bucket made with versioning and object lock in one write, on every
    replica; a bucket applied and then deleted, refused for writes.
  - Each of the put check, the drop on cut-off, the drop on apply and the staged versioning is mutation-checked.
- **`askedRunsAreKeptUntilRun`:**
  - asks kept, listed, and answered by a status write or by a run that writes none;
  - asks removed with their table's maintenance records.
- **The cluster smoke:**
  - `iceberg_check.py`'s configured creates as on `serve`, with no fallback;
  - S3's CreateBucket with object lock and an ACL, through a node (the review's A1). The binary before the fix fails
    those four checks.
- **The cluster maintenance smoke** (in CI):
  - **a fresh cluster whose day's pass does not come:** an asked compaction, its leader killed mid-run, is run by
    the new leader. The slice-1 binary fails this check;
  - **two shards led by one node:** one shard's asked run finishes while the other's compaction is held. It took 1 s
    here and 36 s on the slice-2 binary, which fails the check.
- **Totals:** 538 unit tests; the cluster smoke (214 passed), the maintenance smoke and the S3 smoke; and CI.
- **The review:** two agents read ADR-0128 and the code without my notes, one on the store, one on asks and loops.
  Their findings come from reading.

## Findings

### A. Fixed before closing

1. **Medium: S3's CreateBucket with object lock or a public ACL failed on a cluster, after making the bucket.**
   - Its configuration went through `setBucketConfig`, which saw applied state only. The client got NoSuchBucket for
     a bucket that existed, unlocked.
   - **Fixed:** `setBucketConfig` takes a staged bucket, and a staged bucket keeps the versioning its request staged,
     which its lock needs.
   - **Tests:** `stagedBucketsAreConfiguredAndApplied`, and the cluster smoke.
2. **Medium: an ask's record could outlive its run.** A disabled job, a table with no metadata, a lost race or a
   failed plan writes no status, so the ask was never deleted and was re-run at every change of leader. A dropped
   table's asks were kept.
   - **Fixed:** a run of a table's kind clears its kept ask, whatever it did, in a gated step taken only when one
     exists. `removeTableMaintenance` removes a table's asks.
3. **Medium: a new leader could miss committed asks.** It listed them before it had applied the last term's
   committed tail.
   - **Fixed:** a leader lists them once it is caught up (applied = last = the core's last).
4. **Medium: leadership was tracked as a bool,** so a leadership lost and regained within one long run, or across a
   failed slot, was missed.
   - **Fixed:** the asks are queued once per term the node leads in.
5. **Medium: the step-down test passed without the clearing,** as a put after `setLeaderTerm(0)` is refused for not
   leading. It now uses a later term and expects NoSuchBucket. The drop on apply is now tested too (A1's test).
6. **Low: one unreadable ask hid them all.** A bucket's or an ask's read error is now passed over.

### B. Recorded, not fixed

1. **Deletes, tagging and other bucket setters** still see applied buckets only. A request that makes a bucket and
   deletes in it, or tags it, is refused NoSuchBucket. Only the IAM bucket and S3's CreateBucket configurations need
   it today.
2. **The IAM API's bucket** keeps its `NotReady` workaround (`appliesOnCommit`, which duplicates `isReplica`), though
   a request could now make it inline.
3. **The compaction permit is not fair:** waiters poll every 200 ms.
4. **The smoke's check of two shards** has 15 s of margin against a 20 s hold, and shows asks running side by side,
   not two compactions.
5. **The staged workload is swept once and for crashes,** not for torn or sticky faults.
6. **No test of `--tables-compactions`'s limits,** or of a compaction's permit given back on an error path. The
   permit is read correct.

## Where the code differs from ADR-0128

- **§1:** the writes that take a staged bucket are `checkPut` (every put), an upload's create and `setBucketConfig`.
  Deletes are not among them (B1). A staged bucket keeps its staged versioning.
- **§3:**
  - the key is `.s3tables/maintenance/asks/<table id>/<kind>`;
  - any run of the kind clears the ask, not only its status write;
  - a leader lists kept asks once per term, when caught up.
