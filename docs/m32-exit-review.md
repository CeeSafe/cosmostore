# M32 exit review: S3 Tables' logging, metrics and record expiration (25 Nov 2026)

**M32's exit (ADR-0129 item A; ADR-0130, with the owner's choices):**
- a table bucket's access logs: its calls and its warehouse's requests, in AWS's 25-field records, delivered under
  partitioned keys;
- partitioned keys for S3 buckets too;
- metrics kept and counted;
- record expiration answered as AWS answers for a table one makes.

## How it was checked

- **Unit tests:** `partitionedLogKeys` (the SDKs' XML form), `tableLoggingBodies`, `tableLogRecords` and
  `tablesCallsAreNoted`.
- **`iceberg_check.py`** (on `serve` and through a cluster's node): a table bucket logged into a target. Its calls,
  its creates and a warehouse read are delivered under partitioned keys, 25 fields each; a warehouse target is
  refused; logging turns off.
- **`s3_smoke.sh`:**
  - **the AWS CLI's S3 Tables checks (33):** metrics, the stats' counts, and record expiration;
  - **S3's `PartitionedPrefix`** through the CLI: kept, answered and delivered under a partitioned key (the review's
    A1).
- **The SDK matrix:** Go and JS 17 checks each, .NET 13, Java 6 (its pinned SDK has no logging calls).
- **The cluster smokes and CI.**
- **The review:** one agent read ADR-0130 and the code without my notes. Its findings come from reading. A1 was
  shown on the binary before its fix.

## Findings

### A. Fixed before closing

1. **High: S3's `PartitionedPrefix` used the wrong XML shape.**
   - The SDKs send the date source as a child element (`<PartitionedPrefix><PartitionDateSource>…`), and this read
     and answered an attribute. A DeliveryTime setting was kept as EventTime with no error, and answered with no
     source.
   - The unit test used the same wrong form, and the smoke check ADR-0130 §6 promised was missing.
   - **Fixed:** parsed and answered as the SDKs write it; an unknown source is refused.
   - **Tests:** the unit test in the SDKs' form, and the smoke's CLI round trip and delivery. The binary before the
     fix answers the CLI's DeliveryTime as `None`.
2. **Medium: the table bucket counts grew without bound.** Any name a request carried was counted, and a deleted
   bucket's counts were kept.
   - **Fixed:** a request answered 404 is not counted, at most 4,096 table buckets are, and a table bucket's delete
     ends its counts.
3. **Medium: the promised `PartitionedPrefix` smoke check was missing.** It has been added (A1).
4. **Low: plain S3 logs were split per source bucket.** Simple keys share an object across sources again, as
   before M32.
5. **Low: an S3 Tables call's audit requester depended on some bucket logging.** It is filled whenever the audit log
   or logging is on.
6. **Low: a failure to note a call's log facts could fail an answered call.** It no longer can.
7. **Low: some Iceberg paths named the wrong table:** `tables/rename`, and a namespace named `tables`. Names are
   taken by position now.

### B. Recorded, not fixed

1. **Record expiration on a cluster** is routed to shard 0, so its record and count are not its table bucket's. The
   405 answer is the same on every shard.
2. **Requests refused before their caller is known** (no key, a refused signature, an Express token) are not logged
   or counted. AWS logs them.
3. **A warehouse request's namespace and table name are `-`,** and every record's bytes sent and object size too.
4. **Each S3 Tables request costs a path parse and a lock** to be counted, and on a cluster, where some bucket is
   always taken to log, a configuration lookup.
5. **A downgrade** to a binary before M32 reads a partitioned logging value as none.
6. **The Java SDK pinned in the matrix has no logging calls,** and the AWS CLI 2.34 has none either. boto3, Go, JS
   and .NET check logging.

## Where the code differs from ADR-0130

As its As built records: the configuration is kept as the warehouse's logging; the counts are in the stats endpoint,
not a `/metrics` endpoint; a warehouse request's namespace and name are `-`. Since the review: a 404 is not counted,
the counts are bounded, and simple keys are batched across sources.
