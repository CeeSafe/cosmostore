#!/usr/bin/env python3
"""Compaction end to end (ADR-0098): PyIceberg tables of small files compacted by the maintenance pass, by copying
row groups, and read back the same.

- An unpartitioned table's six one-row files (PyIceberg's ZSTD) are merged: one file of one row group, SNAPPY.
- A SNAPPY table's twelve small files, with a struct, a list and a map, are merged (ADR-0112): one file of one row
  group, SNAPPY, read by PyIceberg and by pyarrow as the same rows.
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


def check_metrics(name, t, f):
    """The merged file's manifest metrics against PyIceberg's own from its footer, under the table's properties
    (ADR-0114 §2: counts and bounds from the rows written, by the table's metrics mode)."""
    from pyiceberg.io.pyarrow import (compute_statistics_plan, data_file_statistics_from_parquet_metadata,
                                      parquet_path_to_id_mapping)
    want = data_file_statistics_from_parquet_metadata(
        f.metadata, compute_statistics_plan(t.schema(), t.properties), parquet_path_to_id_mapping(t.schema())
    ).to_serialized_dict()
    got = next(iter(t.scan().plan_files())).file
    for k in ("value_counts", "null_value_counts", "column_sizes"):
        check("%s: its %s, as PyIceberg's" % (name, k), dict(getattr(got, k) or {}), dict(want.get(k) or {}))
    # Bounds: PyIceberg's, and also a struct's fields', which Iceberg Java keeps and PyIceberg does not; those must be
    # the column's least and greatest values.
    import pyarrow.compute as pc
    from pyiceberg.conversions import to_bytes
    rows = t.scan().to_arrow().flatten()
    for k, pick in (("lower_bounds", "min"), ("upper_bounds", "max")):
        g, w = dict(getattr(got, k) or {}), dict(want.get(k) or {})
        extra = {}
        for fid in set(g) - set(w):
            column = t.schema().find_column_name(fid)
            field = t.schema().find_field(fid)
            if column in rows.column_names and "." in column:
                extra[fid] = to_bytes(field.field_type, pc.min_max(rows.column(column))[pick].as_py())
        check("%s: its %s, as PyIceberg's" % (name, k), {i: v for i, v in g.items() if i in w}, w)
        check("%s: its %s of a struct's fields, the columns' own" % (name, k), {i: g[i] for i in extra}, extra)
        check("%s: its %s beyond PyIceberg's are a struct's fields only" % (name, k), sorted(set(g) - set(w)),
              sorted(extra))


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
check("one row group, the six files' values merged", f.metadata.num_row_groups, 1)
check("written SNAPPY, from ZSTD", f.metadata.row_group(0).column(0).compression, "SNAPPY")
check("its rows", f.metadata.num_rows, 6)
entry = next(iter(t.scan().plan_files()))
check("its manifest's record count", entry.file.record_count, 6)
check("its bounds: the least id", int.from_bytes(entry.file.lower_bounds[1], "little", signed=True), 0)
check("its bounds: the greatest id", int.from_bytes(entry.file.upper_bounds[1], "little", signed=True), 5)
check_metrics("flat", t, f)


def avro_codec(path):
    """An Avro file's codec, as its header names it (read here: the header is `Obj\\x01`, then a map of bytes in
    blocks of zig-zag longs)."""
    b, k = path[5:].split("/", 1)
    data = s3.get_object(Bucket=b, Key=k)["Body"].read()
    at = 4

    def long():
        nonlocal at
        shift, n = 0, 0
        while True:
            byte = data[at]
            at += 1
            n |= (byte & 0x7F) << shift
            shift += 7
            if byte < 0x80:
                return (n >> 1) ^ -(n & 1)

    def text():
        nonlocal at
        size = long()
        at += size
        return data[at - size:at]

    meta = {}
    while True:
        count = long()
        if count == 0:
            break
        if count < 0:
            count = -count
            long()
        for _ in range(count):
            key = text()
            meta[key] = text()
    return meta.get(b"avro.codec", b"null").decode()


def run_codecs(table):
    """The codecs of the current snapshot's manifest list and of the manifests it names that its run wrote."""
    snap = table.current_snapshot()
    return avro_codec(snap.manifest_list), sorted({avro_codec(m.manifest_path) for m in snap.manifests(table.io)
                                                   if m.added_snapshot_id == snap.snapshot_id})


# The run's manifests in the table's Avro codec (ADR-0116 §3): gzip (Avro's deflate) when it sets none.
check("the run's manifest list and manifests in deflate", run_codecs(t), ("deflate", ["deflate"]))
t.append(pa.table({"id": [6], "item": ["row 6"]}, schema=schema))
check("an append after", catalog.load_table("ns.flat").scan().to_arrow().num_rows, 7)

# A SNAPPY table (Spark's codec), nested: its pages read and its values written again as one row group (ADR-0112).
nested = pa.schema([
    pa.field("id", pa.int64(), nullable=False),
    pa.field("item", pa.string()),
    pa.field("st", pa.struct([pa.field("a", pa.int32()), pa.field("b", pa.string())])),
    pa.field("lst", pa.list_(pa.int32())),
    pa.field("m", pa.map_(pa.string(), pa.int64())),
])
catalog.create_table("ns.snappy", schema=nested, properties={"write.parquet.compression-codec": "snappy"})
compaction("snappy", "disabled")
for i in range(12):
    rows = [{"id": i * 10 + k, "item": None if k == 1 else "item %d" % (i * 10 + k),
             "st": None if k == 2 else {"a": None if i % 3 == 0 else i * k, "b": "b%d" % k},
             "lst": None if k == 0 else [i + j for j in range(k)],
             "m": None if (i + k) % 4 == 0 else [("k%d" % j, None if j == 1 else i * 100 + j) for j in range(k)]}
            for k in range(3)]
    catalog.load_table("ns.snappy").append(pa.Table.from_pylist(rows, schema=nested))
snappy_before = catalog.load_table("ns.snappy").scan().to_arrow().sort_by("id")
check("SNAPPY: twelve files before", len(data_files("snappy")), 12)
compaction("snappy", "enabled")
wait_for("SNAPPY: merged to one file", lambda: len(data_files("snappy")) == 1, 4 * day)
t = catalog.load_table("ns.snappy")
check("SNAPPY: the same rows, by PyIceberg", t.scan().to_arrow().sort_by("id").equals(snappy_before), True)
path = data_files("snappy")[0]
bucket, key = path[5:].split("/", 1)
f = pq.ParquetFile(io.BytesIO(s3.get_object(Bucket=bucket, Key=key)["Body"].read()))
check("SNAPPY: one row group, the files' values merged", f.metadata.num_row_groups, 1)
check("SNAPPY: its rows", f.metadata.num_rows, 36)
check("SNAPPY: written SNAPPY", f.metadata.row_group(0).column(0).compression, "SNAPPY")
check("SNAPPY: the same rows, by pyarrow", f.read().sort_by("id").to_pylist(), snappy_before.to_pylist())
entry = next(iter(t.scan().plan_files()))
check_metrics("SNAPPY", t, f)
check("SNAPPY: its manifest's record count", entry.file.record_count, 36)
check("SNAPPY: its bounds", (int.from_bytes(entry.file.lower_bounds[1], "little", signed=True),
                             int.from_bytes(entry.file.upper_bounds[1], "little", signed=True)), (0, 112))

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

# Deletes applied (ADR-0114): delete files committed with PyIceberg's manifest writers (PyIceberg does not write
# merge-on-read deletes itself).
from pyiceberg.io.pyarrow import PyArrowFileIO
from pyiceberg.manifest import (DataFile, DataFileContent, FileFormat, ManifestContent, ManifestEntry,
                                ManifestEntryStatus, ManifestWriterV2, write_manifest_list)
from pyiceberg.table.snapshots import Operation, Snapshot, Summary
from pyiceberg.table.update import AddSnapshotUpdate, AssertRefSnapshotId, SetSnapshotRefUpdate
from pyiceberg.typedef import Record

from pyiceberg.schema import Schema
from pyiceberg.types import LongType, NestedField, StringType


class DeleteManifestWriter(ManifestWriterV2):
    def content(self):
        return ManifestContent.DELETES


def commit_delete(name, table, part, path_suffix, content, delete_table, equality_ids=None):
    """A delete file of `delete_table`'s rows in partition `part`, committed as a snapshot of its own."""
    t = catalog.load_table("ns." + name)
    spec = t.spec()
    fio = PyArrowFileIO(t.properties | {"s3.endpoint": endpoint, "s3.region": region,
                                        "s3.access-key-id": os.environ["AWS_ACCESS_KEY_ID"],
                                        "s3.secret-access-key": os.environ["AWS_SECRET_ACCESS_KEY"]})
    path = t.location() + "/data/part=%s/%s" % (part, path_suffix)
    buf = io.BytesIO()
    pq.write_table(delete_table, buf)
    with fio.new_output(path).create(overwrite=True) as out:
        out.write(buf.getvalue())
    current = t.current_snapshot()
    new_id = current.snapshot_id + 1
    sequence = t.metadata.last_sequence_number + 1
    manifest_path = t.location() + "/metadata/%s-m0.avro" % path_suffix
    with DeleteManifestWriter(spec, t.schema(), fio.new_output(manifest_path), new_id, "null") as w:
        w.add_entry(ManifestEntry.from_args(status=ManifestEntryStatus.ADDED, snapshot_id=new_id,
            data_file=DataFile.from_args(content=content, file_path=path, file_format=FileFormat.PARQUET,
                partition=Record(part), record_count=delete_table.num_rows, file_size_in_bytes=len(buf.getvalue()),
                spec_id=spec.spec_id, equality_ids=equality_ids)))
    delete_manifest = w.to_manifest_file()
    list_path = t.location() + "/metadata/snap-%d-%s.avro" % (new_id, path_suffix)
    with write_manifest_list(2, fio.new_output(list_path), new_id, current.snapshot_id, sequence, "null") as lw:
        lw.add_manifests(current.manifests(fio) + [delete_manifest])
    snap = Snapshot(snapshot_id=new_id, parent_snapshot_id=current.snapshot_id, sequence_number=sequence,
                    timestamp_ms=int(time.time() * 1000), manifest_list=list_path, summary=Summary(Operation.DELETE),
                    schema_id=t.schema().schema_id)
    catalog.commit_table(t, requirements=(AssertRefSnapshotId(ref="main", snapshot_id=current.snapshot_id),),
                         updates=(AddSnapshotUpdate(snapshot=snap),
                                  SetSnapshotRefUpdate(ref_name="main", type="branch", snapshot_id=new_id)))


def manifest_files(name, content):
    """The live files of `content` (data, or deletes) of a table's current snapshot, read from its manifests (PyIceberg
    plans no scan of a table with equality deletes)."""
    t = catalog.load_table("ns." + name)
    want = ManifestContent.DATA if content == "data" else ManifestContent.DELETES
    return sorted(e.data_file.file_path for m in t.current_snapshot().manifests(t.io) if m.content == want
                  for e in m.fetch_manifest_entry(t.io, discard_deleted=True))


def delete_files(name):
    return set(manifest_files(name, "deletes"))


def ids_of(name):
    return sorted(catalog.load_table("ns." + name).scan().to_arrow().column("id").to_pylist())


ischema = Schema(NestedField(1, "id", LongType(), required=True), NestedField(2, "part", StringType(), required=True))
ispec = PartitionSpec(PartitionField(source_id=2, field_id=1000, transform=IdentityTransform(), name="part"))

# A position delete in partition a: a's files merged with the delete applied, the delete file removed; b merged.
catalog.create_table("ns.deletes", schema=ischema, properties={"format-version": "2"}, partition_spec=ispec)
compaction("deletes", "disabled")
for i in range(2):
    catalog.load_table("ns.deletes").append(pa.table({"id": [10 * i, 10 * i + 1], "part": ["a", "b"]}, schema=pschema))
t = catalog.load_table("ns.deletes")
victim = [f.file for f in t.scan(row_filter="part == 'a'").plan_files()][0]
dschema = pa.schema([pa.field("file_path", pa.string(), nullable=False, metadata={b"PARQUET:field_id": b"2147483546"}),
                     pa.field("pos", pa.int64(), nullable=False, metadata={b"PARQUET:field_id": b"2147483545"})])
commit_delete("deletes", t, "a", "position-deletes.parquet", DataFileContent.POSITION_DELETES,
              pa.table({"file_path": [victim.file_path], "pos": [0]}, schema=dschema))
check("the delete applies", catalog.load_table("ns.deletes").scan(row_filter="part == 'a'").to_arrow().num_rows, 1)
rows_before = ids_of("deletes")
check("three rows of four", len(rows_before), 3)
compaction("deletes", "enabled")


def files_of(part):
    return [f for f in data_files("deletes") if "part=" + part in f]


wait_for("both partitions compacted, deletes applied", lambda: len(files_of("a")) == 1 and len(files_of("b")) == 1,
         4 * day)
check("its rows, the delete applied", ids_of("deletes"), rows_before)
check("the position delete file removed", delete_files("deletes"), set())
t = catalog.load_table("ns.deletes")
check("the summary counts the removed delete file", t.current_snapshot().summary.get("removed-position-delete-files"),
      "1")
check("and its records: 4 removed, 3 added", (t.current_snapshot().summary.get("deleted-records"),
                                             t.current_snapshot().summary.get("added-records")), ("4", "3"))

# An equality delete on id, then a row of a deleted id appended after it: the delete applies to the older rows only
# (Iceberg's sequence rule), and the newer row is kept through compaction.
catalog.create_table("ns.equality", schema=ischema, properties={"format-version": "2"}, partition_spec=ispec)
compaction("equality", "disabled")
for ids in ([1, 2], [3, 4]):
    catalog.load_table("ns.equality").append(pa.table({"id": ids, "part": ["a"] * len(ids)}, schema=pschema))
eschema = pa.schema([pa.field("id", pa.int64(), nullable=False, metadata={b"PARQUET:field_id": b"1"})])
commit_delete("equality", catalog.load_table("ns.equality"), "a", "equality-deletes.parquet",
              DataFileContent.EQUALITY_DELETES, pa.table({"id": [2, 3]}, schema=eschema), equality_ids=[1])
catalog.load_table("ns.equality").append(pa.table({"id": [2], "part": ["a"]}, schema=pschema))
# PyIceberg does not read equality deletes (apache/iceberg#6568), so the rows before are stated, not scanned: 2 and 3
# deleted, the later 2 kept. After compaction there is no delete file left, and PyIceberg reads the table.
compaction("equality", "enabled")
wait_for("equality: merged to one file", lambda: len(manifest_files("equality", "data")) == 1, 4 * day)
check("equality: the rows, the older 2 and 3 deleted, the newer 2 kept", ids_of("equality"), [1, 2, 4])
check("equality: the delete file removed", delete_files("equality"), set())
t = catalog.load_table("ns.equality")
path = data_files("equality")[0]
bucket, key = path[5:].split("/", 1)
f = pq.ParquetFile(io.BytesIO(s3.get_object(Bucket=bucket, Key=key)["Body"].read()))
check("equality: the file holds three rows", f.metadata.num_rows, 3)
check_metrics("equality", t, f)
t.append(pa.table({"id": [9], "part": ["a"]}, schema=pschema))
check("equality: an append after", ids_of("equality"), [1, 2, 4, 9])

# A table's own codecs kept (ADR-0116): gzip pages, null manifests (Avro's name, which PyIceberg takes; Java's is
# `uncompressed`) (not snappy: PyIceberg reads snappy
# manifests only with its optional python-snappy, which this check's PyIceberg has not; the snappy writer is a unit
# test's, read back by CosmoStore's own reader).
catalog.create_table("ns.codecs", schema=schema, properties={
    "write.parquet.compression-codec": "gzip", "write.parquet.compression-level": "4",
    "write.avro.compression-codec": "null"})
compaction("codecs", "disabled")
for i in range(3):
    catalog.load_table("ns.codecs").append(pa.table({"id": [i], "item": ["codec %d" % i]}, schema=schema))
codecs_before = catalog.load_table("ns.codecs").scan().to_arrow().sort_by("id")
compaction("codecs", "enabled")
wait_for("codecs: merged to one file", lambda: len(data_files("codecs")) == 1, 4 * day)
t = catalog.load_table("ns.codecs")
check("codecs: the same rows", t.scan().to_arrow().sort_by("id").equals(codecs_before), True)
path = data_files("codecs")[0]
bucket, key = path[5:].split("/", 1)
f = pq.ParquetFile(io.BytesIO(s3.get_object(Bucket=bucket, Key=key)["Body"].read()))
check("codecs: written GZIP, the table's", f.metadata.row_group(0).column(0).compression, "GZIP")
check("codecs: the run's manifests uncompressed, the table's", run_codecs(t), ("null", ["null"]))

# The table's metrics mode (ADR-0114 §2): counts by default, one column's strings truncated to 4 characters.
catalog.create_table("ns.modes", schema=schema, properties={
    "write.metadata.metrics.default": "counts", "write.metadata.metrics.column.item": "truncate(4)"})
compaction("modes", "disabled")
for i in range(4):
    catalog.load_table("ns.modes").append(pa.table({"id": [i, i + 100], "item": ["δέλτα-%d" % i, None]}, schema=schema))
compaction("modes", "enabled")
wait_for("modes: merged to one file", lambda: len(data_files("modes")) == 1, 4 * day)
t = catalog.load_table("ns.modes")
path = data_files("modes")[0]
bucket, key = path[5:].split("/", 1)
f = pq.ParquetFile(io.BytesIO(s3.get_object(Bucket=bucket, Key=key)["Body"].read()))
check_metrics("modes", t, f)
got = next(iter(t.scan().plan_files())).file
check("modes: no bounds for id (counts)", 1 in (got.lower_bounds or {}), False)
check("modes: item's lower bound, 4 characters", (got.lower_bounds or {}).get(2), "δέλτ".encode())

for name in ("flat", "snappy", "modes", "codecs", "parts", "sorted", "deletes", "equality"):
    catalog.purge_table("ns." + name)
catalog.drop_namespace("ns")
for attempt in range(3):
    try:
        tables.delete_table_bucket(tableBucketARN=arn)
        break
    except tables.exceptions.ConflictException:
        time.sleep(0.5)
sys.exit(1 if failed else 0)
