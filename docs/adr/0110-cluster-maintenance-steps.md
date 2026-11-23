# ADR-0110: table maintenance on a cluster as gated writes (M22)

**Status:** accepted, 23 Nov 2026, as amended by its As built and exit-review sections (the owner: "Accept and
close"). Proposed the same day with the owner's choices:
- a test-only pause for the long run;
- a client's maintenance-run on a cluster answered at once.

## Context

- **On `serve`:**
  - `tablesMaintenanceForever` (`table_maintenance.cee:545`) wakes every `dayMs / 24`.
  - For each table it runs snapshot management, then compaction, then unreferenced-file removal.
  - Each step takes the store's lock for itself. `compactTable` (`table_compaction.cee:1202`) runs in order:
    1. plan the run (locked);
    2. read the footers (off the lock);
    3. pin them (locked);
    4. for each bin: prepare it (locked), copy its bytes into a new extent (off the lock), put it as
       `compacted-<uuid>.parquet` (locked, IfAbsent);
    5. commit (locked): the new manifests, the list, and `swapMetadata`, on the table record's generation.
  - A table changed meanwhile fails the commit. The run then deletes what it wrote, and the next run tries again.
- **On a cluster:**
  - `tablesMaintenanceClusterForever` (`tables_maintenance_cluster.cee:94`) runs on each node, for the shards it
    leads. It sends each job as one signed `POST …/maintenance-run?type=` to its own front.
  - The front sends that request to `leadWrite` (`front.cee:483`). It holds the shard's write gate
    (`ShardSlot.gate`) from the forward to the commit, so the job is one write:
    1. the S3 server runs the whole job, staging entries;
    2. `pushExtents` reads each staged extent whole and pushes it to every voter and learner;
    3. `proposeStaged` proposes the entries;
    4. the leader waits until they are applied.
  - **Three costs:**
    - **The gate:** every other write to that shard waits for the whole job.
    - **The timeout:** the forward is under the front client's 30 s total (`front.cee:278`). A long run is cut
      off, and its staged entries are abandoned.
    - **Memory:** every bin's bytes are held at once, at the push.
  - **Staged entries are not applied,** so a job cannot read its own writes. This is why each job is its own request
    (`table_maintenance.cee:143`).
- **No fault sweep covers table maintenance** (`table_maintenance_tests.cee` has functional tests only). M20's
  restore record has the pattern to follow: `restore_record_tests.cee:85`, once, sticky, torn and crash at each I/O
  point.

## Decision (proposed)

1. **A gated step.** A cluster leader's maintenance is a run of steps. Each step that writes is one gated write of
   its own:
   1. take the shard's gate;
   2. run the step against the store, under its lock, staging entries;
   3. push the step's extents, then propose and wait until applied, as `leadWrite` does after its forward;
   4. let the gate go.

   A step's writes are applied before the next step starts, so the run reads its own writes.
   - **The hook:** a step is given to the S3 app's step runner. On `serve` the runner is the store's lock, as now. On
     a cluster it is the shard's gated step. The job code is the same for both.
   - **Not the leader:** a step that finds this node no longer the leader, or its term changed, ends the run. What
     the run wrote so far is unreferenced. Unreferenced removal takes it after the table's retention, as for any
     failed run.
2. **Compaction as steps:**
   - **Off the gate:** the plan and the footers are read from the applied store, under its lock.
   - **Each bin:**
     - its bytes are copied into a new local extent, off the gate and off the lock;
     - its put is then one gated step, with its own extent push.

     Only one bin's bytes are held at a push.
   - **The commit** is one gated step: the manifests, the list, `swapMetadata` on the record's generation, and the
     job status. A table changed meanwhile fails it, as on `serve`, and the run deletes its bins in one more step.
   - **A bin is no snapshot's until the commit.** A reader between steps sees the table as before; after the
     commit, as after.
3. **Snapshot management** is one gated step, as it is one locked step on `serve`.
4. **Unreferenced removal:**
   - the plan is read off the gate;
   - the deletes are gated steps of at most 1,000 keys each;
   - the job status is the last step.
5. **The run is the leader's, not a request:**
   - **The loop:** `tablesMaintenanceClusterForever` runs each job's steps itself, for the shards this node leads,
     and no longer sends itself a request. No front timeout applies to a run.
   - **A client's `POST …/maintenance-run` on a cluster:** it goes to the shard's leader as now. The leader starts
     the job's run on its own and answers at once, with 204, as `serve` answers when the run is done. The job's
     status reads as GetTableMaintenanceJobStatus shows it.
   - **One at a time:** a table already being maintained by this leader is not started twice. A second ask while
     one runs is answered as the first.
6. **The crash sweep (the owner's bar):**
   - **The store's, as M20's restore record's:** a compaction run on a table, then snapshot management, then a
     removal. At each I/O point the injector fails once, sticky or torn, or the store crashes there. The store is
     reopened and checked:
     - the table's metadata names only files that are there;
     - it reads the rows it had;
     - its metadata is the old or the new, never a third;
     - what a run left behind is only unreferenced files, which a later removal takes.
   - **The cluster's:** in-process replicas (`replica_tests.cee`'s `sweepCluster`) run the stepped compaction. The
     leader is stopped before and after each step. A new leader is elected, and the table on every replica is
     checked as above.
   - **The ordering rule (ADR-0001):** a step's job status, or the table's new metadata, is published only after
     its batch is synced. The sweep's crash mode checks it.
7. **A run longer than the front's timeout:** a run takes no request's time (§5), so its length is bounded by
   nothing but its work. How the check shows it is the owner's, below.
8. **M21's B1 and B2,** as the last slices:
   - **B1:** a bucket policy may name a user by an ARN with its path, matched with the credential set's paths
     (M21's finding 5).
   - **B2:** AWS's default quotas for the IAM record:
     - 5,000 users and 1,000 roles;
     - the total size of a user's inline policies, 2,048 characters; a role's, 10,240; a group's, 5,120.

## Slices

1. The gated step on a cluster (§1), and the S3 app's step runner; `serve` unchanged.
2. Compaction as steps (§2), run by the leader's loop (§5), and a client's maintenance-run on a cluster.
3. Snapshot management and unreferenced removal as steps (§3, §4).
4. The crash sweep, the store's and the cluster's (§6).
5. The cluster smoke:
   - a write to the shard goes through while its compaction copies;
   - a long run completes (§7);
   - the PyIceberg checks read every row.
6. M21's B1.
7. M21's B2.
8. The exit review.

## For the owner to decide

- **How the cluster smoke shows a run longer than the front's 30 s:**
  - **A test-only pause (recommended):** `node --tables-copy-pause-ms <n>`, named as a test option in `--help`,
    which waits that long between a bin's copy and its put. The smoke sets it so a run lasts about 40 s, and writes
    to the shard meanwhile.
  - **A table large enough:** bins of a few GB, a run of minutes and as much disk.
- **What a client's maintenance-run answers on a cluster (§5):**
  - **At once, the run started (recommended):** status via GetTableMaintenanceJobStatus.
  - **When done, as on `serve`,** up to the front's timeout, then the run continues and the call answers 503.

## Consequences

- **A compaction's commit on a cluster is no longer one write with its bins.** A leader lost between a bin and the
  commit leaves an unreferenced file, as a failed run on `serve` does, and removal takes it.
- **Maintenance holds the gate only for short steps:** a bin's put and push, and the commit. A write to the shard waits
  for at most one of them.
- **A bin's extent is still pushed whole,** one bin at a time. Its size is bounded by the compaction's target file
  size.

## As built (slices 1 to 5)

- **The gated step** (`src/cluster/tables_steps.cee`):
  - `stepReady` waits, under the gate, until this replica leads and has applied everything;
  - `stepCommit` pushes the step's extents, proposes, and waits until applied in its term.
- **The runner, narrower than §1:** the cluster has its own short run of the same step functions `serve` calls,
  rather than one runner both use.
  - **Why:** a closure is not `Share`, so it cannot be given to `Async.blocking` on a worker thread, and the steps
    must run there.
  - **What is shared:** the steps themselves: plan, footers, prepare, copy, put, commit; removal's read and its
    finish.
- **Compaction (§2):**
  - **Gated steps:** the plan, each bin's put, and the commit. The plan is gated because it may write the job's
    status.
  - **Off the gate:** the footers and the bins' copies.
  - **The bug that showed it:** the cluster smoke's first run had the plan off the gate. Its status writes were
    staged and proposed by no one, so every later write to the shard answered 503.
- **Removal (§4), narrower:** its reads are off the gate, and its sweep is one gated step, not batches of 1,000.
  - **Why:** the sweep's deletes are small entries with no extents to push.
- **The run (§5):**
  - **The loop:** `tablesMaintenanceClusterForever` runs the steps itself every hour of a day, and the asked runs
    within a second.
  - **The ask:** a client's `maintenance-run` on a cluster is authorized as before, queued on its shard's S3 app
    (`askedRuns`, deduplicated) and answered 204.
  - **Removed:** the old self-request, `maintenanceRunThroughFront`.
- **The crash sweep (§6):**
  - **The store's:** `table_compaction_tests.cee` builds a table of two Parquet fixtures, with PyIceberg's fixture
    manifests pointed at them. Its compaction is swept once, sticky, torn and as a crash at every I/O point, and the
    table must read as before (2 files) or after (1 file), every named file there at its size, with its 5 rows.
    This is also compaction's first unit test.
  - **The cluster's, narrower than §6:** it is `tools/cluster_maintenance_smoke.sh` on a real cluster, not
    in-process replicas, whose harness has no front or gate. The shard's leader is killed mid-run. The table reads
    the same rows, and the new leader compacts it.
- **§7, the long run:** `node --tables-copy-pause-ms` (a test option). The smoke's run takes 40 s, and a write to
  its shard meanwhile takes under 3 s. CI runs this smoke.

## Amended by the exit review (`docs/m22-exit-review.md`)

- **§1, terms:** each gated step requires the term its run began in. A change of term ends the run.
- **§2, a failed commit's files:** they are handed back, and deleted in one more gated step, as a step's own writes
  are not applied within it.
- **§2, out of memory after a bin's put:** the step is committed, so nothing it staged waits unproposed, and then the
  run ends.
- **§5, asks:** an ask made while its job runs is answered by that run.
- **§6, the crash sweep:** it reads each file's rows from its Parquet footer and checks the job's status.
- **Recorded, not fixed:** the review's B1 to B5.
