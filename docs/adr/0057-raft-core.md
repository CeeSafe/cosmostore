# ADR-0057: The Raft core, a state machine without I/O, and its simulation

**Status:** accepted for M6 item 1 (ADR-0056), 14 Nov 2026, as recommended (the owner: "I accept ADR-0056 and ADR-0057 as recommended"), and built (`src/cluster/raft.cee`,
`src/cluster/raft_tests.cee`).

## Context

ADR-0056 puts a Raft group under each shard, with the journal as its log, peers over HTTP and the store as its
state machine. Consensus bugs show up as rare interleavings of crashes, elections and delayed messages, which tests
against real processes hit by luck. A core that does no I/O and takes its time and randomness from its host can be
run through millions of such interleavings, reproduced from a seed (the approach of etcd's raft and of
FoundationDB's simulation).

## Decision

1. **The core** (`RaftCore`) holds a replica's Raft state: role, term, vote, leader, the log after its snapshot,
   commit and applied indexes, the leader's view of each peer, pending reads. Inputs: `tick()`,
   `step(message)`, `propose(data)`, `readIndex(id)`, `compact(index)`. Output: `ready()`, a `RaftReady` of a
   snapshot to install, entries to persist (replacing the log from the first one's index), a hard state (term, vote,
   a commit index), messages, committed entries to apply, and reads that may be served; then `advance()`. The host
   persists before it sends and applies, and gives the core nothing more until `advance()`. Times are ticks; the
   election timer's randomness is a seeded SplitMix64, so a run is fixed by its seeds.
2. **The protocol** is Raft's (Ongaro's thesis), with:
   - **pre-vote** (§9.6): a replica asks whether it could win before it raises its term, so one that was cut off
     does not depose a working leader when it returns;
   - **leader stickiness and check-quorum** (§4.2.3, §6.2): a replica that heard from its leader within an election
     timeout ignores vote requests, and a leader that has not heard from a quorum within one steps down, so that a
     leader cut off from the others stops taking requests it cannot commit (availability: reads are kept safe by
     ReadIndex's round, not by this);
   - **commit only of the leader's own term** (§5.4.2), with an empty entry from each new leader;
   - **ReadIndex** (§6.4): a read takes the commit index once the leader has committed an entry of its term, and is
     released when a quorum has answered a heartbeat round sent after it; no clocks;
   - **a leader counts its own entries only once its host persisted them**;
   - **refusal hints**: a follower that lacks an entry names its last; one that conflicts names the entry before the
     conflicting term, so the leader skips a term at a time;
   - **snapshots**: a peer whose next entry is compacted away is sent the snapshot's index and term, and the host
     attaches the state; a follower that already has its last entry keeps its log after it.
   Static voters only: membership changes are item 6.
3. **The simulation** (`raft_tests.cee`) runs 3 or 5 replicas, each with a disk (hard state, log, snapshot and its
   state) that survives its crash; everything else is lost. A seeded network drops (10%), duplicates (5%), delays
   (up to 4 ticks, and 5% of messages up to 30, so a stale message arrives after newer ones were answered) and so
   reorders messages, and partitions the replicas (one alone, often the leader; two sides; or healed). Replicas crash
   (between persisting and sending too) and come back from their disks, and pause (5 to 45 ticks without ticking or
   taking messages, as a stopped process or a stalled VM; the others' clocks run on). Hosts compact behind the
   applied index, so lagging followers get snapshots; appends carry at most 3 entries, so followers lag. Clients
   propose at whoever leads and ask it for reads. After 1500 ticks the faults stop, and the run must elect a leader
   and bring every replica to the same state.
4. **The checker** fails the run at once on: two leaders in one term; two replicas applying different entries at one
   index, or an applied entry lost (an index's first applied value is the value for every replica, snapshots
   included); entries applied out of order; a term going back or a vote changing within a term on disk; a read
   whose index is below an entry any replica had applied when the read was asked (a stale read); a read released
   twice. 300 seeds with 3 replicas and 100 with 5 run in `ceesafec test`, with directed tests of a conflicting
   suffix, a stale leader, a stale snapshot and a read's quorum.
5. **The checker is tested by mutants**, each of which must fail it:

   | Mutant | Fails |
   |---|---|
   | commit an earlier term's entry by counting (Raft's Figure 8) | the 3-replica simulation |
   | grant votes and pre-votes without the up-to-date check | both simulations |
   | two votes in one term | both simulations |
   | a read before the leader has committed in its term | both simulations |
   | a follower's commit past the last entry the leader sent | both simulations |
   | a read released without any confirmation | both simulations (once replicas pause), the read test |
   | a read released on one peer's answer | the read test (with 3 replicas one peer is a quorum) |
   | a snapshot that drops a log it matches | the stale-snapshot test |

   Two more are no faults under this contract and are not in the list: a leader counting entries it has not
   persisted (its host persists every ready before the next input), and no check-quorum (it costs availability, not
   safety). The first runs found 2 of 9; the faults above (late messages, a leader alone, smaller appends, pauses)
   and the directed tests are what it took.

## Consequences

- Item 2 puts the core over the journal: entries become records with their Raft index and term, the hard state a
  small synced file, the snapshot a checkpoint. The core keeps the entries after its last compaction in memory; the
  store compacts at each checkpoint (every 64 MiB of journal by default), which bounds that.
- The simulation is the place a later protocol change is tried first: membership changes (item 6) add their own
  properties to the checker.
- What the simulation cannot show: performance, and a host that breaks the contract; item 3's tests and the chaos
  harness (item 9) cover those.

## Rejected

- **Porting etcd's raft** line by line: its storage interface, flow control and configuration changes are more than
  item 1 needs, and CeeSafe has no interfaces with the same shape; the protocol is the same.
- **Tests with threads and real timers:** not reproducible, and slow to reach rare interleavings.
- **Leases for reads:** they trust clocks (ADR-0056, rejected there).
