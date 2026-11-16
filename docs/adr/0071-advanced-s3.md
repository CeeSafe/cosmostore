# ADR-0071: Advanced S3, the plan of M7

**Status:** accepted, 16 Nov 2026 (the owner: "Yes, accept ADR-0071 to 0077"); proposed the same day for M7, which the owner started ("Go ahead start M7").

## Context

- **ROADMAP M7:** bucket replication and multi-site, inventory, access logs, website hosting, Access Points, STS, and
  possibly directory buckets or Tables; each item an independent project with its own support matrix.
- **What M5 and M6 left to build on:** per-bucket configuration as `BucketConfig` records (policies, CORS, lifecycle,
  notifications, quotas); the journal as an outbox with a delivery cursor (ADR-0048); the per-request audit line and
  its writer task (ADR-0051); bucket policies and their evaluation (ADR-0041 on); the admin API (ADR-0054); a cluster
  whose S3 port does not yet take audit, notifications or rate limits (runbook).

## Decision

1. **The items, in order, each its own ADR with an S3 support matrix** (what is done, what is refused with
   `NotImplemented`, never silently ignored):

   | # | Item | Done when |
   |---|---|---|
   | 1 | Server access logs (`PutBucketLogging`) | a bucket's requests are delivered as log objects, in S3's access log format, to its target bucket |
   | 2 | Static website hosting (`PutBucketWebsite`) | a website endpoint serves index and error documents and redirects, with the bucket's policy |
   | 3 | Inventory (`PutBucketInventoryConfiguration`) | a daily or weekly CSV report and its manifest are written to the destination bucket |
   | 4 | STS (`AssumeRole`, `GetSessionToken`) | temporary credentials with a session token sign requests, scoped by the role's policy, and expire |
   | 5 | Access Points | a named access point with its own policy takes requests by its alias and ARN |
   | 6 | Replication (`PutBucketReplication`) | new versions are copied to a destination bucket on this server or another S3 endpoint, with replication status |

   In that order: each builds on the one before or on what M5 left (access logs on the audit line, inventory on
   delivering objects into a bucket, Access Points on STS's identities and policies, replication on the outbox), and
   the cheapest come first.
2. **Single node first.** Each item works on `serve`; whether and how it works on a cluster's S3 port is in its ADR
   (configuration records replicate by themselves; deliveries need a leader's task).
3. **Directory buckets and S3 Tables** are not in M7: they are other storage classes with APIs of their own; a later
   milestone may take them.

## Consequences

- M7 has no single exit: each item closes when its "done when" holds, with its tests and the S3 smoke or a client SDK
  test exercising it.
