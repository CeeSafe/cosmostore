# ADR-0131: M33, after S3 Tables' logging and metrics (proposed)

**Status:** decided, 25 Nov 2026. The owner chose A, hardening ("A: hardening").

Proposed the same day, after M32 was closed (the owner: "continue").

## Context

- **S3 Tables' API is done but for replication (eight calls) and migrations (six).**
- **Three milestones have recorded Lows** (each in its exit review's B list):
  - **M30** (encryption, tags, storage class):
    - B2: configuration records orphaned;
    - B3: tag keys differing only in case;
    - B4: tag lengths counted in bytes;
    - B5: pre-M30 tables' storage class;
    - B6: `aws:ResourceTag` not taken in identity policies;
    - B7: a tag call's table lookup reading every record;
    - B8: configuration writes unconditional;
    - B9: a sealed manifest reported as missing.
  - **M31** (clusters as `serve`):
    - B1: deletes and setters in a staged bucket;
    - B2: the IAM bucket's workaround;
    - B3: the compaction permit's fairness;
    - B4: the two-shard check's margin;
    - B5: the staged workload's torn and sticky sweeps;
    - B6: no test of `--tables-compactions`.
  - **M32** (logging and metrics):
    - B1: record expiration routed to shard 0 on a cluster;
    - B2: requests refused before their caller is known not logged;
    - B3: warehouse records without namespace and name;
    - B4: per-request cost on a cluster;
    - B5: a downgrade reading a v3 logging value as none;
    - B6: the Java SDK pin without logging calls.
- **Beyond S3 Tables:**
  - Iceberg views and nested namespaces;
  - table replication;
  - Iceberg v3's remaining parts (deletion vectors written by compaction, multi-argument transforms, lineage on
    branches).

## Decision (proposed)

1. **M33 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | Hardening: the recorded Lows | Each of M30's B2–B9, M31's B1–B6 and M32's B1–B6 fixed with a test, or decided to stay with its reason, in the design ADR. **Done when:** the exit review finds each closed one way or the other, and the checks still pass. |
   | B | Iceberg views and nested namespaces | The REST catalog's view endpoints (create, load, replace, rename, drop, list) and namespaces past one level, beyond S3 Tables. **Done when:** Iceberg Java and PyIceberg make, read and replace a view, and a nested namespace holds tables, in CI. |
   | C | Table replication | S3 Tables' eight replication calls: a table bucket's or table's replicas in another table bucket, read-only. **Done when:** a replica reads as its source after each commit, through the CLI and boto3. |
   | D | Iceberg v3's remaining parts | Compaction's position deletes written as deletion vectors in a v3 table; multi-argument transforms; lineage on branches. **Done when:** Iceberg Java reads each, in CI. |

2. **The recommendation is A.**
   - **Why:**
     - twenty small items have built up over three milestones, each low risk and well understood;
     - several touch one another (the tag Lows, the configuration record, the cluster's per-request costs), and are
       cheaper fixed together than one by one later;
     - it leaves the code as its ADRs describe it before a large item (B, C or D).
   - **B** is the largest of the others, and the one engines would use: the next milestone after A.
   - **C and D** wait for a deployment or an engine that asks.
3. **For A, the work:**
   - **The design ADR** takes each Low in turn: its fix and its test, or why it stays.
   - **Expected to stay, with reasons:**
     - M31's B4 (a timing margin, now deterministic in its choice of shards);
     - M32's B5 (downgrades are not supported across a format change);
     - M32's B3's object size and bytes, which S3's lines here leave `-` too.
   - **Expected fixes:**
     - tag keys matched as AWS matches them; lengths in characters;
     - configuration records cleaned up, and their writes conditional;
     - staged buckets for deletes and setters, which retires the IAM workaround;
     - a fair compaction permit;
     - record expiration routed by its table;
     - refused requests logged;
     - the Java SDK pin moved to a release with logging calls;
     - the missing sweeps and tests.
   - **The checks:** each fix's test; the smokes, sweeps and CI as now.

## For the owner to decide

- **Which item is M33:** A (recommended), B, C or D.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A,** the recorded Lows of M30 to M32 are closed one way or the other.
