#!/bin/sh
# The M2 exit test (ROADMAP): `cosmostore soak` for HOURS, killed with SIGKILL every 1-15 minutes and started again.
# Each start rebuilds the model from the soak's log and checks every key against the store before going on; any
# disagreement, fsck problem or failed operation ends the run with status 1.
#
# usage: tools/soak.sh COSMOSTORE DIR HOURS KEYS CAPACITY-BYTES   (output: DIR.out)
set -u
bin=$1; dir=$2; hours=$3; keys=$4; capacity=$5
out="$dir.out"
total=$((hours * 3600))
begin=$(date +%s)
mkdir -p "$dir"
echo "soak: $(date -u +%FT%TZ) $bin, $hours h, $keys keys, capacity $capacity" >> "$out"
kills=0
while :; do
    now=$(date +%s)
    left=$((total - (now - begin)))
    if [ "$left" -le 0 ]; then break; fi
    "$bin" soak "$dir" "$left" "$keys" "$capacity" >> "$out" 2>&1 &
    pid=$!
    nap=$((60 + $(od -An -N2 -tu2 /dev/urandom) % 841))
    waited=0
    while [ "$waited" -lt "$nap" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid"
        wait "$pid" 2>/dev/null
        kills=$((kills + 1))
        echo "kill $kills at $(date -u +%FT%TZ): du $(du -sb "$dir" | cut -f1)" >> "$out"
    else
        wait "$pid"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "soak: FAIL, status $status, after $kills kills" >> "$out"
            exit 1
        fi
    fi
done
"$bin" fsck "$dir" >> "$out" 2>&1
status=$?
echo "soak: end $(date -u +%FT%TZ), $kills kills, fsck status $status, du $(du -sb "$dir" | cut -f1)" >> "$out"
exit "$status"
