# ADR-0135: M35, after Iceberg views (proposed)

**Status:** proposed, 26 Nov 2026, after M34 was closed (the owner: "continue").

## Context

- **The Iceberg REST catalog has views and nested namespaces** (M34, ADR-0134), checked by Iceberg Java and
  PyIceberg on `serve` and a cluster.
- **M34's exit review recorded four items** (`docs/m34-exit-review.md`):
  - **B1:** view metadata is not Iceberg Java's `ViewMetadata.Builder` in every detail: an identical schema or
    version is added again, old versions are not expired (`version.history.num-entries`), the log's entry takes the
    commit's time, and a version's `summary` is not checked;
  - **B2:** checks before writes race: a view and a table made at one name at once may both be written, and a child
    namespace made while its parent is dropped is left without a parent;
  - **B3:** a view's orphan files: no sweep lists view ids, so a crash between a commit's file and its record leaves
    a file;
  - **B4:** S3 Tables' ListNamespaces and ListTables skip nested namespaces after taking a page, so they can answer a
    short or empty page with a continuation token. AWS's clients follow the token, but an empty page is not what AWS
    answers.
  - The review's missing tests: each view update on its own, a concurrent commit's CommitFailed, and a view in an
    encrypted table bucket.
- **Remaining from earlier milestones:**
  - S3 Tables' table replication (eight calls), ADR-0133's B;
  - Iceberg v3's remaining parts (deletion vectors written by compaction, multi-argument transforms, lineage on
    branches), ADR-0133's C;
  - M33's B1 to B5, each kept with its reason.

## Decision (proposed)

1. **M35 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | M34's recorded items | B1 to B4 each fixed or kept with its reason, and the review's missing tests written. **Done when:** a view and a table raced at one name leave one; a namespace raced with its parent's drop is refused or dropped with it; a view's orphan files are swept; S3 Tables' list pages are full, or the last; Iceberg Java's view replace reuses an identical schema and expires versions as its builder does. Each fix with a test, mutation-checked for the races. |
   | B | Table replication | S3 Tables' eight replication calls: a table bucket's or table's replicas in another table bucket, read-only. **Done when:** a replica reads as its source after each commit, through the CLI and boto3. |
   | C | Iceberg v3's remaining parts | Compaction's position deletes written as deletion vectors in a v3 table; multi-argument transforms; lineage on branches. **Done when:** Iceberg Java reads each, in CI. |

2. **The recommendation is A.**
   - **Why:**
     - B2 and B4 are correctness: two objects at one name, a namespace without a parent, and list pages AWS does not
       answer;
     - it is small, and the view code is fresh;
     - B (replication) builds on the namespace and name records B2 changes, so B2 is better closed first.
   - **B** is large, and few deployments run two table buckets as source and replica. It is the natural M36.
   - **C** still waits for an engine that writes those v3 features: PyIceberg 0.12 writes none of them, and Iceberg
     Java's checks here read them but do not yet write them through an engine.
3. **For A, the questions the design ADR answers:**
   - **B2:** a name's reservation (one record per name across tables and views), or each kind's write conditional on
     the other's absence and re-checked after; and a namespace's generation checked by its children, or a child's
     create conditional on its parent's record.
   - **B3:** a sweep per table bucket listing view ids, or view files under their record's id only and removed on a
     commit's failure.
   - **B1:** how far to follow `ViewMetadata.Builder`: reuse and expiry are what engines see; the log's time and the
     summary's check are cosmetic.

## For the owner to decide

- **Which item is M35:** A (recommended), B or C.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A,** M34's views are hardened before replication copies them.
