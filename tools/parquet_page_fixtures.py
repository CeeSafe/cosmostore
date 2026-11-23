#!/usr/bin/env python3
"""Writes src/s3/parquet_page_fixtures.cee (ADR-0112 slice 3): small Parquet files pyarrow writes, of every page
version, encoding and physical type the page reader takes, with nulls, structs, lists and maps; and, for each leaf
column, what a reader must find: its repetition and definition levels and its values, from a Dremel shredding of the
rows here (not from pyarrow's reading).

usage: tools/parquet_page_fixtures.py OUT.cee          (needs pyarrow; the codecs here are none, gzip, snappy and zstd)
"""
import io
import struct
import sys

import pyarrow as pa
import pyarrow.parquet as pq

out_path = sys.argv[1]

# ---- The rows ----

flat_schema = pa.schema([
    pa.field("id", pa.int64(), nullable=False),
    pa.field("i32", pa.int32()),
    pa.field("f", pa.float32()),
    pa.field("d", pa.float64()),
    pa.field("b", pa.bool_()),
    pa.field("s", pa.string()),
    pa.field("fx", pa.binary(4)),
])
flat_rows = []
for i in range(23):
    flat_rows.append({
        "id": i * 1000003 - 7,
        "i32": None if i % 5 == 3 else (i * 37) % 11 - 5,
        "f": None if i % 7 == 2 else i * 0.5 - 3.25,
        "d": None if i % 4 == 1 else (i - 11) * 1.0e10 + 0.125,
        "b": None if i % 6 == 5 else i % 3 == 0,
        "s": None if i % 9 == 4 else ["alpha", "beta", "gamma", "", "δέλτα"][i % 5] * (1 + i % 3),
        "fx": None if i % 8 == 6 else bytes([i, 255 - i, i * 3 % 256, 7]),
    })

# The flat rows again with Iceberg's field ids, and as another writer might lay out the same Iceberg schema: its
# columns in the other order and under other names, their ids the same (compaction matches them by id, ADR-0112 §2).
def with_id(field, i, name=None):
    return pa.field(name or field.name, field.type, nullable=field.nullable, metadata={b"PARQUET:field_id": str(i).encode()})


ids_schema = pa.schema([with_id(f, i + 1) for i, f in enumerate(flat_schema)])
renamed_schema = pa.schema([with_id(f, i + 1, "c_" + f.name) for i, f in reversed(list(enumerate(flat_schema)))])
renamed_rows = [{"c_" + k: r[k] for k in reversed(list(r))} for r in flat_rows]

nested_schema = pa.schema([
    pa.field("id", pa.int32(), nullable=False),
    pa.field("st", pa.struct([pa.field("a", pa.int32()), pa.field("b", pa.string())])),
    pa.field("lst", pa.list_(pa.field("element", pa.int32()))),
    pa.field("m", pa.map_(pa.string(), pa.int64())),
])
nested_rows = []
for i in range(17):
    st = None if i % 6 == 4 else {"a": None if i % 4 == 2 else i * 3, "b": None if i % 5 == 1 else "s%d" % i}
    lst = None if i % 7 == 3 else ([] if i % 5 == 0 else [None if (i + k) % 4 == 0 else i * 10 + k for k in range(i % 4)])
    m = None if i % 6 == 1 else ([] if i % 4 == 0 else [("k%d" % k, None if k == 1 else i * 100 + k) for k in range(i % 3 + 1)])
    nested_rows.append({"id": i, "st": st, "lst": lst, "m": m})

# ---- Dremel shredding ----
# A node: ("prim", name, nullable, kind) | ("struct", name, nullable, [nodes]) | ("list", name, nullable, element node)
# | ("map", name, nullable, key node, value node). Leaves are emitted as (path, kind, max_def, max_rep, [(r, d, v)]).

flat_nodes = [("prim", "id", False, "i64"), ("prim", "i32", True, "i32"), ("prim", "f", True, "f32"),
              ("prim", "d", True, "f64"), ("prim", "b", True, "bool"), ("prim", "s", True, "bytes"),
              ("prim", "fx", True, "bytes")]
renamed_nodes = [(n[0], "c_" + n[1], n[2], n[3]) for n in reversed(flat_nodes)]
nested_nodes = [
    ("prim", "id", False, "i32"),
    ("struct", "st", True, [("prim", "a", True, "i32"), ("prim", "b", True, "bytes")]),
    ("list", "lst", True, ("prim", "element", True, "i32")),
    ("map", "m", True, ("prim", "key", False, "bytes"), ("prim", "value", True, "i64")),
]


