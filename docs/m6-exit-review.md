# M6 exit review: the distributed cluster (15 Nov 2026)

**M6's exit (ROADMAP):** under injected node, disk, rack and network failures, acknowledged writes survive and no
stale reads or lists occur. This review sets what was run against each part of that, what the runs found, and what
is not covered. ADR-0056 to ADR-0065 are accepted.

## How it was checked

- **The Raft core** (ADR-0057): a seeded simulation over thousands of runs with crashes, partitions, late and lost
  messages and membership changes, checked for one leader a term, matching logs, no committed entry lost, and applied
  sequences that are prefixes of one another; `tools/raft_mutants.sh` (12 mutants of the core's rules, every one
  killed).
- **Each node's disk** (ADR-0004): the fault injector and crash model under every journal, hard state, checkpoint and
  snapshot path, swept at every I/O (fail once, fail for good, torn writes, a crash dropping what was not synced);
  coded extents too (`codedFaultsOnce`, `codedFaultsCrash`).
- **The process level** (ADR-0065): `tools/cluster_chaos.py` runs real nodes behind a proxy of its own, injects
  faults while clients race on a few keys (PUT, GET, DELETE, ListObjectsV2), heals, reads every key through every
  node, and checks each key's history for linearizability. Its checker has a self-test of 17 histories, and
  `tools/chaos_mutants.sh` shows it catches stale reads (a leader without ReadIndex, a replica answering alone).

## The failures, and the evidence

| Failure | Injected as | Evidence |
|---|---|---|
| A node | `SIGKILL` and restart; `SIGSTOP` for seconds | every chaos run (mixed with the rest) |
| A network | one node cut off, the leader cut off, a minority split off, a bridge; links cut and their connections closed | every chaos run |
| A clock | a node's clock 20 to 100 s off where the cluster uses one (the peer signatures), `node --clock-skew-ms` | a run of skews only; every default run since |
| A disk | the crash model (unit level); a node's disk lost and recovered from the runbook's way (out, wiped, back in) | `--disk-loss` runs, up to nine losses each while the node held replicas |
| A rack | both nodes of one of three racks killed, or the rack cut off from the others | `--racks 3` runs (six nodes, one replica a rack) |
| Coded data | extents coded within seconds and decoded for reads, under all of the above | `--code-after-seconds 2` runs with keys that stay cold |

**Runs at the review** (commit 9331752 and later): on macOS (M1) dozens of one- to two-minute runs; on binfadel
(Ubuntu 24.04, Xeon) five 5-minute three-node runs, two five-node, two disk-loss and two rack runs; on alghobashi
(Debian 13) four three-node and two disk-loss runs. Each run is about 3,800 to 6,500 operations and 15 to 90 faults.
In every one, every key's history is linearizable (acknowledged writes are read back, no read or listing is stale),
and the cluster answers through every node after the heal.

## What it found on the way (all fixed, with tests where the bug was below the harness)

1. **A forwarded write done twice** (a partition dropped the leader's answer; the forwarding node sent it again after
   later writes): sent again only when certainly not done.
2. **A replica stopped on "journal corrupt"** (a new leader's entry met its own write still in group-commit flight):
   the journal reads what it wrote, and a cut syncs the batch in flight first (`raftLogCutsABatchInFlight`).
3. **A deposed leader stuck for over a minute after a heal** (reads waiting on ReadIndex held the replica's lock
   across their pauses and starved the tick): no lock but the write gate is held across a pause or a send.
4. **In item 8, a coded extent's whole copy removed with no piece written** after a failed read (the fault sweep).
5. Harness bugs: a pruning that hid unknown writes from listings; descriptors leaked (shown only on Linux's 1024).

## The gaps, closed (the owner: "Fix all those gaps before closing")

| Gap the first review left | What closed it | Evidence |
|---|---|---|
| A node started on an empty directory could vote twice | A directory marker; `--init` or `--join`, which asks the peers first (ADR-0066) | `tools/cluster_identity_smoke.sh` (25 checks) |
| Group 0 fixed on the first three nodes | Group 0 moves; a lost log is sent again, not counted as caught up (ADR-0067) | the identity smoke's group 0 part; `raftALostLogIsSentAgain`; disk loss of any node in the harness |
| Listings checked per key | The whole history checked as one register per key | the checker's self-test (a listing of two moments fails) |
| A write answered 503 may have been done, a resend done twice | Request ids and their answers in the log (ADR-0068) | `tools/cluster_sessions_check.py`; its mutant killed |
| One machine, a perfect network | Slow, flaky and throttled links; nodes on several machines through SSH tunnels (ADR-0069) | runs with nodes on this Mac, binfadel and alghobashi |
| Sealed packs not coded | Every replica's segments the same bytes; sealed segments coded; pieces re-homed when a holder leaves (ADR-0070) | `raftLogSegmentsAreTheSameOnEveryReplica`; `tools/cluster_ec_segments_smoke.sh`; the EC smoke's last part |

**Found while closing them:** a learner whose disk was replaced counted as caught up with an empty log; a replica a
shard removed still showing its old group, so a check that took any peer's word could wait for ever; segments that
were not the same on every replica, so that coding one would have thrown a follower's records away; coded pieces
staying with a holder that left; a segment's coding told from an extent's by a bit half of all extent ids have. Each
is fixed and tested.

## Not covered, or not yet

- **Listings across shards** are a merge of each shard's (ADR-0060 §7), not one moment of the whole cluster; S3 does
  not promise more.
- **A client's own retry** is a new write, as S3 has it; only the nodes' own resending is exactly once.
- **Clock skew** is injected where the cluster reads the clock (peer signatures), not system-wide.
- **The multi-machine runs** put the proxy and the clients on one machine, so every message between nodes crosses the
  network twice through it; no two nodes talk directly.
- **The limits the runbook lists** stand: no request streamed past 64 MiB, no copy between buckets of two shards, the
  peer port signed but not encrypted, and the cluster's S3 port without TLS, rate limits, audit or notifications.

## Verdict

For what M6 built, the exit holds: under node, disk, rack, network and clock failures, alone and together, on
three machines and two operating systems, and with nodes on separate machines, acknowledged writes survived and no
read or listing was stale. The gaps the first review listed are closed, each with a test; for the lost log, the write sessions, the
listings and the segments, the test was seen to fail without its fix.
