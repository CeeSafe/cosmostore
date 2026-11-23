#!/usr/bin/env python3
"""Steps of tools/cluster_maintenance_smoke.sh (ADR-0110 §5 to §7): PyIceberg against one node of a cluster.

  make ENDPOINT BUCKET TABLE   a table of two partitions, two one-row files each, compaction off while written, on after
  job ENDPOINT BUCKET TABLE    the compaction job's status
  files ENDPOINT BUCKET TABLE  "<data files> <rows> <ids>", the ids sorted
  write ENDPOINT BUCKET NAME   a namespace made in the table bucket (a write to its shard): the seconds it took

AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are a key of the cluster's (needs pyiceberg with pyarrow, boto3).
"""
import os
import sys
import time

import boto3
import pyarrow as pa
from botocore.config import Config
from pyiceberg.catalog import load_catalog

what, endpoint, bucket = sys.argv[1], sys.argv[2], sys.argv[3]
region = "us-east-1"
tables = boto3.client("s3tables", endpoint_url=endpoint, region_name=region,
                      config=Config(retries={"max_attempts": 6, "mode": "standard"}))


def arn_of(name):
    for b in tables.list_table_buckets()["tableBuckets"]:
        if b["name"] == name:
            return b["arn"]
    return tables.create_table_bucket(name=name)["arn"]


arn = arn_of(bucket)
catalog = load_catalog("cosmo", **{
    "type": "rest", "uri": endpoint + "/iceberg", "warehouse": arn, "rest.sigv4-enabled": "true",
    "rest.signing-name": "s3tables", "rest.signing-region": region, "s3.endpoint": endpoint, "s3.region": region,
    "s3.access-key-id": os.environ["AWS_ACCESS_KEY_ID"], "s3.secret-access-key": os.environ["AWS_SECRET_ACCESS_KEY"],
    "s3.force-virtual-addressing": "false"})


def compaction(name, status):
    tables.put_table_maintenance_configuration(tableBucketARN=arn, namespace="ns", name=name, type="icebergCompaction",
        value={"status": status, "settings": {"icebergCompaction": {"targetFileSizeMB": 1, "strategy": "binpack"}}})


if what == "make":
    name = sys.argv[4]
    if "ns" not in [n[0] for n in catalog.list_namespaces()]:
        catalog.create_namespace("ns")
    schema = pa.schema([pa.field("id", pa.int64(), nullable=False), pa.field("part", pa.string(), nullable=False)])
    catalog.create_table("ns." + name, schema=schema)
    compaction(name, "disabled")
    with catalog.load_table("ns." + name).update_spec() as u:
        u.add_identity("part")
    for i in range(2):
        catalog.load_table("ns." + name).append(pa.table({"id": [2 * i, 2 * i + 1], "part": ["a", "b"]}, schema=schema))
    compaction(name, "enabled")
    print("made")
elif what == "job":
    status = tables.get_table_maintenance_job_status(tableBucketARN=arn, namespace="ns", name=sys.argv[4])
    print(status["status"]["icebergCompaction"].get("status", ""))
elif what == "files":
    t = catalog.load_table("ns." + sys.argv[4])
    files = list(t.scan().plan_files())
    rows = t.scan().to_arrow()
    print(len(files), rows.num_rows, ",".join(str(i) for i in sorted(rows.column("id").to_pylist())))
elif what == "write":
    start = time.time()
    tables.create_namespace(tableBucketARN=arn, namespace=[sys.argv[4]])
    print("%.1f" % (time.time() - start))
