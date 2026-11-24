#!/usr/bin/env python3
"""Writes src/s3/dv_fixtures.cee (ADR-0122 §4): Iceberg v3 deletion vectors as Iceberg's writers frame them, their
roaring bitmaps serialized by pyroaring (CRoaring's portable format).

- DV_PUFFIN: a Puffin file of two `deletion-vector-v1` blobs, for the compaction tests' files a (positions 0, 3, 5)
  and b (position 1), with each blob's offset and length.
- DV_FORMATS: one blob alone, of every container kind (array, bitmap, run) and a position past 2^32, with its
  cardinality and some of its positions.

usage: tools/dv_fixtures.py OUT.cee   (needs pyroaring)
"""
import json
import struct
import sys
import zlib

from pyroaring import BitMap

out_path = sys.argv[1]
DV_MAGIC = bytes([0xD1, 0xD3, 0x39, 0x64])


def vector(positions):
    """The deletion vector of 64-bit `positions`: an 8-byte little-endian count of 32-bit bitmaps, each a 4-byte
    little-endian key (the positions' high 32 bits) and the bitmap of their low 32 bits."""
    keys = {}
    for p in positions:
        keys.setdefault(p >> 32, []).append(p & 0xFFFFFFFF)
    body = struct.pack("<Q", len(keys))
    for key in sorted(keys):
        bm = BitMap(keys[key])
        bm.run_optimize()
        body += struct.pack("<I", key) + bm.serialize()
    return body


def blob(positions):
    """A `deletion-vector-v1` blob: the vector's and magic's length (4 bytes, big-endian), the magic, the vector, and
    the CRC-32 of magic and vector (big-endian)."""
    v = vector(positions)
    framed = DV_MAGIC + v
    return struct.pack(">I", len(framed)) + framed + struct.pack(">I", zlib.crc32(framed) & 0xFFFFFFFF)


compact_path = "s3://compact--table-s3/c0c0c0c0-1111-4222-8333-444444444444/data/kind=a/%s.parquet"
blobs = [(compact_path % "a", [0, 3, 5]), (compact_path % "b", [1])]
puffin = bytearray(b"PFA1")
placed = []
for path, positions in blobs:
    b = blob(positions)
    placed.append({"type": "deletion-vector-v1", "fields": [2147483545], "snapshot-id": -1, "sequence-number": -1,
                   "offset": len(puffin), "length": len(b),
                   "properties": {"referenced-data-file": path, "cardinality": str(len(positions))}})
    puffin += b
payload = json.dumps({"blobs": placed, "properties": {"created-by": "tools/dv_fixtures.py"}}).encode()
puffin += b"PFA1" + payload + struct.pack("<i", len(payload)) + bytes(4) + b"PFA1"

# Every container kind: an array (few values), a bitmap (over 4096 values in one 2^16 chunk), a run (a long range,
# run-optimized), and a key above 0.
formats = sorted(set(list(range(7, 70000, 13)) + list(range(200000, 260000)) + [3, (1 << 32) + 9, (5 << 32) + 65535]))
formats_blob = blob(formats)
samples = [formats[0], formats[1], formats[5000], formats[-3], formats[-2], formats[-1]]


def hex_chunks(data, width=100):
    h = bytes(data).hex()
    return [h[i:i + width] for i in range(0, len(h), width)]


with open(out_path, "w") as f:
    f.write("// Iceberg v3 deletion vectors for the tests (ADR-0122 §4), their bitmaps serialized by pyroaring.\n"
            "// Made by tools/dv_fixtures.py; do not edit.\n")
    chunks = hex_chunks(puffin)
    f.write("\n/// A Puffin file of two deletion vectors: a's positions 0, 3 and 5, b's 1 (%d bytes).\n" % len(puffin))
    f.write("const DV_PUFFIN: [StringView; %d] = [\n" % len(chunks))
    for c in chunks:
        f.write('    "%s",\n' % c)
    f.write("];\n")
    for name, p in zip(["A", "B"], placed):
        f.write("const DV_PUFFIN_%s_OFFSET: u64 = %d;\nconst DV_PUFFIN_%s_LENGTH: u64 = %d;\n"
                % (name, p["offset"], name, p["length"]))
    chunks = hex_chunks(formats_blob)
    f.write("\n/// One blob of every container kind and a position past 2^32 (%d bytes).\n" % len(formats_blob))
    f.write("const DV_FORMATS: [StringView; %d] = [\n" % len(chunks))
    for c in chunks:
        f.write('    "%s",\n' % c)
    f.write("];\n")
    f.write("const DV_FORMATS_CARDINALITY: u64 = %d;\n" % len(formats))
    f.write("const DV_FORMATS_SAMPLES: [i64; %d] = [%s];\n" % (len(samples), ", ".join(str(s) for s in samples)))
print("wrote", out_path, len(puffin), "and", len(formats_blob), "bytes")
