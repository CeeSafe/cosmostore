#!/usr/bin/env python3
"""Writes src/s3/avro_codec_fixtures.cee: one set of records as Avro files of each codec the reader takes besides
deflate (whose fixtures are PyIceberg's own manifests): null, snappy (a raw block and the CRC-32 of what it holds,
big-endian) and zstandard (a zstd frame). The records are encoded by fastavro; the blocks compressed by pyarrow's
libsnappy and libzstd, each checked to decompress to the records.

usage: tools/avro_codec_fixtures.py OUT.cee          (needs fastavro and pyarrow)
"""
import io
import os
import struct
import sys
import zlib

import fastavro
import pyarrow as pa

out_path = sys.argv[1]

schema = fastavro.parse_schema({
    "type": "record", "name": "row", "fields": [
        {"name": "id", "type": "long"},
        {"name": "path", "type": "string"},
        {"name": "size", "type": ["null", "double"]},
    ]})
records = [{"id": i * 7919 - 50, "path": "s3://bucket/warehouse/data/part-%05d.parquet" % (i % 9),
            "size": None if i % 5 == 2 else i * 1.5} for i in range(60)]
COUNT = len(records)


def zigzag(n):
    u = (n << 1) ^ (n >> 63)
    out = bytearray()
    while True:
        b = u & 0x7F
        u >>= 7
        if u:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def avro_bytes(b):
    return zigzag(len(b)) + b


def container(codec, block):
    sync = bytes(range(0x30, 0x40))
    meta = {b"avro.schema": fastavro.schema.to_parsing_canonical_form(schema).encode(), b"avro.codec": codec.encode()}
    out = bytearray(b"Obj\x01")
    out += zigzag(len(meta))
    for k, v in meta.items():
        out += avro_bytes(k) + avro_bytes(v)
    out += zigzag(0) + sync
    out += zigzag(COUNT) + zigzag(len(block)) + block + sync
    return bytes(out)


plain = io.BytesIO()
for r in records:
    fastavro.schemaless_writer(plain, schema, r)
plain = plain.getvalue()

snappy = pa.compress(plain, codec="snappy", asbytes=True)
assert pa.decompress(snappy, len(plain), codec="snappy", asbytes=True) == plain
snappy_block = snappy + struct.pack(">I", zlib.crc32(plain))
zstd = pa.compress(plain, codec="zstd", asbytes=True)
assert pa.decompress(zstd, len(plain), codec="zstd", asbytes=True) == plain

files = [("NULL", "null", container("null", plain)), ("SNAPPY", "snappy", container("snappy", snappy_block)),
         ("ZSTANDARD", "zstandard", container("zstandard", zstd))]
# The null file read by fastavro as the records: the container is Avro's.
assert list(fastavro.reader(io.BytesIO(files[0][2]))) == records


def hex_chunks(data, width=100):
    h = data.hex()
    return [h[i:i + width] for i in range(0, len(h), width)]


with open(out_path, "w") as f:
    f.write("// One set of %d records as Avro files of the codecs null, snappy and zstandard, for the Avro reader's tests:\n"
            "// encoded by fastavro %s, compressed by pyarrow %s's libsnappy and libzstd. Made by\n"
            "// tools/avro_codec_fixtures.py; do not edit.\n" % (COUNT, fastavro.__version__, pa.__version__))
    f.write("\nconst AVRO_CODEC_RECORDS: usize = %d;\n" % COUNT)
    for name, codec, data in files:
        chunks = hex_chunks(data)
        f.write("\n/// The `%s` codec (%d bytes).\n" % (codec, len(data)))
        f.write("const AVRO_CODEC_%s: [StringView; %d] = [\n" % (name, len(chunks)))
        for c in chunks:
            f.write('    "%s",\n' % c)
        f.write("];\n")
print("wrote", out_path, [len(d) for _, _, d in files])
