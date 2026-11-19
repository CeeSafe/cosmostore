# M13 exit review: a cluster as `serve` (20 Nov 2026)

**M13's exit (ROADMAP, M13; ADR-0092, proposed):** a key or user removed from every node's files is refused through
every node without a restart, and SSE-S3 and SSE-KMS objects put through one node read through the others.

## How it was checked

- **The evidence:**
  - **Unit tests:** 387.
  - **The cluster smoke:** 163 checks: a key and a user revoked through each node, SSE-S3 and SSE-KMS across
    nodes, a sealed source replicated, and two refusals in one delivery batch.
  - **The S3 smoke and the SDK matrix.**
- **A review by a reader who had not written the code:** a three-node repro of its own
  (`scratchpad/m13review/repro.sh`).

## The item

| Done when | Verdict |
|---|---|
| A key or user removed from every node's files is refused through every node, without a restart | holds once every node has reloaded; **A1** while they differ |
| SSE-S3 and SSE-KMS put through one node read through the others | holds; **A2** for sealed replicas |

## Findings

### A. To fix

1. **Medium: the shard leader's node decides a request, not the node it reaches** (reproduced).
   - **Why:** the front forwards a signed request to the shard's leader, whose S3 server checks it against its own
     node's set. ADR-0092 §1 says the reverse.
   - **Reproduced:** a key revoked in node 1's file only still passes through node 1 on shards nodes 2 and 3 lead,
     and is refused through node 2, whose file is stale, on shards node 1 leads.
   - **What follows:** a node whose reload failed, or whose 4,096 sets are used up, keeps a revoked key valid for
     every shard it leads, through every node, and which shards those are moves with each election. The same holds
     for SSE's keys.
2. **Medium: sealed replicas are inconsistent** (reproduced).
   - **An SSE-KMS source:** sent as SSE-S3.
     - A single PUT reads FAILED, with a BadDigest.
     - A multipart one completes with another ETag, its encryption downgraded.
   - **An unsealed multipart source into a bucket whose default is SSE-KMS:** it completes as SSE-KMS, with an ETag
     not its source's, where ADR-0092 §2 says it is refused.
   - **The cause:** the multipart fidelity path never checks the ETag it completes with.
3. **Medium: files that differ between nodes turn into a permanent FAILED.**
   - **Credentials:** a replica through the node's own front is signed with the delivering node's first account
     key. A destination leader that does not know it yet answers 403, which marks the version FAILED for good.
   - **SSE's keys:** a delivering node without a master key fails every sealed source the same way.
   - **When:** during a staggered rotation, which is exactly when files differ.
4. **Low-Medium: the two-refusals fix can still lose one after a timeout.**
   - **When noting:** if a noted failure is not applied within 5 s, the next refusal still reads the list without
     it.
   - **Before noting:** noting does not first wait for earlier entries to apply, as a write does.

### B. Notes

1. **Low:** nothing checks at start that the nodes' files match.
2. **Low:** master keys' copies, and replaced secrets in the retained sets, are not wiped. That is so on `serve`
   too.

Checked and right:
- **One reloaded set everywhere:** every shard's S3 server, `selfTarget` and STS's parents read it at each request.
- **Reload mechanics:**
  - a key's place is stable across reloads;
  - the reload runs on a worker thread;
  - a bad file changes nothing.
- **Wipes:** the replication targets' text is still wiped, and so are the SSE key files' texts.
- **Replica sealing:** SSE-S3 sealing of a single replica is right in size and ETag. SSE-C sources are refused.
- **Delivery and the gate:** proposing under the gate cannot deadlock, and a lost lead redelivers rather than loops.

## Verdict

**M13 should not close yet.**
- **A1** makes a revocation depend on which node leads a shard.
- **A2 and A3** make replication's outcome depend on encryption and on timing.

**The recommendation:**
- **A1:** the front also checks a request's access key against its own node's set, so a request passes only if
  both nodes know the key. That is safe while a revocation rolls out.
- **A2:**
  - SSE-KMS sources are refused up front, a FAILED with a reason;
  - a fidelity multipart completion is refused when its upload would seal with SSE-KMS or SSE-C.
- **A3:** for the node's own front, 401 and 403, and a master key missing, are tried again and logged, not FAILED.
- **A4:**
  - wait for earlier entries before noting;
  - on a timeout, try the batch again.

Closing M13 and accepting ADR-0092 are the owner's decisions.

## The fixes (20 Nov 2026)

| Finding | Fix | Shown by |
|---|---|---|
| A1 | the front checks a request's access key against its own node's set (`frontKeyAccepted`): unknown or revoked is InvalidAccessKeyId, before it is forwarded; a session's request is checked at the shard, by its parent | the reviewer's repro: a key revoked in node 1's file only is refused through node 1 on all 8 shards |
| A2 | an SSE-KMS source is refused up front and logged, through the cluster's own front (to another endpoint it goes as before, ADR-0077 §6); a replica's multipart upload completing as its source's version is refused when it would seal with SSE-KMS or SSE-C | the repro: SSE-KMS sources and replicas into an SSE-KMS default read FAILED; SSE-S3 ones COMPLETED with their source's ETag |
| A3 | the cluster's own front answering 401 or 403, or a master key the delivering node has not: tried again, and logged | (by reading) |
| A4 | before noting a refusal, every earlier entry applied (as a write waits); a noted refusal not applied in time is tried again, not reported done | the cluster smoke's two refusals in one batch |

**Found while fixing:** a replica's CompleteMultipartUpload that answered a 4xx was tried for ever. The check for
S3's "200 with an error in its body" matched any error body, and held the shard's whole delivery behind it. Only a
200 is now read that way. This predates M13, and the repro showed it: three replicas PENDING after 40 s.

## Closed (20 Nov 2026)

The owner accepted ADR-0092, as amended, and closed M13 ("Accept and close").

**Still recorded, Low:**
- nothing checks at start that the nodes' files match;
- master keys' copies are not wiped, as on `serve`.
