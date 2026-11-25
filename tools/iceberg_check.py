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


def delete_table_bucket(bucket_arn):
    """DeleteTableBucket, once more on ConflictException: on a cluster a bucket's leftover records (its tables' objects,
    its configuration) are deleted with the request's own writes, so the first answers that it is not empty yet."""
    from botocore.exceptions import ClientError
    try:
        tables.delete_table_bucket(tableBucketARN=bucket_arn)
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConflictException":
            raise
        tables.delete_table_bucket(tableBucketARN=bucket_arn)


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
# S3 Tables' tags and storage class (ADR-0126 §1, §2), through boto3.
import json
from botocore.exceptions import ClientError
try:
    cfg_arn = tables.create_table_bucket(name="config-check", tags={"team": "data"},
                                         storageClassConfiguration={"storageClass": "INTELLIGENT_TIERING"})["arn"]
except ClientError as e:
    # On a cluster a create's settings are refused before anything is made (a shard's write does not see the bucket
    # made in its request): made plain, then set by their own calls.
    check("a configured create refused on a cluster", e.response["Error"]["Code"], "BadRequestException")
    check("and nothing made", [b["name"] for b in tables.list_table_buckets()["tableBuckets"] if b["name"] == "config-check"], [])
    cfg_arn = tables.create_table_bucket(name="config-check")["arn"]
    tables.tag_resource(resourceArn=cfg_arn, tags={"team": "data"})
    tables.put_table_bucket_storage_class(tableBucketARN=cfg_arn,
                                          storageClassConfiguration={"storageClass": "INTELLIGENT_TIERING"})
check("a table bucket's tags at its create", tables.list_tags_for_resource(resourceArn=cfg_arn)["tags"], {"team": "data"})
check("its storage class at its create",
      tables.get_table_bucket_storage_class(tableBucketARN=cfg_arn)["storageClassConfiguration"]["storageClass"],
      "INTELLIGENT_TIERING")
tables.tag_resource(resourceArn=cfg_arn, tags={"env": "test"})
tables.untag_resource(resourceArn=cfg_arn, tagKeys=["team"])
check("tags added and removed", tables.list_tags_for_resource(resourceArn=cfg_arn)["tags"], {"env": "test"})
tables.create_namespace(tableBucketARN=cfg_arn, namespace=["ns"])
made = tables.create_table(tableBucketARN=cfg_arn, namespace="ns", name="inherits", format="ICEBERG",
                           tags={"owner": "ana"})
check("a table's storage class: its bucket's",
      tables.get_table_storage_class(tableBucketARN=cfg_arn, namespace="ns", name="inherits")
      ["storageClassConfiguration"]["storageClass"], "INTELLIGENT_TIERING")
check("a table's tags, by its ARN", tables.list_tags_for_resource(resourceArn=made["tableARN"])["tags"], {"owner": "ana"})
# A write into the table's warehouse that names no class takes the table's.
s3 = boto3.client("s3", endpoint_url=endpoint, region_name=region, config=Config(retries={"max_attempts": 1}))
warehouse = tables.get_table_bucket(tableBucketARN=cfg_arn)["name"] + "--table-s3"
data_key = made["tableARN"].rsplit("/", 1)[1] + "/data/probe.parquet"
s3.put_object(Bucket=warehouse, Key=data_key, Body=b"PAR1")
check("a write into its warehouse takes its class", s3.head_object(Bucket=warehouse, Key=data_key).get("StorageClass"),
      "INTELLIGENT_TIERING")
s3.delete_object(Bucket=warehouse, Key=data_key)
tables.put_table_bucket_storage_class(tableBucketARN=cfg_arn, storageClassConfiguration={"storageClass": "STANDARD"})
check("the bucket's class put", tables.get_table_bucket_storage_class(tableBucketARN=cfg_arn)
      ["storageClassConfiguration"]["storageClass"], "STANDARD")
check("the table's kept from its create", tables.get_table_storage_class(tableBucketARN=cfg_arn, namespace="ns",
      name="inherits")["storageClassConfiguration"]["storageClass"], "INTELLIGENT_TIERING")
try:
    tables.tag_resource(resourceArn=cfg_arn, tags={"aws:x": "y"})
    check("an aws: tag refused", "taken", "refused")
except ClientError:
    check("an aws: tag refused", "refused", "refused")
# A table policy denying by the table's tag (aws:ResourceTag).
deny = {"Version": "2012-10-17", "Statement": [{"Effect": "Deny", "Principal": "*",
        "Action": "s3tables:GetTableMetadataLocation", "Resource": made["tableARN"],
        "Condition": {"StringEquals": {"aws:ResourceTag/stage": "locked"}}}]}
tables.put_table_policy(tableBucketARN=cfg_arn, namespace="ns", name="inherits", resourcePolicy=json.dumps(deny))
tables.get_table_metadata_location(tableBucketARN=cfg_arn, namespace="ns", name="inherits")
check("not denied while the tag is not there", True, True)
tables.tag_resource(resourceArn=made["tableARN"], tags={"stage": "locked"})
try:
    tables.get_table_metadata_location(tableBucketARN=cfg_arn, namespace="ns", name="inherits")
    check("denied by its tag", "allowed", "denied")
except ClientError as e:
    check("denied by its tag", e.response["Error"]["Code"], "ForbiddenException")
