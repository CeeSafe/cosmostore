# ADR-0097: M16, what comes after operations without restarts (proposed)

**Status:** decided, 20 Nov 2026: the owner chose C ("C: Tables compaction"), against the recommendation; ADR-0098
designs it. For A, when it comes, the owner chose re-wrapping on its own once a key is not first. Proposed the same
day. The owner: "propose M16". M15 (operations without restarts, ADR-0096) closed the
same day.

## Context

- **Retiring a master key is still manual** (ADR-0096 §3 as amended):
  - **The operator re-seals every version under it,** with a CopyObject onto itself per version. That rewrites
    each object's bytes, and makes a new version in a versioned bucket.
  - **On a cluster, a key cannot be removed while nodes run:** a node cannot count what other shards, unapplied
    entries and other nodes still seal. Retiring one takes every node's restart.
  - **Why it matters:** this is what a key compromise asks for first.
- **What makes it cheap:** an envelope only wraps the version's data key (ADR-0046 §3). Moving a version to another
  master key re-wraps 32 bytes in its metadata; the object's bytes stay as they are. A metadata-only record, as tags
  are (ADR-0017), can carry it through the journal and through a shard's log.
- **Left by M15's review (docs/m15-exit-review.md B1 to B5):**
  - a key removal holds the store's lock for a full count;
  - old secrets stay in memory;
  - a local replica of a deleted source is not checked at commit;
  - the digests are of the files on disk;
  - no smoke removes a target with deliveries waiting.
- **Still refused or missing:**
  - the archive storage classes, GLACIER and DEEP_ARCHIVE, whose reads need RestoreObject (ADR-0090 §1);
  - compaction for S3 Tables (ADR-0087 §4).

## Decision (proposed)

1. **M16 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Key rotation without re-sealing | **Re-wrap:** every version and upload sealed under a key that is not its file's first is re-wrapped under the first, in the background, by a metadata-only record. The object's bytes and version ids stay as they are. **Counts:** per key, the versions still under each key are kept as writes happen, so a removal's check is immediate (M15's B1). **Status:** `/_cosmostore/stats` and `cluster-status` show the counts. **On a cluster:** each shard's leader re-wraps through the shard's log. A node takes a master key's removal once every shard's leader reports none under it, asked as `cluster-status` asks. **Secrets:** a removed key's bytes are wiped once no set holds it (M15's B2). |
   | B | Archive storage classes | GLACIER and DEEP_ARCHIVE are taken on writes and transitions. An archived object's GET is InvalidObjectState until RestoreObject is asked. After a restore time (configurable, minutes for tests) it reads for the days asked, HeadObject shows `x-amz-restore`, and it goes back to archived after. The bytes stay where they are: the time is a model of S3's. |
   | C | Compaction for S3 Tables | A Parquet reader and writer, enough for Iceberg's data files. A `binpack` strategy rewrites a partition's small files into files of `targetFileSizeMB`, committed as a `replace` snapshot. PyIceberg reads the same rows after. |

2. **The recommendation is A.**
   - **Why:** it finishes what M15 started. Key rotation becomes an edit to a file, on `serve` and on a cluster,
     with no restart and no rewritten bytes.
   - **What it fixes on the way:** M15's B1 (counts kept as writes happen, not walked under the lock) and B2 (old
     key bytes wiped).
   - **What it stands on:**
     - ADR-0046's envelopes;
     - ADR-0017's metadata-only records;
     - the per-shard leaders that apply lifecycle (ADR-0089 §6);
     - M15's reloadable key sets.
   - **What it must decide:** when re-wrapping starts.
3. **B stays the next candidate:** a model of the archive tiers, for clients and tools that exercise RestoreObject.
4. **C is not recommended now,** as ADR-0087, ADR-0089, ADR-0091, ADR-0093 and ADR-0095 said.
5. **Not in M16:**
   - the IAM API;
   - a KMS service;
   - SNI and HTTP/2, which are CeeSafe.Web's;
   - S3 Metadata tables and S3 Vectors.

## For the owner to decide

- **Which item is M16:** A (recommended), B or C.
- **For A, when re-wrapping starts:**
  - **On its own (recommended):** once a key is no longer first in its file, the upkeep re-wraps what it sealed, a
    batch per round. A rotation is then: put the new key first, wait for its count to reach zero, remove the old
    one.
  - **On a command:** `cosmostore rekey` (or a call on `/_cosmostore`) starts it, and nothing moves until then.

## Consequences

- One design ADR follows the choice, with its slices.
- **For A:**
  - **The journal:** a new metadata-only record for a re-wrap, so an older binary cannot open a store that has
    one.
  - **The checkpoint:** keeps each key's count, or rebuilds it at open.
