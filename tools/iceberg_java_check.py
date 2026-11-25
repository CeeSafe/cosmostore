#!/usr/bin/env python3
"""Iceberg Java's v3 table compacted here (ADR-0122 slice 6).

Iceberg Java (tools/iceberg_java, V3Check) upgrades a v2 table to v3 (its next row id from 0), then makes a v3 table
through the REST catalog, appends three files and commits
a deletion vector of the first file's positions 0 and 1, written by its own `BaseDVFileWriter`. Compaction then
merges the table. After it:
- the merged file holds each live row with the `_row_id` it had before (its file's first row id plus its position);
- Iceberg Java reads the same rows, with no delete left;
- the table is still v3, its snapshot a replace with a first row id, and its next row id advanced.
With ENCRYPTED=1 the table bucket is sealed under the KMS key `orders` (ADR-0126 §5): every phase then runs on an
encrypted table, and at the end every file of its warehouse (Java's, PyIceberg's, the catalog's and compaction's) is
sealed under that key in the store.

usage: tools/iceberg_java_check.py ENDPOINT DAY_SECONDS CLASSPATH   against `serve --tables-day-seconds DAY_SECONDS`,
       with AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY set (needs a JDK, pyiceberg, pyarrow and boto3)
"""
import io
import os
import subprocess
import sys
import time

import boto3
import pyarrow.parquet as pq
from botocore.config import Config
from pyiceberg.catalog import load_catalog

endpoint, day, classpath = sys.argv[1], float(sys.argv[2]), sys.argv[3]
failed = False


def check(name, got, want):
    global failed
    if got == want:
        print("ok   " + name)
    else:
        failed = True
        print("FAIL %s: expected [%s], got [%s]" % (name, want, got))


region = "us-east-1"
cfg = Config(retries={"max_attempts": 1})
tables = boto3.client("s3tables", endpoint_url=endpoint, region_name=region, config=cfg)
s3 = boto3.client("s3", endpoint_url=endpoint, region_name=region, config=cfg)
encrypted = os.environ.get("ENCRYPTED") == "1"
KMS_KEY = "arn:aws:kms:us-east-1:000000000000:key/orders"
if encrypted:
    arn = tables.create_table_bucket(name="java-check", encryptionConfiguration={"sseAlgorithm": "aws:kms",
                                                                               "kmsKeyArn": KMS_KEY})["arn"]
else:
    arn = tables.create_table_bucket(name="java-check")["arn"]


def java(phase):
    if os.environ.get("CALL_TRACES") and phase == "calls":
        trace = subprocess.run(["java", "--enable-native-access=ALL-UNNAMED", "-cp", classpath, "V3Check", endpoint, arn,
                                "calls"], capture_output=True, text=True, timeout=300)
        print("\n".join(l for l in trace.stderr.splitlines() if not l.startswith("WARNING"))[:6000])
    run = subprocess.run(["java", "--enable-native-access=ALL-UNNAMED", "-cp", classpath, "V3Check", endpoint, arn,
                          phase], capture_output=True, text=True, timeout=300)
    if run.returncode != 0:
        print(run.stdout[-3000:])
        print(run.stderr[-3000:])
        check("Iceberg Java's %s" % phase, run.returncode, 0)
        sys.stdout.flush()
        os._exit(1)
    out = {}
    rows = []
    ids = []
    for line in run.stdout.splitlines():
        parts = line.split()
        if parts and parts[0] == "row":
            rows.append((int(parts[1]), int(parts[2])))
        elif parts and parts[0] == "id":
            ids.append(int(parts[1]))
        elif len(parts) == 2:
            out[parts[0]] = parts[1]
    return out, rows, ids


# The table made, and its compaction disabled before anything is appended (it is enabled by default, as on S3 Tables).
made, _, _ = java("create")
check("Java made a v3 table", made.get("format"), "3")
tables.put_table_maintenance_configuration(tableBucketARN=arn, namespace="javans", name="v3", type="icebergCompaction",
    value={"status": "disabled", "settings": {"icebergCompaction": {"targetFileSizeMB": 1, "strategy": "binpack"}}})
upgraded, _, _ = java("upgrade")
check("a v2 table upgraded by Java", (upgraded.get("before"), upgraded.get("format")), ("2", "3"))
check("its next row id from 0", upgraded.get("next-row-id"), "0")
check("its first v3 append's rows given ids", (upgraded.get("first-row-id"), upgraded.get("after-append")), ("0", "5"))
# An engine's CREATE TABLE AS SELECT and CREATE OR REPLACE TABLE AS SELECT (ADR-0124): Iceberg Java's create, replace and
# create-or-replace transactions.
ctas, _, _ = java("ctas")
check("CTAS: the table made with its rows", (ctas.get("ctas-rows"), ctas.get("ctas-snapshots")), ("7", "1"))
rtas, _, _ = java("rtas")
check("RTAS: its rows replaced, its schema the new one", (rtas.get("rtas-rows"), rtas.get("rtas-columns")), ("3", "3"))
check("RTAS: its history kept", rtas.get("rtas-snapshots"), "2")
check("create-or-replace, both ways: the second's rows", rtas.get("cor-rows"), "2")
# Each other catalog call Iceberg Java's client makes (ADR-0124 §3).
calls, _, _ = java("calls")
# Refused by design, as S3 Tables does (Java's client sees no such endpoint in the catalog's config):
# - a namespace's properties are its `owner` alone, set at its create;
# - a table is not registered from a metadata file: two tables would share a warehouse, and one's drop would purge the
#   other's files.
refused = {"set-namespace-properties", "remove-namespace-properties", "register-table"}
for name, result in sorted(calls.items()):
    if name.startswith("call-"):
        if name[5:] in refused:
            check("Java's %s refused" % name[5:], result.startswith("UnsupportedOperationException"), True)
        else:
            check("Java's %s" % name[5:], result, "ok")
