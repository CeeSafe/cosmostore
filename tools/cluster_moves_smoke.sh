#!/usr/bin/env bash
# Shards moving on a running cluster (ADR-0062, M6 item 6): four nodes, the fourth a standby. Data is written, a large
# object included; node 4 joins and shards move onto it; node 1 leaves and every shard moves off it; then node 1 is
# killed, and everything is read back through the others. Throughout, a write through one node is read through another
# at once: no read is stale while replicas come and go.
#
#   tools/cluster_moves_smoke.sh               ports 19700 and up
set -u
cd "$(dirname "$0")/.."
BIN="$(pwd)/${COSMOSTORE:-out/cosmostore}"
BASE="${COSMO_PORT_BASE:-19700}"
WORK=$(mktemp -d)
PIDS=()
passed=0
failed=0

cleanup() {
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"

pass() { echo "ok   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1"; failed=$((failed + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
pause() { perl -e "select(undef, undef, undef, $1)"; }
md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

export AWS_ACCESS_KEY_ID=AKIACLUSTERMOVES0001 AWS_SECRET_ACCESS_KEY=clustermovessecret012345 AWS_DEFAULT_REGION=us-east-1
export AWS_MAX_ATTEMPTS=8 AWS_RETRY_MODE=standard
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > credentials
head -c 32 /dev/urandom | base64 > cluster.key
cat > cluster.conf <<EOF
cluster 0aa0bb0cc0dd0ee0
shards 4
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
node 4 peer=127.0.0.1:$((BASE + 4)) domain=d standby
EOF

start() {
    mkdir -p "d$1"
    "$BIN" node "$WORK/d$1" --init --cluster-file cluster.conf --node "$1" --listen $((BASE + 10 + $1)) --credentials credentials >> "log$1" 2>&1 &
    PIDS[$1]=$!
}
on() { local n="$1"; shift; aws --no-cli-pager --endpoint-url "http://127.0.0.1:$((BASE + 10 + n))" "$@"; }
status() { "$BIN" cluster-status --cluster-file cluster.conf --node "$1" 2>/dev/null | tail -n +2 | grep -v '^#' | awk '$1 != 65535'; }
# Shards whose voters include node n, as node m sees them (each shard's line is right on its leader; ask every node).
votesIn() { local n="$1" m="$2"; status "$m" | awk -v n="$n" '{ split($8, v, ","); for (i in v) if (v[i] == n) c++ } END { print c + 0 }'; }
learning() { status "$1" | awk '$9 != "-"' | wc -l | tr -d ' '; }

# The read-after-write prober, in the background from before the join until node 1 is killed: a value written
# through one node is read at once through the next, round the live nodes; each probe's outcome is a line of
# probes.log (ok, or stale; a failed call is neither: the client gives up only after its retries).
prober() {
    local n=0 nodes="$1"
    while [ ! -f stop ]; do
        for w in $nodes; do
            [ -f stop ] && break
            n=$((n + 1))
            r=$(echo "$nodes" | tr ' ' '\n' | awk -v w="$w" 'found { print; exit } $0 == w { found = 1 }')
            [ -z "$r" ] && r=$(echo "$nodes" | awk '{ print $1 }')
            printf '%s' "probe $n" > "probe$w.txt"
            on "$w" s3api put-object --bucket moves --key "probe$w" --body "probe$w.txt" > /dev/null 2>&1 || continue
            on "$r" s3api get-object --bucket moves --key "probe$w" "probe$w.got" > /dev/null 2>&1 || continue
            if [ "$(cat "probe$w.got")" = "probe $n" ]; then echo ok >> probes.log; else echo stale >> probes.log; fi
        done
    done
}
probe() { :; }

for n in 1 2 3 4; do start "$n"; done
for i in $(seq 1 100); do
    leaders=$(status 1 | awk '$4 != 0' | wc -l | tr -d ' ')
    [ "$leaders" = "4" ] && break
    pause 0.2
done
check "every shard has a leader" "$leaders" "4"
check "node 4, a standby, holds no shard" "$(votesIn 4 1)" "0"

on 1 s3api create-bucket --bucket moves > /dev/null 2>&1
on 2 s3api create-bucket --bucket others > /dev/null 2>&1
for k in 1 2 3 4 5 6; do printf 'object %s' "$k" > o$k.txt; on $(( k % 3 + 1 )) s3api put-object --bucket moves --key k$k --body o$k.txt > /dev/null 2>&1; done
head -c 5000000 /dev/urandom > big.bin
on 2 s3api put-object --bucket others --key big --body big.bin > /dev/null 2>&1
check "the data is written" "$(on 3 s3api list-objects-v2 --bucket moves --query 'length(Contents)' --output text 2>&1)" "6"

# Node 4 joins; shards move onto it. The prober goes round nodes 2, 3 and 4 (node 1 is to leave, and be killed).
touch probes.log
prober "2 3 4" &
PROBER=$!
pause 2
"$BIN" cluster-join --cluster-file cluster.conf --node 4
check "cluster-join answered" "$?" "0"
for i in $(seq 1 150); do
    probe 1 2; probe 2 3; probe 3 4; probe 4 1
    v=0; for m in 1 2 3 4; do v=$(( v + $(votesIn 4 "$m") )); done
    l=0; for m in 1 2 3 4; do l=$(( l + $(learning "$m") )); done
    [ "$v" -gt 0 ] && [ "$l" = "0" ] && break
    pause 0.2
done
check "node 4 joined: shards moved onto it, none still moving" "$([ "$v" -gt 0 ] && [ "$l" = "0" ] && echo yes)" "yes"
for k in 1 2 3 4 5 6; do on 4 s3api get-object --bucket moves --key k$k got$k.txt > /dev/null 2>&1; done
check "every object read through node 4" "$(cat got1.txt got2.txt got3.txt got4.txt got5.txt got6.txt)" "object 1object 2object 3object 4object 5object 6"
for i in $(seq 1 25); do
    on 4 s3api get-object --bucket others --key big big.got > /dev/null 2>&1 && [ "$(md5of big.got)" = "$(md5of big.bin)" ] && break
    pause 0.4
done
check "the large object read through node 4" "$(md5of big.got)" "$(md5of big.bin)"

# Node 1 leaves; every shard moves off it.
"$BIN" cluster-leave --cluster-file cluster.conf --node 1
check "cluster-leave answered" "$?" "0"
for i in $(seq 1 200); do
    probe 1 2; probe 2 3; probe 3 4; probe 4 1
    v=0; for m in 1 2 3 4; do v=$(( v + $(votesIn 1 "$m") )); done
    l=0; for m in 2 3 4; do l=$(( l + $(learning "$m") )); done
    # Node 1's own view may lag once it is out of every group; count only the others'.
    v=0; for m in 2 3 4; do v=$(( v + $(votesIn 1 "$m") )); done
    [ "$v" = "0" ] && [ "$l" = "0" ] && break
    pause 0.2
done
check "node 1 left: no shard has it any more" "$v" "0"

pause 2
touch stop
wait "$PROBER" 2>/dev/null
kill -9 "${PIDS[1]}" 2>/dev/null
wait "${PIDS[1]}" 2>/dev/null
PIDS[1]=""
for k in 1 2 3 4 5 6; do rm -f got$k.txt; on $(( k % 3 + 2 )) s3api get-object --bucket moves --key k$k got$k.txt > /dev/null 2>&1; done
check "node 1 down: every object read through the others" "$(cat got1.txt got2.txt got3.txt got4.txt got5.txt got6.txt 2>/dev/null)" "object 1object 2object 3object 4object 5object 6"
rm -f big.got
on 3 s3api get-object --bucket others --key big big.got > /dev/null 2>&1
check "and the large object" "$(md5of big.got)" "$(md5of big.bin)"
check "writes go on: a new object through node 2" "$(on 2 s3api put-object --bucket moves --key after --body o1.txt --query ETag --output text 2>&1 | wc -c | tr -d ' ')" "35"
probes=$(grep -c . probes.log)
check "no stale read in $probes probes while shards moved" "$(grep -c stale probes.log)" "0"
check "the probes ran across both moves" "$([ "$probes" -ge 5 ] && echo yes)" "yes"

echo "cluster moves smoke: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
