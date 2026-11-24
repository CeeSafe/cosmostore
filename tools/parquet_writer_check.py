#!/usr/bin/env python3
"""pyarrow reads each file the page writer's test wrote (ADR-0112 slice 4) as the fixture it came from.

usage: tools/parquet_writer_check.py DIR   (DIR: the package's out/parquet-written, after `ceesafec test`; needs
       pyarrow)
"""
import io
import math
import os
import re
import sys

import pyarrow.parquet as pq

here = os.path.dirname(os.path.abspath(__file__))
source = open(os.path.join(here, "..", "src", "s3", "parquet_page_fixtures.cee")).read()
fixtures = {}
for m in re.finditer(r"const PAGES_(\w+): \[StringView; \d+\] = \[(.*?)\];", source, re.S):
    if not m.group(1).endswith("EXPECTED"):
        fixtures[m.group(1)] = bytes.fromhex("".join(re.findall(r'"([0-9a-f]+)"', m.group(2))))
failed = False
names = sorted(os.listdir(sys.argv[1]))
for name in names:
    fixture = name.rsplit("-", 1)[0]
    written = pq.ParquetFile(os.path.join(sys.argv[1], name))
    got = written.read()
    want = pq.read_table(io.BytesIO(fixtures[fixture]))
    # The codec its name says (`-zstd3` is ZSTD at level 3, ADR-0116 §4).
    suffix = name.rsplit("-", 1)[-1][:-len(".parquet")]
    codec = {"none": "UNCOMPRESSED", "snappy": "SNAPPY", "gzip": "GZIP", "zstd1": "ZSTD", "zstd3": "ZSTD",
             "zstd9": "ZSTD"}.get(suffix)
    # By each row's repr: NaN is equal to NaN there (not to Arrow's `equals`), and -0.0 differs from 0.0.
    same = got.schema.equals(want.schema) and repr(got.to_pylist()) == repr(want.to_pylist()) and all(written.metadata.row_group(0).column(c).compression == codec
                                    for c in range(written.metadata.num_columns))
    stats = all(written.metadata.row_group(0).column(c).statistics is not None
                for c in range(written.metadata.num_columns))
    # Each flat or struct column's min and max (ADR-0118 §1) against its values: nulls and NaNs left out, a zero
    # minimum -0.0 and a zero maximum +0.0.
    flat = got.flatten()
    for c in range(written.metadata.num_columns):
        col = written.metadata.row_group(0).column(c)
        if col.path_in_schema not in flat.column_names or not col.statistics.has_min_max:
            continue
        values = [v for v in flat.column(col.path_in_schema).to_pylist()
                  if v is not None and not (isinstance(v, float) and math.isnan(v))]
        if isinstance(col.statistics.min, bytes) and values and isinstance(values[0], str):
            values = [v.encode() for v in values]
        least, most = min(values), max(values)
        if isinstance(least, float) and least == 0:
            least = -0.0
        if isinstance(most, float) and most == 0:
            most = 0.0
        ok = col.statistics.min == least and col.statistics.max == most and (
            not isinstance(least, float) or math.copysign(1, col.statistics.min) == math.copysign(1, least)) and (
            not isinstance(most, float) or math.copysign(1, col.statistics.max) == math.copysign(1, most))
        if not ok:
            print("FAIL %s: %s's bounds %r..%r, its values' %r..%r" % (name, col.path_in_schema, col.statistics.min,
                                                                      col.statistics.max, least, most))
            stats = False
    print("%s %s: %d rows, codec %s, %s" % ("ok  " if same and stats else "FAIL", name, got.num_rows,
          written.metadata.row_group(0).column(0).compression, "the same table" if same else "NOT the same"))
    failed = failed or not same or not stats
if not names:
    print("FAIL no files")
    failed = True
# os._exit, not sys.exit: under heavy load Arrow's thread pool can deadlock in its shutdown at interpreter exit,
# after every file has been read.
sys.stdout.flush()
os._exit(1 if failed else 0)
