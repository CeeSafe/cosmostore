# ADR-0062: Membership changes, group 0, placement and rebalance (M6 item 6)

**Status:** accepted for M6 item 6 (ADR-0056 §5), 15 Nov 2026, as recommended (the owner: "I accept ADRS: ADR-0062 to ADR-0065 as recommended"); started under the owner's
standing go-ahead ("From now on, I give you permission to commit and push, then start the next"). Slices a, b and c
are built (c narrower than §3 to §5: see As built).

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

## As built (slices a to c, 15 Nov 2026)

Slices a and b are as decided. Slice c is a narrower §3 to §5, to be widened later:

- **The cluster file stays the roster:** every node that may ever take part is in it, with its address, and a
  `standby` word keeps a node out when the cluster begins. Group 0 decides which roster nodes are *active*; a node
  not in the file cannot join, and the file's digest still covers all of it. Addresses that change while the cluster
  runs are later work.
- **Group 0 holds the active set only**, as an object of its store (`cosmo-system/active`), written by its leader
  (the bucket first, then the set: two writes, each committed before the next). Its voters are the first three
  active nodes when the cluster begins and do not move; every other roster node is its learner and has a copy.
- **No placement table:** a shard's target is ADR-0059's rule over the active set, and its Raft configuration is its
  placement. Each shard's leader steps toward its target once a second (`rebalance.cee`): a learner added, promoted
  once its log matches the commit index, a voter the target leaves out removed once every target node votes.
- **Every node holds a replica slot of every shard**, idle until its group adds it (a node outside a shard's group
  never campaigns); extents are pushed to and fetched from a shard's current group, not the file's placement.
- **A replica removed keeps its directory** (a later item removes it); it goes on as a pre-candidate that no member
  answers, as Raft's removed servers do, which pre-vote keeps harmless.
- **Commands:** `cosmostore cluster-join` and `cluster-leave --cluster-file <file> --node <id>` (signed as the
  operator, tried at each roster node until group 0's leader takes it; refused when fewer active nodes than
  replicas would be left). The status shows each shard's voters and learners.
- **Tests:** `tools/cluster_moves_smoke.sh`: four nodes, the fourth a standby; data written, a 5 MB object
  included; node 4 joins and shards move onto it; node 1 leaves and every shard moves off it; node 1 killed; all of
  it read back through the others; a background prober writing through one node and reading through the next all
  along, no stale read.
- **Found on the way:** group 0's first write made its bucket and put into it in one write, which in a Raft log
  fails (the bucket is not applied yet) and left a persisted, unproposed entry that blocked every later write. Two
  writes now, and a failed write cuts what it staged off.

## Consequences

- The cluster file stops being the membership; a node added needs only the bootstrap file, its secret and a join.
- A shard moving copies its whole store to the new replica (a snapshot, ADR-0058 §9, and its extents, ADR-0061 §3).
- Group 0 is one more Raft group on a few nodes; its state is small.

## Rejected

- **Joint consensus:** it allows arbitrary changes in one step, which the rebalancer does not need; single-server
  changes are simpler and are what the simulation can check exhaustively.
- **Placement left to every node's own computation:** two nodes that disagree on membership would move replicas
  differently; group 0 decides, everyone follows.
