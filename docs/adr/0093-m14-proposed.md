# ADR-0093: M14, what comes after a cluster as `serve` (proposed)

**Status:** proposed, 20 Nov 2026. The owner: "continue", after M13 (a cluster as `serve`, ADR-0092) closed the
same day. ADR-0089 §3 and ADR-0091 §3 named configurations decided at delivery the next candidate.

## Context

- **Decided once, when put** (ADR-0088 §2, after M11's exit review):
  - **What is checked:** a user's or a session's replication, inventory and logging destination, with its prefix,
    only when the configuration is put.
  - **The gap:** a user removed, or a policy narrowed, keeps those configurations writing where it may no longer
    write. AWS checks the replication role at each replica.
  - **What M11 and M13 make sharper:** removing a user now takes its keys away at once, on `serve` and through every
    node (ADR-0088 §1, ADR-0092 §1). Its configurations go on writing.
- **Left by M13** (`docs/m13-exit-review.md`): nothing checks that the nodes' files match. A node with another
  credentials or key file is found only by the requests it refuses or cannot open.
- **Left by M10:** compaction for S3 Tables (a Parquet reader and writer; ADR-0087 §4).
- **Left by ADR-0079 §5:** S3 Metadata tables, S3 Vectors, and an Iceberg engine in the server.

## Decision (proposed)

1. **M14 is one of these items**, each its own design ADR with its slices, on `serve` first and then a cluster.

   | # | Item | Done when |
   |---|---|---|
   | A | Configurations decided at delivery | A replication, inventory or logging configuration records who put it: its key, and its user or role. Each replica, report and log object is authorized as that requester when it is written, with the policies of that moment. A refused write is reported (replication's status FAILED; inventory's and logging's in the server's log, and counted). A user removed, or a policy narrowed, stops its configurations' writes at the next one, on `serve` and on a cluster. The account's configurations are unchanged. |
   | B | A cluster that knows its files match | Each node gives its peers, in the handshake (ADR-0062), a digest of its credentials, users and key files. A node whose digest differs is reported by every peer, and `cluster-status` shows it, so a rollout is seen to finish. |
   | C | Compaction for S3 Tables | A Parquet reader and writer, enough for Iceberg's data files. A `binpack` strategy rewrites a partition's small files into files of `targetFileSizeMB`, committed as a `replace` snapshot. PyIceberg reads the same rows after. |

2. **The recommendation is A.**
   - **The gap:** it closes the last authorization decision made once. Since M11 and M13, taking a user away is
     immediate everywhere but there.
   - **Its cost:**
     - each of the three stored configurations gains its requester, a new format version written only when a
       user's or a session's configuration is put;
     - each delivery path (here, another endpoint, a cluster's front, and inventory's and logging's writers)
       authorizes before it writes.
   - **Its fault sweep (ADR-0004):** it touches delivery, so a crash between a refused write and its report is
     swept.
   - **A session's configuration:** a session ends. So a configuration put with a session's credentials records
     the session's key's user or role, and is decided as that user, or that role without its session policy. Or it
     is refused at put; the design ADR chooses.
3. **B is small, and could follow A in the same milestone** if the owner wants. It is a diagnosis, not a fix: files
   that differ are still the operator's to copy.
4. **C is not recommended now,** as ADR-0087, ADR-0089 and ADR-0091 said. Engines can compact through the catalog.
5. **Not in M14:**
   - the IAM API;
   - a KMS service;
   - S3 Metadata tables and S3 Vectors;
   - HTTP/2 and SNI, which are CeeSafe.Web's.

## For the owner to decide

- **Which item is M14:** A (recommended), B, C, or A with B.
- **For A, a configuration put with a session's credentials (STS):**
  - **Decided as the session's parent (recommended):** the role's policy, or the user's, at each write. A session
    lasts hours, a configuration for good.
  - **Refused at put:** a session may not put a replication, inventory or logging configuration.

## Consequences

- One design ADR follows the choice, with its slices.
- For A, configurations put before it have no requester and keep their decision at put, as they were authorized
  then. A note in the upgrade text says so.
