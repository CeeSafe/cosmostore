# M22 exit review: table maintenance on a cluster as gated writes (23 Nov 2026)

**M22's exit (ADR-0109 item A, with M21's B1 and B2; ADR-0110, proposed with the owner's choices):**
- a cluster leader's table maintenance is its own run of gated steps, not one request holding the shard's gate;
- a write to the shard goes through while a compaction runs;
- a run past the front's 30 s completes;
- a leader killed mid-run leaves the table readable, and a new leader compacts it;
- compaction is swept for faults and crashes at every I/O point;
- bucket policies name users with paths;
- the IAM record has AWS's remaining quotas.

## How it was checked

- **The evidence:**
  - **Unit tests (447):**
    - compaction of a two-file fixture table, its first unit test;
    - the compaction sweep, once, sticky, torn and as a crash at every I/O point. The table must read as before or
      after, every named file there at its size, and its rows read from the Parquet footers;
    - bucket-policy principals with paths;
    - inline policies' sizes and the quotas.
  - **`tools/cluster_maintenance_smoke.sh` (17 checks, in CI):**
    - a run of 41 s, with a write to its shard meanwhile in 0.0 s;
    - the leader killed mid-run, the rows kept, and the new leader compacting;
    - `maintenance-run` asked through two nodes and answered at once, and a kind not done refused.
  - **The cluster smoke (209):** its PyIceberg, maintenance and compaction checks run through the leader's steps.
  - **The rest:** the S3 smoke, the SDK matrix, and the Terraform check.
- **Runs found bugs before the review:**
  - **The cluster smoke's first run:** the compaction plan wrote its job status off the gate. Those entries were
    proposed by no one, so every later write to the shard answered 503. The plan is now a gated step.
  - **My local cluster runs before M22 had not set `ICEBERG_PYTHON`,** so their maintenance checks were skipped. CI
    sets it, so CI had run them.
  - **An older test's `user/bad/name`** is a valid ARN since slice 6. It became `user/bad name`.
- **A review by a reader who had not written the code:**
  - **Found:** two Mediums, one Low-Medium and four Lows.
  - **How:** all read only. Each was checked against the code before fixing, and finding 1 was narrowed (below).

## Findings

### A. Fixed before closing

1. **Medium (narrowed): a failed commit on a cluster could not delete what it wrote in its own step.**
   - **Why:** a raft store's delete reads applied state, and the step's new manifests, list and metadata were staged,
     not applied.
   - **The reviewer's scenario cannot happen:** a client's commit to the table mid-run. The commit step holds the gate,
     so nothing changes inside it, and a table changed before it is caught on entry, before anything is written. Its
     bins, applied in earlier steps, are deleted.
   - **What remained:** the failures after the writes, a manifest that does not fit its schema or a store error.
   - **Fixed:** a failed commit hands back what it wrote, and the cluster deletes it in one more gated step (ADR-0110
     §2).
2. **Low: running out of memory after a bin's put left its entries unproposed,** so the shard's later writes answered
   503 and the loop ended.
   - **Fixed:** the step is committed, and then the run ends.
3. **Medium: the crash sweep was weaker than ADR-0110 §6.**
   - **Fixed:** rows are read from each file's Parquet footer and must match the manifest, and the plain run's job
     status must be Successful.
   - **Not fixed (B1):** it runs on a single-node store, and no removal follows it.
4. **Low-Medium: the asked-runs queue.**
   - **Fixed:**
     - an ask made while its job runs is answered by that run, not run again (§5);
     - the smoke sends asks through two nodes;
     - `runMaintenance`'s comment now says what a cluster does.
   - **Not fixed (B2, B3):** an ask lost to a change of leader, and one loop for every shard.
5. **Low: a run was not tied to a term.** Each step now requires the term the run began in (§1).
6. **Low: `user/` and `user/a/` principals answered NotImplemented.**
   - **Fixed:** they answer MalformedPolicy.
   - **Removed:** `configuredUserAt`'s unused `anyPath`.
7. **Low: inline sizes counted bytes.** They count UTF-8 characters, as AWS does.

### B. Recorded, not fixed

1. **The sweep runs on a single-node store.**
   - **What it does not see:** a cluster's staged-but-not-applied entries.
   - **What covers that instead:** the cluster maintenance smoke, with a leader killed mid-run.
   - **Not in it:** removal after the run, and the check that leftovers are only unreferenced files. Removal re-reads
     the table's metadata under the gate before it deletes, and that read was found sound.
2. **An ask is lost if the shard's leader changes, or the node restarts, before the loop takes it.** It was answered
   204. The day's pass runs every job within the hour anyway.
3. **One loop serves every shard a node leads, in turn,** so a long compaction delays the other shards' passes and
   asks. Each shard's writes are not held up, which was M22's aim.
4. **The 5,000-user quota counts the IAM API's users only,** not the users file's, which are the operator's (ADR-0104
   §5).
5. **`user//x` is taken as a path,** as `iamPathOk` takes it for CreateUser. The reviewer read AWS as refusing it.
   AWS documents the path pattern as `(\u002F)|(\u002F[\u0021-\u007E]+\u002F)`, whose middle range includes `/`,
   so it takes `//` too.

## Where the code differs from ADR-0110

These are in its As built section, amended here:
- **§1, the runner:** the cluster's own run of the shared step functions, since a closure cannot reach
  `Async.blocking`.
- **§1, terms:** each step requires the run's term (finding 5).
- **§2:** the plan is a gated step too, as it may write the job's status. A failed commit's files are deleted in one
  more step (finding 1).
- **§4:** removal's sweep is one gated step, not batches of 1,000.
- **§6:** the cluster's crash check is the smoke, not in-process replicas (B1).
