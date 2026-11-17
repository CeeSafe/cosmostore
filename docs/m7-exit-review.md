# M7 exit review: advanced S3 (17 Nov 2026)

**M7's exit (ADR-0071):** no single exit. Each item closes when its "done when" holds, with its tests and the S3 smoke
or a client SDK test exercising it, and with what it does not do refused (`NotImplemented` or another error), never
silently ignored. ADR-0071 to ADR-0078 are accepted; ADR-0078 put every item on a cluster's S3 port.

## How it was checked

- **Each item against its "done when"**, on `serve` (`tools/s3_smoke.sh`) and on a cluster (`tools/cluster_s3_smoke.sh`,
  97 checks), with the unit tests (313, no leaks) and the store fault sweeps of the new records.
- **The outbox under faults** (ADR-0078 §4): `tools/cluster_chaos.py --outbox` with leader kills among every default
  fault.
- **Two reviews of the code by readers who had not written it:** one of every M7 configuration call against the AWS
  API, for what is taken and has no effect; one of the cluster code of ADR-0078 for correctness and trust boundaries.

## The items

| # | Item | Done when (ADR-0071) | `serve` | Cluster (ADR-0078) | Verdict |
|---|---|---|---|---|---|
| 1 | Access logs (ADR-0072) | log objects in S3's format in the target bucket | S3 smoke | each node delivers its shards' lines; smoke (three nodes, another shard's target, a bucket logging into itself) | holds; finding B3 |
| 2 | Website hosting (ADR-0073) | index, error documents, redirects, with the bucket's policy | S3 smoke | `--website-domain`; smoke through every node | holds |
| 3 | Inventory (ADR-0074) | daily or weekly CSV and manifest in the destination | S3 smoke (a 3 s day) | each shard's leader; smoke (another shard, a leader killed) | holds; finding A4 |
| 4 | STS (ADR-0075) | session tokens sign requests, scoped by the role, and expire | S3 smoke, `stsTokens` and others | same key and roles files; smoke (a token from one node through another) | holds; **finding A1** |
| 5 | Access Points (ADR-0076) | its own policy, requests by alias and ARN | S3 smoke | names claimed in group 0; smoke (20 checks) | holds; **findings B1, B4–B6**, A5 |
| 6 | Replication (ADR-0077) | new versions copied here or elsewhere, with status | S3 smoke, fault sweep `replicaFaults*` | via the front, ids kept across shards; smoke (a 72 MiB upload); chaos | holds; findings A2, A3, B2 |

**Chaos runs with `--outbox`** (versioned bucket, webhook, replication to a bucket of the other shard; faults with
`kill-leader`): three runs of 60 to 90 s and three of 5 minutes (about 5,100 to 5,800 operations and 50 faults
each). In every one: every acknowledged PUT's and DELETE's event delivered at least once (246 to 682 delivered again
after a leader's change), none of a write never made, the first deliveries in sequencer order, the replicas' bucket
exactly the source's versions and markers, and every key's history linearizable. The check across keys did not
settle in three of the 5-minute runs, one of them without the outbox: four runs at once on one Mac left 500 to 600
unknown outcomes each, past what its search takes. A fourth 5-minute run alone (7,908 operations, 463 unknown, 49
faults; 3,980 events, 635 again) passed every outbox check, and its per-key search was too large for one key: the
harness then stopped with an exception instead of saying so (fixed here: it reports "not settled"). Inconclusive, not
a failure: no history has been found that is not linearizable, and the M6 review's 5-minute runs on binfadel settled.

## Findings

### A. Taken and not done (the "never silently ignored" rule)

1. **STS: `PolicyArns`, `SerialNumber`/`TokenCode`, `ExternalId`, `Tags`, `TransitiveTagKeys`, `SourceIdentity`**
   are not read (`src/s3/sts.cee` reads `Action`, `RoleArn`, `RoleSessionName`, `Policy`, `DurationSeconds`). A
   client narrowing a session with `PolicyArns` gets the role's whole rights. **Security: refuse them.**
2. **Replication: `Destination/StorageClass`** is neither refused nor kept (lost on Get).
3. **Replication: `Priority`** is kept and given back but not used: every enabled rule whose filter takes a key
   replicates it (deduplicated by destination), a disabled rule of higher priority does not stop one of lower, and
   two rules' delete-marker settings combine. AWS takes the highest-priority rule. Use it, or refuse overlapping
   rules. A `DeleteMarkerReplication/Status` other than `Enabled` (a typo) reads as disabled.
4. **Inventory: `S3BucketDestination/AccountId`** is not read (lost on Get); an `IsEnabled` other than `true` reads
   as disabled.
5. **Access Points: the account** is not kept: Get and List give the ARN and `BucketAccountId` of the asking
   request's `x-amz-account-id`; `BucketAccountId` at creation is not read; `ListAccessPoints`' `maxResults` and
   `nextToken` are not read (ADR-0076 §4 says it has no paging).

Checked and refused as they should be: logging's grants and partitioned keys, inventory's encryption, formats and
other optional fields, replication's tag filters, existing-object replication, replica modification sync, RTC,
metrics, access control translation, destination encryption, access points' VPC and other control paths. Website
configurations round-trip whole.

### B. Defects in the cluster code (ADR-0078)

1. **High: an access point's claim can be let go while it exists.** The front lets a claim it made go when the
   shard refuses the create with any 4xx, AccessPointAlreadyOwnedByYou included, and claims before the shard
   authenticates. Two creates of a name for the same bucket (the second finding the first's claim, 200) can leave
   the access point with no claim; an anonymous create racing a real one does it on purpose (its 403 lets the claim
   go). The access point is then not reachable through the front, its name can be claimed for another bucket, and
   `<name>-<account>` routes there. The same for `releaseBucketClaims` racing a bucket made again. Fix: claims carry
   a token, let go only by the request that made them and only on a refusal before anything was made; no claim
   before authentication.
2. **Medium: replica fields from any long-term key** (on `serve` too): a user who may write the destination can
   PUT other bytes under a source version's id first, after which the real replica is "already there" and the
   status reads COMPLETED. Fix: take them only from the node's own delivery (the front adds them on an internal
   path, strips them from clients), or only with a replication permission.
3. **Medium: `x-cosmo-log-delivery` from any long-term key** keeps that key's requests (any method) out of a
   bucket's access log. Fix: as B2, or at least a PUT signed by the delivery key.
4. **Medium: bucket names shaped like an access point's** (`-` and 12 digits, `-s3alias`) that miss this node's
   copy ask group 0's leader on every request, behind its gate; a short alias stem scans every claim it begins.
   Unauthenticated clients can do it. Fix: no gate for a find (a read), a negative answer kept a moment, a minimum
   stem.
5. **Low: a `<Bucket>` over 65,535 bytes** breaks the claim request's framing (a u16 length). Fix: check the name
   (S3's 3 to 63 characters) before claiming.
6. **Low: a DeleteBucket with a query** (a presigned URL) does not let its names go. Fix: ignore the signature's
   parameters.

Seen and not new: S3 Control has no per-bucket authorization (any long-term key may make or delete any bucket's
access points), as on `serve`; ADR-0076 §1 says long-term keys only.

### C. What CI does not run

CI runs the unit tests, the S3 smoke and the TLS smoke. **No cluster smoke and no chaos run is in CI**: everything
ADR-0078 built is checked only by hand. The cluster S3 smoke takes about four minutes; its ARN check needs
`door-000000000000.localhost` in the runner's `/etc/hosts`, as the S3 smoke's do.

### D. The ADRs

ADR-0072 to ADR-0075 and ADR-0077 still said a cluster refuses their item; each now points to ADR-0078's section
(this review).

## Not covered, or not yet

- What ADR-0071 left out: directory buckets and S3 Tables. What each item's ADR lists as not done (multi-Region and
  Object Lambda access points, ORC and Parquet, RTC, a custom website domain without the `<bucket>.` form, a KMS
  service).
- No client SDK test of M7's calls beyond the AWS CLI (M3's matrix predates them).
- Access logs on a cluster are lost with a node (best effort, as S3's are).

## Verdict

Every item's "done when" holds, on `serve` and on a cluster, and the outbox delivers at least once and in order
under leader kills. **M7 should not close yet:** A1 (an STS parameter that would narrow a session is ignored) and B1
(an access point's name can be let go, by anyone) are security defects; B2 and B3 let a key holder do what it should
not; A2 to A5 break the "never silently ignored" rule. Recommended before closing: fix A1 to A5 and B1 to B6, each
with a test, and put the cluster S3 smoke in CI (C).
