# ADR-0062: Membership changes, group 0, placement and rebalance (M6 item 6)

**Status:** proposed for M6 item 6 (ADR-0056 §5), 15 Nov 2026, started under the owner's standing go-ahead ("From now
on, I give you permission to commit and push, then start the next"). Slice a is built.

## Context

- **Today** (ADR-0059) the node set and the placement are the cluster file's: every node computes the same placement
  by rendezvous hashing, and a shard's voters are fixed when its replicas are made. The file's digest goes with every
  request, so nodes with different files never talk. Adding or removing a node means a new file everywhere and a
  restart, and nothing moves a shard's data.
- **ADR-0056 §5:** from item 6 on, membership and placement are the state of a group of their own (group 0), changed by
  single-server Raft changes, one node at a time. **Done when** a node added or removed moves its shards without a
  stale read.
- **Raft's single-server changes** (Ongaro's thesis §4.1, with its 2015 correction): a configuration that differs from
  the last by one voter can be adopted without joint consensus, as long as a leader proposes a change only when its
  previous one is committed and it has committed an entry of its own term. A server uses the latest configuration in
  its log, committed or not, and goes back to the previous one if that entry is cut off. A new server joins as a
  learner (it gets the log, it does not vote) until it has caught up, so the group does not lose its quorum while it
  copies.

## Decision

1. **Configurations in the core** (`raft.cee`): voters and learners; a learner is replicated to and counts for nothing;
   only a voter campaigns, votes counted, quorums of voters. The core keeps the configuration of each configuration
   entry in its log after its snapshot, and the snapshot's; the latest one is in force; cutting entries off restores
   the one before. `proposeConfig(voters, learners)` refuses while an earlier change is uncommitted or before the
   leader has committed an entry of its term; the change may add or remove one voter, or add, promote or remove
   learners. A leader that removes itself steps down once that change is committed. Snapshots carry their
   configuration.
2. **Configurations in the log:** a record type of its own, `Config` (16), the voters and learners. The host tells the
   core about a configuration entry when it persists it (the core keeps terms, not entries, ADR-0058 §7); a checkpoint
   records the configuration at its index (checkpoint format 16) and a snapshot carries it.
3. **Group 0:** a Raft group of its own on up to five nodes (the first five of the cluster file at bootstrap), its
   state a store like a shard's, holding the cluster's membership (each node's id, peer address, domain, and whether it
   is joining, active or leaving) and the placement (each shard's replicas). The cluster file becomes the bootstrap:
   its digest covers what cannot change (the name, the shard count, the secret); nodes come and go through group 0.
4. **Placement:** group 0's leader computes it from the membership with ADR-0059's rendezvous rule, and when it differs
   from the placement in force, moves one replica at a time, per shard: the new replica joins as a learner, is promoted
   once its applied index is within a few entries of the leader's, and then the replica that goes is removed. The
   replica removed deletes its directory once the change that removed it is committed and it has heard of it.
5. **Operators:** `cosmostore cluster-join` (a node with an empty directory, a peer address and a domain asks group 0
   to add it), `cosmostore cluster-leave` (a node asks to be drained, then removed), and the status shows each
   shard's voters and learners. A node a quorum cannot reach is removed by `cluster-remove`, its replicas replaced.
6. **No stale reads across changes:** reads stay ReadIndex reads of the configuration in force; a node that is not
   in a shard's configuration any more answers 421 and the front asks again (ADR-0060 §4).

## Slices

| Slice | What | Done when |
|---|---|---|
| a | the core's configurations, learners and changes (§1), in the simulation | ADR-0057's checker holds over thousands of seeded runs with random changes under faults; mutants of the change rules fail it |
| b | the `Config` record, checkpoints and snapshots with configurations (§2); a replica added and one removed in the in-process tests | the replica sweeps pass with a group going from three replicas to four and back |
| c | group 0, the membership, placement and rebalance (§3–§6); the commands | `tools/cluster_s3_smoke.sh` with a fourth node added and one removed during a run, no stale read |

## Consequences

- The cluster file stops being the membership; a node added needs only the bootstrap file, its secret and a join.
- A shard moving copies its whole store to the new replica (a snapshot, ADR-0058 §9, and its extents, ADR-0061 §3).
- Group 0 is one more Raft group on a few nodes; its state is small.

## Rejected

- **Joint consensus:** it allows arbitrary changes in one step, which the rebalancer does not need; single-server
  changes are simpler and are what the simulation can check exhaustively.
- **Placement left to every node's own computation:** two nodes that disagree on membership would move replicas
  differently; group 0 decides, everyone follows.
