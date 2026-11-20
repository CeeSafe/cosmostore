#!/usr/bin/env python3
"""Compaction end to end (ADR-0098): PyIceberg tables of small files compacted by the maintenance pass, by copying
row groups, and read back the same.

- An unpartitioned table's six one-row files become one file of six row groups.
- A partitioned table's files are compacted each partition apart.
- The sort strategy is not done, and the job's status says so.
- Appends work after compaction.

usage: tools/compaction_check.py ENDPOINT DAY_SECONDS   against `serve --tables-day-seconds DAY_SECONDS`, with
       AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY set to a key of the server's (needs pyiceberg with pyarrow, boto3)
"""
import io
import os
import sys
import time

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
from botocore.config import Config
from pyiceberg.catalog import load_catalog
from pyiceberg.partitioning import PartitionField, PartitionSpec
from pyiceberg.transforms import IdentityTransform

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
            return True
        time.sleep(0.5)
    check(name, "not within %.0f s" % seconds, "done")
    return False


region = "us-east-1"
cfg = Config(retries={"max_attempts": 1})
tables = boto3.client("s3tables", endpoint_url=endpoint, region_name=region, config=cfg)
s3 = boto3.client("s3", endpoint_url=endpoint, region_name=region, config=cfg)
arn = tables.create_table_bucket(name="compact-check")["arn"]
catalog = load_catalog("cosmo", **{
    "type": "rest", "uri": endpoint + "/iceberg", "warehouse": arn, "rest.sigv4-enabled": "true",
    "rest.signing-name": "s3tables", "rest.signing-region": region, "s3.endpoint": endpoint, "s3.region": region,
    "s3.access-key-id": os.environ["AWS_ACCESS_KEY_ID"], "s3.secret-access-key": os.environ["AWS_SECRET_ACCESS_KEY"],
    "s3.force-virtual-addressing": "false"})
catalog.create_namespace("ns")


def compaction(name, status, strategy="binpack", mb=1):
    tables.put_table_maintenance_configuration(tableBucketARN=arn, namespace="ns", name=name, type="icebergCompaction",
        value={"status": status, "settings": {"icebergCompaction": {"targetFileSizeMB": mb, "strategy": strategy}}})


def data_files(name):
    return sorted(f.file.file_path for f in catalog.load_table("ns." + name).scan().plan_files())


def job(name):
    return tables.get_table_maintenance_job_status(tableBucketARN=arn, namespace="ns", name=name)["status"]["icebergCompaction"]


# Off while the files are written, so nothing is compacted between appends.
schema = pa.schema([pa.field("id", pa.int64(), nullable=False), pa.field("item", pa.string())])
catalog.create_table("ns.flat", schema=schema)
compaction("flat", "disabled")
for i in range(6):
    catalog.load_table("ns.flat").append(pa.table({"id": [i], "item": ["row %d" % i]}, schema=schema))
before = catalog.load_table("ns.flat").scan().to_arrow().sort_by("id")
check("six files before", len(data_files("flat")), 6)
compaction("flat", "enabled")
wait_for("compacted to one file", lambda: len(data_files("flat")) == 1, 4 * day)
t = catalog.load_table("ns.flat")
check("a replace snapshot", t.current_snapshot().summary.operation.value, "replace")
check("the same rows", t.scan().to_arrow().sort_by("id").equals(before), True)
check("its job Successful", job("flat")["status"], "Successful")
path = data_files("flat")[0]
bucket, key = path[5:].split("/", 1)
f = pq.ParquetFile(io.BytesIO(s3.get_object(Bucket=bucket, Key=key)["Body"].read()))
check("the file's row groups are the six files'", f.metadata.num_row_groups, 6)
check("its rows", f.metadata.num_rows, 6)
entry = next(iter(t.scan().plan_files()))
check("its manifest's record count", entry.file.record_count, 6)
check("its bounds: the least id", int.from_bytes(entry.file.lower_bounds[1], "little", signed=True), 0)
check("its bounds: the greatest id", int.from_bytes(entry.file.upper_bounds[1], "little", signed=True), 5)
t.append(pa.table({"id": [6], "item": ["row 6"]}, schema=schema))
check("an append after", catalog.load_table("ns.flat").scan().to_arrow().num_rows, 7)

