# ADR-0100: Key rotation without re-sealing (M17)

**Status:** proposed, 20 Nov 2026. M17 is item A of ADR-0099 (the owner: "A: key rotation"). Re-wrapping starts on
its own once a key is not first (the owner's choice, ADR-0097). A cluster takes a removal by asking the shards'
leaders (the owner's choice, ADR-0099).

## Context

- **What an SSE-S3 envelope holds** (ADR-0046 §3): the version's data key, wrapped by a master key, and the master
  key's id (`v1.s3.<id>.<nonce>.<wrapped>`).
  - **What depends on the master key:** only the 48 wrapped bytes. The object's bytes, its version id, its
    generation and its ETag do not.
- **What M15 gave** (ADR-0096 §3 as amended):
  - **On `serve`:** a removal is refused while any version, upload or bucket default needs the key. The count walks
    the whole index under the store's lock (M15's B1).
  - **On a cluster:** any master key removal is refused.
  - **So retiring a key means re-sealing:** a CopyObject onto itself rewrites every version, and adds versions in a
    versioned bucket.
- **Already in the store:** a metadata-only record, SetTags, whose formats replace one field of a version when its
  generation still matches (tags, ACL, lock, storage class).

## Decision (proposed)

1. **Counts kept as the index changes.**
   - **What is counted:** the version index keeps, per envelope prefix (`v1.<mode>.<id>.`), how many of its versions
     carry it.
   - **Where it changes:** at the index's own changes, adding (`put`, `push`) and removing (`removeVersion`,
     `removeOlder`, and the version `put` replaces), and at a re-wrap (§2).
   - **At open:** a checkpoint's load goes through the same changes, so the counts are rebuilt without a format
     change.
   - **Uploads in progress:** counted the same way in the uploads' table.
   - **What it fixes:** a removal's check reads the counts, with no walk. That is M15's B1.
2. **The re-wrap record.**
   - **Its form:** SetTags format 5 (`SET_ENVELOPE_FORMAT`). It replaces a version's `x-amz-server-side-encryption`
     field when its generation still matches, as the other formats do their fields.
   - **What it changes:** the envelope only, so the version id, generation and ETag stay.
   - **Which envelopes:** SSE-S3 only.
     - **KMS envelopes are not moved:** a KMS key is the one a client named (by request or by bucket default), and
       moving it would change what HeadObject says. A KMS key is still retired only once nothing needs it (ADR-0096
       §3).
     - **SSE-C envelopes have no master key.**
   - **Uploads in progress are not re-wrapped:** they complete or are aborted, and a removal waits for them.
   - **Its durability:** the record goes through the journal as SetTags does, so its fault sweep is SetTags' with
     the new format (ADR-0004).
3. **The re-wrap pass.**
   - **When:** each upkeep round re-wraps up to 1,000 versions whose SSE-S3 key is not its file's first, under the
     first, resuming from where the last round stopped.
   - **How a version is re-wrapped:**
     - its data key is unwrapped with the old key and wrapped with the first, in memory;
     - the record is written under the store's lock;
     - the version's bytes are not read.
   - **A rotation is then:** put the new key first; wait until the old key's count is zero (`/_cosmostore/stats`
     and `cluster-status` show each key's count); remove the old key from the file.
4. **On a cluster:**
   - **Who re-wraps:** each shard's leader, a batch a round, by the same record through the shard's log, as it
     applies lifecycle (ADR-0089 §6).
   - **How a node takes a master key's removal:** it asks every shard's leader for its count under the key, as
     `cluster-status` asks. It takes the removal when every shard's leader answers zero, and refuses it otherwise
     (logged, tried again when the file next changes): a shard with no answer, or a count above zero.
   - **What could still land between the ask and the take:** an SSE-S3 version under a key that is no longer first
     cannot, as nothing seals new ones under it. A KMS request that names the key explicitly can, as ADR-0096 §3
     said for `serve`. It fails its commit on the node that took the removal (`sealKeyHeld`). Operators should
     remove a KMS key from bucket defaults first.
   - **Amended by the exit review (docs/m17-exit-review.md, A1 and A2):**
     - **Which counts are trusted:**
       - a leader reports counts only when caught up (an entry of its own term committed, and applied to
         `commit`);
       - a shard's report counts only from a leader of the highest term any node shows for it;
       - every node must answer.
     - **What each node shows:** the keys it holds, by id and a tag (HMAC under the cluster's secret).
     - **When a leader re-wraps:** only under a first key every node was last seen to hold.
     - **When a removal is refused:** while any node has the SSE-S3 key first.
     - **The rule for operators:** add the new key on every node; put it first on every node; wait until the old
       key's count is 0; remove it.
5. **Key bytes wiped (M15's B2).**
   - **The problem:** a set's keys are read without a lock (ADR-0050), so a removed key's bytes cannot be zeroed in
     place.
   - **The design:**
     - the keys' bytes live in a table of atomic cells, one per key;
     - a set names its keys' cells;
     - a reader copies a key into a local array for its use, and zeroes it after;
     - a removed key's cell is zeroed once no current set names it.
   - **If CeeSafe cannot express this without `unsafe`,** it is recorded in CEESAFE_GAPS.md and left for later.

## Slices

1. The counts, in the index and the uploads' table; the removal check reads them (serve's walk removed).
2. The re-wrap record: format 5, the store's call, replay and a checkpoint, and its fault sweep.
3. The re-wrap pass on `serve`, and each key's count in the stats. The S3 smoke rotates a key without a restart.
4. A cluster: leaders re-wrap; the counts are asked of the leaders; a node takes a removal; `cluster-status` shows
   the counts. The cluster smoke rotates a key.
5. Key bytes wiped.
6. The exit review.

## Consequences

- **The journal:** SetTags format 5 is new, so an older binary cannot open a store that has one.
- **The checkpoint:** no new format; the counts are rebuilt at load.
- **A rotation's cost:** one small record per version, a batch per round. A store of N versions under the old key
  takes N / 1,000 rounds.
