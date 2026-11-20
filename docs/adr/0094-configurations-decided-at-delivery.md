# ADR-0094: Configurations decided at delivery (M14)

**Status:** accepted, 20 Nov 2026 (the owner: "Accept and close"), as amended after M14's exit review. Proposed
the same day. M14 is item A of ADR-0093 (the owner: "A: decided at delivery"); a session's
configuration is decided as its parent (the owner's choice).

## Context

- **Where the server writes for a configuration:**
  - a replication's replicas (ADR-0077, ADR-0078 §4);
  - an inventory's reports (ADR-0074);
  - a bucket's access logs (ADR-0072).
- **How it is authorized today:** a user's or a session's destination is authorized once, when the configuration is
  put (ADR-0088 §2, after M11's exit review): the action on the destination's objects under the prefix, and no Deny
  that could reach them.
- **What is then never checked again:** the writes themselves. A user removed, or a policy narrowed, does not stop
  them.

## Decision

1. **The requester is recorded** with each of the three configurations when a user or a session puts it.
   - **What is recorded:** `user <name> <id>` for a user, or a GetSessionToken session's user (ADR-0088), and
     `role <name>` for an AssumeRole session's role. A session is decided as its parent, the owner's choice.
   - **The account's keys record nothing,** and their configurations are decided as today, as the account owns
     every bucket.
   - **Configurations put before M14** have no requester. They keep the decision made when they were put; the
     upgrade text says so.
   - **Stored formats:** each configuration's stored format gains a version, written only when a requester is
     recorded. Older versions read as having none.
2. **Each write is decided as its requester,** with the credentials, users, roles and policies of that moment, as a
   request of theirs would be (`gateDecision`).
   - **The action and resource:** a replica is `s3:ReplicateObject` (a delete marker `s3:ReplicateDelete`) on the
     destination object, and an inventory report or a log object is `s3:PutObject` on it.
   - **The facts:** a write has no client, so a policy condition on the client's address, Referer or User-Agent
     does not hold for it. A statement conditioned on them neither allows nor denies.
   - **Who is refused:**
     - **A user** that no longer exists (its name and id in no users file);
     - **A role** that is no longer in the roles file;
     - **Any requester** that is denied, or not allowed.
3. **A refused write is reported, not retried:**
   - **A replica:** its source's status FAILED, as a destination's refusal is (ADR-0077 §7).
   - **An inventory report or a log object:** it is not written. The refusal is logged.
   - **Later writes:** each is decided again. One a user's policy allows once more goes through.
4. **On a cluster,** the destination's shard decides.
   - **How it learns the requester:** the delivering node sends it with the write, in a field the front passes only
     with the node's stamp (`x-cosmo-replica-requester`, one of ADR-0078 §4's replica fields).
   - **What decides:** the shard's S3 server decides that write as the requester, with its own node's credentials
     and policies. A field without the stamp is dropped by the front, as the cluster's other fields are.

## Amended after M14's exit review

- **Whose requester a write is decided as (A3):**
  - **Recorded with the event:** a replica's requester is the one its rule recorded when the event was made, kept
    with the event in the outbox and its checkpoints. A rule deleted or re-pointed while events wait changes nothing
    of them; before, they were written as the account's.
  - **A configuration that does not decode** makes no event.
- **A refusal fails closed (B3):** a role or user that cannot be named records `role ` or `user `, which no write is
  allowed as.
- **Inventory (A1):** a report is decided file by file, before each is written. A refusal stops it before its
  manifest.
- **A replica's upload on a cluster (A2):**
  - it is decided at CreateMultipartUpload, before any part is stored;
  - a refused completion is aborted at the destination.
- **No client (B1):** a condition on a client's fact holds for no write, whatever its operator (`Not…` and `Null`
  included), so its statement neither allows nor denies. Only `aws:SecureTransport` is the server's own.
- **AccessDenied is for good (B2):** a node's own front answering AccessDenied is FAILED, the account's replication
  included. A user not yet in the destination leader's users file also reads FAILED during a rollout, where an
  unknown key is tried again.
- **Coarse, and recorded (B4):**
  - a user is decided with one of its keys as the principal, so a bucket Deny naming one specific key of a user with
    several may not apply;
  - the roles file is read at start, as `serve` reads it, so a role removed takes effect at the next start;
  - a role session's configuration is decided by the role's policy without its session policy (§1, the owner's
    choice).
- **A refused replica's body (B6):** a 4xx answer is the answer, even if the destination cut the body short.

## Durability (slice 2)

- **No new record kind:** a refused replica is noted FAILED with the bucket configuration record a destination's
  refusal already uses (ADR-0077 §7), whose crash behaviour the journal's sweeps cover.
- **A crash between the decision and the note:** the event is still in the outbox, so it is delivered again after
  recovery and decided again, with the same result. A crash after the note leaves FAILED, and the event delivered.
- **What is not swept:** a fault injected between the decision and the note is not. The ordering above is why it
  needs no sweep of its own.

## Slices

1. Record the requester (§1), and the decision as a requester (§2), with unit tests.
2. Decide at each write on `serve` (§3): replication, inventory and logs, with the S3 smoke's checks of a policy
   narrowed under a running server. No new record kind, so no fault sweep of its own (Durability, above).
3. On a cluster (§4), with the cluster smoke's checks.
4. The SDK matrix where it applies, and the exit review.

## Consequences

- **The journal:** no new record kind. Configurations are bucket configurations, as before, with new format
  versions.
- **Cost:** a write by an account's configuration costs what it costs now. A user's or role's costs one decision,
  from memory.
