# M15 exit review: operations without restarts (20 Nov 2026)

**M15's exit (ADR-0095 item A; ADR-0096, proposed):** the roles, STS key, SSE-S3 and KMS key, and notification and
replication target files reload when they change, as the credentials file does. A master key a stored object needs
is not removed. On a cluster, `cluster-status` shows a node whose files differ.

## How it was checked

- **The evidence:**
  - **Unit tests:** 394, with `rolesReloadKeepTheirPlaces`, `versionsSealedUnderAKeyAreCounted`,
    `nodeFileDigestsCompared` and `keyRemovalsAreCheckedWhole`.
  - **The S3 smoke, all under a running server:**
    - a role removed, and its session refused;
    - a key added, then refused when removed or given new bytes;
    - a notification target added, then removed.
  - **The cluster smoke:** a node with a roles file of its own named by `cluster-status`; a key added on the nodes,
    and its removal refused.
  - **The SDK matrix.**
- **A review by a reader who had not written the code:** one finding reproduced, the others read.

## Findings

### A. Fixed before closing

1. **High: new bytes under a key's id were taken unchecked** (reproduced).
   - **Why:** the reload compared ids only.
   - **The effect:** a regenerated line, or a typo in one, would leave every version sealed under that key unopenable.
   - **Fixed:** a key kept with other bytes counts as removed, so the reload is refused while anything needs it.
2. **Medium: the count raced with writes already sealing under the key.**
   - **Why:** a PUT, POST, Copy, upload or replica that picked its key before the reload, and committed after the
     count, escaped it. Staged inline writes were not in the index the count read.
   - **Also missed:** a bucket whose default encryption names the KMS key.
   - **Fixed on `serve`:**
     - the count and the install happen under one hold of the store's lock;
     - the count commits staged writes first, and counts buckets whose default names the KMS key;
     - each sealed write checks its key is still in the set, under the same lock, just before it commits
       (`sealKeyHeld`). A write whose key was removed fails with InternalError, and its retry seals under a current
       key.
   - **On a cluster:** a node cannot count what other shards, unapplied entries and other nodes still seal. So a
     node now refuses any reload that removes or changes a master key. Adding one is taken.
     - **To retire a key on a cluster:** re-seal what it sealed, then restart the nodes with the new file.
     - **ADR-0096 §3 should say so.**
3. **Low: a lock failure let a removal through.** The count's lock error read as "nothing needs it". Now it
   refuses.
4. **Low: a roles reload that failed was not retried.** The file counted as read before its roles were installed.
   Now it counts only after.
5. **Low: the smokes checked less than they claimed.**
   - **The digest check:** it counted nodes instead of comparing their digests. It now checks the odd node differs
     and the others agree.
   - **The roles restore:** it did not wait for its reload. It now waits.
   - **Key files on a node:** they were not tested. The cluster smoke now does.

### B. Recorded, not fixed

1. **Low: a key removal holds the store's lock for a full count.**
   - **The cost:** the count walks every version in memory, once per removed key. On a store of millions of
     versions, requests wait for it, which is far past ADR-0029's 10 ms mark.
   - **Why it stays:** the lock is what makes the count exact (A2), and a removal is a rare operator act.
   - **Later:** a count kept per key as versions are written would make it immediate.
2. **Low: old secrets stay in memory for the process's life.**
   - **What stays:** every past set of keys, roles and targets, in write-once cells, so a removed master key, a
     revoked STS key and an old replication secret are never wiped. The node also keeps its start-time copies.
   - **None is logged or sent.**
   - **Before:** M13's review recorded the same of master keys.
3. **Low: a local replica whose source was deleted meanwhile is not checked at commit.**
   - **What happens:** a replica copies its source's envelope. If the source is deleted between the count and the
     copy, the count can pass and the replica commit under the removed key.
   - **The other sealed writes are checked (A2).**
4. **Low: the digests are of the files on disk.** A node that refused a reload shows the file it was given, not the
   keys it uses, so `# files agree` can hold while two nodes' keys differ. That is ADR-0096 §6 as amended, and the
   refusal is logged on the node.
5. **Low: no smoke removes a target while its deliveries wait.** The unknown target's path is the one tested
   before M15.

## Decisions for the owner

- **Taken, 20 Nov 2026** (the owner: "Accept and close"): ADR-0096 accepted with its amendments, and M15 closed.
  - **The amendments:**
    - §5: targets keep no places;
    - §6: the digests are in the status answer;
    - §3: a node refuses a master key's removal or change (A2).
