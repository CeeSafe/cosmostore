# ADR-0078: M7 on a cluster

**Status:** proposed, 16 Nov 2026, after M7 (ADR-0071 to ADR-0077, accepted), on the owner's "continue". §2 and §3 are built; §4 is built for event notifications and replication (steps 1 to 3), designed for access logs and inventory.

## Context

- M7's features work on `serve`. On a cluster's S3 port (ADR-0060) they are refused (`NotImplemented`) or, for STS,
  every token is InvalidToken. A cluster routes each request by its bucket to the bucket's shard and its leader;
  requests without a bucket other than ListBuckets were refused. Nothing on a cluster delivers anything yet: event
  notifications are not there either (ADR-0060, the runbook).
- Their configurations are `BucketConfig` records, which a shard's Raft log replicates already. What each feature
  needs beyond that differs a great deal.

## Decision

1. **In order of what each needs**, a slice each, each with its checks in `tools/cluster_s3_smoke.sh`:

   | Slice | What | Needs |
   |---|---|---|
   | a | STS (§2) | the same key and roles files on every node; STS's POST routed |
   | b | Website hosting | the front routing `<bucket>.<website domain>` requests by their host, as reads |
   | c | The outbox on a cluster: notifications, access logs, inventory, replication | a delivery task on each shard's leader, its cursor a record of the shard's log, so a new leader goes on where the old one stopped |
   | d | Access Points | names unique across shards (group 0's metadata, ADR-0067), the front resolving an alias or an ARN host to its bucket's shard, S3 Control routed |

2. **STS on a cluster (slice a, built).** `cosmostore node` takes `--sts-key-file` and `--roles-file` (the same files
   on every node; read and checked before any shard opens), and every shard's S3 server holds the keys and the roles.
   A POST to the service is STS's: the front routes it to shard 0's leader, any shard's server being able to answer,
   since a session token is sealed, not stored (ADR-0075 §4). A token made through one node signs requests through
   any other, and a role session is narrowed on every shard as on `serve` (the check is in the shared S3 layer).
3. **Website hosting on a cluster (slice b, built).** `cosmostore node --website-domain <domain>`: the front takes a
   request whose `Host` is `<bucket>.<domain>` as that bucket's, routes it to the bucket's shard as any request (a
   GET or HEAD, so a ReadIndex read on its leader, ADR-0060 §6), and the shard's S3 server, which has the domain too,
   serves it as a website (ADR-0073). `PutBucketWebsite` is no longer refused on a cluster: its configuration is a
   record of the shard's log already.
4. **The outbox on a cluster (slice c, designed).** Every replica of a shard applies the same records, so every
   replica's outbox (ADR-0048 §2) queues the same events, in the same order. Only the shard's leader delivers them.
   - **Where it stops is a record:** after a batch is delivered, the leader stages an `OutboxDelivered` record (the
     LSN of the last event delivered) and proposes it as a write's entries are (ADR-0060 §5), behind the shard's
     gate. Applied on every replica, it drops those events and moves the cursor, which checkpoints and snapshots
     then carry (a new checkpoint format) instead of `serve`'s `outbox.cursor` file. A new leader goes on from the
     last such record: at least once, as on `serve`; what a deposed leader delivered after its last record is
     delivered again.
   - **Writes into buckets go through the cluster:** an access log object, an inventory report and a replica to a
     bucket of the same cluster may belong to another shard, so the delivery task sends them as signed S3 requests to
     its node's own front (with the first key of the node's credentials), which routes, forwards and commits them
     like any client's. Webhooks and remote replication targets are as on `serve`.
   - **A replica keeps its version id across shards:** a PUT with `x-cosmo-replica-version: <id>`,
     `x-cosmo-replica-md5: <hex>`, `x-cosmo-replica-parts: <n>` and, when its base64 is at most 8 KiB,
     `x-cosmo-replica-extras` (the source's checksums and part sizes), is written by `putReplica` (ADR-0077 §3); a
     DELETE with `x-cosmo-replica-version` by `putReplicaMarker`. The shard's S3 server takes these fields only when
     they are among the request's signed headers and a long-term key signed it (not a session's, never anonymous):
     AccessDenied otherwise. The front strips every other `x-cosmo-` field from clients' requests and lets these
     through. A single PUT's body must have the MD5 it names (BadDigest). A multipart source goes as one PUT: its
     ETag and parts are the source's, and with its extras so are its part numbers; one over 5 GiB is refused, so it
     reads FAILED. Its body is a client's, unsealed: a destination that seals is refused (a cluster has no SSE keys,
     and SSE-C sources cannot be opened by the delivery task, so they read FAILED).
   - **Built so far:** step 1, the record (`OutboxDelivered`, type 19; a raft replica's cursor at open derived from
     its checkpoint, so no new checkpoint format); step 2, webhooks: `cosmostore node --notify-targets` (its shards'
     S3 servers take rules naming them), and a delivery loop on every node that, for each shard it leads, delivers a
     batch, stages and proposes the record behind the shard's gate, and waits for it to be applied before the next
     batch (else it would find the same events still waiting and send them again); step 3, replication:
     `cosmostore node --replication-targets` as `serve`'s; a replica into a bucket of the cluster goes to the node's
     own front (its listening address, loopback for an unspecified one), signed with the current first key that is
     not revoked; another endpoint's as on `serve`. A replica refused for good, by either, is noted behind the
     shard's gate, so the version reads FAILED. PutBucketReplication on a cluster cannot see a destination of another
     shard: it is taken, and refused at delivery if it is not a bucket with versioning.
   - **Status** on a cluster reads the cursor the shard's records moved, so it is the same on every replica. A
     destination of another shard counts as another endpoint's does: COMPLETED once delivered, FAILED if noted.
     The S3 server's count of buckets with replication stays at "some" on a cluster, as the policy counts do: the
     configuration's record is applied after the response, so a count taken then was 0 and hid every status.
   - **Tests:** a store fault sweep of the new record and the checkpoint's cursor; the cluster smoke delivering a
     webhook, an access log, an inventory report and replicas (same shard, another shard) through every node; the
     chaos harness with webhooks and replication on, killing leaders mid-delivery: every event delivered at least
     once, in order per shard.
5. **Until its slice**, a feature keeps refusing on a cluster as it does now.

## Consequences

- Slice c, step 3: `replicaFieldsOnlySignedByAKey`; the cluster smoke replicates a PUT and a two-part upload to a
  bucket of another shard (id, ETag, bytes, part 2 by number, REPLICA), a delete marker with its id, a PUT to
  "another endpoint" (node 1's front) with its ETag and metadata, reads COMPLETED through every node, and FAILED
  through every node for a destination that refuses.

- Slice c, steps 1 and 2: `outboxDeliveredOnEveryReplica`, `clusterOutboxFaults{Once,Sticky,Torn,Crash}`; the
  cluster smoke sets a notification rule through one node, writes through all three, gets each event once, in order,
  kills the bucket's shard's leader, and gets the next event from the new leader with none lost.
- Slice b: the cluster smoke configures a site through node 2 (its objects and policy through others) and gets its
  index through each of the three nodes, and its error document.
- Slice a: the cluster smoke gets a session token through node 1 and writes with it through node 2, assumes a role
  through node 3, reads with it through node 1, and is refused a write and another bucket.
