"""The comparison run's tables, from the bench.json of each run that tools/compare/compare.sh wrote.

usage: python3 -I tools/compare/report.py WORK_DIR > report.md
Columns are the runs in RUNS order (those present); rows are each size and concurrency, per operation.
"""
import json
import os
import sys

RUNS = [
    ("cosmostore-durable", "CosmoStore"),
    ("seaweedfs-durable", "SeaweedFS, fsync"),
    ("garage-durable", "Garage, fsync"),
    ("rustfs-durable", "RustFS (fsync by default)"),
    ("seaweedfs-default", "SeaweedFS, default"),
    ("garage-default", "Garage, default"),
]
OPS = ["put", "get", "head", "overwrite", "delete"]


def size_name(n):
    if n >= 1048576:
        return f"{n // 1048576} MiB"
    if n >= 1024:
        return f"{n // 1024} KiB"
    return f"{n} B"


def main():
    work = sys.argv[1]
    runs = []
    for d, title in RUNS:
        path = os.path.join(work, d, "bench.json")
        if os.path.exists(path):
            with open(path) as f:
                runs.append((title, {(r["size"], r["concurrency"], r["op"]): r for r in json.load(f)["results"]}))
    keys = sorted({(s, c) for _, res in runs for (s, c, _) in res})
    head = "| size, concurrency | " + " | ".join(t for t, _ in runs) + " |"
    rule = "|---|" + "---:|" * len(runs)
    for op in OPS:
        for metric, label, fmt in [("opsPerSec", "operations per second", "{:,.0f}"), ("p99ms", "p99, ms", "{:.2f}")]:
            print(f"### {op}: {label}\n")
            print(head)
            print(rule)
            for s, c in keys:
                cells = []
                for _, res in runs:
                    r = res.get((s, c, op))
                    if r is None:
                        cells.append("")
                    elif r["errors"]:
                        cells.append(fmt.format(r[metric]) + f" ({r['errors']} errors)")
                    else:
                        cells.append(fmt.format(r[metric]))
                print(f"| {size_name(s)}, {c} | " + " | ".join(cells) + " |")
            print()
    print("### Errors and memory\n")
    print("| run | errors | largest RSS, MiB |")
    print("|---|---:|---:|")
    for title, res in runs:
        errors = sum(r["errors"] for r in res.values())
        rss = max((r.get("serverRssMiB") or 0) for r in res.values())
        print(f"| {title} | {errors} | {rss:.0f} |")


main()
