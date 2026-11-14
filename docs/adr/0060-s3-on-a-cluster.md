# ADR-0060: S3 on a cluster: routing, forwarding, commit before answer, ReadIndex (M6 item 4)

**Status:** accepted for M6 item 4 (ADR-0056 §4, §7), 15 Nov 2026, as recommended (the owner: "I accept ADR-0060 as
recommended"), asked for by the owner ("Yes. Go ahead", after item 3); built (slices a and b).

## Context

- **Items 1 to 3** made a cluster that replicates (ADR-0057 to ADR-0059): `cosmostore node` runs a node's replicas
  and its signed peer port, and nothing writes to it but each new leader's empty entry. **Item 4's done-when**
  (ADR-0056): S3 works against any node of a cluster.
- **ADR-0056 §7:** any node takes S3 requests and forwards to the shard's leader it last heard of; writes are
  acknowledged once committed and applied; reads, listings included, are linearizable through ReadIndex. **§4:** a
  bucket's shard is a hash of its name; ListBuckets asks every shard.
- **The S3 layer** (`src/s3/`, ADR-0008 on) is one `S3App` over one store behind an `AsyncMutex`: some 40 places
  lock it, and each operation sends its own response, right after its store calls return. In a Raft log those calls
  stage and persist entries without applying them (ADR-0058): sent as they are, a response would acknowledge a write
  no quorum holds. The checks a write makes (a condition, a version, a quota) see the applied state only.
- **What cannot change in item 4:** extents (item 5), membership (item 6). A cluster shard refuses what writes an
  extent (ADR-0058 §10).

## Decision

1. **The store leaves the replica.** A shard's store is an `Arc<AsyncMutex<ObjectStore>>`, as `serve`'s is; the
   replica (core, hard state, generation) takes it as an argument for everything it does with it, and the node locks
   the replica and then the store, never the other way round. The S3 layer's own locking stays as it is.
2. **An S3 server per shard, inside the node:** each shard's store gets an `S3App` of its own (its group commit, its
   counts, its writers), sharing the node's credentials, on a loopback port the node picks (`127.0.0.1:0`). It is the
   whole S3 layer, unchanged, and only the node talks to it.
3. **The front:** the node's S3 port (`--listen`, `--credentials`, as `serve`'s) takes every client request. The
   bucket is the path's first segment (virtual hosts with `--domain`, as `serve`'s); its shard is the first 8 bytes of
   `SHA-256(cluster name ‖ bucket)` modulo the shard count. The request goes to the shard's leader as this node knows
   it: itself, or the node it forwards to.
4. **Forwarding:** `POST /s3/<shard>` on the leader's peer port, signed as every peer request is (ADR-0059 §4), its
   body the client's request as it came (method, target, headers, body); the answer is the response as the leader's
   S3 server gave it (status, headers, body). The client's own signature travels with its request and is checked by
   the leader's S3 layer, as a single node checks it. A node that is not the leader any more answers 421, and the
   forwarder learns the leader from its next status and tries once more; no leader within two seconds is 503
   (`ServiceUnavailable`), which S3 clients retry.
5. **Writes on the leader** (PUT, POST, DELETE): one at a time per shard, behind a gate: the gate is taken, the
   leader waits until it has applied every entry it holds (so the write's checks see every earlier write), the request
   goes to the shard's S3 server, the entries it staged are proposed, and the response is held until they are
   committed and applied, the last one's term the term they were proposed in (so it is that write, not another
   leader's at the same index). Only then is the response relayed. A leader deposed meanwhile answers 503: the write
   may or may not have happened, as with any request whose answer is lost. Pipelining writes is later work.
6. **Reads on the leader** (GET, HEAD): a ReadIndex round first (ADR-0057 §2), then a wait until the store has applied
   its index, then the shard's S3 server. A leader cut off from a quorum cannot finish the round, so it never answers
   from a stale state; after two seconds the read is 503.
7. **ListBuckets** asks every shard's leader (each a ReadIndex read) and merges their `<Bucket>` entries by name into
   one answer. Requests with no bucket other than ListBuckets are refused with NotImplemented on a cluster for now
   (the admin API and stats are per node, item 7).
8. **Responses are buffered:** a response is relayed whole, after its commit. Bodies are inline objects (extents are
   item 5), at most the inline limit; a streamed large GET comes with item 5.

## Slices

| Slice | What | Done when |
|---|---|---|
| a | the store out of the replica (§1); the in-process tests over the new shape | ADR-0058's sweeps and snapshot tests pass as before |
| b | the shards' S3 servers, the front, routing, the leader's write gate and commit wait, ReadIndex reads, forwarding, ListBuckets (§2–§8); `cosmostore node --listen --credentials` | `tools/cluster_s3_smoke.sh`: buckets and objects written through one node, read through the others; a condition that sees the write before it; a leader killed mid-run and the run going on through the others |

## As built (slices a and b, 15 Nov 2026)

- **The bucket counts** (policies, denies, CORS, encryption: "while 0, skip the read", ADR-0043 §8 and after) cannot
  be kept on a shard's S3 server: they are recounted from the store right after a write, which in a Raft log is
  before the write is applied, and other leaders' writes reach the store without passing the server at all. A
  cluster's S3 servers keep them at "some" (`S3App.cluster`), so every request reads what they would let it skip:
  slower, never wrong.
- **Group commit's published mark** is durable, not applied, in a Raft log (`ObjectStore.isPublished`): the shard's
  S3 server answers once its records are persisted, and the front holds that answer until they are applied.
- **A copy between buckets of two shards** (`x-amz-copy-source` naming another shard's bucket) is refused by the
  front with NotImplemented: the copy runs on the destination's store, which does not hold the source. Copies within
  a shard work. A cross-shard copy (the front reading the source as the client) is later work.
- **Found on the way:** CeeSafe.Web's `Ascii.equalsIgnoringCase(a, lower)` wants its second argument lower case; with
  `"PUT"` every write was taken for a read, answered without being proposed, and so never replicated. Methods are
  compared as parsed `Method`s now. A HEAD's relayed answer keeps its Content-Length (`setContentLength` and an empty
  write), as a single node's does.

## Consequences

- Every S3 operation works on a cluster that works on a single node, but extents (item 5): the S3 layer is the same
  code. Its tests, sweeps and `tools/s3_smoke.sh` keep testing it.
- A write costs a loopback hop, a Raft round and an apply before its answer; writes to one shard are serialized. The
  p99 gate gets its cluster matrix once writes pipeline.
- Policies, ACLs, CORS, quotas, encryption and versioning are per shard as they are per store; their counts
  (`encryptedBuckets` and the like) are the shard's. Rate limits and the audit log are the front's (one per node).

## Rejected

- **Making the S3 layer wait for commits itself:** a wait at each of the some 40 places that write, any one of them
  missed an acknowledgement before a quorum holds it, and a second code path in every handler. The gate and the held
  response put it in one place.
- **Answering from any replica's applied state:** a follower's state may be behind, so a read after a write could
  miss it (ADR-0056 §7).
- **Redirecting clients to the leader** (a 307 to its address): S3 clients do not follow redirects for writes with
  bodies, and a client would need every node's address.
