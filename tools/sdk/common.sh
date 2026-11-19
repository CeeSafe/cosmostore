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
# Users (ADR-0088): a user that may read the objects of `sdk-*-users` buckets, and nothing else.
echo "AKIASDKUSER000000001 sdkuser/secret/0123456789abcdefgh" >> "$work/credentials"
cat > "$work/users" <<'USERS'
sdkuser AKIASDKUSER000000001 {"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::sdk-*-users/*"}}
USERS
# SSE-S3's master key (ADR-0046 §4).
printf 'k1 %s\n' "$(head -c 32 /dev/urandom | base64)" > "$work/sse.keys"

# M7 (ADR-0072 to ADR-0077): STS's token key and a role that reads boto3's M7 bucket; access logs every 2 s, a 3 s
# inventory day, websites under web.localhost. Directory buckets (ADR-0080) in the zone local-az1.
printf 'sts1 %s\n' "$(head -c 32 /dev/urandom | base64)" > "$work/sts.keys"
cat > "$work/roles" <<'ROLES'
reader 3600 {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::sdk-m7","arn:aws:s3:::sdk-m7/*"]}]}
ROLES

"$bin" serve "$work/store" "$port" "$work/credentials" localhost --users-file "$work/users" --sse-key-file "$work/sse.keys" --sts-key-file "$work/sts.keys" --roles-file "$work/roles" --access-log-seconds 2 --inventory-day-seconds 3 --website-domain web.localhost --zone-id local-az1 2> "$work/server.log" &
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
