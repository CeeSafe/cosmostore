# ADR-0130: S3 Tables' logging, metrics and record expiration (M32)

**Status:** proposed, 25 Nov 2026. M32 is ADR-0129's item A (the owner: "A: Tables' small calls").

## Context

- **AWS's table bucket logging** (the S3 user guide's "Server access logging for S3 Tables"):
  - **The calls:**
    - `PUT /buckets/{arn}/logging`, with `{"tableBucketLoggingStatus": {"loggingEnabled": {"targetBucket",
      "targetPrefix", "targetObjectKeyFormat": {"partitionedPrefix": {"partitionDateSource": "EventTime" |
      "DeliveryTime"}}}}}`;
    - `{"tableBucketLoggingStatus": {}}` turns it off. There is no delete call;
    - `GET` answers `{"tableBucketLoggingStatus": {}}` when none is set, not an error.
  - **What is logged:** every request to the table bucket, in one record each:
    - its S3 Tables calls and its Iceberg catalog's, as `S3Tables.<Action>` (a table load is
      `S3Tables.GetTableMetadataLocation`);
    - its tables' storage, as `REST.<METHOD>.OBJECT`, with the key and size.
  - **The record:** 25 space-delimited fields:
    - `table_bucket_arn [time] table_arn namespace_name table_name key object_size remote_ip requester request_id
      operation http_status error_code bytes_sent total_time turnaround_time "referer" "user_agent"
      signature_version cipher_suite authentication_type host_header tls_version request_time_iso source_region`;
    - `-` where a field does not apply.
  - **The key:** partitioned only (no SimplePrefix):
    - `{prefix}{account}/{region}/{tableBucketName}/{YYYY}/{MM}/{DD}/{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}-{unique}`;
    - the date is the record's event time by default, or its delivery time.
  - **The target:**
    - a general purpose bucket of the same account and region;
    - SSE-S3 only (not SSE-KMS);
    - no object lock;
    - no requester pays;
    - writable by the logging service (here: by the requester who set it, as CosmoStore's S3 logs are, ADR-0094).
- **What CosmoStore has:**
  - **S3 server access logs** (ADR-0072, M7): a bucket's requests as lines of S3's format, queued
    (`AccessLogEntry`) and delivered as objects by the access log writer every `--access-log-seconds`, written as the
    requester who set the configuration.
  - Its keys are simple only: `PartitionedPrefix` is NotImplemented (ADR-0072 §1).
  - On a cluster, each node's shards queue to the node's writer, which delivers through its front.
- **Metrics:**
  - `Put`/`Get`/`DeleteTableBucketMetricsConfiguration`: CloudWatch request metrics on or off, an `id` answered;
  - CosmoStore's metrics are its `/metrics` endpoint (Prometheus).
- **Record expiration:** AWS's three calls are for its managed tables, and list MethodNotAllowedException.

## Decision (proposed)

1. **The logging configuration** (slice 1):
   - `PutTableBucketLogging` and `GetTableBucketLogging`, kept in the table bucket's configuration record (ADR-0126);
   - `{}` turns it off; a Get with none answers `{"tableBucketLoggingStatus": {}}`;
   - **refused (BadRequestException):** a target that is not a general purpose bucket here (a table bucket's
     warehouse, a directory bucket, none), one with SSE-KMS default encryption or object lock, a key format other
     than `partitionedPrefix`, and a target the caller may not `s3:PutObject` into (as `putBucketLogging` checks);
   - the requester who set it kept, and its log objects written as it (ADR-0094).
2. **The records** (slice 2): one per request on the table bucket, in AWS's 25 fields:
   - **its S3 Tables calls and Iceberg catalog calls,** after their answer, as `S3Tables.<Action>`, the action its
     authorization named (ADR-0084), with the table's ARN, namespace and name when the call names a table;
   - **its warehouse's S3 requests,** as `REST.<METHOD>.OBJECT`, with the key, size and the table its key's id names;
   - queued to the access log writer as S3's lines are, dropped and counted past its queue, never holding a request.
3. **Partitioned keys** (slice 2): a log object's key in AWS's partitioned form, by event time or delivery time. The
   same form for S3 buckets' `PartitionedPrefix`, NotImplemented until now (ADR-0072 §1).
4. **Metrics** (slice 3):
   - the configuration kept in the table bucket's record. Put answers 200; Get answers its `tableBucketARN` and an
     `id` (NotFoundException when none); Delete removes it;
   - while it is on, the table bucket's requests counted in `/metrics`, by operation and status class
     (`cosmostore_tables_requests_total{bucket,operation,status}`).
5. **Record expiration** (slice 3): `Put`/`GetTableRecordExpirationConfiguration` and
   `GetTableRecordExpirationJobStatus` answer MethodNotAllowedException, as AWS answers for a table one makes.
6. **The checks** (slice 4):
   - unit tests of the record and key formats, and of the configuration's refusals;
   - the S3 smoke and `iceberg_check.py`: a table bucket logged into a target, its calls and its warehouse's reads
     found in the delivered objects, partitioned by date, and logging turned off;
   - the cluster smoke: the same through a node;
   - the CLI, boto3 and the SDK matrix: logging, metrics and record expiration's answers;
   - S3's `PartitionedPrefix` checked in the S3 smoke.
7. **The exit review** (slice 5).

## For the owner to decide

- **Which requests a table bucket's logs hold:**
  - **all, as AWS (recommended):** its S3 Tables and catalog calls, and its warehouse's object reads and writes;
  - **its calls only:** fewer records, and no logging hook in the S3 path.
- **Partitioned keys for S3 buckets too:**
  - **yes (recommended):** the same code, and S3's `PartitionedPrefix` stops being NotImplemented;
  - **table buckets only.**
- **Metrics:**
  - **kept, and counted in `/metrics` (recommended);**
  - **kept and answered only.**

## Consequences

- **S3 Tables' API is done but for replication and migrations.**
- **A table bucket's requests can be audited** where its owner reads logs.
