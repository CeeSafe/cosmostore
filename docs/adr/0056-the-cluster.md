# ADR-0056: The cluster: a Raft group per shard, the journal as its log (the M6 plan)

**Status:** accepted for M6, 14 Nov 2026, as recommended (the owner: "I accept ADR-0056 and ADR-0057 as recommended"), asked for by the owner ("Go ahead with M6"). Item 1 (ADR-0057) is built;
the later items get ADRs of their own before they are built.

## Context

- **What M6 asks** (ROADMAP Part 2): Raft per metadata shard, using the journal as the Raft log; a placement map with
  failure domains and a gateway routing cache; extent replication to a quorum before the `PutExtent` proposal;
  erasure coding of sealed packs; membership, health, rebalance, scrub, repair and rolling upgrades; Jepsen-style
  tests. **Exit:** under injected node, disk, rack and network failures, acknowledged writes survive and no stale
  reads or lists occur.
- **What M1 left ready** (ROADMAP issues #1, #5, #6; ADR-0001): one journal per shard is the only write-ahead log;
  every record has a `term` field (0 on a single node) and a segment header has a shard id; small payloads live in
  their record, so replicating the record replicates the object; large payloads are extents synced before their
  `PutExtent` record. The cluster ADR that issue #6 asked for in M0 was not written: this is it.
- **What does not map one to one.** The journal also holds records that are local to a node: compaction's
  `Relocate` (ADR-0005) and the copies that a checkpoint makes possible. Those are physical, not logical, and a
  Raft log's index must not move under them. A checkpoint's locators name this node's segments. The index is
  applied after a batch's sync (ADR-0001 §3); under Raft it may be applied only after the entry is committed by a
  majority. A follower may have to drop an uncommitted suffix that a new leader does not have.
- **What CeeSafe gives.** An HTTP/1.1 server and client with TLS (CeeSafe.Web; the client already delivers event
  notifications, ADR-0048), timers and async tasks, `Random.fill`, CRC32C, HMAC-SHA256 and AES-256-GCM. No
  consensus library: Raft is CosmoStore's own code, as the journal is.

## Decision

1. **Raft, one group per shard.** Each shard's replicas (three by default, five allowed) run Raft; the leader is
   the shard's only writer. Single-node CosmoStore is a one-replica group that never campaigns, so today's `serve`
   stays as it is, term 0 and all.
2. **The Raft core is a deterministic state machine without I/O** (item 1, ADR-0057): messages, ticks and
   proposals go in; messages to send, entries and a hard state to persist, and committed entries to apply come
   out. The journal, the network and the clock are around it, not in it, so the same code runs under a seeded
   simulation of crashes, partitions, drops, duplicates and reordering, and in `serve`.
3. **The log is the journal** (item 2): a replicated record carries its Raft index and term; local records
   (`Relocate`) carry neither and are not log entries. A node persists the term and its vote in a small file of its
   own, synced before it answers. The index is applied up to the commit index, and on recovery only up to a
   commit index the node has recorded (a committed entry never changes). An uncommitted suffix that a new leader
   does not have is cut off the active segment, durably and through `DurableFile` (the crash model learns
   truncation). A checkpoint is the snapshot; a follower too far behind is sent a logical snapshot (keys, versions
   and inline payloads), which it writes into its own journal and checkpoints.
4. **Shards by bucket.** A bucket's shard is a hash of its name, modulo a shard count fixed when the cluster is
   made (16 by default). A bucket's listing, versions, uploads and configuration then stay in one group, so a
   listing is one leader's and never stale; a bucket's name is unique because one group holds it. ListBuckets asks
   every shard. A bucket larger than a shard can carry is a later item (a split by key range), not M6.
5. **Membership and placement** (items 3 and 6): a cluster file names the nodes, their failure domains (rack, site)
   and a shared secret, and the shard count; placement (which nodes hold which shard) is rendezvous hashing over
   the nodes, one replica per failure domain where there are enough. From item 6 on, membership and placement are
   the state of a group of their own (group 0), changed by single-server Raft changes, one node at a time.
6. **Between nodes, HTTP/1.1 on a port of its own** (item 3), TLS when the cluster file has certificates, every
   request signed with HMAC-SHA256 under the cluster secret, its time and a nonce. Raft's messages, snapshot and
   extent transfers, and forwarded S3 requests use it. Raft's messages are batched per peer, one request at a time,
   so a slow peer delays only itself.
7. **Any node takes S3 requests** (item 4): a node that is not the shard's leader forwards the request to the
   leader it last heard of (the routing cache), and learns another from a refusal. Writes are acknowledged after
   their entry is committed and applied. Reads, listings included, are linearizable: the leader confirms its
   leadership with a heartbeat round after the read arrives (Raft's ReadIndex), so no read is stale; a lease is an
   option later, not a default, because it trusts clocks.
8. **Extents** (item 5): the leader writes a large object's extent, sends it to the shard's other replicas, and
   proposes `PutExtent` only after a majority has synced it (the leader counts). A replica that has the record but
   not the extent fetches it from one that has it before it acknowledges reads of it; scrub (item 7) finds and
   repairs what is missing or damaged.
9. **Erasure coding of sealed packs** (item 8): a sealed segment whose live bytes are cold is encoded into k+m
   pieces across failure domains, and its replicas are dropped only after the pieces are synced and verified; the
   switch is one committed record, so a crash leaves either the replicas or the pieces. Extents follow the same
   rule.
10. **Tests before features** (item 9 and every item): each item's safety properties are checked in the seeded
    simulation (ADR-0057's checker: one leader a term, logs that match, committed entries never lost, the applied
    sequences prefixes of one another), with ADR-0004's crash model under each node's journal from item 2 on; then
    a process-level harness (`tools/cluster_chaos.sh`) kills, pauses and partitions real `serve` processes behind
    a proxy of our own (no firewall rules: our hosts run the owner's services) and checks a history of S3
    operations for linearizability.

## The items, in order

| # | Item | Done when |
|---|---|---|
| 1 | Raft core and its simulation (ADR-0057) | the checker holds over thousands of seeded runs with crashes and partitions |
| 2 | The journal as the log; term, vote and truncation; snapshots | a three-replica group in one process survives the crash model's sweeps |
| 3 | The cluster file, the peer port, signed messages | three `serve` processes elect a leader and replicate |
| 4 | Routing, forwarding, ReadIndex | the S3 smoke tests pass against any node of a cluster |
| 5 | Extent replication and fetch | large objects survive the loss of a replica |
| 6 | Group 0, membership changes, placement, rebalance | a node added or removed moves its shards without a stale read |
| 7 | Health, scrub, repair, rolling upgrades | a damaged extent or segment is found and repaired from a replica |
| 8 | Erasure coding of sealed packs and extents | k+m pieces survive m lost nodes |
| 9 | The chaos harness and its linearizability check | M6's exit |

## Consequences

- One shard's writes go through one leader and a majority's syncs: a PUT costs a network round and a sync on two
  nodes, not one; the p99 gate gets a cluster matrix from item 4 on.
- A bucket is limited by one shard's throughput until splits come.
- Single-node CosmoStore does not change: its records keep term 0 and its journal stays the format it is.
- The owner's hosts are shared: cluster tests run processes on one machine, or in our scratch directories on the
  hosts the owner names, and never change their firewall.

## Rejected

- **A consensus library or an external store** (etcd, FoundationDB) for metadata: CosmoStore calls no C, and a
  second store would bring back two commit logs (ROADMAP issue #1).
- **Multi-Paxos or a leaderless design:** Raft is what issue #6 chose; its leader is the single writer the journal
  already assumes.
- **Shards by key hash:** a listing would merge every shard's and could not be made linearizable cheaply.
- **Raft's log apart from the journal:** two logs and two syncs per write, the problem ADR-0001 removed.
- **Leases for reads by default:** they trust bounded clock drift, which the exit's clock-skew tests break.
