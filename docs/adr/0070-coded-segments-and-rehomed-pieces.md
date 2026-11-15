# ADR-0070: Sealed segments coded; pieces re-homed when a holder leaves (M6 exit gap F)

**Status:** proposed, 15 Nov 2026, for the gaps of the M6 exit review (`docs/m6-exit-review.md`), which the owner
asked to fix before closing M6 ("Fix all those gaps before closing").

## Context

- ADR-0056 §9 named sealed packs for erasure coding; ADR-0064 coded extents only, and left segments replicated.
- **Found while planning it:** a coded extent's pieces are named by holder, the shard's voters when it was coded. A
  holder that leaves the shard (ADR-0062) takes its piece with it, and nothing made it again elsewhere: one more lost
  node and a 2+1 extent was gone.
- **Found while building it:** a Raft log's segments were not the same on every replica. A segment was sealed after a
  batch, once all its entries were committed, and each replica batches and learns commits on its own, so segment N
  ended a few entries apart from one replica to the next. A coding of segment N is of the leader's bytes; applied to a
  replica whose segment N is not those bytes, it threw away that replica's records (a first version of this did, in
  a smoke test: reads of objects in it failed).

## Decision

1. **Every replica's segments are the same bytes.** A Raft log seals its active segment before the record that would
   start at or past the target size, at the write of the batch that holds it (`commitAcrossSegments`), whatever the
   batches and whatever is committed; its segment headers carry no time. An uncommitted suffix can therefore start in
   a sealed segment: `truncateAfter` then removes the newer segments, newest first, the directory synced after each,
   and cuts the segment it starts in, which is active again. A crash between leaves a log without a gap. The group
   commit sends a batch that would seal a segment to the synchronous commit (which runs off the event loop).
2. **Sealed segments are coded** as extents are (ADR-0064): the shard's leader picks sealed segments wholly before the
   newest checkpoint's segment (Raft never sends an entry from there: a replica that far behind gets a snapshot), at
   least 1 MiB, mostly live (compaction would not take them), older than `--code-after-seconds`, not pinned. One
   `Coded` record, the coding marked as a segment's (the top bit of its m byte), its key the segment's id with the top
   bit set. Applying it, each replica writes its piece from its segment file and removes the file, unless the file is
   not the bytes coded (its first piece's CRC), in which case it keeps it.
3. **Reads** of an object in a coded segment with no whole copy here answer as reads of a coded extent do: wanted,
   decoded from k pieces into the segment's file again, kept an hour. Compaction does not copy out of a coded
   segment; when nothing in it is live, its pieces go. A snapshot carries only the segment files there are, so a
   replica installed from one decodes a coded segment the first time it reads from it.
4. **Pieces are re-homed.** The leader's coding loop also finds codings (extents and segments) with a holder that no
   longer votes, and proposes the same coding with that holder replaced by a voter that holds no piece of it; the
   new holder finds its piece missing and makes it from k others (ADR-0064 §4).
5. `node --segment-mb` sets a shard's segment size (and checkpoints at least as often), for tests and tuning.

## Consequences

- Cold inline objects cost (k+m)/k of their size in a cluster instead of the replica count times.
- A replica's segment boundaries no longer wait for commits.
- `raftLogSegmentsAreTheSameOnEveryReplica` (two logs, other batches and commit points, the same files byte for
  byte), `raftLogCutsAcrossSegments`, and the Raft log's fault sweeps; `sealedSegmentsAreCoded`;
  `tools/cluster_ec_segments_smoke.sh` (objects in coded segments read back, with the leader down too);
  `tools/cluster_ec_smoke.sh`'s last part (a holder leaves, its piece is made again on the node that took its place,
  byte for byte, and the object outlives another holder's loss).
- Found on the way: a first version told a segment's coding from an extent's by the key's top bit, but extent ids
  are random and half have it; the coding's record says which now.

## Rejected

- **Coding by LSN range instead of by segment:** an object's place is a segment and an offset on its replica, so a
  range decoded would have to be laid out as that replica's segment was; making segments the same is simpler, and
  useful for snapshots too.
- **Moving cold inline objects into pack extents first:** many versions would share one extent, which the extent
  reaping (one version, its extents) does not count.
