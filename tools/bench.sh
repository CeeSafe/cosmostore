#!/bin/sh
# Runs tools/bench (the M4 load generator, ADR-0021) against a fresh `cosmostore serve`, with the server's PID for
# RSS. Extra arguments go to the generator; the store and the server's log are left in $BENCH_DIR (default: a new
# temporary directory) for inspection.
#
# usage: tools/bench.sh [-sizes …] [-concurrency …] [-ops N] [-json out.json] [-label …]
#        (COSMOSTORE, PORT, BENCH_BIN override the server binary, the port, and a prebuilt generator)
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${COSMOSTORE:-$root/out/cosmostore}
port=${PORT:-9600}
dir=${BENCH_DIR:-$(mktemp -d)}
mkdir -p "$dir"
export AWS_ACCESS_KEY_ID=AKIABENCH00000000001 AWS_SECRET_ACCESS_KEY=bench/secret/0123456789abcdef
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > "$dir/credentials"
rm -rf "$dir/store"
"$bin" serve "$dir/store" "$port" "$dir/credentials" 2> "$dir/server.log" &
server=$!
trap 'kill "$server" 2>/dev/null' EXIT
gen=${BENCH_BIN:-}
if [ -z "$gen" ]; then
    gen="$dir/cosmostore-bench"
    (cd "$root/tools/bench" && go build -o "$gen" .) || exit 1
fi
sleep 1
"$gen" -endpoint "http://127.0.0.1:$port" -pid "$server" "$@"
status=$?
kill "$server"
wait "$server" 2> /dev/null
"$bin" fsck "$dir/store" > "$dir/fsck.out" 2>&1 || { echo "bench: fsck found problems"; cat "$dir/fsck.out"; status=1; }
exit "$status"