# A partitioned table: each partition compacted apart.
pschema = pa.schema([pa.field("id", pa.int64(), nullable=False), pa.field("part", pa.string(), nullable=False)])
ptable = catalog.create_table("ns.parts", schema=pschema)
compaction("parts", "disabled")
# Two files under the first spec (unpartitioned), then the spec changes and eight more under it: each spec's files
# are compacted under their own spec (the M16 exit review).
for i in range(2):
    catalog.load_table("ns.parts").append(pa.table({"id": [100 + i], "part": ["a"]}, schema=pschema))
with catalog.load_table("ns.parts").update_spec() as u:
    u.add_identity("part")
for i in range(4):
    catalog.load_table("ns.parts").append(pa.table({"id": [2 * i, 2 * i + 1], "part": ["a", "b"]}, schema=pschema))
check("ten files before, under two specs", len(data_files("parts")), 10)
compaction("parts", "enabled")
wait_for("compacted to a file a spec's partition", lambda: len(data_files("parts")) == 3, 4 * day)
rows = catalog.load_table("ns.parts").scan(row_filter="part == 'a'").to_arrow().sort_by("id")
check("partition a's rows, both specs'", rows.column("id").to_pylist(), [0, 2, 4, 6, 100, 101])
specs = sorted(f.file.spec_id for f in catalog.load_table("ns.parts").scan().plan_files())
check("each file under its own spec", specs, [0, 1, 1])
rows = catalog.load_table("ns.parts").scan(row_filter="part == 'b'").to_arrow().sort_by("id")
check("partition b's rows", rows.column("id").to_pylist(), [1, 3, 5, 7])

# The sort strategy is not done: Failed, and the files stay.
catalog.create_table("ns.sorted", schema=schema)
compaction("sorted", "disabled")
for i in range(2):
    catalog.load_table("ns.sorted").append(pa.table({"id": [i], "item": ["x"]}, schema=schema))
compaction("sorted", "enabled", strategy="sort")
wait_for("sort: Failed", lambda: job("sorted").get("status") == "Failed", 4 * day)
check("sort: why", "sort and z-order are not" in job("sorted").get("failureMessage", ""), True)
check("sort: the files stay", len(data_files("sorted")), 2)

# A partition with a delete file is left as it is (ADR-0098 §2): a position delete in partition a, committed with
# PyIceberg's manifest writers (PyIceberg does not write delete files itself); b is compacted, a is not.
from pyiceberg.io.pyarrow import PyArrowFileIO
from pyiceberg.manifest import (DataFile, DataFileContent, FileFormat, ManifestContent, ManifestEntry,
                                ManifestEntryStatus, ManifestWriterV2, write_manifest_list)
from pyiceberg.table.snapshots import Operation, Snapshot, Summary
from pyiceberg.table.update import AddSnapshotUpdate, AssertRefSnapshotId, SetSnapshotRefUpdate
from pyiceberg.typedef import Record

from pyiceberg.schema import Schema
from pyiceberg.types import LongType, NestedField, StringType

ischema = Schema(NestedField(1, "id", LongType(), required=True), NestedField(2, "part", StringType(), required=True))
catalog.create_table("ns.deletes", schema=ischema, properties={"format-version": "2"},
                     partition_spec=PartitionSpec(PartitionField(source_id=2, field_id=1000, transform=IdentityTransform(), name="part")))
spec = catalog.load_table("ns.deletes").spec()
compaction("deletes", "disabled")
for i in range(2):
    catalog.load_table("ns.deletes").append(pa.table({"id": [10 * i, 10 * i + 1], "part": ["a", "b"]}, schema=pschema))
