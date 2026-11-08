# Shared by the SDK matrix scripts (tools/sdk/*.sh): a fresh `cosmostore serve` on a temporary store, and check
# helpers. Source it; then $work is the temporary directory and $AWS_ENDPOINT_URL the server.
set -u
bin=$(cd "$(dirname "${COSMOSTORE:-out/cosmostore}")" && pwd)/$(basename "${COSMOSTORE:-out/cosmostore}")
port=${PORT:-9411}
work=$(mktemp -d)
trap 'kill "$server" 2>/dev/null; rm -rf "$work"' EXIT

export AWS_ACCESS_KEY_ID=AKIASDKMATRIX0000001
export AWS_SECRET_ACCESS_KEY=sdk/secret/0123456789abcdefghijklm
export AWS_DEFAULT_REGION=us-east-1
export AWS_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="http://127.0.0.1:$port"
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > "$work/credentials"

"$bin" serve "$work/store" "$port" "$work/credentials" localhost 2> "$work/server.log" &
server=$!
sleep 1

failed=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi; }

# Stops the server, runs fsck on what the client left, and reports; call last.
finish() {
    kill "$server"
    wait "$server" 2> /dev/null
    "$bin" fsck "$work/store" > "$work/fsck.out" 2>&1 && pass "fsck" || { fail "fsck"; cat "$work/fsck.out"; }
    if grep -q "Internal\|Unavailable" "$work/server.log"; then fail "server logged errors"; cat "$work/server.log"; fi
    [ "$failed" = 0 ] && echo "$1: all passed" || { echo "$1: FAILED"; grep "on /" "$work/server.log" | sort | uniq -c | head -20; }
    exit "$failed"
}
