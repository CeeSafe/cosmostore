#!/usr/bin/env python3
"""pyarrow reads each file the page writer's test wrote (ADR-0112 slice 4) as the fixture it came from.

usage: tools/parquet_writer_check.py DIR   (DIR: the package's out/parquet-written, after `ceesafec test`; needs
       pyarrow)
"""
import io
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
    same = got.equals(want)
    stats = all(written.metadata.row_group(0).column(c).statistics is not None
                for c in range(written.metadata.num_columns))
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
