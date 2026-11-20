# M17 exit review: key rotation without re-sealing (20 Nov 2026)

**M17's exit (ADR-0099 item A; ADR-0100, proposed):** a key is rotated and its old key removed without a restart or
a re-seal, on `serve` and on a cluster.

## How it was checked

- **The evidence:**
  - **Unit tests:**
    - the index's counts through overwrites, deletes, replay and a checkpoint;
    - the re-wrap record moving envelopes, not bytes;
    - a round keeping the data key;
    - removed keys wiped.
  - **The fault sweep** of the re-wrap record (once, sticky, torn, crash; ADR-0004).
  - **The S3 smoke:** a rotation under a running server.
    - **Before the old key's removal:** the old keys' counts reach 0; re-wrapped versions, inline and in extents,
      read with their ETags.
    - **The removal:** the old keys' removal is taken; the key in use is refused.
  - **The cluster smoke:** the same through every node, after the node killed earlier comes back.
  - **The SDK matrix.**
- **A review by a reader who had not written the code:** six findings, all read, none reproduced.

## Findings

### A. Fixed before closing

1. **Medium: a lagging or deposed leader's count was trusted on a cluster.**
   - **Why:**
     - a status reported counts whenever a replica thought it led, though a leader just elected may hold committed
       entries it has not applied;
     - a node that did not answer was skipped, so a deposed leader's stale count could stand for its shard.
   - **The effect:** a key could be removed while a version committed under it waited to be applied.
   - **Fixed:**
     - a leader reports counts only caught up: an entry of its own term committed, and its store applied to
       `commit`;
     - its `sealed-led` line names its term, and a shard's report counts only from a leader of the highest term any
       node shows for it;
     - every node must answer, or the removal is refused.
2. **Medium: nodes' key sets could differ.**
   - **Why:** each shard's leader re-wrapped under its own node's first key.
   - **The effects:**
     - a key put first on one node had versions re-wrapped under it while other nodes did not yet hold it, so reads
       through those failed until they reloaded;
     - a node that had not reloaded kept sealing under a key another node had removed.
   - **Fixed:**
     - each node's status lists the keys it holds, by id and a tag (HMAC under the cluster's secret);
     - a leader re-wraps only under a first key every node was last seen to hold (checked every 10 s);
     - a removal of an SSE-S3 key is refused while any node still has it first.
   - **The rule for operators,** now in ADR-0100 §4: add the new key on every node, put it first on every node,
     wait for the old key's count to reach 0, then remove it.
3. **Low: out of memory while replaying a re-wrap failed the store's open as if the record were corrupt.** It now
   marks the counts not known.
4. **Low: decoding a key file could leave a freed copy of a key** as its buffer grew. The buffer is reserved before
   it is decoded.

### B. Recorded, not fixed

1. **Low: new bytes under a key that is first can never be taken.**
   - **Why:** the re-wrap skips the first key's versions, so the count under it never reaches 0.
   - **The way:** put a new key first; the old one then empties and is removed.
   - **The refusal's message** names the key and the count.
2. **Low: not every copy of a key's bytes is wiped.**
   - **Not wiped:**
     - a key set's vector, when it grows, leaves its old buffer to the allocator;
     - lib/std's `Aes256Gcm` key schedule.
   - **Done:** the key file's text, the decoded bytes, every `MasterKey` copy (its `drop`) and every `KeyBytes`
     copy are wiped.
3. **Low: once a node's counts are not known (out of memory), every removal on the cluster is refused until it
   restarts.** That is safe, but nothing recovers it. `serve` walks instead.
4. **Low: a KMS key named explicitly in a request can still be sealed under between a node's count and its take**
   (ADR-0100 §4). The commit check refuses it on the node that took the removal. Remove a KMS key from bucket
   defaults, and from every node, first.
5. **Low: a node's re-wrap gate is up to 10 s old.**
   - **The window:** a node that drops the first key from its set in those seconds can see versions re-wrapped
     under it, which it cannot open until it holds it again.
   - **Why it is acceptable:** the operator's rule (A2) never removes the first key, and a removal of one is refused
     anyway.

## Decisions for the owner

- **Accept ADR-0100,** with §4 amended:
  - caught-up leaders of the highest term;
  - every node answering;
  - key views in the status;
  - the re-wrap gate;
  - the rule for operators.
- **Close M17.**
