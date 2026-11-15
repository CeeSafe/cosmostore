# ADR-0067: Group 0 moves off a node that leaves; a lost log is sent again (M6 exit gap)

**Status:** proposed, 15 Nov 2026, for the gaps of the M6 exit review (`docs/m6-exit-review.md`), which the owner
asked to fix before closing M6 ("Fix all those gaps before closing").

## Context

- Group 0, the Raft group that holds the active set (ADR-0062 §3, as built), stayed on the first three active nodes,
  every other roster node its learner. A node of those three could not be taken out, so a disk lost on one of them
  had no safe way back: the runbook said to keep them on redundant disks.
- Taking a node out, wiping it and starting it with `--join` (ADR-0066) works for a shard because the shard removes
  the node and adds it again: its leader keeps no state of the old one. A node of group 0 is never removed (every
  node reads the active set from its replica of group 0), so the leader kept what the node had acknowledged before
  its disk was lost. Raft's leader never lowers a peer's match (a healthy replica never loses what it acknowledged),
  so it went on counting the wiped node as matched: never sending it the log again, and calling it caught up.

## Decision

1. **Group 0's target** is three voters among the active nodes: its voters that are still active, in their order;
   then active nodes of failure domains not yet among them, in the roster's order; then any active nodes.
2. **Group 0's leader moves it there** as each shard's leader moves its shard (ADR-0062 §4), one change at a time,
   except that no node leaves group 0: a target node that is not in it joins as a learner; a target learner that has
   caught up becomes a voter; then a voter the target leaves out becomes a learner (the leader too, which then steps
   down). `cluster-leave` of one of the three moves group 0's vote elsewhere before the node may be wiped.
3. **A lost log is sent again.** A replica's refusal of an append whose hint (its last entry) is below what it
   acknowledged means it lost its log. The leader lowers its match to the hint and sends from there (or a snapshot).
   The commit index does not go back: an entry committed with the lost replica's help was on a majority when it was
   committed, and ADR-0066 makes sure a voter is never wiped.

## Consequences

- The runbook's "keep the first three on redundant disks" goes: any node can be taken out, wiped and joined again.
- `raftALostLogIsSentAgain` is the core's case. `tools/cluster_identity_smoke.sh` takes node 1 (one of the three
  group 0 began on) out: group 0 keeps three voters without it, and node 1, wiped, comes back with `--join`, holds
  replicas, and takes writes. The chaos harness's `lose-disk` now loses any node's disk, not only the fourth's.
- Group 0 can still be left with fewer than three voters when fewer than three nodes are active; `cluster-leave`
  refuses to leave fewer active nodes than `replicas` (409).

## Rejected

- **Removing the node from group 0** and adding it back: a node outside group 0 has no replica to read the active
  set from, and every node needs it.
- **An incarnation number in every message**, so that a leader drops a peer's state when it changes: it changes the
  wire format of every message for what one refusal already says.
