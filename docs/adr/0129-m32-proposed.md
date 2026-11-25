# ADR-0129: M32, after clusters as `serve` (proposed)

**Status:** decided, 25 Nov 2026. The owner chose A, S3 Tables' remaining small calls ("A: Tables' small calls").

Proposed the same day, after M31 was closed (the owner: "continue").

## Context

- **S3 Tables' API** (botocore 1.44.9's 58 calls) is done but for these.
  - **Metrics:** `Put`/`Get`/`DeleteTableBucketMetricsConfiguration`. A table bucket's CloudWatch metrics: on or off,
    with an `id`.
  - **Logging:** `Put`/`GetTableBucketLogging`. A table bucket's access logs, delivered to a target S3 bucket and
    prefix (with a key format), as S3's server access logs are. CosmoStore has those for S3 buckets (M7, the
    `AccessLogWriter`).
  - **Record expiration:** three calls. AWS documents it for its own managed tables only, and the calls list
    MethodNotAllowedException.
  - **Replication:** eight calls. **Migrations:** six calls.
- **Beyond S3 Tables:** Iceberg views and nested namespaces, which S3 Tables does not have.
- **Recorded Lows:**
  - **M30's B2–B9:**
    - configuration records orphaned;
    - tag keys differing only in case;
    - tag lengths counted in bytes;
    - pre-M30 tables' storage class;
    - `aws:ResourceTag` not taken in identity policies;
    - a tag call's table lookup reading every table record;
    - configuration writes unconditional;
    - a sealed manifest reported as missing.
  - **M31's B1–B6:**
    - deletes and other setters in a staged bucket;
    - the IAM bucket's workaround;
    - the compaction permit's fairness;
    - the staged workload's torn and sticky sweeps;
    - tests of `--tables-compactions`.
- **Iceberg v3's remaining parts:** deletion vectors written, encryption keys, multi-argument transforms, lineage on
  branches.

## Decision (proposed)

1. **M32 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | S3 Tables' remaining small calls | **Logging:** a table bucket's access logs (its S3 Tables and Iceberg catalog calls) delivered to its target bucket, in S3's access log format, by the access log writer, on `serve` and a cluster. **Metrics:** the configuration stored and answered, and the bucket's request counts in the server's metrics. **Record expiration:** answered as AWS answers for a table one makes (MethodNotAllowedException). Replication and migrations stay NotImplemented. **Done when:** the CLI, boto3 and the SDK matrix see AWS's answers, and a logged table bucket's calls appear in its target bucket. |
   | B | Hardening: the recorded Lows | M30's B2–B9 and M31's B1–B6, each fixed with a test or decided to stay, with its reason. **Done when:** each is closed one way or the other in the exit review. |
   | C | Iceberg views and nested namespaces | The REST catalog's view endpoints and namespaces nested past one level, beyond S3 Tables. **Done when:** Iceberg Java and PyIceberg make, read and replace a view, and a nested namespace holds tables. |
   | D | Table replication | A table bucket's or table's replication to another table bucket, the replica read-only. **Done when:** a replica reads the same as its source after each commit. |
   | E | Iceberg v3's remaining parts | Compaction's position deletes written as deletion vectors in a v3 table; multi-argument transforms; lineage on branches. **Done when:** Iceberg Java reads each, in CI. |

2. **The recommendation is A.**
   - **Why:**
     - it leaves only replication and migrations of S3 Tables' API undone, both large and seldom used;
     - logging is built on what CosmoStore has (the access log writer and its formats), and a table bucket's access
       logs are what an operator asks for first after its encryption;
     - it is a medium-sized milestone, with no on-disk format change.
   - **B** is the alternative: fifteen small items, each low risk. It could follow A, or ride along with it where
     they touch the same code (M30's tag Lows sit beside logging's calls).
   - **C, D and E** go beyond S3 Tables, and wait for an engine or a deployment that asks.
3. **For A, the work:**
   - **Logging:**
     - the configuration stored per table bucket, its target an S3 bucket the caller may write, as S3's
       PutBucketLogging checks;
     - each S3 Tables and Iceberg catalog call on the table bucket queued as an access log record, with its
       operation, the table bucket's ARN, the resource, status and bytes;
     - delivered to the target by the existing writer, every `--access-log-seconds`;
   - **Metrics:** the configuration stored; the table bucket's request counts in `/metrics`;
   - **Record expiration:** the three calls answering MethodNotAllowedException for any table;
   - **The checks:** the CLI and boto3, the SDK matrix, and the cluster smoke's logging through a node.

## For the owner to decide

- **Which item is M32:** A (recommended), B, C, D or E.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A,** S3 Tables' API is done but for replication and migrations.
