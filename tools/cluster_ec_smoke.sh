#!/usr/bin/env bash
# Erasure-coded extents on a three-node cluster (ADR-0064, M6 item 8): a large object's extent, cold after two seconds,
# becomes three 2+1 Reed-Solomon pieces, one per node, its whole copies gone; a read decodes it again; with the
# shard's leader down the new leader decodes it from the two pieces left; a lost piece is rebuilt and a damaged one
# found by scrub and rebuilt, byte for byte.
#
#   tools/cluster_ec_smoke.sh               ports 20000 and up
set -u
cd "$(dirname "$0")/.."
BIN="$(pwd)/${COSMOSTORE:-out/cosmostore}"
BASE="${COSMO_PORT_BASE:-20000}"
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
sizeof() { wc -c < "$1" | tr -d ' '; }
flip() { perl -e 'open(my $f, "+<", $ARGV[0]) or die; binmode $f; seek($f, $ARGV[1], 0); read($f, my $c, 1); seek($f, $ARGV[1], 0); print $f chr(ord($c) ^ 0xFF); close $f' "$1" "$2"; }

export AWS_ACCESS_KEY_ID=AKIACLUSTERCODED0001 AWS_SECRET_ACCESS_KEY=clustercodedsecret012345 AWS_DEFAULT_REGION=us-east-1
# A read of a coded extent answers 503 until it is decoded: the client retries.
export AWS_MAX_ATTEMPTS=12 AWS_RETRY_MODE=standard
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > credentials
head -c 32 /dev/urandom | base64 > cluster.key
cat > cluster.conf <<EOF
cluster 0cc0dd0ee0ff0aa0
shards 2
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
node 4 peer=127.0.0.1:$((BASE + 4)) domain=d standby
EOF

start() {
    mkdir -p "d$1"
    "$BIN" node "$WORK/d$1" --init --cluster-file cluster.conf --node "$1" --listen $((BASE + 10 + $1)) --credentials credentials \
        --scrub-seconds 2 --code-after-seconds 2 >> "log$1" 2>&1 &
    PIDS[$1]=$!
}
stop() { kill "${PIDS[$1]}" 2>/dev/null; wait "${PIDS[$1]}" 2>/dev/null; PIDS[$1]=; }
on() { local n="$1"; shift; aws --no-cli-pager --endpoint-url "http://127.0.0.1:$((BASE + 10 + n))" "$@"; }
status() { "$BIN" cluster-status --cluster-file cluster.conf --node "$1" 2>/dev/null | tail -n +2; }
scrubOf() { status "$1" | awk '$1 == "#" && $2 == "scrub" { print $4, $5, $6 }'; }  # damaged repaired fetched
extentsOf() { ls d$1/shard-0$shard/store-*/extents/ext-*.ce 2>/dev/null | wc -l | tr -d ' '; }
piecesOf() { ls d$1/shard-0$shard/store-*/extents/piece-*.cp 2>/dev/null | wc -l | tr -d ' '; }
pieceOf() { ls d$1/shard-0$shard/store-*/extents/piece-*.cp 2>/dev/null | head -1; }

for n in 1 2 3; do start "$n"; done
for i in $(seq 1 100); do
    [ "$(status 1 | grep -v '^#' | awk '$1 != 65535 && $4 != 0' | wc -l | tr -d ' ')" = "2" ] && break
    pause 0.2
done

head -c 10000000 /dev/urandom > big.bin
printf 'small and inline' > small.txt
on 1 s3api create-bucket --bucket coded > /dev/null 2>&1
on 2 s3api put-object --bucket coded --key big --body big.bin > /dev/null 2>&1
on 3 s3api put-object --bucket coded --key small --body small.txt > /dev/null 2>&1
check "the objects are written" "$(on 3 s3api list-objects-v2 --bucket coded --query 'length(Contents)' --output text 2>&1)" "2"
shard=$(status 1 | grep -v '^#' | awk '$1 != 65535' | sort -k7 -n -r | head -1 | awk '{ print $1 }')
check "every node has the extent whole at first" "$(extentsOf 1)$(extentsOf 2)$(extentsOf 3)" "111"

# Cold after two seconds: coded, one piece per node, the whole copies gone.
for i in $(seq 1 100); do
    [ "$(piecesOf 1)$(piecesOf 2)$(piecesOf 3)" = "111" ] && [ "$(extentsOf 1)$(extentsOf 2)$(extentsOf 3)" = "000" ] && break
    pause 0.2
done
check "coded: a piece on each node" "$(piecesOf 1)$(piecesOf 2)$(piecesOf 3)" "111"
check "and no whole copy" "$(extentsOf 1)$(extentsOf 2)$(extentsOf 3)" "000"
check "each piece is half the extent" "$(sizeof "$(pieceOf 1)")" "5000000"
for n in 1 2 3; do md5of "$(pieceOf "$n")" > piece$n.md5; done
check "the three pieces differ" "$(sort -u piece1.md5 piece2.md5 piece3.md5 | wc -l | tr -d ' ')" "3"

