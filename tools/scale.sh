#!/bin/sh
# The M4 scale run (docs/targets.md T9 to T11): fills a fresh `cosmostore serve` with OBJECTS small objects in one
# bucket, then measures:
#   - memory: the server's footprint (RSS off macOS) before and after the fill, and after it has been idle (T9);
#   - listing: ListObjectsV2 pages of 1,000 at the first, middle and last keys (T10);
#   - recovery: the server is killed (SIGKILL, as a crash) and restarted; the time from launch to its first HTTP
#     answer is recovery plus startup, since `serve` opens the store before it listens (T11).
# Then listing again on the recovered store, and fsck. Results go to $OUT (JSON lines from the generator) and the
# summary to standard output.
#
# usage: OBJECTS=1000000 SIZE=128 CONC=128 OUT=dir tools/scale.sh
#        (COSMOSTORE, PORT, BENCH_BIN, BENCH_DIR as in tools/bench.sh)
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${COSMOSTORE:-$root/out/cosmostore}
port=${PORT:-9601}
objects=${OBJECTS:-1000000}
size=${SIZE:-128}
conc=${CONC:-128}
idle=${IDLE:-30}
dir=${BENCH_DIR:-$(mktemp -d)}
out=${OUT:-$dir}
mkdir -p "$dir" "$out"
export AWS_ACCESS_KEY_ID=AKIABENCH00000000001 AWS_SECRET_ACCESS_KEY=bench/secret/0123456789abcdef
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > "$dir/credentials"
rm -rf "$dir/store"
gen=${BENCH_BIN:-}
if [ -z "$gen" ]; then
    gen="$dir/cosmostore-bench"
    (cd "$root/tools/bench" && go build -o "$gen" .) || exit 1
fi

# The server's memory in MiB: its physical footprint on macOS (RSS drops when idle pages are compressed), else RSS.
rss() {
    if command -v footprint > /dev/null; then
        footprint -p "$1" | awk '/phys_footprint:/ { u = $3; v = $2; m = (u == "GB") ? 1024 : (u == "MB") ? 1 : (u == "KB") ? 1 / 1024 : 1 / 1048576; printf "%.1f", v * m; exit }'
    else
        ps -o rss= -p "$1" | awk '{printf "%.1f", $1 / 1024}'
    fi
}
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# Starts the server and waits for its first HTTP answer (any status). Sets `server` (its PID) and `took` (seconds).
# Not called in a subshell: the server would hold a command substitution's pipe open.
start() {
    t0=$(now)
    "$bin" serve "$dir/store" "$port" "$dir/credentials" >> "$dir/server.log" 2>&1 &
    server=$!
    while ! curl -s -o /dev/null "http://127.0.0.1:$port/"; do
        kill -0 "$server" 2> /dev/null || { echo "scale: the server exited" >&2; exit 1; }
        sleep 0.02
    done
    t1=$(now)
    took=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')
}
trap 'kill "$server" 2>/dev/null' EXIT
run() { "$gen" -endpoint "http://127.0.0.1:$port" -pid "$server" "$@"; }

status=0
start
first=$took
"$gen" -endpoint "http://127.0.0.1:$port" -mode bucket > /dev/null # creates the bucket, measures nothing
base=$(rss "$server")
echo "started in ${first}s, RSS ${base} MiB"
run -mode fill -objects "$objects" -sizes "$size" -concurrency "$conc" -json "$out/fill.json" || status=1
filled=$(rss "$server")
sleep "$idle"
idled=$(rss "$server")
run -mode list -objects "$objects" -json "$out/list.json" || status=1
listed=$(rss "$server")
echo "RSS: ${base} MiB empty, ${filled} after the fill, ${idled} after ${idle}s idle, ${listed} after listing"

kill -9 "$server"
wait "$server" 2> /dev/null
start
recovered=$took
after=$(rss "$server")
echo "recovered in ${recovered}s (SIGKILL, then launch to first answer), RSS ${after} MiB"
run -mode list -objects "$objects" -json "$out/list-recovered.json" || status=1

printf '{"objects": %s, "size": %s, "concurrency": %s, "rssEmptyMiB": %s, "rssFilledMiB": %s, "rssIdleMiB": %s, "rssListedMiB": %s, "recoverySeconds": %s, "rssRecoveredMiB": %s}\n' \
    "$objects" "$size" "$conc" "$base" "$filled" "$idled" "$listed" "$recovered" "$after" > "$out/summary.json"
cat "$out/summary.json"
kill "$server"
wait "$server" 2> /dev/null
"$bin" fsck "$dir/store" > "$dir/fsck.out" 2>&1 || { echo "scale: fsck found problems"; cat "$dir/fsck.out"; status=1; }
exit "$status"