tables.untag_resource(resourceArn=made["tableARN"], tagKeys=["stage"])
tables.get_table_metadata_location(tableBucketARN=cfg_arn, namespace="ns", name="inherits")
check("allowed again once untagged", True, True)
tables.delete_table_policy(tableBucketARN=cfg_arn, namespace="ns", name="inherits")
tables.delete_table(tableBucketARN=cfg_arn, namespace="ns", name="inherits")
tables.delete_namespace(tableBucketARN=cfg_arn, namespace="ns")
delete_table_bucket(cfg_arn)
# S3 Tables' encryption (ADR-0126 §3, §4): a KMS table bucket (the smokes' KMS key `orders`), its tables' default.
kms_key = "arn:aws:kms:us-east-1:000000000000:key/orders"
enc_config = {"sseAlgorithm": "aws:kms", "kmsKeyArn": kms_key}
try:
    enc_arn = tables.create_table_bucket(name="enc-check", encryptionConfiguration=enc_config)["arn"]
except ClientError as e:
    # On a cluster, as the tags above: made plain, its encryption then put.
    check("an encrypted create refused on a cluster", e.response["Error"]["Code"], "BadRequestException")
    enc_arn = tables.create_table_bucket(name="enc-check")["arn"]
    tables.put_table_bucket_encryption(tableBucketARN=enc_arn, encryptionConfiguration=enc_config)
got = tables.get_table_bucket_encryption(tableBucketARN=enc_arn)["encryptionConfiguration"]
check("a table bucket's encryption at its create", (got["sseAlgorithm"], got.get("kmsKeyArn")), ("aws:kms", kms_key))
tables.create_namespace(tableBucketARN=enc_arn, namespace=["ns"])
kms_table = tables.create_table(tableBucketARN=enc_arn, namespace="ns", name="sealed", format="ICEBERG")
got = tables.get_table_encryption(tableBucketARN=enc_arn, namespace="ns", name="sealed")["encryptionConfiguration"]
check("a table's encryption: its bucket's", got["sseAlgorithm"], "aws:kms")
# A table made with its schema: its first metadata file, written in its create's request, sealed with the key (the
# M30 exit review: on a cluster the create's configuration is not read back in its own request).
tables.create_table(tableBucketARN=enc_arn, namespace="ns", name="schemed", format="ICEBERG",
                    metadata={"iceberg": {"schema": {"fields": [{"name": "a", "type": "long", "required": True}]}}})
first = tables.get_table_metadata_location(tableBucketARN=enc_arn, namespace="ns", name="schemed")["metadataLocation"]
head = s3.head_object(Bucket="enc-check--table-s3", Key=first.split("/", 3)[3])
check("its first metadata file sealed with the key",
      (head.get("ServerSideEncryption"), head.get("SSEKMSKeyId", "").rsplit("/", 1)[-1]), ("aws:kms", "orders"))
tables.delete_table(tableBucketARN=enc_arn, namespace="ns", name="schemed")
own = tables.create_table(tableBucketARN=enc_arn, namespace="ns", name="own", format="ICEBERG",
                          encryptionConfiguration={"sseAlgorithm": "AES256"})
check("a table's own encryption", tables.get_table_encryption(tableBucketARN=enc_arn, namespace="ns", name="own")
      ["encryptionConfiguration"]["sseAlgorithm"], "AES256")
enc_warehouse = "enc-check--table-s3"
sealed_key = kms_table["tableARN"].rsplit("/", 1)[1] + "/data/probe.parquet"
s3.put_object(Bucket=enc_warehouse, Key=sealed_key, Body=b"PAR1")
head = s3.head_object(Bucket=enc_warehouse, Key=sealed_key)
check("a write into its warehouse sealed with its key",
      (head.get("ServerSideEncryption"), head.get("SSEKMSKeyId", "").rsplit("/", 1)[-1]), ("aws:kms", "orders"))
check("and read back", s3.get_object(Bucket=enc_warehouse, Key=sealed_key)["Body"].read(), b"PAR1")
try:
    s3.put_object(Bucket=enc_warehouse, Key=sealed_key, Body=b"PAR1", ServerSideEncryption="AES256")
    check("a write asking for another encryption refused", "taken", "refused")
except ClientError as e:
    check("a write asking for another encryption refused", e.response["Error"]["Code"], "InvalidArgument")
s3.delete_object(Bucket=enc_warehouse, Key=sealed_key)
tables.delete_table_bucket_encryption(tableBucketARN=enc_arn)
try:
    tables.get_table_bucket_encryption(tableBucketARN=enc_arn)
    check("the bucket's encryption deleted", "there", "gone")
except ClientError:
    check("the bucket's encryption deleted", "gone", "gone")
check("its table's kept from its create", tables.get_table_encryption(tableBucketARN=enc_arn, namespace="ns",
      name="sealed")["encryptionConfiguration"]["sseAlgorithm"], "aws:kms")
for name in ("sealed", "own"):
    tables.delete_table(tableBucketARN=enc_arn, namespace="ns", name=name)
tables.delete_namespace(tableBucketARN=enc_arn, namespace="ns")
delete_table_bucket(enc_arn)
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
delete_table_bucket(arn)
check("cleaned up", "iceberg-check" in [b["name"] for b in tables.list_table_buckets()["tableBuckets"]], False)
sys.exit(1 if failed else 0)
