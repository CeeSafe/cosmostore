#!/bin/sh
# The p99 regression gate (ADR-0030): runs tools/bench against two builds of the server on this machine, in turns
# (base then head, head then base, …), then compares them with tools/bench/gate.
# Exits 0 if it passed, 1 on a regression, 3 if the machine was too noisy to judge.
#
# usage: tools/perf_gate.sh BASE_BINARY HEAD_BINARY
#        ROUNDS (3), PERF_SIZES (0,1024,4096,1048576), PERF_CONCURRENCY (1,32), PERF_OPS (1000) and
#        PERF_READ_REPEAT (10: small GET and HEAD phases go over the keys 10 times, so they last seconds) set the matrix;
#        PERF_DIR keeps the results (default: a new temporary directory); GATE_FLAGS go to the gate (tolerances).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
[ $# -eq 2 ] || { echo "usage: $0 BASE_BINARY HEAD_BINARY" >&2; exit 2; }
base_bin=$1
head_bin=$2
for b in "$base_bin" "$head_bin"; do [ -x "$b" ] || { echo "perf_gate: $b is not an executable" >&2; exit 2; }; done
rounds=${ROUNDS:-3}
sizes=${PERF_SIZES:-0,1024,4096,1048576}
conc=${PERF_CONCURRENCY:-1,32}
ops=${PERF_OPS:-1000}
read_repeat=${PERF_READ_REPEAT:-10}
dir=${PERF_DIR:-$(mktemp -d)}
mkdir -p "$dir"

(cd "$root/tools/bench" && go build -o "$dir/cosmostore-bench" . && go build -o "$dir/gate" ./gate) || exit 2

base_runs=
head_runs=
i=1
while [ "$i" -le "$rounds" ]; do
    # The first build of a round alternates, so a drift during the run (heat, other load) favours neither.
    if [ $((i % 2)) -eq 1 ]; then order="base head"; else order="head base"; fi
    for which in $order; do
        if [ "$which" = base ]; then bin=$base_bin; else bin=$head_bin; fi
        out="$dir/$which-$i.json"
        echo "perf_gate: round $i of $rounds, $which"
        COSMOSTORE=$bin BENCH_BIN="$dir/cosmostore-bench" BENCH_DIR="$dir/$which-$i" \
            "$root/tools/bench.sh" -sizes "$sizes" -concurrency "$conc" -ops "$ops" -read-repeat "$read_repeat" -label "$which round $i" \
            -json "$out" > "$dir/$which-$i.txt" 2>&1 || { cat "$dir/$which-$i.txt"; echo "perf_gate: the $which run failed" >&2; exit 1; }
        rm -rf "$dir/$which-$i/store"
        if [ "$which" = base ]; then base_runs="$base_runs${base_runs:+,}$out"; else head_runs="$head_runs${head_runs:+,}$out"; fi
    done
    i=$((i + 1))
done

# shellcheck disable=SC2086 # GATE_FLAGS is a list of flags
"$dir/gate" -base "$base_runs" -head "$head_runs" ${GATE_FLAGS:-} > "$dir/report.md"
status=$? # 0 passed, 1 a regression, 3 inconclusive (too noisy to judge), 2 bad input
cat "$dir/report.md"
echo "perf_gate: results in $dir"
exit "$status"
