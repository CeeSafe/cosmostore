#!/usr/bin/env python3
"""PyIceberg against CosmoStore's Iceberg REST catalog (ADR-0083 §5): a table made, appended to twice and read back,
a stale commit refused, commits that change nothing or name another table, a snapshot expired, a rename and a drop.

usage: tools/iceberg_check.py ENDPOINT     with AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY set to a key of the server's
       (needs pyiceberg with pyarrow, and boto3)
"""
import os
import sys

import boto3
import pyarrow as pa
from botocore.config import Config
from pyiceberg.catalog import load_catalog
from pyiceberg.exceptions import NoSuchNamespaceError, NoSuchTableError, TableAlreadyExistsError

endpoint = sys.argv[1]
failed = False


def check(name, got, want):
    global failed
    if got == want:
        print("ok   " + name)
    else:
        failed = True
        print("FAIL %s: expected [%s], got [%s]" % (name, want, got))


region = "us-east-1"
tables = boto3.client("s3tables", endpoint_url=endpoint, region_name=region, config=Config(retries={"max_attempts": 1}))
arn = tables.create_table_bucket(name="iceberg-check")["arn"]
catalog = load_catalog(
    "cosmo",
    **{
        "type": "rest",
        "uri": endpoint + "/iceberg",
        "warehouse": arn,
        "rest.sigv4-enabled": "true",
        "rest.signing-name": "s3tables",
        "rest.signing-region": region,
        "s3.endpoint": endpoint,
        "s3.region": region,
        "s3.access-key-id": os.environ["AWS_ACCESS_KEY_ID"],
        "s3.secret-access-key": os.environ["AWS_SECRET_ACCESS_KEY"],
        "s3.force-virtual-addressing": "false",
    },
)
catalog.create_namespace("sales", {"owner": "ana"})
check("list_namespaces", catalog.list_namespaces(), [("sales",)])
check("its owner kept", catalog.load_namespace_properties("sales"), {"owner": "ana"})
schema = pa.schema([pa.field("id", pa.int64(), nullable=False), pa.field("item", pa.string())])
table = catalog.create_table("sales.orders", schema=schema)
# Compaction (ADR-0098) is on by default; off here, so the snapshots counted below are this check's own (a cluster's
# day is seconds, and its pass may run between them).
tables.put_table_maintenance_configuration(tableBucketARN=arn, namespace="sales", name="orders", type="icebergCompaction",
                                           value={"status": "disabled"})
check("create_table: its location is its warehouse", table.location().startswith("s3://"), True)
try:
    catalog.create_table("sales.orders", schema=schema)
    check("a name twice", "made", "TableAlreadyExistsError")
except TableAlreadyExistsError:
    check("a name twice", "TableAlreadyExistsError", "TableAlreadyExistsError")
table.append(pa.table({"id": [1, 2], "item": ["apple", "pear"]}, schema=schema))
stale = catalog.load_table("sales.orders")
table.append(pa.table({"id": [3], "item": ["plum"]}, schema=schema))
rows = catalog.load_table("sales.orders").scan().to_arrow().sort_by("id")
check("two appends read back", rows.column("item").to_pylist(), ["apple", "pear", "plum"])
check("two snapshots", len(catalog.load_table("sales.orders").snapshots()), 2)
# A commit on metadata no longer current: the catalog refuses it (409), and PyIceberg refreshes and retries an append.
old_snapshot = stale.metadata.current_snapshot_id
with stale.transaction() as tx:
    tx.append(pa.table({"id": [4], "item": ["fig"]}, schema=schema))
check("a stale append, retried on fresh metadata", catalog.load_table("sales.orders").scan().to_arrow().num_rows, 4)
url = catalog.url("namespaces/sales/tables/orders")
raw = catalog._session.post(url, json={"requirements": [{"type": "assert-ref-snapshot-id", "ref": "main", "snapshot-id": old_snapshot}],
                                       "updates": [{"action": "set-properties", "updates": {"k": "v"}}]})
