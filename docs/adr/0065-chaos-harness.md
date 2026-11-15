# ADR-0065: The chaos harness and its linearizability check (M6 item 9)

**Status:** proposed for M6 item 9 (ADR-0056 §10), 15 Nov 2026, under the owner's standing go-ahead.

## Context

- **ADR-0056 §10:** after the seeded simulation and the crash model, "a process-level harness
  (`tools/cluster_chaos.sh`) kills, pauses and partitions real `serve` processes behind a proxy of our own (no
  firewall rules: our hosts run the owner's services) and checks a history of S3 operations for linearizability".
  **M6's exit:** under injected node, disk, rack and network failures, acknowledged writes survive and no stale reads
  or lists occur.
- **What exists:** the Raft simulation's checker (ADR-0057), the crash model's sweeps of each journal (ADR-0004), and
  smoke tests that kill a node and read back. None runs real processes against faults while clients race, and none
  checks what the clients saw against a model.

## Decision

1. **One program, standard-library Python** (`tools/cluster_chaos.py`, the way `tools/s3_raw.py` is): it starts the
   nodes, runs the proxy, the clients and the faults, and checks the history. `tools/cluster_chaos.sh` builds and runs
   it. Nothing is installed and no firewall is touched.
2. **The proxy:** the cluster file names, as each node's peer address, a port of the proxy's; the node listens on
   another (`node --peer-listen`). The proxy reads the first request of each connection for its `x-cosmo-node`
   header (the sender, signed, ADR-0059 §4) and pipes the connection to its node unless the link between the sender
   and that node is cut; cutting a link closes its open connections and refuses new ones. The operator (sender 0,
   `cluster-status`) is never cut. Partitions are sets of cut links: one node isolated, the leader isolated, a
   majority and a minority, a bridge (one node that sees both sides).
3. **The faults** (the nemesis), one at a time with a heal after each, at random: a node killed (`SIGKILL`) and
   restarted, a node paused (`SIGSTOP`, then `SIGCONT`), a partition. Clients go straight to the nodes' S3 ports, so a
   node on the minority side still takes requests: that is the stale read the check must not see.
4. **The clients:** several threads, each one operation at a time against a random node, on a few keys of one bucket:
   PUT of a value no other write has (some large enough to be extents), GET, DELETE, and ListObjectsV2. No retries.
   Each operation is recorded with its start and end on one monotonic clock and its outcome: done, failed (a 4xx
   refusal: it did not happen), or unknown (a 5xx, a timeout, a dropped connection: it may have happened).
5. **The check:** linearizability per key (it composes, so the history is linearizable if each key's is), by
   Wing–Gong–Lowe search with memoization (Lowe 2017; the algorithm Porcupine and Knossos use) against a register
   whose state is a value or absent. A PUT writes its value, a DELETE writes absent, a GET reads, and a listing reads
   each key's presence. An unknown write may take effect at any time after it began, or never. One whose value no
   GET read can only stand in the way of GETs, and is left out; but a listing sees only that a key is there, which any
   of them explains, so the search keeps the earliest of them first (one that began earlier can stand in for a later
   one, its end being open), and, if that finds no order, all of those that began in the five seconds before the
   operation it could not get past. Leaving operations out can only make a history harder to explain, so a pass is a
   pass; a failure names the operation, or says the search was too large to settle it, and fails the run either way.
   A read without an answer says nothing, and is left out. After the faults, everything is healed and every key is read through every node: those reads must answer
   (the cluster came back), and they are part of the history, so an acknowledged write lost shows as a read that no
   order explains.
6. **The checker is tested** (`--self-test`): histories that are linearizable pass, and a stale read, a lost
   acknowledged write, a read of a value never written and a listing that misses a present key fail. A mutant that
   serves reads without ReadIndex must be caught by a run of the harness.
7. **Clock skew and disk loss** (the second slice). Raft runs on ticks, not the clock; the clock matters between
   nodes in the peer signatures' 60 s window, and a test-only `node --clock-skew-ms` moves a node's clock there (what
   it signs with and checks by). The `skew` fault restarts a node with its clock 20 to 100 s off for a few seconds:
   within the window nothing changes, past it the node is cut off as by a partition. A disk lost is recovered from
   as the runbook says (ADR-0062): `--disk-loss` runs four nodes, the fourth joined from standby, and its `lose-disk`
   fault kills that node, takes it out with `cluster-leave`, waits until no shard has it, wipes its directory, starts
   it and joins it again, and waits for shards to come back to it. Only a node outside group 0 can be lost so:
   group 0 stays on the first three (ADR-0062 §3). A node started again on an empty directory under its id would
   vote again in terms it voted in, and nothing detects it; the runbook says never to.

## As built

- **`tools/cluster_chaos.py`** (the proxy, the clients, the faults, the checker) and **`tools/cluster_chaos.sh`** (the
  self-test, then `RUNS` runs of `SECONDS_EACH`, `NODES` nodes); `--nemesis` picks the faults a run chooses from.
  `node --peer-listen` moves a node's peer port behind the proxy.
- **The checker's self-test** has 17 histories, each one linearizable or not, among them the stale read, the lost
  write, the value never written, a listing that is stale either way, unknown writes seen and unseen, and 3000
  operations in a row.
- **`tools/chaos_mutants.sh`**: two mutants of the read path, a leader that answers without its ReadIndex round
  (with the leader isolated) and any replica answering from its own store (with isolations, splits and pauses). The
  harness kills both. Under the same seeds and faults, the build without mutants passes.
- **The harness found a real bug in its first runs**, two of three: a node that forwards a write to its shard's
  leader sent it again when the exchange failed, and the exchange fails when a partition drops the leader's answer
  after the write is done. The write was done twice: the second time after a DELETE and two listings that saw the
  key gone, and the final reads saw it back. A forwarded write is now sent again only when it was certainly not
  done: a 421 (the leader refused it before staging anything) or a connection refused (nothing was sent). Otherwise
  the client is answered 503 and finds out for itself, as with a timeout. (Writes that are idempotent end to end need
  client request ids in the log, the Raft thesis's sessions, §6.3: later work.)
- **And a second:** a replica stopped itself on "journal corrupt" when a new leader's entry came for the index of a
  write of its own still in flight as a leader (written, its group-commit sync running without the store's lock):
  reading that entry's term read past the synced end, which the journal took for damage, and the cut that should
  follow refused a batch in flight. The journal now reads what it has written, synced or not, and a cut makes the
  batch in flight durable first; `raftLogCutsABatchInFlight` is the case.
- **And a third:** after a heal, a deposed leader could stay one for over a minute, so its shard answered nothing
  through it. Reads waiting for the core to take their ReadIndex held the replica's lock across each pause, and the
  tick that would have made the core step down waited behind them (a log of slow ticks showed 78 s for the lock).
  The lock is let go before each pause now, and no lock but a shard's write gate is held across a pause or a send
  (the peer port's extent answers were sent holding the store's).
- **Slice b:** under clock skew alone (twelve skews from −100 s to +95 s in a minute) and under disk loss (four
  nodes, every fault, node 4's disk lost and recovered from three to nine times a run while it held replicas), the
  histories are linearizable.
- **Diagnostics it brought:** `cluster-status` prints `# peer <ticks> <sent> <unsent> <received> <refused>`; a node
  logs a tick that took over a second, with where the time went; a replica stopped fails a run; a final read slow
  to come back saves every node's status and, on macOS, a `sample` of its threads, in the work directory.

## Consequences

- A run takes about a minute and finds a violation with the key and the operations around it; the work directory is
  kept for the nodes' logs.
- Each run is random; a seed makes the schedule of faults and operations repeatable, not the processes' timing.

## Rejected

- **Jepsen itself:** Clojure, SSH to dedicated machines, and iptables: our hosts run the owner's services.
- **iptables, `tc` or `pfctl` for partitions:** they change the host's network for everything on it.
- **Checking whole-history linearizability across keys:** exponential in the keys, and per-key checks are as strong
  for single-key operations; listings are checked per key, which finds a listing that is stale on any key but not one
  that is a mixture of two moments (no S3 client can rely on that either).
