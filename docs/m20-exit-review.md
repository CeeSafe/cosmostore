# M20 exit review: the recorded Lows of M15 to M19 (21 Nov 2026)

**M20's exit (ADR-0105 item A; ADR-0106, proposed):** each of the 26 Lows recorded by M15 to M19's exit reviews is
fixed, or decided to stay with a reason. The security ones come first.

## How it was checked

- **The evidence:**
  - **Unit tests (about 430):**
    - retiring keys, and the retiring set's order;
    - sessions naming their role's id, and tokens from before the field;
    - file users with no live key;
    - the restore record with its marks, its events, and its fault sweep (once, sticky, torn, crash);
    - restore expiry rounding;
    - key file digests, and the removal back-off.
  - **The S3 smoke:**
    - archived GETs refused before their conditions and range;
    - `RestoreStatus` in a listing;
    - restore events at a webhook;
    - a role made again under its name;
    - the roles file's roles, the account's keys, another account's role;
    - a replication target removed while its delivery waits;
    - the PyIceberg compaction checks, with footers now read off the lock.
  - **The cluster smoke (206):** a KMS key retired on every node, refused for new seals, its removal waiting and
    then taken.
  - **The SDK matrix:** boto3, Go, Java, JS and .NET, unchanged and passing.
- **Two runs found bugs before the review:**
  - **CreateRole right after DeleteRole answered EntityAlreadyExists.** The deleted API role was still in the live
    set and was taken for a roles file's. It was found by slice 4's smoke and fixed there.
  - **The ARN account check ran before its kind check,** so a `group/` ARN was taken. A unit test found it.
- **A review by a reader who had not written the code:**
  - **Found:** one Medium-High, three Mediums and five Lows.
  - **Reproduced:** one (finding 2), with a unit test in a scratch copy.
  - **Read only:** the others.

## Findings

### A. Fixed before closing

1. **Medium-High: the count could still miss a write sealed under a KMS key being removed.**
   - **Why:** a node's status gave its shard counts first and its keys line after. A write could commit between
     them, and the key then retire, all in one reply. The count read 0 with every node retiring.
   - **Fixed:** a node reports its keys before its counts. A leader checks a write's key and commits it under one
     hold of the store's lock, so once the keys line shows the key retiring, no count after it misses a write
     (ADR-0106 §1.1, amended).
2. **Medium: one version with no room for its restore mark stopped every restore's marks.**
   - **What else it stopped:** on `serve`, the rest of the upkeep; on a cluster, the shard's orphan sweeps.
   - **Fixed:** that version is skipped and no longer watched. A round that fails no longer stops the upkeep or the
     replica's maintenance.
3. **Medium: a roles file's role's sessions came back to life under an API role of its name.**
   - **Fixed:** a session's role id must match its role's now exactly, and a file role has none.
   - **The cost:** an API role's sessions from before the field are refused too, within their 12 hours at most. That
     fails closed (ADR-0106 §1.5, amended).
4. **Medium: removing the first KMS key refused default-KMS writes for the whole removal.**
   - **Fixed:** the retiring set takes the file's new order, so its first key seals by default at once. Only a first
     key that is itself retiring (new bytes under its id) refuses.
5. **Low: followers' restore watch lists never shrank.**
   - **Fixed:** followers drop the watches that are done with, writing nothing.
   - **Still true:** the duplicate check is a linear scan. Watched versions are the restored ones, so the list
     stays short.
6. **Low: compaction planning read up to 256 KB of every candidate.**
   - **Fixed:** it reads each candidate's last 8 bytes off the lock. Then it pins just the footer, under the lock and
     with the generation checked, and reads it off the lock.
7. **Low: two of ADR-0106's descriptions were wrong:**
   - **The recount (M17 B3):** it is one walk under the lock, not "in steps".
   - **The older-binary note:** it left out a cluster's rolling upgrade. Followers on an older binary stop applying
     once a new leader writes restore marks.
   - **Both are corrected.**

### B. Recorded, not fixed

1. **Low: a local replica refused because its key is retiring is not tried again** if the operator puts the key
   back. The source reads FAILED (its event is delivered and the destination lacks the version), as a refusing
   destination's does.

## The 26 Lows, and what became of them

- **Fixed (16):**
  - **M15:** B1 (by M17), B2 (in part), B3, B4, B5.
  - **M16:** B6.
  - **M17:** B2 (in part), B3, B4.
  - **M18:** B2, B3, B4 (all but SELECT), B5.
  - **M19:** B1, B2, B4.
- **Staying, with their reasons (7; ADR-0106, accepted with its choices):**
  - **M16:** B2, B3, B4.
  - **M17:** B5.
  - **M18:** B1, and SELECT restores.
  - **M19:** B3, B5.
  - **§1.3:** old sets, and the copies a move leaves (G42).
- **Proposed differently during M20, for the owner to decide (3):**
  - **M17 B1, to stay:** an envelope names its key's id, not its bytes, so nothing can re-wrap what old bytes under
    the first id sealed. The way out, a new id put first, works.
  - **M16 B1, to stay:** the lock is lost only as the server stops, when nothing can delete. Unreferenced file
    removal reclaims the files.
  - **M16 B5, as a design of its own:** a cluster's maintenance run is one leader write, and holds its shard's
    write gate throughout. The fix splits it into gated writes with the copy between them.

## Decisions for the owner

**Taken, 21 Nov 2026** (the owner: "Accept and close"; the three Lows "As proposed"):
- ADR-0106 is accepted as amended.
- M17 B1 and M16 B1 stay.
- M16 B5 is an item of its own, beside ADR-0105's B.
- M20 is closed, once CI passed on e0b12bc.

- **Accept ADR-0106,** with its amendments:
  - §1.1: keys before counts;
  - §1.3: G42, and lib/std's `Aes256Gcm` found to wipe;
  - §1.5: exact ids; file roles have none;
  - §2: the recount;
  - restore events, and their older-binary and rolling-upgrade consequences.
- **The three proposed differently:**
  - M17 B1 to stay;
  - M16 B1 to stay;
  - M16 B5 as an item of its own, beside ADR-0105's B (IAM for tools).
- **Close M20.**