# A read decodes it (503s until then, retried).
on 1 s3api get-object --bucket coded --key big big.got > /dev/null 2>&1
check "the coded object reads back whole" "$(md5of big.got)" "$(md5of big.bin)"
on 2 s3api get-object --bucket coded --key small small.got > /dev/null 2>&1
check "the inline object too" "$(cat small.got)" "small and inline"

# The shard's leader down: a new one decodes from the two pieces left.
leader=$(status 1 | awk -v s="$shard" '$1 == s { print $4 }')
stop "$leader"
other=$(( leader % 3 + 1 ))
for i in $(seq 1 100); do
    l=$(status "$other" | awk -v s="$shard" '$1 == s { print $4 }')
    [ -n "$l" ] && [ "$l" != "0" ] && [ "$l" != "$leader" ] && break
    pause 0.2
done
rm -f big.got
on "$other" s3api get-object --bucket coded --key big big.got > /dev/null 2>&1
check "with the leader (node $leader) down, the object decodes from two pieces" "$(md5of big.got)" "$(md5of big.bin)"
start "$leader"

# A lost piece is rebuilt from the other two, the same bytes.
victim=$(( leader % 3 + 1 ))
lost=$(pieceOf "$victim")
rm -f "$lost"
for i in $(seq 1 100); do [ -f "$lost" ] && [ "$(md5of "$lost")" = "$(cat piece$victim.md5)" ] && break; pause 0.2; done
check "node $victim's lost piece is rebuilt, byte for byte" "$([ -f "$lost" ] && md5of "$lost")" "$(cat piece$victim.md5)"

# A damaged piece is found by scrub and rebuilt.
victim=$(( victim % 3 + 1 ))
hurt=$(pieceOf "$victim")
before=$(scrubOf "$victim" | awk '{ print $1 }')
flip "$hurt" 123456
check "the piece is damaged" "$([ "$(md5of "$hurt")" != "$(cat piece$victim.md5)" ] && echo yes)" "yes"
for i in $(seq 1 150); do
    [ -f "$hurt" ] && [ "$(md5of "$hurt")" = "$(cat piece$victim.md5)" ] && break
    pause 0.2
done
check "scrub found node $victim's damaged piece" "$([ "$(scrubOf "$victim" | awk '{ print $1 }')" -gt "${before:-0}" ] && echo yes)" "yes"
check "and it is rebuilt, byte for byte" "$([ -f "$hurt" ] && md5of "$hurt")" "$(cat piece$victim.md5)"

# Deleted: its pieces go too.
on 1 s3api delete-object --bucket coded --key big > /dev/null 2>&1
for i in $(seq 1 150); do [ "$(piecesOf 1)$(piecesOf 2)$(piecesOf 3)" = "000" ] && break; pause 0.2; done
check "the deleted object's pieces are reaped" "$(piecesOf 1)$(piecesOf 2)$(piecesOf 3)" "000"

# A holder leaves (the M6 exit review's F1): its piece is made again on the node that takes its place, byte for byte,
# and the object outlives the loss of another holder.
head -c 6000000 /dev/urandom > big2.bin
on 2 s3api put-object --bucket coded --key big2 --body big2.bin > /dev/null 2>&1
for i in $(seq 1 100); do
    [ "$(piecesOf 1)$(piecesOf 2)$(piecesOf 3)" = "111" ] && [ "$(extentsOf 1)$(extentsOf 2)$(extentsOf 3)" = "000" ] && break
    pause 0.2
done
check "the second object is coded, a piece on each node" "$(piecesOf 1)$(piecesOf 2)$(piecesOf 3)" "111"
md5of "$(pieceOf 1)" > left.md5
start 4
"$BIN" cluster-join --cluster-file cluster.conf --node 4 > /dev/null 2>&1
check "node 4 joined" "$?" "0"
"$BIN" cluster-leave --cluster-file cluster.conf --node 1 > /dev/null 2>&1
check "node 1 left" "$?" "0"
for i in $(seq 1 300); do [ "$(piecesOf 4)" = "1" ] && break; pause 0.2; done
check "node 4 holds the piece node 1 held" "$(piecesOf 4)" "1"
check "rebuilt byte for byte" "$([ -n "$(pieceOf 4)" ] && md5of "$(pieceOf 4)")" "$(cat left.md5)"
stop 1
stop 2
rm -f big2.got
on 4 s3api get-object --bucket coded --key big2 big2.got > /dev/null 2>&1
check "with nodes 1 and 2 down, the object decodes from node 3's and node 4's pieces" "$(md5of big2.got 2>/dev/null)" "$(md5of big2.bin)"

echo "cluster ec smoke: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
