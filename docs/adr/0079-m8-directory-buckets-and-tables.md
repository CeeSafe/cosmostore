# ADR-0079: Directory buckets and S3 Tables, the plan of M8

**Status:** proposed, 18 Nov 2026, for the owner to accept or change. M7 left both out (ADR-0071 §3: "other storage
classes with APIs of their own; a later milestone may take them"); the owner asked to go on after M7 closed.

## Context

- **Directory buckets** (S3 Express One Zone) are buckets named `<base>--<zone-id>--x-s3`, made with a
  `CreateBucketConfiguration` that names a zone (`Location`, `Type` AvailabilityZone) and a `Bucket` of `Type`
  Directory. Their data calls are authorized by **CreateSession** (`GET /<bucket>?session`), which gives short-lived
  credentials and a session token sent as `x-amz-s3session-token`; requests are signed for the service `s3express`.
  `ListDirectoryBuckets` lists them. They do less than general-purpose buckets (no versioning, object lock, ACLs or
  tags among other things), and some calls behave differently (listings are not in key order; a prefix in a listing
  ends in the delimiter `/`).
- **What a client does here, checked 18 Nov 2026** (boto3 1.42.97, endpoint `http://127.0.0.1:…`): for a bucket
  named `data--usw2-az1--x-s3` it first sends `GET /data--usw2-az1--x-s3?session` signed for `s3express`, then the
  PUT path-style with the session's credentials. With `disable_s3_express_session_auth` it signs the PUT for
  `s3express` with the long-term key and no session. So a custom endpoint is used as is; CreateSession and the
  `s3express` signing service are the entry fee.
- **S3 Tables** are table buckets (`arn:aws:s3tables:…:bucket/<name>`) holding namespaces and Apache Iceberg tables,
  through a separate API (`s3tables`: Create/Get/List/Delete of table buckets, namespaces and tables;
  `GetTableMetadataLocation` and `UpdateTableMetadataLocation` with a version token, the compare-and-set that commits
  an Iceberg snapshot) and an Iceberg REST catalog endpoint. The engines (Spark, Trino, PyIceberg) write the data and
  metadata files themselves, as objects in the table's warehouse location; AWS adds maintenance (compaction, snapshot
  expiry, unreferenced file removal) and table policies.
- **What CosmoStore has:** sealed session tokens and their verification (STS, ADR-0075), `BucketConfig` records,
  bucket and access point policies (ADR-0043, ADR-0076), the cluster's group 0 for names that span shards (ADR-0078
  §5), and conditional writes (ADR-0015) that a version-token compare-and-set can stand on.

## Decision (proposed)

1. **M8 has two items, each its own ADR with a support matrix,** as M7's were (what is done; what is refused with
   `NotImplemented` or another error, never silently ignored), on `serve` first and then a cluster's S3 port.

   | # | Item | Done when |
   |---|---|---|
   | 1 | Directory buckets | CreateBucket with a directory configuration, CreateSession, requests signed for `s3express` with a session token, `ListDirectoryBuckets`, and S3's differences for them, exercised by the AWS CLI and every SDK of the matrix |
   | 2 | S3 Tables | the `s3tables` API for table buckets, namespaces and tables, and the Iceberg REST catalog's calls an engine needs, so PyIceberg can create a table, append to it and read it back, its commits a compare-and-set |

2. **Directory buckets first:** smaller, an extension of buckets and of STS's tokens, and every S3 SDK already speaks
   it. Tables are a catalog service of their own and the larger item.
3. **What a directory bucket is here:** an ordinary bucket underneath, marked as a directory bucket, with S3's limits
   enforced (the calls it does not take are refused, as S3 refuses them) and its listing rules. One zone id per
   server (`serve --zone-id`, e.g. `local-az1`) names the zone its buckets may be made in; a cluster has one per
   cluster. Being one zone changes nothing here: the durability is the store's, as it is for every bucket.
4. **What Tables are here, at first:** the catalog (the records and the compare-and-set), stored as `BucketConfig`
   records of the table bucket, and the warehouse an ordinary bucket. Maintenance (compaction, snapshot expiry,
   unreferenced files) is NotImplemented in the first slice and a candidate for a second one; table policies follow
   ADR-0043's evaluation.
5. **Not in M8:** S3 Metadata tables (a journal of a bucket's changes as a table), S3 Vectors, and any Iceberg
   engine inside the server.

## For the owner to decide

- **Both items, or directory buckets only.** Tables are worth it only if Iceberg engines are meant to run against
  CosmoStore; directory buckets are worth it for S3 compatibility alone.
- **How strict directory buckets are.** Proposed: S3's limits enforced, so code that works here works on AWS. The
  other way, a directory bucket that does everything a bucket does, is less to build and less faithful.

## Consequences

- Each item's ADR fixes its record formats and checkpoint format, its fault sweep if it writes new records, and its
  cluster section; S3's behaviour that this ADR summarizes is checked against AWS's documentation and the SDKs there.
- The SDK matrix gains each item's calls, as it did M7's (`docs/compatibility.md`).

## Rejected

- **Directory buckets as a name check only** (taking `--x-s3` names as ordinary buckets): every SDK calls
  CreateSession first and signs for `s3express`, so nothing would work without them.
- **Tables as an Iceberg engine in the server:** engines already write Iceberg; the catalog and its compare-and-set
  are what a store must give them.
