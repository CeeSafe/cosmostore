# ADR-0095: M15, what comes after configurations decided at delivery (proposed)

**Status:** decided, 20 Nov 2026: the owner chose A ("A: no restarts"), a reload that would remove a needed
master key refused; ADR-0096 designs it. Proposed the same day. The owner: "propose M15". M14 (configurations decided at delivery, ADR-0094)
closed the same day.

## Context

- **Read at start only,** on `serve` and on every node, so a change takes a restart:
  - the roles file (ADR-0075): a role removed, or its policy narrowed, holds only after one. Since M14 that includes
    the writes of a role's configurations (ADR-0094 §5);
  - the STS key file (ADR-0075): adding or retiring a token key;
  - the SSE-S3 and KMS key files (ADR-0046 §4, ADR-0055): adding a master key, the first step of a rotation;
  - the notification and replication target files (ADR-0048, ADR-0077 §6).
- **Reloaded today:** only the credentials and users files (ADR-0050, ADR-0088, and ADR-0092 on a cluster).
- **Left by M13 and ADR-0093 §3:** nothing checks that a cluster's nodes have the same files. A node that differs is
  found only by the requests it refuses or cannot open.
- **Still refused:** the archive storage classes, GLACIER and DEEP_ARCHIVE, whose reads need RestoreObject (ADR-0090
  §1, the owner's choice for M12).
- **Left by M10:** compaction for S3 Tables (ADR-0087 §4).

## Decision (proposed)

1. **M15 is one of these items**, each its own design ADR with its slices, on `serve` first and then a cluster.

   | # | Item | Done when |
   |---|---|---|
   | A | Operations without restarts | The roles, STS key, SSE-S3 and KMS key, and notification and replication target files are reloaded when they change, as the credentials file is (ADR-0050): a file that does not read changes nothing and is reported once. A master key added is used for new objects at once, the old ones still open; a key a stored object needs cannot be removed (the reload is refused, and says which). On a cluster, each node gives its peers a digest of its files, and `cluster-status` shows any node that differs. |
   | B | Archive storage classes | GLACIER and DEEP_ARCHIVE are taken on writes and transitions. An archived object's GET is InvalidObjectState until RestoreObject is asked: then, after a restore time (configurable, minutes for tests), it reads for the days asked, HeadObject shows `x-amz-restore`, and it goes back to archived after. The bytes stay where they are; the time is a model of S3's, for clients that expect it. |
   | C | Compaction for S3 Tables | A Parquet reader and writer, enough for Iceberg's data files. A `binpack` strategy rewrites a partition's small files into files of `targetFileSizeMB`, committed as a `replace` snapshot. PyIceberg reads the same rows after. |

2. **The recommendation is A.**
   - **Why:** every milestone since M11 has left "read at start" behind it, and some of it is security. Removing a
     role does not stop its sessions' or its configurations' writes until a restart. Rotating a master key, the
     first thing a key compromise asks for, takes every node's restart.
   - **What it stands on:** ADR-0050's `Rotation`, which M13 put on every node. Each file gains the same watch, and
     the cluster's handshake (ADR-0062) carries the digests.
   - **What it must decide:** what a reload refuses. For example, a master key that stored objects still need must
     not disappear, as a credential's place must not.
3. **B completes storage classes,** and is the next candidate. It is a model, not a cold tier: its value is clients
   and tools that exercise RestoreObject.
4. **C is not recommended now,** as ADR-0087, ADR-0089, ADR-0091 and ADR-0093 said.
5. **Not in M15:**
   - the IAM API;
   - a KMS service;
   - SNI and HTTP/2, which are CeeSafe.Web's;
   - S3 Metadata tables and S3 Vectors.

## For the owner to decide

- **Which item is M15:** A (recommended), B or C.
- **For A, a key file whose reload removes a key a stored object needs:**
  - **Refuse the reload (recommended):** report which key and how many objects need it, and keep the keys in use.
    The operator re-seals those objects first (CopyObject onto itself, ADR-0046 §3), then retires the key.
  - **Take it:** those objects then answer InternalError until the key is back.

## Consequences

- One design ADR follows the choice, with its slices.
- For A, no new journal record: the files stay files.
