#!/usr/bin/env bash
# A three-node cluster on this machine (ADR-0059, M6 item 3): three `cosmostore node` processes on loopback ports.
# Checks that every shard elects one leader and every node applies the same entries; that killing a leader gets its
# shards new leaders, in a later term, which the survivors replicate; that the killed node, restarted, catches up
# without deposing anyone; and that a request signed under another secret is refused.
#
#   tools/cluster_smoke.sh                       ports 19101 to 19103
#   COSMO_PORT_BASE=29100 tools/cluster_smoke.sh
set -u
cd "$(dirname "$0")/.."
BIN="${COSMOSTORE:-out/cosmostore}"
BASE="${COSMO_PORT_BASE:-19100}"
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

ok() { echo "ok   $1"; passed=$((passed + 1)); }
bad() { echo "FAIL $1"; failed=$((failed + 1)); }
pause() { perl -e "select(undef, undef, undef, $1)"; }

head -c 32 /dev/urandom | base64 > "$WORK/cluster.key"
head -c 32 /dev/urandom | base64 > "$WORK/other.key"
cat > "$WORK/cluster.conf" <<EOF
cluster 0123456789abcdef
shards 4
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
EOF

start() {
    mkdir -p "$WORK/d$1"
    "$BIN" node "$WORK/d$1" --cluster-file "$WORK/cluster.conf" --node "$1" >> "$WORK/log$1" 2>&1 &
    PIDS[$1]=$!
}

status() { "$BIN" cluster-status --cluster-file "$WORK/cluster.conf" --node "$1" 2>/dev/null | tail -n +2 | grep -v "^#"; }

# Whether, among the nodes given, every shard has exactly one leader and every node has applied the same index of
# each shard, at least `min`.
agreed() {
    local min="$1"; shift
    local all=""
    for n in "$@"; do
        local s
        s=$(status "$n") || return 1
        [ -z "$s" ] && return 1
        all="$all$s"$'\n'
    done
    echo "$all" | awk -v nodes="$#" -v min="$min" '
        NF == 9 { rows[$1]++; if ($2 == "leader") leaders[$1]++; applied[$1, rows[$1]] = $7; if ($7 < min) low = 1 }
        END {
            if (low) exit 1
            for (s in rows) {
                if (rows[s] != nodes || leaders[s] != 1) exit 1
                for (i = 2; i <= rows[s]; i++) if (applied[s, i] != applied[s, 1]) exit 1
            }
            exit 0
        }'
}

await() {
    local what="$1"; shift
    for i in $(seq 1 100); do
        if "$@"; then ok "$what"; return 0; fi
        pause 0.2
    done
    bad "$what"
    for n in 1 2 3; do echo "  node $n:"; status "$n" | sed 's/^/    /'; done
    return 1
}

for n in 1 2 3; do start "$n"; done
await "three nodes: one leader per shard, every entry applied everywhere" agreed 1 1 2 3

# The node that leads shard 0 goes down hard.
leader=$(status 1 | awk '$1 == 0 { print $4 }')
term=$(status 1 | awk '$1 == 0 { print $3 }')
survivors=()
for n in 1 2 3; do [ "$n" != "$leader" ] && survivors+=("$n"); done
kill -9 "${PIDS[$leader]}" 2>/dev/null
wait "${PIDS[$leader]}" 2>/dev/null
PIDS[$leader]=""
newTerm() {
    local t
    t=$(status "${survivors[0]}" | awk '$1 == 0 { print $3 }')
    [ -n "$t" ] && [ "$t" -gt "$term" ] && agreed 1 "${survivors[@]}"
}
await "node $leader killed: shard 0 has a new leader in a later term, and the survivors agree" newTerm

# It comes back as a follower and catches up, deposing no one.
start "$leader"
before=$(status "${survivors[0]}" | awk '$1 == 0 { print $3 }')
await "node $leader restarted: it catches up" agreed 1 1 2 3
after=$(status "${survivors[0]}" | awk '$1 == 0 { print $3 }')
if [ "$before" = "$after" ]; then ok "the restarted node deposed no leader (pre-vote)"; else bad "the term moved on from $before to $after"; fi

# Another secret: refused.
sed "s#$WORK/cluster.key#$WORK/other.key#" "$WORK/cluster.conf" > "$WORK/other.conf"
if "$BIN" cluster-status --cluster-file "$WORK/other.conf" --node 1 > /dev/null 2>&1; then
    bad "a request under another cluster file was answered"
else
    ok "a request under another cluster file or secret is refused"
fi

echo "cluster smoke: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
