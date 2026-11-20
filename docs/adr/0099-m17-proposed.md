# ADR-0099: M17, what comes after compaction for S3 Tables (proposed)

**Status:** decided, 20 Nov 2026: the owner chose A ("A: key rotation"), a cluster's removal taken by asking the
leaders; ADR-0100 designs it. Proposed the same day. The owner: "propose M17". M16 (compaction for S3 Tables, ADR-0098) closed the
same day.

## Context

- **Retiring a master key is still manual** (ADR-0097 item A, not chosen for M16):
  - **On `serve`:** every version under the key is re-sealed with a CopyObject onto itself. That rewrites its
    bytes, and makes a new version in a versioned bucket.
  - **On a cluster:** a node refuses a master key's removal while it runs (ADR-0096 §3 as amended), so retiring one
    takes every node's restart.
  - **Already decided for it:** re-wrapping starts on its own once a key is no longer first in its file (the
    owner's choice, ADR-0097).
  - **What makes it cheap:** an envelope wraps only the version's 32-byte data key (ADR-0046 §3), so moving a
    version to another key is a metadata-only record, as tags are (ADR-0017).
- **Still refused:** the archive storage classes, GLACIER and DEEP_ARCHIVE, whose reads need RestoreObject (ADR-0090
  §1).
- **Left by M16 (ADR-0098 §5, docs/m16-exit-review.md):**
  - partitions with delete files are not compacted;
  - row groups are not merged;
  - page indexes and bloom filters are dropped from joined files.

  All three need pages decoded and written again: zstd and snappy in CeeSafe, which has neither (CEESAFE_GAPS
  G40), and Parquet's encodings.
- **Left by M15's review (docs/m15-exit-review.md B1, B2):** a key removal's count holds the store's lock for a full
  walk, and old key bytes stay in memory. Item A fixes both.

## Decision (proposed)

1. **M17 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Key rotation without re-sealing | **Re-wrap:** every version and upload sealed under a key that is not its file's first is re-wrapped under the first, a batch per upkeep round, by a metadata-only journal record. The bytes, version ids and ETags stay as they are. **Counts:** each key's versions are counted as writes happen, so a removal's check needs no walk (M15's B1). **Status:** `/_cosmostore/stats` and `cluster-status` show them. **On a cluster:** each shard's leader re-wraps through its log. A node takes a master key's removal once every shard's leader reports none under it. **Secrets:** a removed key's bytes are wiped once no set holds it (M15's B2). |
   | B | Archive storage classes | GLACIER and DEEP_ARCHIVE are taken on writes and transitions. An archived object's GET is InvalidObjectState until RestoreObject is asked. After a restore time (configurable, minutes for tests) it reads for the days asked, HeadObject shows `x-amz-restore`, and it goes back to archived after. A model of S3's tiers: the bytes stay where they are. |
   | C | Compaction that re-encodes | zstd and snappy, decoders and compressors, in plain CeeSafe. Parquet's PLAIN, dictionary and RLE/bit-packed encodings, nested levels included. Compaction then merges row groups and applies position and equality deletes while it rewrites, so partitions with delete files are compacted too. |

2. **The recommendation is A.**
   - **Why:** it is the security item, and it was the recommendation for M16 too. Answering a key compromise on a
     cluster still takes every node's restart.
   - **What it fixes on the way:** M15's B1 and B2.
   - **How big it is:** the smallest of the three. The record is metadata-only, and the background pass is like
     lifecycle's.
   - **Already decided:** when re-wrapping starts.
3. **B is the next candidate,** as before: a model for clients and tools that exercise RestoreObject.
4. **C is the largest by far:**
   - **What it needs:** two codecs and Parquet's encodings, all from scratch.
   - **What it gives:** a gain readers see mostly on tables with deletes.
   - **Alternative:** the codecs would serve better in CeeSafe's `lib/std` (G40), from which C could follow.
5. **Not in M17:**
   - the IAM API;
   - a KMS service;
   - SNI and HTTP/2, which are CeeSafe.Web's;
   - S3 Metadata tables and S3 Vectors.

## For the owner to decide

- **Which item is M17:** A (recommended), B or C.
- **For A, how a cluster takes a removal:**
  - **Asked of the leaders (recommended):** a node asks every shard's leader, as `cluster-status` asks, for its
    count under the key. It takes the removal when all answer zero, and refuses it (logged) when any is nonzero or
    does not answer.
  - **Two-phase:** the removal is proposed through every shard's log and taken when all have applied it. That is
    stronger against a write landing between the ask and the take, but it adds a record and a protocol.

## Consequences

- One design ADR follows the choice, with its slices.
- **For A:**
  - **The journal:** a new record, so an older binary cannot open a store that has one.
  - **The checkpoint:** keeps each key's count, or rebuilds it at open.
