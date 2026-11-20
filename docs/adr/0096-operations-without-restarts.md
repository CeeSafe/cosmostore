# ADR-0096: Operations without restarts (M15)

**Status:** proposed, 20 Nov 2026. M15 is item A of ADR-0095 (the owner: "A: no restarts"). A reload that would
remove a master key stored objects still need is refused (the owner's choice).

## Context

- **What reloads now:** `serve` and every node reload the credentials and users files (ADR-0050, ADR-0088,
  ADR-0092). Each key keeps its place across reloads, so a request decided against one set means the same key in
  the next.
- **What does not:**
  - the roles file;
  - the STS, SSE-S3 and KMS key files;
  - the notification and replication target files.

  They are read at start, into the S3 server's state and the writers' copies.

## Decision (proposed)

1. **Each file reloads as the credentials file does:**
   - **When:** checked every upkeep on `serve`, every 2 s on a node; a change to its modification time reloads it.
   - **A file that does not read** changes nothing and is reported once.
   - **What sees it:** every reader the next request or write.
2. **Stable places.** A role, a master key and a target keep their place across reloads, as a key does in the
   credential sets.
   - **Removed:** it is marked so, not taken out; a new one goes after the others.
   - **Why:** a request that resolved a role, or a writer that picked a key, means the same one when a reload lands
     in between.
   - **What a removed role means:** its sessions are refused (InvalidToken, as today for a role no longer there),
     and its configurations' writes too (ADR-0094).
3. **Master keys** (SSE-S3's and KMS's):
   - **Added:** a key added first in its file is the one new objects are sealed with, at once. The old ones still
     open what they sealed.
   - **Removed while needed:** a reload that removes a key some stored version's envelope still names is refused
     (the owner's choice). It is reported with the key's id and how many versions need it, and the keys in use stay.
   - **How to retire a key:** re-seal those versions first (CopyObject onto itself, ADR-0046 §3), then remove it.
   - **The count:** from the index's metadata in memory, so a reload reads no object.
   - **Amended by the exit review (docs/m15-exit-review.md, A1 and A2):**
     - **New bytes under a key's id** count as that key's removal.
     - **On `serve`:**
       - the count and the install happen under one hold of the store's lock;
       - the count takes in staged writes, and buckets whose default encryption names the KMS key;
       - each sealed write checks, just before it commits, that its key is still in the set.
     - **On a cluster:** a node refuses any reload that removes or changes a master key. It cannot count what other
       shards, unapplied entries and other nodes still seal. A key is retired by re-sealing, then restarting the
       nodes with the new file. Adding a key is taken.
4. **STS keys:** a key removed takes the tokens it sealed with it, as a revocation does. Adding one makes it the key
   new tokens are sealed with.
5. **Targets:** a notification or replication target removed makes its pending events' deliveries fail as an
   unknown target's do today. One changed is used from the next delivery.
   - **No places (amended in slice 3):** every reader finds a target by its id, never by a place, so a target list
     is replaced whole (`Reloaded<T>`), and a target removed is simply not found.
6. **On a cluster:**
   - **Reloads:** each node reloads its files as `serve` does (ADR-0092 §1's task, widened).
   - **Digests:** each node gives a digest of each file's contents, a salted hash that holds no secret.
     `cluster-status` shows, per node, the files whose digest differs from the others'.
   - **Amended in slice 4:** the digests are in each node's status answer (`# file <option> <digest>`), and
     `cluster-status` asks every node for its own, rather than the peer handshake carrying them.
     - **Why:** only the operator reads them, so they need not travel between nodes, and the peer protocol is
       unchanged.
     - **The digest:** HMAC-SHA256 under the cluster's secret, cut to 16 bytes, of the file as it is on disk now
       (so a reload the node refused shows as the file, not as what the node uses).
     - **What `cluster-status` adds:** `# files agree`, or a `# file-differs <option>` line with each answering
       node's digest (`-` for a file not given), and `# no-answer` for the nodes that did not answer.

## Slices

1. A reloadable set with stable places, and the roles file on it, on `serve` and a node.
2. The STS, SSE-S3 and KMS key files: the refusal of a needed master key, and its count.
3. The target files.
4. The cluster's digests and `cluster-status`.
5. The exit review.

## Consequences

- **The journal:** no new record. The files stay files.
- **Places:** a long-running server keeps every role, key and target it ever had, marked removed. That is as many
  as its files ever named, with a limit like the credential sets' (MAX_CREDENTIAL_SETS reloads).