def leaf_paths(node, prefix, d, r):
    kind = node[0]
    d2 = d + (1 if node[2] else 0)
    if kind == "prim":
        return [(prefix + [node[1]], node[3], d2, r)]
    if kind == "struct":
        return [p for f in node[3] for p in leaf_paths(f, prefix + [node[1]], d2, r)]
    if kind == "list":
        return leaf_paths(node[3], prefix + [node[1], "list"], d2 + 1, r + 1)
    return (leaf_paths(node[3], prefix + [node[1], "key_value"], d2 + 1, r + 1) +
            leaf_paths(node[4], prefix + [node[1], "key_value"], d2 + 1, r + 1))


def nulls(node, r, d, out, prefix):
    for path, _, _, _ in leaf_paths(node, prefix, 0, 0):
        out[".".join(path)].append((r, d, None))


def shred(node, v, r, d, rl, out, prefix):
    """`r` the repetition level to emit first, `d` the definition level so far, `rl` this node's repetition depth."""
    kind = node[0]
    if v is None:
        nulls(node, r, d, out, prefix)
        return
    d2 = d + (1 if node[2] else 0)
    if kind == "prim":
        out[".".join(prefix + [node[1]])].append((r, d2, v))
    elif kind == "struct":
        for f in node[3]:
            shred(f, v.get(f[1]), r, d2, rl, out, prefix + [node[1]])
    else:
        items = v
        inner = prefix + [node[1], "list" if kind == "list" else "key_value"]
        if len(items) == 0:
            sub = node[3] if kind == "list" else ("struct", "kv", False, [node[3], node[4]])
            if kind == "list":
                nulls(node[3], r, d2, out, inner)
            else:
                nulls(node[3], r, d2, out, inner)
                nulls(node[4], r, d2, out, inner)
            return
        for k, item in enumerate(items):
            rr = r if k == 0 else rl + 1
            if kind == "list":
                shred(node[3], item, rr, d2 + 1, rl + 1, out, inner)
            else:
                shred(node[3], item[0], rr, d2 + 1, rl + 1, out, inner)
                shred(node[4], item[1], rr, d2 + 1, rl + 1, out, inner)


def shredded(nodes, rows):
    out = {}
    leaves = []
    for n in nodes:
        for path, kind, md, mr in leaf_paths(n, [], 0, 0):
            out[".".join(path)] = []
            leaves.append((".".join(path), kind, md, mr))
    for row in rows:
        for n in nodes:
            shred(n, row[n[1]], 0, 0, 0, out, [])
    return [(p, kind, md, mr, out[p]) for p, kind, md, mr in leaves]


def value_text(kind, v):
    if kind in ("i32", "i64"):
        return str(v)
    if kind == "f32":
        return struct.pack("<f", v).hex()
    if kind == "f64":
        return struct.pack("<d", v).hex()
    if kind == "bool":
        return "1" if v else "0"
    return (v.encode() if isinstance(v, str) else v).hex()


def expected_lines(leaves):
    lines = []
    for path, kind, md, mr, triples in leaves:
        reps = "".join(str(t[0]) for t in triples)
        defs = "".join(str(t[1]) for t in triples)
        vals = ",".join(value_text(kind, t[2]) for t in triples if t[2] is not None)
        lines.append("%s|%d|%d|%s|%s|%s" % (path, md, mr, reps, defs, vals))
    return lines


# ---- The files ----

def write(schema, rows, **opts):
    buf = io.BytesIO()
    table = pa.Table.from_pylist(rows, schema=schema)
    pq.write_table(table, buf, write_statistics=True, **opts)
    return buf.getvalue()


