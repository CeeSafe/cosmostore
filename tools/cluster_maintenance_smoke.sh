#!/usr/bin/env bash
# Table maintenance on a cluster as the leader's gated steps (ADR-0110, M22): three nodes whose compaction waits
# 20 s between each bin's copy and its put (`--tables-copy-pause-ms`, a test option), so a run of two bins lasts
# more than the front's 30 s.
# - A write to the table bucket's shard goes through while its compaction waits mid-run.
# - The run completes, past the front's timeout, and the table reads the same rows from fewer files.
# - The shard's leader killed mid-run: the table reads the same rows, and a new leader compacts it.
#
#   ICEBERG_PYTHON=<python with pyiceberg[pyarrow] and boto3> tools/cluster_maintenance_smoke.sh   ports 19600 and up
#   COSMOSTORE=<binary> COSMO_PORT_BASE=29600 ICEBERG_PYTHON=… tools/cluster_maintenance_smoke.sh
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
BIN="$ROOT/${COSMOSTORE:-out/cosmostore}"
BASE="${COSMO_PORT_BASE:-19600}"
PY="${ICEBERG_PYTHON:?set ICEBERG_PYTHON to a python with pyiceberg[pyarrow] and boto3}"
WORK=$(mktemp -d)
PIDS=()
failed=0

cleanup() {
    exec 2> /dev/null
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p"; done
    for i in $(seq 1 50); do
        alive=""
        for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -0 "$p" && alive="$alive $p"; done
        [ -z "$alive" ] && break
        perl -e 'select(undef, undef, undef, 0.2)'
    done
    for p in $alive; do kill -9 "$p"; done
    wait
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
pause() { perl -e "select(undef, undef, undef, $1)"; }

export AWS_ACCESS_KEY_ID=AKIACLUSTERMAINT0001 AWS_SECRET_ACCESS_KEY=clustermaintsecret0123456789ab AWS_DEFAULT_REGION=us-east-1
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > "$WORK/credentials"
head -c 32 /dev/urandom | base64 > "$WORK/cluster.key"
cat > "$WORK/cluster.conf" <<EOF
cluster 00c1a55e5e0c1a57
shards 4
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
EOF
start() {
    mkdir -p "$WORK/d$1"
    "$BIN" node "$WORK/d$1" --init --cluster-file "$WORK/cluster.conf" --node "$1" --listen $((BASE + 10 + $1)) \
        --credentials "$WORK/credentials" --domain localhost --tables-day-seconds 24 --tables-copy-pause-ms 20000 \
        >> "$WORK/log$1" 2>&1 &
    PIDS[$1]=$!
}
status() { "$BIN" cluster-status --cluster-file "$WORK/cluster.conf" --node "$1" 2> /dev/null | tail -n +2 | grep -v "^#"; }
shardOf() { python3 -c 'import hashlib,sys; d=hashlib.sha256(bytes.fromhex("00c1a55e5e0c1a57")+sys.argv[1].encode()).digest(); print(int.from_bytes(d[:8],"big") % 4)' "$1"; }
step() { local n="$1"; shift; "$PY" -I "$ROOT/tools/cluster_maintenance_check.py" "$1" "http://127.0.0.1:$((BASE + 10 + n))" "${@:2}" 2>&1 | tail -1; }
leaders() { status "$1" | awk '$1 != 65535 && $4 != 0' | wc -l | tr -d ' '; }

for n in 1 2 3; do start "$n"; done
for i in $(seq 1 100); do [ "$(leaders 1)" = 4 ] && break; pause 0.2; done
check "every shard has a leader" "$(leaders 1)" 4

# A run past the front's timeout, with a write to its shard meanwhile.
check "a table of four files" "$(step 1 make lake t1)" made
check "four files, four rows" "$(step 2 files lake t1)" "4 4 0,1,2,3"
began=$(date +%s)
# Its first bin is copied within the pass's second; then it waits 20 s before its put.
pause 6
check "the run not done yet" "$(step 2 job lake t1)" "Not_Yet_Run"
took=$(step 3 write lake meanwhile)
check "a write to its shard meanwhile, in under 3 s (took $took s)" "$(echo "$took < 3" | bc)" 1
done=""
for i in $(seq 1 240); do [ "$(step 2 job lake t1)" = Successful ] && { done=yes; break; }; pause 0.5; done
check "the run completes" "$done" yes
elapsed=$(( $(date +%s) - began ))
check "past the front's 30 s (took $elapsed s)" "$([ "$elapsed" -gt 30 ] && echo yes)" yes
check "two files, the same rows" "$(step 1 files lake t1)" "2 4 0,1,2,3"

# The shard's leader killed mid-run: the same rows, and a new leader compacts it.
check "another table of four files" "$(step 1 make lake t2)" made
pause 6
check "its run not done yet" "$(step 2 job lake t2)" "Not_Yet_Run"
shard=$(shardOf lake--table-s3)
leader=$(status 1 | awk -v s="$shard" '$1 == s { print $4 }')
kill -9 "${PIDS[$leader]}" 2> /dev/null
wait "${PIDS[$leader]}" 2> /dev/null
PIDS[$leader]=""
up=$(( leader % 3 + 1 ))
for i in $(seq 1 100); do
    now=$(status "$up" | awk -v s="$shard" '$1 == s { print $4 }')
    [ -n "$now" ] && [ "$now" != 0 ] && [ "$now" != "$leader" ] && break
    pause 0.2
done
check "the shard has a new leader" "$([ "$now" != "$leader" ] && [ "$now" != 0 ] && echo yes)" yes
check "the table reads the same rows" "$(step "$up" files lake t2 | cut -d' ' -f2-)" "4 0,1,2,3"
done=""
for i in $(seq 1 240); do [ "$(step "$up" job lake t2)" = Successful ] && { done=yes; break; }; pause 0.5; done
check "the new leader compacts it" "$done" yes
check "two files, the same rows" "$(step "$up" files lake t2)" "2 4 0,1,2,3"

if [ "$failed" = 0 ]; then echo "cluster maintenance smoke: all passed"; else echo "cluster maintenance smoke: FAILED"; fi
exit "$failed"
