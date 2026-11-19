#!/bin/sh
# The p99 regression gate (ADR-0030): runs tools/bench against two builds of the server on this machine, in turns
# (base then head, head then base, …), then compares them with tools/bench/gate.
# A failure must repeat (ADR-0030 §8): when the first pass fails, a second pass of fresh rounds runs, and the gate fails
# only on a row that failed in both. A shared runner's noise moves one pass; a regression moves both.
# Exits 0 if it passed, 1 on a regression, 3 if the machine was too noisy to judge.
#
# usage: tools/perf_gate.sh BASE_BINARY HEAD_BINARY
#        ROUNDS (3), PERF_SIZES (0,1024,4096,1048576), PERF_CONCURRENCY (1,32), PERF_OPS (1000) and
#        PERF_READ_REPEAT (10: small GET and HEAD phases go over the keys 10 times, so they last seconds) set the matrix;
#        PERF_CONFIRM (1; 0 judges on one pass) whether a failure is run again before it counts;
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
confirm=${PERF_CONFIRM:-1}
dir=${PERF_DIR:-$(mktemp -d)}
mkdir -p "$dir"

(cd "$root/tools/bench" && go build -o "$dir/cosmostore-bench" . && go build -o "$dir/gate" ./gate) || exit 2

# One pass: ROUNDS rounds of both builds, judged by the gate into $dir/report-PASS.md; its status in $pass_status.
run_pass() {
    pass=$1
    base_runs=
    head_runs=
    i=1
    while [ "$i" -le "$rounds" ]; do
        # The first build of a round alternates, so a drift during the run (heat, other load) favours neither.
        if [ $((i % 2)) -eq 1 ]; then order="base head"; else order="head base"; fi
        for which in $order; do
            if [ "$which" = base ]; then bin=$base_bin; else bin=$head_bin; fi
            name="$which-$pass-$i"
            out="$dir/$name.json"
            echo "perf_gate: pass $pass, round $i of $rounds, $which"
            COSMOSTORE=$bin BENCH_BIN="$dir/cosmostore-bench" BENCH_DIR="$dir/$name" \
                "$root/tools/bench.sh" -sizes "$sizes" -concurrency "$conc" -ops "$ops" -read-repeat "$read_repeat" \
                -label "$which pass $pass round $i" -json "$out" > "$dir/$name.txt" 2>&1 ||
                { cat "$dir/$name.txt"; echo "perf_gate: the $which run failed" >&2; exit 1; }
            rm -rf "$dir/$name/store"
            if [ "$which" = base ]; then base_runs="$base_runs${base_runs:+,}$out"; else head_runs="$head_runs${head_runs:+,}$out"; fi
        done
        i=$((i + 1))
    done
    # shellcheck disable=SC2086 # GATE_FLAGS is a list of flags
    "$dir/gate" -base "$base_runs" -head "$head_runs" ${GATE_FLAGS:-} > "$dir/report-$pass.md"
    pass_status=$? # 0 passed, 1 a regression, 3 inconclusive (too noisy to judge), 2 bad input
}

# The rows a report failed, by their first column ("small GETs, c32").
failed_rows() {
    awk -F'|' '/^\|.*\*\*FAIL/ { gsub(/^ +| +$/, "", $2); if ($2 != "") print $2 }' "$1" | sort -u
}

run_pass 1
status=$pass_status
cp "$dir/report-1.md" "$dir/report.md"
if [ "$status" -eq 1 ] && [ "$confirm" -ne 0 ]; then
    failed_rows "$dir/report-1.md" > "$dir/failed-1.txt"
    echo "perf_gate: pass 1 failed ($(tr '\n' ';' < "$dir/failed-1.txt")); a second pass confirms it or not"
    run_pass 2
    failed_rows "$dir/report-2.md" > "$dir/failed-2.txt"
    both=$(comm -12 "$dir/failed-1.txt" "$dir/failed-2.txt")
    if [ -n "$both" ]; then
        status=1
        verdict="**Confirmed:** these failed in both passes:
$(echo "$both" | sed 's/^/- /')"
    elif [ "$pass_status" -eq 2 ]; then
        status=2
        verdict="**The second pass gave no report.**"
    elif [ "$pass_status" -eq 0 ]; then
        status=0
        verdict="**Not confirmed:** the second pass passed, so the first pass's failure was the machine's noise."
    else
        # Failures in other rows, or a noisy second pass: no row failed twice, yet nothing cleared the head.
        status=3
        verdict="**Not confirmed, not cleared:** no row failed in both passes, and the second pass was not clean."
    fi
    {
        echo "$verdict"
        echo
        echo "## Pass 1"
        echo
        cat "$dir/report-1.md"
        echo
        echo "## Pass 2"
        echo
        cat "$dir/report-2.md"
    } > "$dir/report.md"
fi
cat "$dir/report.md"
echo "perf_gate: results in $dir"
exit "$status"