before, rows, _ = java("write")
check("still v3 after its appends", before.get("format"), "3")
check("its deletion vector committed", before.get("deletes"), "1")
check("28 live rows of 30", len(rows), 28)
next_before = int(before["next-row-id"])
check("its rows given ids", next_before >= 30, True)

catalog = load_catalog("cosmo", **{
    "type": "rest", "uri": endpoint + "/iceberg", "warehouse": arn, "rest.sigv4-enabled": "true",
    "rest.signing-name": "s3tables", "rest.signing-region": region, "s3.endpoint": endpoint, "s3.region": region,
    "s3.access-key-id": os.environ["AWS_ACCESS_KEY_ID"], "s3.secret-access-key": os.environ["AWS_SECRET_ACCESS_KEY"],
    "s3.force-virtual-addressing": "false"})
check("PyIceberg reads the v3 table, its deletion vector applied",
      sorted(catalog.load_table("javans.v3").scan().to_arrow().column("id").to_pylist()), sorted(r[0] for r in rows))
# PyIceberg's staged create (ADR-0124): its create transaction, rows appended in it, the table made at its commit.
import pyarrow as pa
pyschema = pa.schema([pa.field("id", pa.int64(), nullable=False), pa.field("data", pa.string())])
with catalog.create_table_transaction("javans.pytx", schema=pyschema) as tx:
    tx.append(pa.table({"id": [1, 2, 3], "data": ["a", "b", "c"]}, schema=pyschema))
check("PyIceberg's create transaction: the table made with its rows",
      sorted(catalog.load_table("javans.pytx").scan().to_arrow().column("id").to_pylist()), [1, 2, 3])
tables.put_table_maintenance_configuration(tableBucketARN=arn, namespace="javans", name="v3", type="icebergCompaction",
    value={"status": "enabled", "settings": {"icebergCompaction": {"targetFileSizeMB": 1, "strategy": "binpack"}}})


def data_files():
    t = catalog.load_table("javans.v3")
    s = t.current_snapshot()
    return [e.data_file.file_path for m in s.manifests(t.io) if m.content == 0
            for e in m.fetch_manifest_entry(t.io, discard_deleted=True)]


end = time.time() + 4 * day
while time.time() < end and len(data_files()) != 1:
    time.sleep(0.5)
files = data_files()
check("compacted to one file", len(files), 1)
bucket, key = files[0][5:].split("/", 1)
merged = pq.read_table(io.BytesIO(s3.get_object(Bucket=bucket, Key=key)["Body"].read()))
check("the merged file holds _row_id", "_row_id" in merged.column_names, True)
check("and _last_updated_sequence_number", "_last_updated_sequence_number" in merged.column_names, True)
got = sorted(zip(merged.column("id").to_pylist(), merged.column("_row_id").to_pylist()))
check("each row's _row_id as before, the deleted rows gone", got, sorted(rows))

check("PyIceberg reads the same rows after", sorted(catalog.load_table("javans.v3").scan().to_arrow().column("id")
                                                    .to_pylist()), sorted(r[0] for r in rows))
after, _, ids = java("read")
check("Java reads the same rows", sorted(ids), sorted(r[0] for r in rows))
check("no delete left", after.get("deletes"), "0")
check("still v3", after.get("format"), "3")
check("a replace", after.get("operation"), "replace")
check("its first row id the table's next before", after.get("first-row-id"), str(next_before))
check("the next row id advanced", int(after["next-row-id"]) > next_before, True)
if encrypted:
    # Every file of the warehouse sealed under the table's KMS key: data, deletes, manifests, lists and metadata,
    # whoever wrote them; and the stored bytes are not the plaintext (a GET opens them).
    # Each table's files, by its id's prefix (the warehouse's root is the catalog's, not S3's to list).
    keys = []
    for t in tables.list_tables(tableBucketARN=arn)["tables"]:
        token = None
        while True:
            page = s3.list_objects_v2(Bucket="java-check--table-s3", Prefix=t["tableARN"].rsplit("/", 1)[1] + "/",
                                      **({"ContinuationToken": token} if token else {}))
            keys += [o["Key"] for o in page.get("Contents", [])]
            token = page.get("NextContinuationToken")
            if not token:
                break
    check("the warehouse has files", len(keys) > 10, True)
    sealed = [k for k in keys
              if (lambda h: (h.get("ServerSideEncryption"), h.get("SSEKMSKeyId", "").rsplit("/", 1)[-1]))(
                  s3.head_object(Bucket="java-check--table-s3", Key=k)) == ("aws:kms", "orders")]
    check("every file sealed under the table's KMS key", sorted(set(keys) - set(sealed)), [])
    check("compaction's merged file among them", key in sealed, True)
sys.stdout.flush()
os._exit(1 if failed else 0)