check("a commit whose requirement does not hold", (raw.status_code, raw.json()["error"]["type"]), (409, "CommitFailedException"))
raw = catalog._session.post(url, json={"requirements": [], "updates": [{"action": "set-statistics", "snapshot-id": 1}]})
check("an update not done here", raw.status_code, 400)
current = catalog.load_table("sales.orders").metadata_location
raw = catalog._session.post(url, json={"requirements": [], "updates": []})
check("a commit that changes nothing writes no file", (raw.status_code, raw.json()["metadata-location"]), (200, current))
raw = catalog._session.post(url, json={"identifier": {"namespace": ["sales"], "name": "other"}, "requirements": [],
                                       "updates": [{"action": "set-properties", "updates": {"k": "v"}}]})
check("a commit naming another table", raw.status_code, 400)
# The first snapshot expired: the table still loads and reads, its later snapshots' parent dropped with it.
raw = catalog._session.post(url, json={"requirements": [], "updates": [{"action": "remove-snapshots", "snapshot-ids": [old_snapshot]}]})
check("remove-snapshots", raw.status_code, 200)
after = catalog.load_table("sales.orders")
check("the snapshot is gone", old_snapshot in [s.snapshot_id for s in after.snapshots()], False)
check("rows after it", after.scan().to_arrow().num_rows, 4)
table = catalog.load_table("sales.orders")
with table.transaction() as tx:
    tx.set_properties(owner="check")
check("set_properties", catalog.load_table("sales.orders").properties.get("owner"), "check")
check("the S3 Tables API sees it", tables.get_table(tableBucketARN=arn, namespace="sales", name="orders")["metadataLocation"],
      catalog.load_table("sales.orders").metadata_location)
# A table made through the S3 Tables API with an Iceberg schema: its first metadata file, which PyIceberg reads.
tables.create_table(tableBucketARN=arn, namespace="sales", name="events", format="ICEBERG", metadata={"iceberg": {
    "schema": {"fields": [{"id": 1, "name": "at", "type": "timestamp", "required": True}, {"id": 2, "name": "kind", "type": "string"}]},
    "partitionSpec": {"fields": [{"sourceId": 1, "transform": "day", "name": "at_day"}]}}})
events = catalog.load_table("sales.events")
check("an S3 Tables API table's schema", [f.name for f in events.schema().fields], ["at", "kind"])
check("and its partition spec", [(f.name, f.source_id, str(f.transform)) for f in events.spec().fields],
      [("at_day", 1, "day")])
catalog.purge_table("sales.events")
try:
    catalog.rename_table("sales.orders", "nowhere.orders")
    check("a rename into a namespace not there", "renamed", "NoSuchNamespaceError")
except NoSuchNamespaceError:
    check("a rename into a namespace not there", "NoSuchNamespaceError", "NoSuchNamespaceError")
# A staged create (ADR-0124): PyIceberg's create transaction, its rows appended in it, the table made at its commit
# (on `serve` and through a cluster's node).
with catalog.create_table_transaction("sales.staged", schema=schema) as tx:
    tx.append(pa.table({"id": [7, 8], "item": ["fig", "kiwi"]}, schema=schema))
check("create_table_transaction: the table made with its rows",
      sorted(catalog.load_table("sales.staged").scan().to_arrow().column("id").to_pylist()), [7, 8])
catalog.purge_table("sales.staged")
catalog.rename_table("sales.orders", "sales.orders_v2")
check("rename_table", catalog.list_tables("sales"), [("sales", "orders_v2")])
check("rows after the rename", catalog.load_table("sales.orders_v2").scan().to_arrow().num_rows, 4)
catalog.purge_table("sales.orders_v2")
try:
    catalog.load_table("sales.orders_v2")
    check("purge_table", "there", "NoSuchTableError")
except NoSuchTableError:
    check("purge_table", "NoSuchTableError", "NoSuchTableError")
catalog.drop_namespace("sales")
tables.delete_table_bucket(tableBucketARN=arn)
check("cleaned up", "iceberg-check" in [b["name"] for b in tables.list_table_buckets()["tableBuckets"]], False)
sys.exit(1 if failed else 0)
