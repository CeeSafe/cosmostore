# ADR-0078: M7 on a cluster

**Status:** accepted by the owner, 17 Nov 2026 (proposed 16 Nov 2026, after M7, on the owner's "continue"). §2 and §3 are built; §4 is built (steps 1 to 4: event notifications, replication, access logs, inventory) and passes its chaos-harness run; §5, slice d (Access Points), is built. The owner accepted it as written, §5 included, the same day ("I accept the ADRs as it were written").

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
     through. A single PUT's body must have the MD5 it names (BadDigest). A multipart source goes as an upload with
     its parts, whose CompleteMultipartUpload carries `x-cosmo-replica-version`: the store completes it as that
     version (`completeUploadAs`; the record is an ordinary completion with that id, so no new format), and, the
     key having one with that id already (a delivery tried again), aborts the upload and answers with it. So no
     replica is bigger than the front's 64 MiB request limit: every source on a cluster came through it, a part
     at a time. Its body is a client's, unsealed: a destination that seals is refused (a cluster has no SSE keys,
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
   - **Access logs (step 4):** every shard's S3 server queues its requests' lines on one queue of its node, as
     `serve`'s does; the node delivers each target's lines as an object (`--access-log-seconds`, 300 by default),
     a PUT through its own front signed with the first key, with `x-cosmo-log-delivery`: such a request, signed by
     a long-term key, is not logged itself, or a bucket that logs into itself would never stop. Lines are lost
     with a node, as `serve`'s with it. PutBucketLogging cannot see a target of another shard; a wrong one loses
     its lines (said on stderr). The count of buckets that log stays at "some" on a cluster.
   - **The client's address:** the front forwards it as `x-cosmo-peer` (dropping a client's), and a shard's S3
     server on a cluster takes its peer from it: access log lines name the client, and a policy's `aws:SourceIp`
     is the client's, where before this it was the front's (a node reaches a shard's S3 server only on loopback).
   - **Inventory (step 4):** each shard's leader makes its buckets' reports from its store, a page of versions
     at a time under the store's lock (`InventoryScan`, which `serve` now uses too), and PUTs each file through
     its front, the destination being any shard's. When a configuration's last report was made is found, the
     first time a leader looks at it, by a ListObjectsV2 of the destination through the front; a node forgets
     the shards it stops leading, so a new leader neither repeats a report nor skips one.
   - **Status** on a cluster reads the cursor the shard's records moved, so it is the same on every replica. A
     destination of another shard counts as another endpoint's does: COMPLETED once delivered, FAILED if noted.
     The S3 server's count of buckets with replication stays at "some" on a cluster, as the policy counts do: the
     configuration's record is applied after the response, so a count taken then was 0 and hid every status.
   - **Tests:** a store fault sweep of the new record and the checkpoint's cursor; the cluster smoke delivering a
     webhook, an access log, an inventory report and replicas (same shard, another shard) through every node; the
     chaos harness with webhooks and replication on, killing leaders mid-delivery: every event delivered at least
     once, in order per shard.
5. **Access Points on a cluster (slice d, built).** An access point's configuration stays its bucket's, a record of the
   bucket's shard, as on `serve` (ADR-0076 §2), so the shard's S3 server checks requests through it as `serve` does.
   - **Its name is the cluster's:** a claim in group 0, the object `access-point/<name>` (`<bucket>\n<alias>`) of its
     system bucket, which every node holds a copy of (no new record: group 0's writes are a store's, ADR-0062 §3).
     Group 0's leader takes claims on a peer path of its own, `POST /cluster/access-point`, signed by a node: take a
     name for a bucket (made now, the bucket's already, or another bucket's: 409), let it go if it is a bucket's, let
     go every name of a bucket, find one. Behind group 0's gate, once its replica has applied everything it holds.
   - **CreateAccessPoint** through any node: the front picks an alias, claims the name with it, then sends the
     request to the bucket's shard with the alias (`x-cosmo-access-point-alias`, which a client cannot send: the front
     strips its `x-cosmo-` fields). A claim made now that the shard refuses (NoSuchBucket, AccessDenied) is let go; a
     claim the bucket had already is kept, since its access point may be there (the shard answers
     AccessPointAlreadyOwnedByYou). A claim left by a failure that is not one (ServiceUnavailable) is let go by a
     DeleteAccessPoint of the name, which its bucket's shard answers NoSuchAccessPoint.
   - **The other calls** find the name's bucket by its claim (this node's copy, then group 0's leader, whose copy
     has every claim made) and go to its shard; DeleteAccessPoint lets the name go once the shard has deleted it.
     ListAccessPoints of a bucket goes to its shard; of every bucket, to every shard, merged by name, as ListBuckets.
     A bucket deleted through the front lets its names go.
   - **A request through one** names it by its alias or by `<name>-<account>`: the front finds the claim and routes
     the request, as it came, to the bucket's shard, whose S3 server finds the access point in its own store. For
     ARNs, whose host is `<name>-<account>.<domain>`, `cosmostore node --domain` gives the nodes `serve`'s domain:
     the front and the shards' S3 servers read virtual-hosted requests by it.
   - The S3 server's count of buckets with access points stays at "some" on a cluster, as the others do.
6. **Until its slice**, a feature keeps refusing on a cluster as it does now.

## Consequences

- Slice d: `accessPointClaimsFoundByNameAliasAndArn` (by name, by an alias, one of a name over 30 letters among others
  that begin the same, by `<name>-<account>`), `accessPointClaimRequestsAndTargets`; the cluster smoke (97 checks)
  makes an access point through node 1 and reads it through node 3, is refused its name for a bucket of another shard
  and a bucket that is not there (whose name stays free), lists every shard's and a bucket's, writes by alias, lists
  by alias, reads by ARN, has a policy deny a write through it, deletes it and finds its alias gone, takes its name
  for another bucket, and sees a deleted bucket's names let go.

- Slice c, the chaos-harness run: `tools/cluster_chaos.py --outbox` versions the clients' bucket, sends its events to
  a webhook of the harness's and replicates it to a bucket of the other shard, while the faults (with `kill-leader`)
  run; after the heal, every acknowledged PUT's and DELETE's event was delivered at least once, no event of a write
  never made, the first deliveries' sequencers rising, and the replicas' bucket holding exactly the source's versions
  and markers. Three runs (60 s of leader kills alone, two of 90 s with every default fault) passed, with 297, 17 and
  67 events delivered again after a leader's change, and stayed linearizable.

- Slice c, step 4: `replicaUploadCompletesAsItsSourcesVersion`; the cluster smoke replicates a 72 MiB upload
  across shards (its id, ETag and bytes), logs PUTs made through three nodes and a GET into a bucket of another
  shard, sees a bucket that logs into itself stop, and gets an inventory report (manifest, checksum, a CSV row per
  object) in a bucket of another shard.

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
