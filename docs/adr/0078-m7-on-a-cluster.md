# ADR-0078: M7 on a cluster

**Status:** proposed, 16 Nov 2026, after M7 (ADR-0071 to ADR-0077, accepted), on the owner's "continue". §2 is built.

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
3. **Until its slice**, a feature keeps refusing on a cluster as it does now.

## Consequences

- Slice a: the cluster smoke gets a session token through node 1 and writes with it through node 2, assumes a role
  through node 3, reads with it through node 1, and is refused a write and another bucket.
