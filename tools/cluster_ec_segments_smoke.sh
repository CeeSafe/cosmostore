#!/usr/bin/env bash
# Coded segments on a three-node cluster (ADR-0070, the M6 exit review's F2): 1 MiB segments, coded after two
# seconds. Small (inline) objects fill sealed segments; once a checkpoint covers them they become 2+1 pieces, one per
# node, their files gone; every object still reads, first through decoding; with a node down, from two pieces.
#
#   tools/cluster_ec_segments_smoke.sh               ports 21300 and up
set -u
cd "$(dirname "$0")/.."
BIN="$(pwd)/${COSMOSTORE:-out/cosmostore}"
BASE="${COSMO_PORT_BASE:-21300}"
WORK=$(mktemp -d)
PIDS=()
passed=0
failed=0

cleanup() {
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    if [ "${KEEP:-}" = "1" ]; then echo "kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT
cd "$WORK"

pass() { echo "ok   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1"; failed=$((failed + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
pause() { perl -e "select(undef, undef, undef, $1)"; }
md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

export AWS_ACCESS_KEY_ID=AKIACLUSTERSEGCODE01 AWS_SECRET_ACCESS_KEY=clustersegcodesecret0123 AWS_DEFAULT_REGION=us-east-1
export AWS_MAX_ATTEMPTS=12 AWS_RETRY_MODE=standard
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > credentials
head -c 32 /dev/urandom | base64 > cluster.key
cat > cluster.conf <<EOC
cluster 0ff0aa0bb0cc0dd0
shards 1
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
EOC

start() {
    mkdir -p "d$1"
    "$BIN" node "$WORK/d$1" --init --cluster-file cluster.conf --node "$1" --listen $((BASE + 10 + $1)) --credentials credentials \
        --code-after-seconds 2 --segment-mb 1 >> "log$1" 2>&1 &
    PIDS[$1]=$!
}
stop() { kill "${PIDS[$1]}" 2>/dev/null; wait "${PIDS[$1]}" 2>/dev/null; PIDS[$1]=; }
on() { local n="$1"; shift; aws --no-cli-pager --endpoint-url "http://127.0.0.1:$((BASE + 10 + n))" "$@"; }
status() { "$BIN" cluster-status --cluster-file cluster.conf --node "$1" 2>/dev/null | tail -n +2; }
segPieces() { ls d$1/shard-00/store-*/extents/ 2>/dev/null | grep -c '^piece-8'; }
segFiles() { ls d$1/shard-00/store-*/ 2>/dev/null | grep -c '^seg-'; }

for n in 1 2 3; do start "$n"; done
for i in $(seq 1 100); do
    [ "$(status 1 | grep -v '^#' | awk '$1 == 0 && $4 != 0' | wc -l | tr -d ' ')" = "1" ] && break
    pause 0.2
done
on 1 s3api create-bucket --bucket segs > /dev/null 2>&1
for k in $(seq 1 40); do
    head -c 100000 /dev/urandom > o$k.bin
    on $(( k % 3 + 1 )) s3api put-object --bucket segs --key o$k --body o$k.bin > /dev/null 2>&1
done
check "40 small objects written" "$(on 1 s3api list-objects-v2 --bucket segs --query 'length(Contents)' --output text 2>&1)" "40"
for i in $(seq 1 150); do
    [ "$(segPieces 1)" -ge 1 ] && [ "$(segPieces 2)" -ge 1 ] && [ "$(segPieces 3)" -ge 1 ] && break
    pause 0.2
done
coded=$(segPieces 1)
check "sealed segments are coded: a piece on each node" "$([ "$coded" -ge 1 ] && [ "$(segPieces 2)" = "$coded" ] && [ "$(segPieces 3)" = "$coded" ] && echo yes)" "yes"
ok=0
for k in $(seq 1 40); do
    rm -f got.bin
    on $(( k % 3 + 1 )) s3api get-object --bucket segs --key o$k got.bin > /dev/null 2>&1
    if [ "$(md5of got.bin 2>/dev/null)" = "$(md5of o$k.bin)" ]; then ok=$((ok + 1)); else echo "  o$k did not read back: $(on $(( k % 3 + 1 )) s3api get-object --bucket segs --key o$k got.bin 2>&1 | grep -o "An error occurred ([A-Za-z]*)[^:]*" | head -1)"; fi
done
check "every object reads back, the coded ones decoded" "$ok" "40"
leader=$(status 1 | awk '$1 == 0 { print $4 }')
stop "$leader"
# A fresh look: decoded copies kept an hour on the stopped leader are gone with it; the others decode from two pieces.
ok=0
other=$(( leader % 3 + 1 ))
for k in 1 2 3 4 5; do
    rm -f got.bin
    on "$other" s3api get-object --bucket segs --key o$k got.bin > /dev/null 2>&1
    [ "$(md5of got.bin 2>/dev/null)" = "$(md5of o$k.bin)" ] && ok=$((ok + 1))
done
check "with the leader (node $leader) down, the oldest objects read back" "$ok" "5"

echo "cluster ec segments smoke: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
