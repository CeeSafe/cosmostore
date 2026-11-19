# ADR-0091: M13, what comes after the long tail (proposed)

**Status:** decided, 19 Nov 2026: the owner chose A, each node watching its own files ("A. - Each node watches
its own files"); ADR-0092 designs it. Proposed the same day. The owner: "propose M13". M12 (the long tail, ADR-0090) closed the same day.
ADR-0089 §3 named configurations decided at delivery the next candidate.

## Context

- **Decided once, when put** (ADR-0088 §2, after M11's exit review):
  - **Which configurations:** a user's or session's replication, inventory and logging.
  - **What is checked:** the destination is authorized, its prefix included, only when the configuration is put.
  - **The gap:** a user removed, or a policy narrowed, keeps those configurations writing where it may no longer
    write, until someone puts them again. AWS checks the replication role at each replica.
- **A cluster is behind `serve`:**
  - **Credentials:** a node reads its credentials and users files at start only (ADR-0088 §5). Revoking a key
    (ADR-0050) or a user (ADR-0088) on a cluster takes a restart of every node; on `serve` it takes a save of the
    file.
  - **SSE-KMS:** a node has no KMS key file, so SSE-KMS, and M12's encryption context, are not served on a cluster
    (ADR-0090 §7).
- **Left by M10:** compaction for S3 Tables (a Parquet reader and writer, ADR-0087 §4, ADR-0089 §4).
- **Left by ADR-0079 §5:** S3 Metadata tables, S3 Vectors, and an Iceberg engine in the server.

## Decision (proposed)

1. **M13 is one of these items**, each its own design ADR with its slices and a support matrix, on `serve` first
   and then a cluster.

   | # | Item | Done when |
   |---|---|---|
   | A | A cluster as `serve` | Each node reloads its credentials and users files when they change, as `serve` does (ADR-0050, ADR-0088 §1): a key removed is refused through every node within the reload's interval, a user removed likewise. `node --kms-key-file` serves SSE-KMS, its encryption context included, through every node. The cluster smoke shows a revocation through every node without a restart, and an SSE-KMS object put through one node and read through another. |
   | B | Configurations decided at delivery | A replication, inventory or logging configuration records who put it (its key, user or role). Each replica, report and log object is authorized as that requester when it is written. A refused write is counted and reported: replication's status FAILED, inventory's and logging's in the server's log. A user removed, or a policy narrowed, stops its configurations' writes at the next one. |
   | C | Compaction for S3 Tables | A Parquet reader and writer, enough for Iceberg's data files. A `binpack` strategy rewrites a partition's small files into files of `targetFileSizeMB`, committed as a `replace` snapshot. PyIceberg reads the same rows after. |

2. **The recommendation is A.**
   - **Revocation is a security operation.** On `serve` it takes a save of a file. On a cluster it takes every
     node's restart, which an operator under pressure may not do, or may do late. A is the larger exposure of A and
     B: any key, not only a user's configurations.
   - **It is small, and most of it exists:**
     - the reload (ADR-0050's `Rotation`) and the users file's application (ADR-0088) are `serve`'s, to be run on
       each node;
     - the credential sets keep a key's place across reloads, which the shards' decisions depend on;
     - KMS keys are a file, as SSE-S3's are, which nodes already take.
   - **What it must decide:** whether the nodes' files may differ for a moment, during a rollout. Each node
     decides its own requests, so a request is decided by the files of the node it reaches. The front's merged
     calls are decided by the shards that answer them.
3. **B is the next candidate after A.**
   - **What it closes:** the one decision M11 makes once.
   - **What it changes:**
     - a requester recorded on three stored configurations, each a new format version;
     - each delivery path (here, another endpoint, a cluster's front) authorizing before it writes.
   - **Its cost:** it touches delivery, so it needs its own fault sweep (ADR-0004).
4. **C is not recommended now,** as ADR-0087 §4 and ADR-0089 §4 said. Engines can compact through the catalog.
5. **Not in M13:**
   - the IAM API;
   - a KMS service (keys stay a local file);
   - S3 Metadata tables and S3 Vectors;
   - HTTP/2 and SNI, which are CeeSafe.Web's.

## For the owner to decide

- **Which item is M13:** A (recommended), B or C.
- **For A, how a node learns of a change:**
  - **Each node watches its own files (recommended):** as `serve` does, every few seconds. The operator copies the
    files to every node.
  - **The cluster carries them:** one node's files, replicated through group 0, so every node has the same keys at
    once. This is larger (the keys and users become cluster state), and the credentials file stops being the only
    source of truth.

## Consequences

- One design ADR follows the choice, with its slices.
- For A, no new journal record: the files stay files, as on `serve`.
