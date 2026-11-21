# ADR-0106: The recorded Lows of M15 to M19 (M20)

**Status:** proposed, 21 Nov 2026, with the owner's choices made: the KMS race closed by retiring, then counting
("Retire, then count"), and the Lows that stay accepted with their reasons ("Accept them"). M20 is item A of ADR-0105
(the owner: "A: the recorded Lows", all of them, the security ones first).

## Context

- **What there is:** 26 Lows recorded across M15 to M19's exit reviews, each with what it is and why it stayed.
- **The rule for M20:** each one is fixed, or decided to stay with a reason the owner accepts.
- **Already fixed:** one (M15 B1, below) by a later milestone.

## Decision (proposed)

### 1. The security Lows, first

1. **A KMS key named in a request can still be sealed under, during a removal (M17 B4).**
   - **The race:** a node counts the versions sealed under the key, then takes the removal. A write naming the key
     explicitly, made on another node in between, is sealed under the key. The node that took the removal refuses
     it at commit, but another node can commit it.
   - **The fix proposed: retire, then count.**
     - **Retiring:** a removal first marks the key retiring in every node's set, through the same reload.
     - **A retiring key:** opens what it sealed, but seals nothing new; a write naming it answers KMS.KMSInvalidStateException
       (400), as AWS does for a key pending deletion.
     - **The count:** taken only once every node reports the key retiring (`# keys` status lines, as M17's are). It
       then reaches 0 and stays there.
   - **The other way:** every sealed write's commit checks the key against a cluster-wide list. That is a check per
     write, across the log.
2. **A local replica whose source was deleted meanwhile is not checked at commit (M15 B3).**
   - **The fix:** a replica's commit checks its envelope's key against the set, as the other sealed writes do
     (M15 A2).
3. **Not every copy of a key's bytes is wiped (M17 B2), and old secrets stay in memory (M15 B2).**
   - **Wiped, newly:** every vector of master keys is reserved at its full size before a key goes in, so none
     grows and leaves an old buffer behind. That covers the key file's keys, a set's copies, and the retiring set.
   - **Already wiped, found in slice 2:**
     - **A removed master key:** `KeySets.replace` already zeroes every earlier set's copy of a key the new set
       does not hold (ADR-0100 §5). A retiring key keeps its bytes until its removal is taken, then goes the same
       way.
     - **lib/std's `Aes256Gcm`:** it wipes its schedule in its `drop` (CeeSafe ADR 0135, checked at v0.54.0). M17
       B2 recorded it as not wiped, which was wrong about the library.
   - **Staying, with a reason:**
     - **Old credential, role and target sets:** requests read them without a lock, from write-once cells. Wiping a
       set a request may still read would need a lock or a count of readers on every request. None is logged or
       sent.
     - **Copies a move leaves behind:** a value moved out of a stack slot, and a growing buffer in a library, keep
       their bytes. That is the language's, logged as G42 in `CEESAFE_GAPS.md`. `HmacSha256` has no wiping `drop`,
       still true at v0.59.0 and already logged as G34.
4. **An archived GET checks its conditions and range before its class (M18 B2).**
   - **The fix:** the class is checked first, so an archived version not restored answers 403
     InvalidObjectState, whatever its Range or If-None-Match. That is S3's order.
5. **A role deleted and made again under its name revives the old role's sessions (M19 B1).**
   - **The fix:** a session names its role's id (`AROA…`). A session whose role's id is not the role's now is
     refused (InvalidToken), as users' grants are matched by name and id (M11).
   - **The roles file's roles (amended in slice 4):** they have no id, as the file has none to give. A file role
     removed refuses its sessions while it is out of the file (ADR-0096 §2). Putting it back is the operator's act,
     as before.
   - **Sessions from before the change** do not name an id. They stay valid until they expire, at most 12 hours.
6. **CreateUser can take the name of a users file's user with no key (M19 B2).**
   - **The fix:** the files' names come from the users file itself, keyed or not, not from the live set.

### 2. Key rotation's rest

| Low | Decided |
|---|---|
| M15 B1: a removal holds the lock for a full count | **Fixed in M17:** the count is the index's, kept as versions are written (ADR-0100 §1). Recorded as fixed. |
| M15 B4: the status digests are of the files, not the keys in use | **Fixed:** the digest is of the keys a node uses, so `# files agree` means the keys agree. |
| M17 B1: new bytes under the first key can never be taken | **Proposed to stay (amended in slice 5, the owner's to decide at the exit review):** an envelope names its key's id, not its bytes. Once new bytes take the id, nothing opens what the old bytes sealed, so no re-wrap can move it. A fix would change the envelope's format. **The way out works:** put a new id first; the old key's versions re-wrap under it, and its removal is then taken. The refusal's message says so. |
| M17 B3: counts unknown (out of memory) refuse every removal until a restart | **Fixed:** the node walks to count again in its next upkeep, off the lock and in steps, and its counts are known again. |
| M17 B5: a node's re-wrap gate is up to 10 s old | **Stays:** the operator's rule never removes the first key, and such a removal is refused anyway. |
| M18 B5: a waiting removal is asked of every node every 2 s | **Fixed:** the asks back off, doubling to 60 s, and reset when the file changes. |

### 3. Compaction's rest

| Low | Decided |
|---|---|
| M16 B1: a run that loses the lock leaves the files it put | **Proposed to stay (amended in slice 6, the owner's to decide at the exit review):** the lock is lost only when the store closes, as the server stops, and nothing can delete then. Unreferenced file removal reclaims them after its age, as M16 recorded. A failed put or commit already deletes what it wrote. |
| M16 B2: the joined footer keeps the first input's key-value metadata | **Stays:** the inputs share schema, writer and column orders, so it describes them all. |
| M16 B3: page indexes and bloom filters are dropped | **Stays:** ADR-0098 §1's choice. Row-group statistics still skip. |
| M16 B4: only files of the same writer join | **Stays:** by design. A reader may work around a writer's quirks by its name. |
| M16 B5: on a cluster, compaction runs inside a request under the front's timeout | **Proposed as a design of its own (amended in slice 6, the owner's to decide at the exit review):** the request is one leader write. `leadWrite` holds the shard's write gate from the forward to the commit, so a long run also holds up that shard's other writes, not only the timeout. The fix splits a run into gated writes (each bin's put, then the commit), with the copy between them outside the gate, each with its own extent push and proposal. That is more than this table's fixes, so it is proposed as ADR-0105's next item, beside B. Not seen at test sizes. |
| M16 B6: footers are read under the store's lock | **Fixed (slice 6):** the plan pins each candidate's tail (its last 256 KB) under the lock. The footers are read and parsed off it, and the bins made there. The generation is checked again before each copy, as it already was. A longer footer's file is not joined that run. |

### 4. Archive classes' rest

| Low | Decided |
|---|---|
| M18 B1: a nearly full version cannot be restored | **Stays:** it takes about 16 KB of headers and tags, and the way out (removing its tags) is in the error's message. |
| M18 B3: the restore's expiry is the exact time | **Fixed:** rounded up to the next midnight UTC, as S3 does. |
| M18 B4: not done (restore events, `RestoreStatus`, SELECT restores) | **Done:** `s3:ObjectRestore:Post`, `:Completed` and `:Delete` events, and ListObjectsV2's `RestoreStatus`. **Stays:** SELECT restores (S3 retired them). |

### 5. IAM's rest

| Low | Decided |
|---|---|
| M19 B3: a deleted user's key works until the next round | **Stays:** ADR-0104 §4's choice. AWS's IAM is eventually consistent too. |
| M19 B4: compatibility | **Fixed:** ListRoles and GetRole show the roles file's roles, as ListUsers shows the users file's users; ListAccessKeys with the account's key lists its keys; ServiceFailure is a Receiver error; an IAM ARN's account is checked. |
| M19 B5: groups, managed policies, tags and more | **Stays:** ADR-0105 item B, a milestone of its own. |

### 6. Tests

| Low | Decided |
|---|---|
| M15 B5: no smoke removes a target while its deliveries wait | **Fixed:** the S3 smoke removes a replication target with deliveries waiting, and checks they fail as the unknown target's do and are not lost. |

## Slices

1. **Sealed writes:** retire, then count (§1.1), and the replica's commit check (§1.2), with their fault sweeps.
2. **Key bytes** (§1.3), and G42 logged.
3. **S3's order and the archive's rest:** §1.4 and §4.
4. **IAM:** role ids in sessions (§1.5), the files' names (§1.6), and §5.
5. **Key rotation's rest** (§2).
6. **Compaction's rest** (§3).
7. **The target smoke** (§6), and the exit review.

## For the owner to decide

- **The KMS race:**
  - **Retire, then count (recommended):** a key being removed seals nothing new on any node before it is counted.
    Writes naming it are refused during the removal.
  - **Check every sealed commit:** no new state, but every sealed write checks a cluster-wide list.
- **The Lows that stay:** M16 B2, B3 and B4; M17 B5; M18 B1 and SELECT restores; M19 B3 and B5; and, in §1.3, old
  sets, and the copies a move leaves behind (G42, found in slice 2 in place of lib/std's key schedule, which is wiped).

## Consequences

- **The store:** sessions carry a role id, so an older binary refuses sessions issued by a newer one. That costs
  nothing a restart would not, since sessions do not outlive their keys' sets.
- **Restore events (§4, decided in slice 3):**
  - **How they work:** a restore's state takes an optional mark after its class, ` c` once its :Completed event is
    raised and ` d` once its :Delete is. The upkeep writes the marks as their times come, on `serve` and as a write
    on each shard's leader.
  - **Which event:** it comes from the state before and after, as the record applies, so replay raises the same
    ones.
  - **Older binaries:** an older binary refuses a restore record with a mark, so it cannot open a store holding one.
    A notification rule naming restore events reads as no rules to an older binary.
- **The cluster:** a new `retiring` mark in the key sets and their status lines, so nodes on an older binary do not
  report it. A removal waits until every node does, as M17's removals wait for every node's count.
