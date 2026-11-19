#!/usr/bin/env python3
"""Table maintenance end to end (ADR-0086): a PyIceberg table appended to six times, its snapshots expired to the two
newest, an orphan file and the expired snapshots' files removed, and every row still read back.

usage: tools/maintenance_check.py ENDPOINT DAY_SECONDS   against `serve --tables-day-seconds DAY_SECONDS`, with
       AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY set to a key of the server's (needs pyiceberg with pyarrow, boto3)
"""
import os
import sys
import time

import boto3
import pyarrow as pa
from botocore.config import Config
from pyiceberg.catalog import load_catalog

endpoint, day = sys.argv[1], float(sys.argv[2])
failed = False


def check(name, got, want):
    global failed
    if got == want:
        print("ok   " + name)
    else:
        failed = True
        print("FAIL %s: expected [%s], got [%s]" % (name, want, got))


def wait_for(name, test, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if test():
            check(name, True, True)
            return
        time.sleep(0.5)
    check(name, "not within %.0f s" % seconds, "done")


region = "us-east-1"
cfg = Config(retries={"max_attempts": 1})
tables = boto3.client("s3tables", endpoint_url=endpoint, region_name=region, config=cfg)
s3 = boto3.client("s3", endpoint_url=endpoint, region_name=region, config=cfg)
arn = tables.create_table_bucket(name="maint-check")["arn"]
catalog = load_catalog("cosmo", **{
    "type": "rest", "uri": endpoint + "/iceberg", "warehouse": arn, "rest.sigv4-enabled": "true",
    "rest.signing-name": "s3tables", "rest.signing-region": region, "s3.endpoint": endpoint, "s3.region": region,
    "s3.access-key-id": os.environ["AWS_ACCESS_KEY_ID"], "s3.secret-access-key": os.environ["AWS_SECRET_ACCESS_KEY"],
    "s3.force-virtual-addressing": "false"})
catalog.create_namespace("ns")
schema = pa.schema([pa.field("id", pa.int64(), nullable=False), pa.field("item", pa.string())])
table = catalog.create_table("ns.t", schema=schema)
for i in range(6):
    table.append(pa.table({"id": [i], "item": ["row %d" % i]}, schema=schema))
check("six snapshots", len(catalog.load_table("ns.t").snapshots()), 6)

# The configurations: AWS's defaults until set; compaction is not done here.
got = tables.get_table_maintenance_configuration(tableBucketARN=arn, namespace="ns", name="t")["configuration"]
check("snapshot management on by default", got["icebergSnapshotManagement"]["status"], "enabled")
check("compaction off", got["icebergCompaction"]["status"], "disabled")
try:
    tables.put_table_maintenance_configuration(tableBucketARN=arn, namespace="ns", name="t", type="icebergCompaction",
                                               value={"status": "enabled"})
    check("compaction enabled", "taken", "refused")
except Exception as e:
    check("compaction enabled", "NotImplemented" in str(e), True)

# Keep the two newest; expire the rest after an hour (a 24th of the day).
tables.put_table_maintenance_configuration(tableBucketARN=arn, namespace="ns", name="t", type="icebergSnapshotManagement",
    value={"status": "enabled", "settings": {"icebergSnapshotManagement": {"minSnapshotsToKeep": 2, "maxSnapshotAgeHours": 1}}})
wait_for("snapshots expired to the two newest", lambda: len(catalog.load_table("ns.t").snapshots()) == 2, day)
status = tables.get_table_maintenance_job_status(tableBucketARN=arn, namespace="ns", name="t")["status"]
check("snapshot management Successful", status["icebergSnapshotManagement"]["status"], "Successful")
check("compaction Disabled", status["icebergCompaction"]["status"], "Disabled")
rows = catalog.load_table("ns.t").scan().to_arrow().sort_by("id")
check("every row after expiry", rows.column("id").to_pylist(), [0, 1, 2, 3, 4, 5])

# An orphan in the warehouse; the expired snapshots' manifest lists are now unreferenced too. Removal after
# unreferencedDays + nonCurrentDays = 2 days.
wh = tables.get_table(tableBucketARN=arn, namespace="ns", name="t")["warehouseLocation"]
bucket, prefix = wh[5:].split("/", 1)
orphan = prefix + "/data/orphan.parquet"
s3.put_object(Bucket=bucket, Key=orphan, Body=b"not a table's")
tables.put_table_bucket_maintenance_configuration(tableBucketARN=arn, type="icebergUnreferencedFileRemoval",
    value={"status": "enabled", "settings": {"icebergUnreferencedFileRemoval": {"unreferencedDays": 1, "nonCurrentDays": 1}}})


def keys():
    out, token = [], None
    while True:
        kw = {"Bucket": bucket, "Prefix": prefix + "/"}
        if token:
            kw["ContinuationToken"] = token
        page = s3.list_objects_v2(**kw)
        out += [o["Key"] for o in page.get("Contents", [])]
        if not page.get("IsTruncated"):
            return out
        token = page["NextContinuationToken"]


before = keys()
expired_lists = [k for k in before if "/metadata/snap-" in k]
live = catalog.load_table("ns.t")
live_lists = [s.manifest_list.split("/", 3)[3] for s in live.snapshots()]
wait_for("the orphan removed after two days", lambda: orphan not in keys(), 3.5 * day)
after = keys()
check("the expired snapshots' manifest lists removed", sorted(k for k in after if "/metadata/snap-" in k), sorted(live_lists))
check("fewer files than before", len(after) < len(before), True)
status = tables.get_table_maintenance_job_status(tableBucketARN=arn, namespace="ns", name="t")["status"]
check("unreferenced file removal Successful", status["icebergUnreferencedFileRemoval"]["status"], "Successful")
rows = catalog.load_table("ns.t").scan().to_arrow().sort_by("id")
check("every row after removal", rows.column("id").to_pylist(), [0, 1, 2, 3, 4, 5])
table = catalog.load_table("ns.t")
table.append(pa.table({"id": [6], "item": ["row 6"]}, schema=schema))
check("and it takes appends", catalog.load_table("ns.t").scan().to_arrow().num_rows, 7)
catalog.purge_table("ns.t")
catalog.drop_namespace("ns")
# Its maintenance configuration is left over: on a cluster that is deleted with the first DeleteTableBucket, which
# answers ConflictException, and a retry deletes the bucket (ADR-0083 §7).
for attempt in range(3):
    try:
        tables.delete_table_bucket(tableBucketARN=arn)
        break
    except tables.exceptions.ConflictException:
        time.sleep(0.5)
check("the table bucket deleted", "maint-check" in [b["name"] for b in tables.list_table_buckets()["tableBuckets"]], False)
sys.exit(1 if failed else 0)