fixtures = [
    ("FLAT_V1_DICT", "plain v1 pages, dictionary, none", write(flat_schema, flat_rows, compression="none",
        data_page_version="1.0", max_rows_per_page=8), flat_nodes, flat_rows),
    ("FLAT_V2_DICT_GZIP", "v2 pages, dictionary, gzip", write(flat_schema, flat_rows, compression="gzip",
        data_page_version="2.0", max_rows_per_page=8), flat_nodes, flat_rows),
    ("FLAT_V1_PLAIN", "v1 pages, PLAIN, none", write(flat_schema, flat_rows, compression="none",
        use_dictionary=False, data_page_version="1.0", max_rows_per_page=8), flat_nodes, flat_rows),
    ("FLAT_V2_DELTA", "v2 pages: DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY, BYTE_STREAM_SPLIT", write(
        flat_schema, flat_rows, compression="none", use_dictionary=False, data_page_version="2.0",
        max_rows_per_page=8, column_encoding={"id": "DELTA_BINARY_PACKED", "i32": "DELTA_BINARY_PACKED",
                                              "s": "DELTA_LENGTH_BYTE_ARRAY", "f": "BYTE_STREAM_SPLIT",
                                              "d": "BYTE_STREAM_SPLIT", "fx": "BYTE_STREAM_SPLIT"}),
        flat_nodes, flat_rows),
    ("FLAT_V1_DELTA_BYTES", "v1 pages: DELTA_BYTE_ARRAY", write(flat_schema, flat_rows, compression="none",
        use_dictionary=False, data_page_version="1.0", column_encoding={"s": "DELTA_BYTE_ARRAY",
                                                                        "fx": "DELTA_BYTE_ARRAY"}),
        flat_nodes, flat_rows),
    ("NESTED_V1", "a struct, a list and a map: v1 pages, dictionary, none", write(nested_schema, nested_rows,
        compression="none", data_page_version="1.0", max_rows_per_page=6), nested_nodes, nested_rows),
    ("NESTED_V2_GZIP", "a struct, a list and a map: v2 pages, PLAIN, gzip", write(nested_schema, nested_rows,
        compression="gzip", use_dictionary=False, data_page_version="2.0", max_rows_per_page=6),
        nested_nodes, nested_rows),
    ("FLAT_V1_SNAPPY", "v1 pages, dictionary, snappy (Spark's default codec)", write(flat_schema, flat_rows,
        compression="snappy", data_page_version="1.0", max_rows_per_page=8), flat_nodes, flat_rows),
    ("NESTED_V2_SNAPPY", "a struct, a list and a map: v2 pages, dictionary, snappy", write(nested_schema, nested_rows,
        compression="snappy", data_page_version="2.0", max_rows_per_page=6), nested_nodes, nested_rows),
    ("FLAT_V1_ZSTD", "v1 pages, dictionary, zstd (PyIceberg's default codec)", write(flat_schema, flat_rows,
        compression="zstd", data_page_version="1.0", max_rows_per_page=8), flat_nodes, flat_rows),
    ("NESTED_V2_ZSTD", "a struct, a list and a map: v2 pages, PLAIN, zstd at level 19", write(nested_schema,
        nested_rows, compression="zstd", compression_level=19, use_dictionary=False, data_page_version="2.0",
        max_rows_per_page=6), nested_nodes, nested_rows),
    ("FLAT_V1_GROUPS", "v1 pages, dictionary, snappy, in row groups of 8 rows (3 row groups)", write(flat_schema,
        flat_rows, compression="snappy", data_page_version="1.0", row_group_size=8), flat_nodes, flat_rows),
    ("FLAT_IDS", "v1 pages, dictionary, snappy, with Iceberg's field ids", write(ids_schema, flat_rows,
        compression="snappy", data_page_version="1.0"), flat_nodes, flat_rows),
    ("FLAT_IDS_RENAMED", "the same columns and ids, in the other order and renamed: v2 pages, PLAIN, none", write(
        renamed_schema, renamed_rows, compression="none", use_dictionary=False, data_page_version="2.0"),
        renamed_nodes, renamed_rows),
]

# Each file read back by pyarrow as the rows here: the fixtures are what they say.
for name, _, data, nodes, rows in fixtures:
    back = pq.read_table(io.BytesIO(data)).to_pylist()
    for got, want in zip(back, rows):
        for k in want:
            g, w = got[k], want[k]
            if isinstance(w, list) and w and isinstance(w[0], tuple):
                g = [tuple(x) for x in g]
            if isinstance(w, float) or isinstance(g, float):
                assert g is None and w is None or abs(g - w) <= abs(w) * 1e-6, (name, k, g, w)
            else:
                assert g == w, (name, k, g, w)


def hex_chunks(data, width=100):
    h = data.hex()
    return [h[i:i + width] for i in range(0, len(h), width)]


with open(out_path, "w") as f:
    f.write("// Parquet files pyarrow %s wrote for the page reader's tests (ADR-0112 slice 3), as hex, and what a reader\n"
            % pa.__version__)
    f.write("// must find in each: a line a leaf column, `path|max def|max rep|reps|defs|values`, the levels a digit\n"
            "// each and the values (non-null, in order) as decimal, a float's or double's little-endian bytes as hex,\n"
            "// 0 or 1, or bytes as hex. Made by tools/parquet_page_fixtures.py; do not edit.\n")
    for name, what, data, nodes, rows in fixtures:
        chunks = hex_chunks(data)
        f.write("\n/// %s (%d bytes).\n" % (what, len(data)))
        f.write("const PAGES_%s: [StringView; %d] = [\n" % (name, len(chunks)))
        for c in chunks:
            f.write('    "%s",\n' % c)
        f.write("];\n")
        lines = expected_lines(shredded(nodes, rows))
        f.write("const PAGES_%s_EXPECTED: [StringView; %d] = [\n" % (name, len(lines)))
        for ln in lines:
            f.write('    "%s",\n' % ln)
        f.write("];\n")
print("wrote", out_path, sum(len(d) for _, _, d, _, _ in fixtures), "bytes of Parquet")
