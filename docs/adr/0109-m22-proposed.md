# ADR-0109: M22, what comes after IAM for tools (proposed)

**Status:** decided, 23 Nov 2026. The owner chose:
- A, with M21's B1 and B2 as its last slices ("A + B1, B2");
- a crash sweep as A's crash bar;
- CeeSafe's snappy and zstd "Not yet".

ADR-0110 designs it. Proposed the same day (the owner: "propose M22"). M21 (IAM for tools, ADR-0108) was closed on 22 Nov 2026.

## Context

- **Table maintenance on a cluster** (M16 B5; ADR-0106 made it an item of its own; ADR-0107's B):
  - a compaction run on a cluster is one leader write, so `leadWrite` holds the shard's write gate from the forward
    to the commit;
  - a long run holds up every other write to that shard, and it also runs into the front's 30 s timeout;
  - the snapshot expiry and orphan removal jobs are written the same way;
  - it has not been seen at test sizes. Its cost is a stall, not a wrong answer.
- **Compaction that re-encodes** (ADR-0105's and ADR-0107's C):
  - today's compaction joins small Parquet files whole: row groups are copied, not merged, and delete files are not
    applied;
  - merging row groups means decoding and encoding Parquet pages;
  - PyIceberg and Spark write those pages with snappy or zstd by default;
  - CeeSafe 0.90.0 has deflate and gzip, while snappy and zstd are its ADR 0196's phases 2 and 3, accepted and not
    built.
  - **The work is in two repositories:** a CeeSafe release for each codec (about 1 to 2 days of agent work for
    snappy, 6 to 9 for the zstd decoder), then Parquet's encodings and the compaction here.
- **M21's recorded Lows** (`docs/m21-exit-review.md` B1 to B5):
  - B1: a bucket policy naming a user by an ARN with a path (refused as NotImplemented, failing closed);
  - B2: the record's other bounds (users, roles, inline policies' total size);
  - B3: tag keys' case and characters;
  - B4: the whole record decoded per call;
  - B5: a failed users file's report.
  - All are small; none fails open.

## Decision (proposed)

1. **M22 is one of these items**, each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Table maintenance on a cluster, as gated writes | **What changes:** a cluster leader's compaction is a run of gated writes: each bin's file put, then the commit, with the bytes read and joined outside the gate. Snapshot expiry and orphan removal follow it. A run takes no request's time: it is the leader's, as `serve`'s is the upkeep's. **Done when:** on a cluster, a write to the shard goes through while its compaction copies; a run longer than the front's timeout completes; a leader killed mid-run leaves the table as before or as after, never between (a crash sweep); the PyIceberg checks read every row. |
   | B | Compaction that re-encodes | **What it needs first:** CeeSafe's snappy and zstd, two releases (ADR 0196's phases 2 and 3). **Then:** Parquet's page encodings (PLAIN, RLE/bit-packed, dictionary), row groups merged to a target size, position and equality deletes applied. **Done when:** PyIceberg's and Spark's tables, snappy and zstd, compact to fewer, larger files that read the same rows. |
   | C | M21's recorded Lows | B1 to B5, each fixed or decided to stay with a reason. |

2. **The recommendation is A,** with C's B1 and B2 as its last slices.
   - **Why A:**
     - it is the one gap that can stop writes: a busy cluster table with compaction on;
     - everything it needs is in place;
     - it is the smallest of the three.
   - **Why B1 and B2 with it:** they are small, and both are IAM's open ends from the milestone just closed.
   - **B next:** its first half is CeeSafe's, which can run in the CeeSafe repo meanwhile if the owner wants.
3. **Not in M22:**
   - permission boundaries;
   - MFA;
   - SAML and OIDC federation;
   - a KMS service;
   - SNI and HTTP/2.

## For the owner to decide

- **Which item is M22:**
  - **A with B1 and B2 (recommended);**
  - A alone;
  - B;
  - C.
- **For A, the crash bar:**
  - **A crash sweep (recommended):** a fault sweep over the leader's run, its put and commit points, as the restore
    record's was in M20. It follows the ordering rule (ADR-0001) and ADR-0004's crash model.
  - **The cluster smoke alone:** a leader killed mid-run, checked once.
- **For B, if it is chosen or next:** whether CeeSafe's snappy and zstd start now, in the CeeSafe repo, while M22 runs
  here.

## Consequences

- One design ADR follows the choice, with its slices.
- **For A:** a compaction's commit on a cluster is no longer one write. A table may be read between a bin's put and
  the commit, so the bin's file must be one no snapshot names until the commit, as `serve`'s is today.
