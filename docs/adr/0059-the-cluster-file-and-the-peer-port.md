# ADR-0059: The cluster file, the peer port and signed messages (M6 item 3)

**Status:** accepted for M6 item 3 (ADR-0056 §5, §6), 15 Nov 2026, as recommended (the owner: "I accept ADR-0059 as
recommended"), asked for by the owner ("Yes. Go ahead", after item 2); built (slices a and b).

## Context

- **Item 2** (ADR-0058) made a shard's replica: the store over a Raft log, the core, the hard state, snapshots; three
  replicas agree in one process, under every fault sweep, over an in-memory network. Item 3 puts them in separate
  `serve` processes. **Done when** three `serve` processes elect a leader and replicate (ADR-0056's table).
- **ADR-0056** fixed the frame: a cluster file names the nodes, their failure domains, a shared secret and the shard
  count; placement is rendezvous hashing, one replica per failure domain where there are enough; peers talk HTTP/1.1
  on a port of their own, each request signed with HMAC-SHA256 under the cluster secret, its time and a nonce; Raft's
  messages are batched per peer, one request at a time, so a slow peer delays only itself.
- **What `serve` has:** CeeSafe.Web's server and client (the client already delivers event notifications, ADR-0048);
  a store behind an `AsyncMutex`, its I/O on `Async.blocking` workers (N0295); upkeep raced beside the server.
  lib/std has `Sha256`, `HmacSha256`, `Random.fill` and timers.
- **What is not item 3:** S3 requests on a cluster (item 4: routing, forwarding, ReadIndex), extents (item 5),
  membership changes (item 6). Until item 4 a node serves no S3; until item 6 the node set is the file's.

## Decision

1. **The cluster file** (`cosmostore node <dir> --cluster-file <path> --node <id>`; §8), lines of words, `#` to the
   end of a line:
   ```text
   cluster 7f3a9c2e5b1d4f60          # the cluster's name: 16 hex digits
   shards 16                         # fixed when the cluster is made (ADR-0056 §4)
   replicas 3                        # per shard, at most the node count
   secret-file /etc/cosmostore/cluster.key   # base64 of 32 bytes, the same on every node
   node 1 peer=10.0.0.1:9100 domain=rack-a
   node 2 peer=10.0.0.2:9100 domain=rack-b
   node 3 peer=10.0.0.3:9100 domain=rack-c
   ```
   Node ids are 1 to 255, distinct; a peer address is `a.b.c.d:port` or `[v6]:port`; a domain is 1 to 64 of
   `A-Z a-z 0-9 . _ -`. A file that does not parse stops `serve`, as a key file does. Every request between nodes
   carries the SHA-256 of the file's canonical form (its lines, comments and spacing removed, in order) and a node
   refuses one whose digest differs from its own: two nodes that disagree on the placement never talk.
2. **Placement:** shard `s` goes to the `replicas` nodes with the highest score `SHA-256(cluster ‖ s ‖ node)`, taking
   at most one node per domain while there are domains left, then the next highest. Every node computes the same
   placement from the same file; a node holds a replica of each shard placed on it, in `<data>/shard-<2 hex>/`
   (ADR-0058's replica directory).
3. **The peer port** is the node's `peer=` address, plain HTTP/1.1 for now: a private network, every request signed.
   TLS on it, with the cluster's own certificate authority, is a slice of its own; the signature does not depend on
   it.
4. **Signed requests:** headers `x-cosmo-cluster` (the digest), `x-cosmo-node` (the sender), `x-cosmo-time` (Unix
   milliseconds), `x-cosmo-nonce` (16 random bytes, hex) and `x-cosmo-signature`, the hex HMAC-SHA256 under the
   secret of `cosmo-peer-v1`, the method, the path, the digest, the sender, the time, the nonce and the body's
   SHA-256, one per line. A node refuses (403, and a count in its stats) a request whose signature is wrong, whose
   sender is not in the file or is itself, whose time is more than 60 s from its own, or whose nonce it has seen from
   that sender in the last two minutes. Raft tolerates a replayed message, but item 4's forwarded writes would not.
5. **Raft's messages:** `POST /raft`, its body a batch: u32 count, then per message u16 shard and the message
   encoded (its kind, ids, term, index, log term, commit, flags, round, entries as term, index and record, snapshot
   data; little-endian, lengths before bytes, all checked on decoding). 204 once the messages are handed to their
   replicas. Replies go back as the receiver's own batches, not in the response: both directions are the same code.
6. **The node's runtime:** each replica behind its own `AsyncMutex`; a tick every 100 ms (an election timeout of 10 to
   20 ticks, a heartbeat every tick) steps every replica and drains it on a worker (`Async.blocking`: its journal and
   hard state do I/O); a message received is stepped and drained the same way. What a replica sends goes to its
   peer's queue; one sender per peer takes the whole queue, posts it, and on failure drops it (Raft sends again) and
   waits 100 ms before the next. A replica's upkeep (`maintain`) runs every 50 ticks.
7. **Status:** `GET /cluster/status` on the peer port, signed like the rest: one line per replica (shard, role, term,
   leader, last, commit, applied). `cosmostore cluster-status --cluster-file <path> --node <id>` signs and prints it,
   so an operator and `tools/cluster_smoke.sh` need nothing else. It signs as sender 0, an operator who holds the
   secret, which a node takes for the status only, never for `/raft`.
8. **A command of its own until item 4:** `cosmostore node <dir> --cluster-file <path> --node <id>` runs a node: its
   peer port and its replicas, no S3. `serve`'s arguments (a port, a credentials file) mean nothing to it yet; item 4
   brings S3 to the node, and the two commands together.

## Slices

| Slice | What | Done when |
|---|---|---|
| a | the cluster file and placement, the wire format, signing and checking requests (§1, §2, §4, §5) | unit tests of parsing, placement (determinism, domains), round trips, and every refusal of §4 |
| b | the runtime, the peer port, the status and its command, `cosmostore node` (§3, §6–§8) | `tools/cluster_smoke.sh`: three processes elect one leader per shard and agree; a leader killed is replaced; a node restarted catches up |

## Consequences

- A cluster runs, with nothing to write to it yet: each election's empty entry is what replicates, and what the smoke
  test watches. S3 comes with item 4.
- The peer port is plain until its TLS slice: the signature keeps a node from taking messages it did not sign for,
  but on an untrusted network the traffic (records, so objects) can be read. The runbook says so.
- One request in flight per peer: a slow peer delays only its own queue, which grows until its request returns; a
  queue's messages are dropped on failure, so it is bounded by a tick's worth per shard.

## Rejected

- **gRPC or a binary protocol of our own:** CeeSafe.Web's HTTP/1.1 is what `serve` and its client already use, and a
  batch per request keeps the overhead small.
- **Replies in the HTTP response:** the reply of a step comes after its drain, perhaps after a sync; holding the
  request open would tie a sender to the slowest replica on the other side.
- **Placement by a table in the file:** rendezvous hashing needs no table, and moving a shard is item 6's.
- **Mutual TLS instead of signatures:** it needs certificates on every node before anything works; the signature
  works on the first start and stays when TLS comes.
