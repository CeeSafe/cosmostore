# ADR-0072: Server access logs (M7 item 1)

**Status:** proposed, 16 Nov 2026, for M7 item 1 (ADR-0071), under the owner's standing go-ahead ("Go ahead start
M7").

## Context

- S3's server access logging: `PutBucketLogging` names a target bucket and a prefix; S3 delivers the bucket's
  requests, a line each in its access log format, as objects in the target, best effort, within hours.
- CosmoStore has the audit log (ADR-0051): a line per request into one file, for the server's operator. Access logs
  are the bucket owner's, per bucket, into a bucket, in S3's format, so that tools that read S3's logs read these.

## Decision

1. **The configuration** is a `BucketConfig` record of kind 12: the target bucket and the prefix (checkpoint format
   19 keeps it in the bucket's entry). `PutBucketLogging` with a `<LoggingEnabled>` sets it, without one takes it
   off; `GetBucketLogging` gives it back. The target bucket must exist (`InvalidTargetBucketForLogging`). Target
   grants and partitioned object keys (`TargetObjectKeyFormat` with `PartitionedPrefix`) are `NotImplemented`.
2. **A line per request** to a bucket that logs, after its response, in S3's field order: owner (`cosmostore`),
   bucket, time, remote address, requester (the access key, `-` for anonymous), request id, operation
   (`REST.GET.OBJECT`, `REST.PUT.LOGGING_STATUS`, ...), key, request-URI, status, error code, bytes sent and object
   size (`-`: not measured), total time in ms, turn-around (`-`), referrer, user agent, version id and host id
   (`-`), signature version, cipher (`-`), authentication type, host, TLS version, access point and ACL (`-`).
   **The request-URI gives its query's names, never their values**, as the audit log does (ADR-0051 §2): a presigned
   URL's values are its credentials while it lasts. Spaces and quotes in a field are written `%20` and `%22`.
   While no bucket logs, a request looks nothing up.
3. **Delivery:** lines go to a queue (8,192; a full queue drops the line and counts it); a task beside the audit
   writer gathers them per target and, every `--access-log-seconds` (300 by default) or at 1 MiB, writes them as one
   object `<prefix>YYYY-mm-DD-HH-MM-SS-<16 hex>` in the target bucket. A delivery that fails (the target gone) loses
   its lines and says so once on stderr. A crash loses what is queued: as S3, best effort.
4. **A cluster's S3 port** refuses `PutBucketLogging` with `NotImplemented` for now, as it keeps no audit log
   (runbook): the lines would need a delivering task per shard leader.

## Consequences

- `loggingConfigurationXml`, `accessLogLineFormat`; the S3 smoke turns logging on, makes requests, and finds the
  delivered object with the PUT's line and a missing key's `NoSuchKey`.
- A bucket that logs to itself logs its own log deliveries' lists and reads, not the deliveries (they are no
  requests).

## Rejected

- **The full query in the request-URI**, as S3 writes it: a log readable by whoever reads the target bucket would
  hold presigned URLs' signatures.
