#!/usr/bin/env bash
# A node's directory and how it starts (ADR-0066): four nodes, the fourth from standby. An empty directory without
# --init or --join is refused; a voter that lost its disk is refused --join until it is taken out; a directory is
# refused to another node; a restart needs no flag; and a node out of every shard, wiped, comes back with --join and
# holds replicas again.
#
#   tools/cluster_identity_smoke.sh               ports 20400 and up
set -u
cd "$(dirname "$0")/.."
BIN="$(pwd)/${COSMOSTORE:-out/cosmostore}"
BASE="${COSMO_PORT_BASE:-20400}"
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

export AWS_ACCESS_KEY_ID=AKIACLUSTERIDENTITY1 AWS_SECRET_ACCESS_KEY=clusteridentitysecret0123 AWS_DEFAULT_REGION=us-east-1
export AWS_MAX_ATTEMPTS=8 AWS_RETRY_MODE=standard
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > credentials
head -c 32 /dev/urandom | base64 > cluster.key
cat > cluster.conf <<EOF
cluster 0ee0ff0aa0bb0cc0
shards 2
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
node 4 peer=127.0.0.1:$((BASE + 4)) domain=d standby
EOF

# start <node> <dir> <flag...>: in the background; run <node> <dir> <flag...>: in the foreground, its exit status.
start() {
    local n="$1" d="$2"; shift 2
    mkdir -p "$d"
    "$BIN" node "$WORK/$d" --cluster-file cluster.conf --node "$n" --listen $((BASE + 10 + n)) --credentials credentials "$@" >> "log$n" 2>&1 &
    PIDS[$n]=$!
}
run() {
    local n="$1" d="$2"; shift 2
    "$BIN" node "$WORK/$d" --cluster-file cluster.conf --node "$n" --listen $((BASE + 30 + n)) --credentials credentials "$@" > "run.out" 2>&1
    echo $?
}
stop() { kill "${PIDS[$1]}" 2>/dev/null; wait "${PIDS[$1]}" 2>/dev/null; PIDS[$1]=; }
on() { local n="$1"; shift; aws --no-cli-pager --endpoint-url "http://127.0.0.1:$((BASE + 10 + n))" "$@"; }
status() { "$BIN" cluster-status --cluster-file cluster.conf --node "$1" 2>/dev/null | tail -n +2 | grep -v '^#' | awk '$1 != 65535'; }
# Shards whose voters or learners include node n, each shard judged by the other nodes' view of its highest term (a
# leader's first): a replica the shard removed goes on showing the group it was removed from.
holds() {
    local n="$1"
    for m in 1 2 3 4; do [ "$m" = "$n" ] || status "$m"; done | awk -v n="$n" '
        { rank = $3 * 2 + ($2 == "leader"); if (!($1 in best) || rank > best[$1]) { best[$1] = rank; v[$1] = $8; l[$1] = $9 } }
        END { c = 0; for (s in best) { if (("," v[s] ",") ~ ("," n ",") || ("," l[s] ",") ~ ("," n ",")) c++ } print c }'
}

check "an empty directory with no flag is refused" "$(run 1 d1)" "2"
check "and says why" "$(grep -c 'an empty node directory' run.out)" "1"
for n in 1 2 3 4; do start "$n" "d$n" --init; done
for i in $(seq 1 100); do
    [ "$(status 1 | awk '$4 != 0' | wc -l | tr -d ' ')" = "2" ] && break
    pause 0.2
done
check "each node wrote its marker" "$(cat d1/cosmo-node d2/cosmo-node d3/cosmo-node d4/cosmo-node | grep -c '^start init')" "4"
"$BIN" cluster-join --cluster-file cluster.conf --node 4 > /dev/null 2>&1
for i in $(seq 1 150); do [ "$(holds 4)" -gt 0 ] && break; pause 0.2; done
check "node 4 joined" "$([ "$(holds 4)" -gt 0 ] && echo yes)" "yes"
on 1 s3api create-bucket --bucket ident > /dev/null 2>&1
printf 'before' > before.txt
on 2 s3api put-object --bucket ident --key before --body before.txt > /dev/null 2>&1

