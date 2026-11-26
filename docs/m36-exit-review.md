# M36 exit review: table replication (26 Nov 2026)

**M36 closed, 26 Nov 2026** (the owner: "Yes, I accept ADR-0138 and close M36"), with ADR-0138 accepted and B1 to B7
recorded below.

**M36's exit (ADR-0137 item A, with M35's B1 first; ADR-0138, with the owner's choices):** S3 Tables' eight
replication calls, replicas that read as their sources after each commit through the CLI, boto3, PyIceberg and Iceberg
Java, on `serve` and on a cluster; and the orphan sweep's reads off the store's hold.

## How it was checked

- **Unit tests:**
  - slice 0: `orphanFinishSeesChangesSinceItsReads`, `orphanSweepHoldMeasured` (2,000 tables in CI; 10,000 measured:
    the longest hold 38 to 74 ms against 192 to 435 ms, on a loaded machine);
  - slice 1: `replicationConfigurations` (tokens, Conflict, limits, a configuration's Put asking for its tables, the
    cluster's account-only destinations);
  - slice 2: `replicaPathsSwapped`, `replicaManifestsSwapped`, `replicaPuffinSwapped`, `replicaPositionDeletesSwapped`,
    `replicaCopied`, `replicationAskedAndAnswered`;
  - slice 4 and this review: `replicaNotMadeOnceRemoved`, `replicaIdsNotShared`;
  - mutation-checked: the finish's change check, the rewrites' bounds and Puffin length, the copy's metadata and
    delete rewrites, the replica's commit refusal, the configuration's removal, the replica id's reuse, and the
    version's order.
- **The S3 smoke:** the six configuration calls through the CLI.
- **PyIceberg** (`iceberg_check.py`, 77), on `serve` and through a cluster's node with source and replica on shards 2
  and 1 of 8:
  - a table bucket replicated;
  - an append and a delete read from the replica;
  - its marks;
  - an append to it refused;
  - disassociated (boto3), then appended.
- **Iceberg Java** (`iceberg_java_check.py`), plain and on a KMS table bucket: a v3 table with a deletion vector
  replicated, its replica read with the same rows and its deletion vector.

- **After the review's fixes:** 570 unit tests, the S3 smoke, the cluster S3 smoke (214) and the Java check (60
  plain, 63 on KMS). CI is green for slices 0 to 4 (`e69be35` to `432ca57`).

## The review

An independent agent, reading only, given the diff `4318e99..432ca57`, ADR-0138 and the rules. It found nothing
that deletes or corrupts a source table, and the orphan sweep still errs only towards keeping. **One High, four
Mediums.**

### A. Found and fixed

1. **High (H1): two tables at one replica id.** A copy reused the id kept in its source's status even when another
   record at the destination held it, or a dropped replica's purge was still running. Their files would then have
   been deleted by each other's removal or purge. This can happen after a rename of the source or of the replica,
   or after a replica is deleted. Now:
   - an earlier copy's id is reused only while its configuration names this replica's namespace and name (a
     dropped table's goes with it), and no table record holds the id (`replicaIdFree`);
   - a replica's rename is refused.
2. **Medium (M1): a failed copy waited for its source's next commit.** Reconcile now treats a failed status as
   behind, so each maintenance pass tries it again.
3. **Medium (M2): a copy that found its files there could name files deleted meanwhile.** These are files of an
   earlier failed copy, which the sweep or unreferenced removal may delete. Before its finish, the copy checks that
   every file it names is still there:
   - on `serve`, under the finish's hold;
   - on a cluster, by HEADs through the front (see B4).
4. **Medium (M3): a late copy could move a replica back.** The replica's record keeps its source's metadata version
   (`sourceVersion`), and a finish of an earlier one is refused.
5. **Medium (M4): on a cluster, another shard's destination was not authorized.** Its policies are not read there, so
   only the account's keys may name one; a user or a role's session is Forbidden.
6. **Lows:**
   - L1: a table bucket's Delete takes no token, as AWS's model; a token for a configuration that is not there is
     NotFound;
   - L2: one rule of one to five destinations, as AWS's model;
   - L3: a position delete file's `file_path` bound that cannot be swapped is dropped, not left naming the source;
   - L4: a format 1 snapshot that names its manifests itself fails the copy with its reason;
   - L6: a replica is not a source (PutTableReplication on one is BadRequest, and none is copied on);
   - L7: a dropped source's ask and statuses go with it.

### B. Recorded, not fixed

1. **Files over 64 MiB on a cluster (L5)** fail the copy with their reason. Sending them in parts (as S3's replicas
   go, ADR-0078 §4) is the next step, and it matters: data files are often larger.
2. **`role` is checked for its shape only (L2's rest),** not that this server knows it; copies run as the server.
3. **A full scan per call (L8):** `tableKeyOfId` reads every table record under one hold, for each status,
   configuration and copy call. An index by id would end it.
4. **Narrow races left:**
   - on a cluster, a file's HEAD and the finish are two requests (M2's rest);
   - `replicationStillNames` is read before the finish, not in its step, so a Delete in between still gets one last
     replica made (L9).
5. **`write.*.path` values an engine set under another id** (L4's rest) are left naming the source. The catalog
   refuses them since M35, but not in metadata an engine writes itself.
6. **Values the model does not give,** chosen here: a Put's `status` (`Successful`) and `managedByService`
   (`replication.s3tables.amazonaws.com`).
7. **The review's other missing tests:**
   - a real engine's position deletes (PyIceberg deletes copy-on-write; Java's check writes a deletion vector);
   - two concurrent copies of different versions on a cluster;
   - a client outside the cluster sending `x-cosmo-replica-table` or `_replica/*`.
