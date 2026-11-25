# ADR-0125: M30, after engines' catalog calls (proposed)

**Status:** decided, 25 Nov 2026. The owner chose A, S3 Tables' configuration ("A: encryption, tags").

Proposed the same day (the owner: "continue", after M29 was closed the same day).

## Context

- **The Iceberg side is complete for engines:**
  - v3 tables, compaction of every kind of delete, staged creates;
  - Iceberg Java's 22 other catalog calls (two refused by design, as S3 Tables does);
  - all checked by Iceberg Java and PyIceberg in CI.
- **S3 Tables' own API** (botocore 1.44.9 lists 58 calls) is done for table buckets, namespaces, tables, policies,
  maintenance, rename, the metadata location and job status. **Not done (each refused NotImplemented):**
  - **encryption:** `Put`/`Get`/`DeleteTableBucketEncryption`, `GetTableEncryption`, and `encryptionConfiguration`
    on CreateTableBucket and CreateTable;
  - **tags:** `TagResource`, `UntagResource`, `ListTagsForResource`, and `tags` on the creates;
  - **storage class:** `Put`/`GetTableBucketStorageClass`, `GetTableStorageClass`;
  - **metrics and logging:** `Put`/`Get`/`DeleteTableBucketMetricsConfiguration`, `Put`/`GetTableBucketLogging`;
  - **record expiration:** `Put`/`GetTableRecordExpirationConfiguration`, `GetTableRecordExpirationJobStatus`;
  - **replication:** eight calls, of buckets and tables;
  - **migrations:** six `…TableMigration` calls.
- **What CosmoStore has to build them on:**
  - SSE-S3 and SSE-KMS by its own KMS keys (ADR-0071, M5);
  - object tags and storage classes (M7);
  - bucket replication (M7);
  - the table maintenance loop (M22).
- **The cluster's Lows (M22's B2 and B3)** stand as recorded.

## Decision (proposed)

1. **M30 is one of these items,** each its own design ADR with its slices.

   | # | Item | Done when |
   |---|---|---|
   | A | S3 Tables' configuration: encryption, tags, storage class | Encryption: a table bucket's and table's SSE-S3 or SSE-KMS (this server's keys), every file of a table then sealed with it, including those compaction and the catalog write. Tags: the three calls and the creates' `tags`, on table buckets and tables, with tag-based policy conditions as S3's. Storage class: a table bucket's and table's, given to their files. **Done when:** the AWS CLI and boto3 set, read and remove each; a KMS table's files are sealed with its key and read back by PyIceberg and Iceberg Java; every SDK of the matrix sees the same answers. |
   | B | Record expiration | A table's records older than a column's age deleted by the maintenance loop: a delete (position deletes or deletion vectors) committed for the rows past it, as S3 Tables' job does. **Done when:** a table's expired rows are gone for PyIceberg and Java, its job status reported. |
   | C | Table replication | A table bucket's or table's replication to another table bucket here or on another node: its metadata and files copied, the replica read-only. **Done when:** a replica table reads the same as its source after each commit. |
   | D | The cluster's Lows | As ADR-0123's C. |

2. **The recommendation is A.**
   - **Why:**
     - encryption and tags are the S3 Tables settings tools set first (Terraform's `aws_s3tables_table_bucket` has
       `encryption_configuration`; tags are on every resource);
     - each is built on what CosmoStore has for S3: SSE, KMS, tags, storage classes;
     - today a tool that sets either is refused.
   - **B** is a feature of its own: a row-level delete job, built on M24's and M28's delete machinery. It comes after A.
   - **C** is large, and few deployments run one table bucket on two nodes' storage.
3. **For A, the work:**
   - **encryption:**
     - the configuration stored, inherited by a table from its bucket;
     - the table's files written by the catalog and by compaction sealed with it;
     - files written by clients through S3 sealed with it, as a bucket's default encryption seals them;
   - **tags:** stored per resource, with `aws:ResourceTag` conditions in table bucket and table policies;
   - **storage class:** stored and given to the table's objects;
   - **the checks:** the AWS CLI, boto3, the SDK matrix, Terraform's S3 Tables resources, and the Java check on a
     KMS table.
4. **Not in M30:** replication, migrations, metrics and logging (stored-only settings, for a later milestone).

## For the owner to decide

- **Which item is M30:** A (recommended), B, C or D.

## Consequences

- **One design ADR follows the choice,** with its slices.
- **For A, the S3 Tables settings tools set first are taken,** and a KMS table's files are sealed with its key.
