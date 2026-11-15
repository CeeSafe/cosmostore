# ADR-0066: A node's directory knows whose it is; an empty one starts only as told (M6 exit gap)

**Status:** accepted, 15 Nov 2026, as recommended (the owner: "Yes I accept ADR-0066 to ADR-0070 as recommended"); for
the gaps of the M6 exit review (`docs/m6-exit-review.md`), which the owner
asked to fix before closing M6 ("Fix all those gaps before closing").

## Context

- A node keeps each shard's term and vote in its directory (ADR-0058). Started again on an empty directory under its
  id, it opens every shard as the cluster began (its initial placement): a node that was a voter is one again, with
  no memory of the votes it gave. It can vote twice in a term, and two leaders of one term become possible. Nothing
  stopped it; the runbook only said not to.
- A disk lost is recovered from by taking the node out (`cluster-leave`), wiping it, starting it, and joining it
  again (ADR-0062). The node started on the empty directory must then be a replica of no shard until a leader adds it.

## Decision

1. **A marker.** The first time a node starts in a directory, it writes `<dir>/cosmo-node`: the cluster file's
   digest, the node's id, and how it began (`start init` or `start join`), through a temporary file renamed into
   place, synced, its directory synced. Later starts read it, and refuse a directory whose marker names another
   cluster or another node (a directory copied, or a path mistyped). A directory with a node's data from before
   markers (group 0's hard state) is taken as `init` and gets its marker.
2. **An empty directory starts only as told.** Without a marker or data, the node refuses to start unless given
   `--init` (the cluster is being formed, or the node was never part of it: the operator says so) or `--join` (it
   joins, or comes back after its disk was lost). With `--join`, it first asks its peers for their status (signed, as
   the operator): unless a majority of them answer and none lists it among a shard's voters, it refuses, and says to
   run `cluster-leave` first. Nothing is written until it may start.
3. **A node that joined** opens every shard it holds nothing of without itself in the shard's group, on every start:
   it is no voter until a leader adds it as a learner and promotes it, with a log it caught up.
4. **`cluster-join` and `cluster-leave` keep trying** for about fifteen seconds, pausing between rounds: a group 0
   between leaders answered at once, and ten rounds back to back were over in milliseconds (found by the smoke).

## As built

- **A removed replica's word is not taken.** A replica its shard removed never hears of the removal: it goes on
  showing the group it was removed from (harmless, since it only pre-votes and is never granted). The `--join` check
  therefore judges each shard by the view of its highest term among the peers' answers, a leader's before others of
  that term. A first version took any peer's word, and a disk-loss run under load waited 90 s on a node that one stale
  replica still listed; the chaos harness and the identity smoke count the same way now.

## Consequences

- Starting a cluster takes `--init` on each node's first start (ignored once the marker is there). `--init` is the
  operator's word: given on a wiped voter's directory, it would bring the hazard back, so the runbook says when each
  flag is right.
- `tools/cluster_identity_smoke.sh` (17 checks): an empty directory without a flag refused; a voter's empty
  directory refused `--join`, nothing written; another node's directory refused; restarts need no flag; node 4 out,
  wiped, back with `--join`, holding replicas, the data read through it. The chaos harness starts with `--init` and
  restarts a wiped node with `--join`.

## Rejected

- **Detecting the loss inside Raft** (a node that finds no hard state refuses to vote until it has heard from a
  leader): a leader's message does not say whether the node is still a voter of a configuration it has forgotten, and
  a cluster being formed has every node in that state.
- **`--join` as the default for an empty directory:** a cluster being formed has no peer that could answer for it.