# A voter that lost its disk: node 2 stopped, an empty directory in place of its own; --join is refused while it votes.
stop 2
check "a voter's empty directory, --join: refused" "$(run 2 d2-empty --join)" "1"
check "because it is still a voter" "$(grep -c 'still a voter' run.out)" "1"
check "and nothing was written there" "$(ls d2-empty 2>/dev/null | wc -l | tr -d ' ')" "0"
check "another node's directory is refused" "$(run 3 d2)" "2"
check "and says whose it is" "$(grep -c 'another node' run.out)" "1"
start 2 d2
pause 1
check "node 2 restarts on its own directory with no flag" "$(kill -0 "${PIDS[2]}" 2>/dev/null && echo up)" "up"

# The way back: node 4 taken out, wiped, started with --join, and its shards moved back.
stop 4
"$BIN" cluster-leave --cluster-file cluster.conf --node 4 > leave.out 2>&1
left=$?
cat leave.out
check "cluster-leave answered" "$left" "0"
for i in $(seq 1 200); do [ "$(holds 4)" = "0" ] && break; pause 0.2; done
check "node 4 is in no shard" "$(holds 4)" "0"
rm -rf d4
start 4 d4 --join
pause 2
check "node 4 started again with --join" "$(kill -0 "${PIDS[4]}" 2>/dev/null && echo up)" "up"
check "its marker says it joined" "$(grep -c '^start join' d4/cosmo-node)" "1"
"$BIN" cluster-join --cluster-file cluster.conf --node 4 > /dev/null 2>&1
for i in $(seq 1 150); do [ "$(holds 4)" -gt 0 ] && break; pause 0.2; done
check "node 4 holds replicas again" "$([ "$(holds 4)" -gt 0 ] && echo yes)" "yes"
for i in $(seq 1 25); do
    on 4 s3api get-object --bucket ident --key before got.txt > /dev/null 2>&1 && break
    pause 0.4
done
check "the data reads through it" "$(cat got.txt 2>/dev/null)" "before"
stop 4
start 4 d4
pause 2
check "and it restarts with no flag" "$(kill -0 "${PIDS[4]}" 2>/dev/null && echo up)" "up"

# A voter of group 0 loses its disk (ADR-0067): node 1, one of the three group 0 began on, is taken out; group 0 moves
# its vote to another active node and keeps it as a learner; wiped, it comes back with --join.
g0voter() { "$BIN" cluster-status --cluster-file cluster.conf --node "$1" 2>/dev/null | awk -v n="$2" '$1 == 65535 { split($8, v, ","); for (i in v) if (v[i] == n) print "yes" }' | head -1; }
check "node 1 votes in group 0 at first" "$(g0voter 2 1)" "yes"
"$BIN" cluster-leave --cluster-file cluster.conf --node 1 > leave1.out 2>&1
check "cluster-leave 1 answered" "$?" "0"
for i in $(seq 1 300); do
    [ "$(holds 1)" = "0" ] && [ -z "$(g0voter 2 1)" ] && [ -z "$(g0voter 3 1)" ] && break
    pause 0.2
done
check "node 1 is in no shard" "$(holds 1)" "0"
check "and no longer votes in group 0" "$(g0voter 2 1)$(g0voter 3 1)" ""
check "group 0 still has three voters" "$("$BIN" cluster-status --cluster-file cluster.conf --node 2 | awk '$1 == 65535 { print split($8, v, ",") }')" "3"
stop 1
rm -rf d1
start 1 d1 --join
pause 2
check "node 1, wiped, starts with --join" "$(kill -0 "${PIDS[1]}" 2>/dev/null && echo up)" "up"
"$BIN" cluster-join --cluster-file cluster.conf --node 1 > /dev/null 2>&1
for i in $(seq 1 150); do [ "$(holds 1)" -gt 0 ] && break; pause 0.2; done
check "node 1 holds replicas again" "$([ "$(holds 1)" -gt 0 ] && echo yes)" "yes"
printf 'after' > after.txt
on 1 s3api put-object --bucket ident --key after --body after.txt > /dev/null 2>&1
on 3 s3api get-object --bucket ident --key after got2.txt > /dev/null 2>&1
check "a write through it reads back elsewhere" "$(cat got2.txt 2>/dev/null)" "after"

echo "cluster identity smoke: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
