#!/usr/bin/env bash
# Scrub and repair on a three-node cluster (ADR-0063, M6 item 7): a byte flipped in a follower's copy of an inline
# object's segment record, and one in its copy of a large object's extent; the follower's scrub finds both and puts
# them right from another replica, byte for byte. Then a rolling restart, one node at a time, writes going on, and
# everything read back.
#
#   tools/cluster_repair_smoke.sh               ports 19900 and up
set -u
cd "$(dirname "$0")/.."
BIN="$(pwd)/${COSMOSTORE:-out/cosmostore}"
BASE="${COSMO_PORT_BASE:-19900}"
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
# The byte at `offset` of `file` turned over (every bit), in place.
flip() { perl -e 'open(my $f, "+<", $ARGV[0]) or die; binmode $f; seek($f, $ARGV[1], 0); read($f, my $c, 1); seek($f, $ARGV[1], 0); print $f chr(ord($c) ^ 0xFF); close $f' "$1" "$2"; }
# Where `text` first is in `file`, or -1.
offsetOf() { perl -0777 -ne 'BEGIN { $t = shift } print index($_, $t)' "$2" "$1"; }

export AWS_ACCESS_KEY_ID=AKIACLUSTERREPAIR001 AWS_SECRET_ACCESS_KEY=clusterrepairsecret01234 AWS_DEFAULT_REGION=us-east-1
export AWS_MAX_ATTEMPTS=8 AWS_RETRY_MODE=standard
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > credentials
head -c 32 /dev/urandom | base64 > cluster.key
cat > cluster.conf <<EOF
cluster 0bb0cc0dd0ee0ff0
shards 2
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
EOF

start() {
    mkdir -p "d$1"
    "$BIN" node "$WORK/d$1" --init --cluster-file cluster.conf --node "$1" --listen $((BASE + 10 + $1)) --credentials credentials --scrub-seconds 2 >> "log$1" 2>&1 &
    PIDS[$1]=$!
}
on() { local n="$1"; shift; aws --no-cli-pager --endpoint-url "http://127.0.0.1:$((BASE + 10 + n))" "$@"; }
status() { "$BIN" cluster-status --cluster-file cluster.conf --node "$1" 2>/dev/null | tail -n +2; }
scrubOf() { status "$1" | awk '$1 == "#" && $2 == "scrub" { print $4, $5, $6 }'; }  # damaged repaired fetched

for n in 1 2 3; do start "$n"; done
for i in $(seq 1 100); do
    [ "$(status 1 | grep -v '^#' | awk '$1 != 65535 && $4 != 0' | wc -l | tr -d ' ')" = "2" ] && break
    pause 0.2
done

marker="REPAIRME-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
perl -e "print '$marker' x 200" > inline.txt
head -c 3000000 /dev/urandom > big.bin
on 1 s3api create-bucket --bucket repair > /dev/null 2>&1
on 1 s3api put-object --bucket repair --key inline --body inline.txt > /dev/null 2>&1
on 2 s3api put-object --bucket repair --key big --body big.bin > /dev/null 2>&1
check "the objects are written" "$(on 3 s3api list-objects-v2 --bucket repair --query 'length(Contents)' --output text 2>&1)" "2"
pause 2

# The bucket's shard, its leader, and a follower whose copies will be damaged.
shard=$(status 1 | grep -v '^#' | awk '$1 != 65535' | sort -k7 -n -r | head -1 | awk '{ print $1 }')
leader=$(status 1 | awk -v s="$shard" '$1 == s { print $4 }')
victim=$(( leader % 3 + 1 ))
segment=$(grep -l "$marker" d$victim/shard-0$shard/store-*/seg-*.cj | head -1)
check "the follower's segment holds the inline object" "$([ -n "$segment" ] && echo yes)" "yes"
extent=$(ls d$victim/shard-0$shard/store-*/extents/ext-*.ce 2>/dev/null | head -1)
check "and its extent file" "$([ -n "$extent" ] && echo yes)" "yes"
good=$(ls d$leader/shard-0$shard/store-*/extents/$(basename "$extent"))
before=$(scrubOf "$victim")
at=$(offsetOf "$segment" "$marker")
flip "$segment" $(( at + 100 ))
flip "$extent" 100000
whole() { perl -0777 -ne "print((index(\$_, '$marker' x 200) >= 0) ? 'yes' : 'no')" "$segment"; }
check "the copies are damaged" "$([ "$(whole)" = "no" ] && [ "$(md5of "$extent")" != "$(md5of "$good")" ] && echo yes)" "yes"

for i in $(seq 1 60); do
    after=$(scrubOf "$victim")
    set -- $after
    [ "${1:-0}" -ge 2 ] && [ "${2:-0}" -ge 2 ] && [ "${3:-0}" -ge 1 ] && [ -f "$extent" ] && [ "$(md5of "$extent")" = "$(md5of "$good")" ] && break
    pause 0.5
done
check "scrub found both and repaired them (damaged, repaired, fetched: $after)" "$(set -- $after; [ "$1" -ge 2 ] && [ "$2" -ge 2 ] && [ "$3" -ge 1 ] && echo yes)" "yes"
check "the record is whole again" "$(whole)" "yes"
check "the extent is the leader's again, byte for byte" "$(md5of "$extent")" "$(md5of "$good")"

# A rolling restart, one node at a time, each caught up before the next; writes between.
caughtUp() {
    local n="$1"
    local mine theirs
    mine=$(status "$n" | grep -v '^#' | awk '{ print $1, $7 }' | sort)
    theirs=$(status $(( n % 3 + 1 )) | grep -v '^#' | awk '{ print $1, $7 }' | sort)
    [ -n "$mine" ] && [ "$mine" = "$theirs" ]
}
k=0
for n in 1 2 3; do
    kill "${PIDS[$n]}" 2>/dev/null
    wait "${PIDS[$n]}" 2>/dev/null
    k=$((k + 1))
    printf 'written while node %s was down' "$n" > during$n.txt
    on $(( n % 3 + 1 )) s3api put-object --bucket repair --key during$n --body during$n.txt > /dev/null 2>&1
    start "$n"
    for i in $(seq 1 100); do caughtUp "$n" && break; pause 0.2; done
    check "node $n restarted and caught up" "$(caughtUp "$n" && echo yes)" "yes"
done
check "after the rolling restart, every object is there" "$(on 2 s3api list-objects-v2 --bucket repair --query 'length(Contents)' --output text 2>&1)" "5"
on 3 s3api get-object --bucket repair --key big big.got > /dev/null 2>&1
check "the large object reads whole" "$(md5of big.got)" "$(md5of big.bin)"
on 1 s3api get-object --bucket repair --key inline inline.got > /dev/null 2>&1
check "the inline object reads whole" "$(md5of inline.got)" "$(md5of inline.txt)"

echo "cluster repair smoke: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