t = catalog.load_table("ns.deletes")
victim = [f.file for f in t.scan(row_filter="part == 'a'").plan_files()][0]
fio = PyArrowFileIO(t.properties | {"s3.endpoint": endpoint, "s3.region": region,
                                    "s3.access-key-id": os.environ["AWS_ACCESS_KEY_ID"],
                                    "s3.secret-access-key": os.environ["AWS_SECRET_ACCESS_KEY"]})
dschema = pa.schema([pa.field("file_path", pa.string(), nullable=False, metadata={b"PARQUET:field_id": b"2147483546"}),
                     pa.field("pos", pa.int64(), nullable=False, metadata={b"PARQUET:field_id": b"2147483545"})])
deletes_path = t.location() + "/data/part=a/position-deletes.parquet"
buf = io.BytesIO()
pq.write_table(pa.table({"file_path": [victim.file_path], "pos": [0]}, schema=dschema), buf)
with fio.new_output(deletes_path).create(overwrite=True) as out:
    out.write(buf.getvalue())
current = t.current_snapshot()
new_id = current.snapshot_id + 1
sequence = t.metadata.last_sequence_number + 1


class DeleteManifestWriter(ManifestWriterV2):
    def content(self):
        return ManifestContent.DELETES


manifest_path = t.location() + "/metadata/deletes-m0.avro"
with DeleteManifestWriter(spec, t.schema(), fio.new_output(manifest_path), new_id, "null") as w:
    w.add_entry(ManifestEntry.from_args(status=ManifestEntryStatus.ADDED, snapshot_id=new_id, data_file=DataFile.from_args(
        content=DataFileContent.POSITION_DELETES, file_path=deletes_path, file_format=FileFormat.PARQUET,
        partition=Record("a"), record_count=1, file_size_in_bytes=len(buf.getvalue()), spec_id=spec.spec_id)))
delete_manifest = w.to_manifest_file()
list_path = t.location() + "/metadata/snap-%d-deletes.avro" % new_id
with write_manifest_list(2, fio.new_output(list_path), new_id, current.snapshot_id, sequence, "null") as lw:
    lw.add_manifests(current.manifests(fio) + [delete_manifest])
snap = Snapshot(snapshot_id=new_id, parent_snapshot_id=current.snapshot_id, sequence_number=sequence,
                timestamp_ms=int(time.time() * 1000), manifest_list=list_path, summary=Summary(Operation.DELETE),
                schema_id=t.schema().schema_id)
catalog.commit_table(t, requirements=(AssertRefSnapshotId(ref="main", snapshot_id=current.snapshot_id),),
                     updates=(AddSnapshotUpdate(snapshot=snap),
                              SetSnapshotRefUpdate(ref_name="main", type="branch", snapshot_id=new_id)))
check("the delete applies", catalog.load_table("ns.deletes").scan(row_filter="part == 'a'").to_arrow().num_rows, 1)
rows_before = sorted(catalog.load_table("ns.deletes").scan().to_arrow().column("id").to_pylist())
compaction("deletes", "enabled")


def files_of(part):
    return [f for f in data_files("deletes") if "part=" + part in f]


wait_for("the partition without deletes compacted", lambda: len(files_of("b")) == 1, 4 * day)
check("the partition with a delete file left", len(files_of("a")), 2)
check("its rows, the delete still applied", sorted(catalog.load_table("ns.deletes").scan().to_arrow().column("id").to_pylist()),
      rows_before)
check("three rows of four", len(rows_before), 3)

for name in ("flat", "parts", "sorted", "deletes"):
    catalog.purge_table("ns." + name)
catalog.drop_namespace("ns")
for attempt in range(3):
    try:
        tables.delete_table_bucket(tableBucketARN=arn)
        break
    except tables.exceptions.ConflictException:
        time.sleep(0.5)
sys.exit(1 if failed else 0)
