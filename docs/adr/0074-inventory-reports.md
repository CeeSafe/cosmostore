# ADR-0074: Inventory reports (M7 item 3)

**Status:** proposed, 16 Nov 2026, for M7 item 3 (ADR-0071), under the owner's standing go-ahead.

## Context

- S3 Inventory: a bucket's inventory configurations each name a destination bucket and a prefix, a schedule (daily
  or weekly), the versions (current or all), a filter prefix and optional fields; S3 writes the report as data files
  (gzip CSV, ORC or Parquet) and a `manifest.json` (with a `manifest.checksum`) under
  `<prefix>/<source bucket>/<id>/`, and tools (Athena, scripts) read them.

## Decision

1. **The configurations** are a `BucketConfig` of kind 14 (checkpoint format 21), up to 1,000 a bucket:
   `PutBucketInventoryConfiguration`, `Get…`, `List…` and `Delete…` (`?inventory&id=`; `NoSuchConfiguration`). The
   destination bucket must exist (InvalidArgument). **CSV only:** ORC, Parquet, the destination's encryption, and
   optional fields other than `Size`, `LastModifiedDate`, `ETag`, `StorageClass` and `IsMultipartUploaded` are
   `NotImplemented`.
2. **A report:** the source's versions under the filter (the current ones, or all with `VersionId`, `IsLatest`,
   `IsDeleteMarker`), a CSV row each in S3's form (every field quoted, the key URL-encoded, `STANDARD` the one storage
   class), in data files `<base>data/<32 hex>.csv.gz` cut at 32 MiB of CSV, then
   `<base><YYYY-MM-DDTHH-MMZ>/manifest.json` (S3's fields: source and destination, `version` `2016-11-30`,
   `creationTimestamp`, `fileFormat`, `fileSchema`, the files with their sizes and MD5s) and `manifest.checksum` (the
   manifest's MD5).
3. **When:** a task beside the access logs' looks every minute for enabled configurations whose last report is a day
   (or a week) old, or that have none, and writes theirs. The last report's time is read from the destination (its
   newest report folder) the first time a configuration is looked at, so a restart neither repeats a report nor skips
   one. `serve --inventory-day-seconds` shortens a day, for tests.
4. **gzip without compression:** lib/std has no deflate (CEESAFE_GAPS G35), so a data file is gzip of stored blocks
   (RFC 1951 §3.2.4) with its own CRC-32: valid, every reader opens it, as large as its CSV.
5. **A cluster's S3 port** refuses `PutBucketInventoryConfiguration` for now: the reports would need a leader's task.

## Consequences

- `inventoryConfigurationXml`, `gzipOfStoredBlocks` (the CRC-32 check value, one and two blocks), `inventoryRows`;
  the S3 smoke configures a daily report (a 3-second day), finds its manifest, checks its checksum, opens the data
  file with Python's `gzip` and finds a row per object with the bucket, key, size and ETag.

## Rejected

- **Uncompressed `.csv` files:** S3's CSV reports are gzip, and tools expect the `.csv.gz` they name.
