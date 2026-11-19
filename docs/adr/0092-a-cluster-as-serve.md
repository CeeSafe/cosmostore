# ADR-0092: A cluster as `serve`: reloaded keys and users, SSE's keys (M13)

**Status:** proposed, 19 Nov 2026. M13 is item A of ADR-0091 (the owner: "A. - Each node watches its own files").

## Context

- **What `serve` reloads:**
  - **The files:** its credentials file (ADR-0050) and its users file (ADR-0088 §1). A change to either reloads
    both, every upkeep.
  - **The sets:** the keys go into credential sets that keep a key's place, so a request decided against one set
    means the same key in the next.
  - **A bad file:** one that does not read changes nothing and is reported once.
- **What a node does instead:**
  - **The files:** it reads both files at start and never again (ADR-0088 §5).
  - **The sets:** it already holds one `Arc<CredentialSets>`, which every shard's S3 server and the front share.
- **SSE on a cluster:**
  - **The keys:** a node gives its S3 servers no SSE-S3 keys and no KMS keys. Its delivery task gets none either
    ("a cluster seals nothing", ADR-0078 §4).
  - **The result:** SSE-S3 is refused (InvalidRequest) and SSE-KMS is NotImplemented on a cluster. SSE-C, which
    brings its key, works. `docs/compatibility.md` does not say so.

## Decision (proposed)

1. **Each node reloads its files** (the owner's choice: each node watches its own).
   - **How:** a node with `--credentials` runs `serve`'s `Rotation` on its one credential set, every 2 seconds,
     with `--users-file` as on `serve`. A change to either file reloads both. A file that does not read changes
     nothing and is reported once, in the node's log, as on `serve`.
   - **What it reaches:** every shard's S3 server and the front read the same set, so one reload reaches all of a
     node's requests.
   - **During a rollout:** each node decides the requests it receives by its own files, so the operator copies the
     files to every node. While they differ, a request is decided by the files of the node it reaches. The front's
     merged calls (ListBuckets and the like) are decided by the shards that answer them, each with its own node's
     files.
2. **SSE's keys on a node:** `node --sse-key-file` and `node --kms-key-file`, as `serve`'s (ADR-0046, ADR-0055).
   - **Where they go:** every shard's S3 server seals and opens with them, and the delivery task opens sealed
     sources with them (replication, ADR-0078 §4).
   - **Every node's keys must be the same,** as its credentials must. An object is sealed by the node whose shard
     leads when it is put, and read through any node.
     - **A node without the key:** it answers an object sealed under a key it does not have with InternalError, as
       `serve` does for a key its file lost.
     - **At start:** a node checks nothing against the others; ADR-0062's roster carries no keys.
   - **A replica on a cluster** (found while building §2): replication goes through the node's own front, a sealed
     source as its plaintext, marked SSE-S3. The receiving shard now seals it with SSE-S3, whose ETag is the
     plaintext's MD5, as the source's (ADR-0078 §4 refused it while nodes had no keys). A destination bucket whose
     default is SSE-KMS still refuses a replica, which reads FAILED: an SSE-KMS ETag would not be its source's.
   - **Not reloaded:** like `serve`'s, the key files are read at start. A new master key is a restart, as on
     `serve` (ADR-0046 §4).
3. **Checked on a cluster:**
   - **Revocation:** a key removed from every node's credentials file is refused through every node, without a
     restart; likewise a user removed from every node's users file.
   - **SSE:** SSE-S3 and SSE-KMS objects, with an encryption context, put through one node and read through the
     others; a bucket's default encryption; a sealed source replicated.

## Found on the way

- **A refused replica could read COMPLETED on a cluster** (before M13). Noting a refusal reads the bucket's list of
  failures and writes it back. On a cluster the write applies only when Raft commits it, so a second refusal in one
  delivery batch read the list without the first, and dropped it. The delivery task now proposes each noted refusal,
  and waits for it to apply, as it does its delivery record. The cluster smoke checks two refusals in one batch.

## Slices

1. Reloads on every node (§1), with the cluster smoke's revocation checks.
2. SSE's keys on a node (§2), with the cluster smoke's SSE checks.
3. The SDK matrix where it reaches a cluster, `docs/compatibility.md`, and the exit review.

## Consequences

- **The journal:** no new record. The files stay files.
- **`docs/compatibility.md`** states SSE on a cluster, and that a cluster's files must match.
