# ADR-0094: Configurations decided at delivery (M14)

**Status:** proposed, 20 Nov 2026. M14 is item A of ADR-0093 (the owner: "A: decided at delivery"); a session's
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

## Decision (proposed)

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
   - **An inventory report or a log object:** it is not written. The refusal is logged once per configuration and
     run, and counted in the stats.
   - **Later writes:** each is decided again. One a user's policy allows once more goes through.
4. **On a cluster,** the destination's shard decides.
   - **How it learns the requester:** the delivering node sends it with the write, in a field the front passes only
     with the node's stamp (`x-cosmo-acting-as`, as ADR-0078 §4's replica fields).
   - **What decides:** the shard's S3 server decides that write as the requester, with its own node's credentials
     and policies. A field without the stamp is dropped by the front, as the cluster's other fields are.

## Slices

1. Record the requester (§1), and the decision as a requester (§2), with unit tests.
2. Decide at each write on `serve` (§3): replication, inventory and logs, with the S3 smoke's checks of a user
   removed and a policy narrowed, and a fault sweep of the replication path (ADR-0004).
3. On a cluster (§4), with the cluster smoke's checks.
4. The SDK matrix where it applies, and the exit review.

## Consequences

- **The journal:** no new record kind. Configurations are bucket configurations, as before, with new format
  versions.
- **Cost:** a write by an account's configuration costs what it costs now. A user's or role's costs one decision,
  from memory.
