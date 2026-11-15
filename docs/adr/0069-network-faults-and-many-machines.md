# ADR-0069: A network that misbehaves, and nodes on several machines (M6 exit gap)

**Status:** proposed, 15 Nov 2026, for the gaps of the M6 exit review (`docs/m6-exit-review.md`), which the owner
asked to fix before closing M6 ("Fix all those gaps before closing").

## Context

- The chaos harness (ADR-0065) partitions links through a proxy of its own, but between partitions its network is
  perfect: no latency, no jitter, no connection dying mid-request, no slow link. And every node runs on the harness's
  machine, so the network is a loopback.
- Real failures in between: a slow or jittery network makes elections and ReadIndex rounds race their timeouts; a
  connection reset mid-request loses an answer after the work was done (ADR-0068's case); a throttled link makes a
  replica fall behind and need a snapshot.
- No firewall rule or traffic control may be used: the hosts run the owner's services (ADR-0056 §10).

## Decision

1. **The proxy shapes links.** Between a sender and a node, it can delay each chunk it forwards (a delay and a
   jitter), cap a link's bandwidth, and reset a connection at a chunk with some chance. Three faults use it: `slow`
   (every link 20 to 200 ms, jitter up to 100 ms), `flaky` (every link resets 1 to 5% of its chunks' connections) and
   `throttle` (one node's links at 50 to 200 KB/s). They are among the default faults.
2. **Nodes on several machines.** `--hosts` runs node i on the i-th host given (`local`, or `user@host` over SSH,
   the binary copied into a scratch directory there beforehand). The harness keeps the proxy and the clients; every
   node listens on its host's loopback only, and SSH tunnels carry its peer and S3 ports to the harness's machine and
   the proxy's ports to it (`-L`, `-R`): no port opens on any host's network, and every message between two nodes
   crosses the real network twice, through the proxy. Kills, pauses, skews and disk losses are done over SSH.

## Consequences

- `flaky` loses answers after the work was done often enough to show a write done twice: the mutant that turns
  ADR-0068's sessions off is killed by it, and it is in `tools/chaos_mutants.sh`.
- A multi-host run's latency is the real network's, between the harness's machine and each host.

## Rejected

- **`tc netem` or `pfctl` dummynet:** they shape the host's network for every program on it.
- **Nodes talking to each other directly across hosts:** their peer ports would have to listen on a public address,
  and partitions would need firewall rules.
