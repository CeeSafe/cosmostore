#!/bin/sh
# TLS end to end (ADR-0016): a throwaway CA and server certificate, `cosmostore serve --tls-cert --tls-key` on all
# addresses, and the AWS CLI, curl and rclone over HTTPS, verifying the certificate. Then the refusals: plain HTTP to
# the TLS port, a client that does not trust the CA, and bad server setups. Exit status 1 if any check fails.
#
# usage: tools/tls_smoke.sh [COSMOSTORE] [PORT]     (defaults: out/cosmostore, 9443; needs openssl 3, the AWS CLI v2)
set -u
bin=$(cd "$(dirname "${1:-out/cosmostore}")" && pwd)/$(basename "${1:-out/cosmostore}")
port=${2:-9443}
openssl=${OPENSSL:-$(command -v /opt/homebrew/opt/openssl@3/bin/openssl || command -v openssl)}
work=$(mktemp -d)
server=0
trap 'kill "$server" 2>/dev/null; rm -rf "$work"' EXIT
cd "$work"

export AWS_ACCESS_KEY_ID=AKIATLSSMOKE00000001
export AWS_SECRET_ACCESS_KEY=tls/secret/0123456789abcdefghijk
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="https://localhost:$port"
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > credentials

failed=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
code() { aws "$@" 2>&1 | sed -n 's/.*error occurred (\([A-Za-z0-9]*\)).*/\1/p' | head -1; }
printf 'k1 %s\n' "$(head -c 32 /dev/urandom | base64)" > sse.keys

# A CA, and a certificate for localhost and 127.0.0.1 signed by it.
"$openssl" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj "/CN=CosmoStore test CA" \
    -keyout ca.key -out ca.pem 2> /dev/null
"$openssl" req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=localhost" \
    -keyout server.key -out server.csr 2> /dev/null
# Apple's TLS (the AWS CLI's CRT client on macOS) also requires serverAuth in an extended key usage.
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature\n' > san.ext
"$openssl" x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile san.ext \
    -out server.pem 2> /dev/null
[ -s server.pem ] && pass "certificate made" || fail "certificate made"

# Refused setups: they exit before the store is opened.
"$bin" serve store "0.0.0.0:$port" credentials --tls-cert server.pem > out.txt 2>&1
check "cert without key" "$(cat out.txt)" "--tls-cert and --tls-key go together"
"$bin" serve store "0.0.0.0:$port" credentials --tls-cert server.pem --tls-key ca.key > out.txt 2>&1
check "key of another certificate" "$(cat out.txt)" "the TLS certificate and key could not be used together"
"$bin" serve store "0.0.0.0:$port" credentials --tls-cert missing.pem --tls-key server.key > out.txt 2>&1
check "missing certificate" "$(sed 's/ (.*//' out.txt)" "cannot read the TLS certificate: cannot open it"
[ -e store ] && fail "a refused setup opened the store" || pass "a refused setup opens no store"

"$bin" serve store "0.0.0.0:$port" credentials --tls-cert server.pem --tls-key server.key --maintain-seconds 1 \
    --sse-key-file sse.keys 2> server.log &
server=$!
until curl -s -o /dev/null --cacert ca.pem "https://localhost:$port/"; do
    kill -0 "$server" 2> /dev/null || { fail "server exited"; cat server.log; exit 1; }
done
check "notice" "$(head -1 server.log)" "cosmostore: serving S3 over TLS on 0.0.0.0:$port"

# Clients that verify the certificate.
export AWS_CA_BUNDLE="$work/ca.pem"
head -c 12000000 /dev/urandom > big.bin
aws s3api create-bucket --bucket tls-smoke > /dev/null 2>&1 && pass "create-bucket over TLS" || fail "create-bucket over TLS"
aws s3 cp --only-show-errors big.bin s3://tls-smoke/big.bin > cp.txt 2>&1 &&
    aws s3 cp --only-show-errors s3://tls-smoke/big.bin got.bin >> cp.txt 2>&1
if cmp -s got.bin big.bin; then
    pass "multipart cp both ways over TLS"
else
    # What the client and the server said, so a failure on another machine (CI) can be read from its log.
    fail "multipart cp both ways over TLS"
    aws --version
    sed 's/^/  aws: /' cp.txt | tail -20
    sed 's/^/  server: /' server.log | tail -20
fi
check "TLS version" "$(curl -s -o /dev/null -w '%{ssl_verify_result} %{http_version}' --cacert ca.pem "https://localhost:$port/")" "0 1.1"
check "anonymous over TLS" "$(curl -s --cacert ca.pem "https://127.0.0.1:$port/" | sed -n 's/.*<Code>\(.*\)<\/Code>.*/\1/p')" AccessDenied
url=$(aws s3 presign s3://tls-smoke/big.bin --expires-in 60)
curl -s --cacert ca.pem "$url" | cmp -s - big.bin && pass "presigned GET over TLS" || fail "presigned GET over TLS"

if command -v rclone > /dev/null; then
    RCLONE_CONFIG_T_TYPE=s3 RCLONE_CONFIG_T_PROVIDER=Other RCLONE_CONFIG_T_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    RCLONE_CONFIG_T_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" RCLONE_CONFIG_T_ENDPOINT="$AWS_ENDPOINT_URL" \
    RCLONE_CONFIG_T_REGION=us-east-1 RCLONE_CONFIG_T_FORCE_PATH_STYLE=true \
        rclone --config /dev/null --ca-cert ca.pem lsf t:tls-smoke > rc.txt 2>&1
    check "rclone over TLS" "$(cat rc.txt)" "big.bin"
fi

# SSE-C (ADR-0046 §6): the request's key seals and opens; the key is never stored.
ckey=0123456789abcdef0123456789abcdef
other=fedcba9876543210fedcba9876543210
sc="--sse-customer-algorithm AES256 --sse-customer-key $ckey"
head -c 200000 /dev/urandom > c.bin
check "SSE-C put" "$(aws s3api put-object --bucket tls-smoke --key c.bin --body c.bin $sc --query SSECustomerAlgorithm --output text)" AES256
aws s3api get-object --bucket tls-smoke --key c.bin $sc got.bin > /dev/null 2>&1
cmp -s got.bin c.bin && pass "SSE-C get" || fail "SSE-C get"
aws s3api get-object --bucket tls-smoke --key c.bin $sc --range bytes=65000-140000 got.bin > /dev/null 2>&1
dd if=c.bin of=want.bin bs=1 skip=65000 count=75001 2> /dev/null
cmp -s got.bin want.bin && pass "SSE-C range" || fail "SSE-C range"
check "SSE-C head" "$(aws s3api head-object --bucket tls-smoke --key c.bin $sc --query '[SSECustomerAlgorithm,SSECustomerKeyMD5,ContentLength]' --output text | tr '\t' ' ')" "AES256 $(printf '%s' "$ckey" | "$openssl" dgst -md5 -binary | base64) 200000"
check "SSE-C get without the key" "$(code s3api get-object --bucket tls-smoke --key c.bin got.bin)" InvalidRequest
check "SSE-C head without the key" "$(code s3api head-object --bucket tls-smoke --key c.bin)" 400
check "SSE-C with another key" "$(code s3api get-object --bucket tls-smoke --key c.bin --sse-customer-algorithm AES256 --sse-customer-key $other got.bin)" InvalidRequest
check "SSE-C attributes without the key" "$(code s3api get-object-attributes --bucket tls-smoke --key c.bin --object-attributes ObjectSize)" InvalidRequest
# get-object-attributes takes the key as it is sent, in base64 with its MD5 (the CLI encodes it only for some calls).
b64=$(printf '%s' "$ckey" | base64)
kmd5=$(printf '%s' "$ckey" | "$openssl" dgst -md5 -binary | base64)
check "SSE-C attributes" "$(aws s3api get-object-attributes --bucket tls-smoke --key c.bin --object-attributes ObjectSize --sse-customer-algorithm AES256 --sse-customer-key "$b64" --sse-customer-key-md5 "$kmd5" --query ObjectSize --output text)" 200000
check "a key for an object in the clear" "$(code s3api get-object --bucket tls-smoke --key big.bin $sc got.bin)" InvalidRequest
check "the key is not stored" "$(grep -rl "$ckey" store | wc -l | tr -d ' ')" 0
aws s3 cp --only-show-errors big.bin s3://tls-smoke/c-mp.bin --sse-c AES256 --sse-c-key "$ckey" > cpc.txt 2>&1 \
    || { fail "SSE-C multipart cp"; tail -5 cpc.txt; grep -v '^cosmostore: serving' server.log | tail -5; }
aws s3 cp --only-show-errors s3://tls-smoke/c-mp.bin got.bin --sse-c AES256 --sse-c-key "$ckey" > /dev/null 2>&1
cmp -s got.bin big.bin && pass "SSE-C multipart both ways" || fail "SSE-C multipart both ways"
src="--copy-source tls-smoke/c.bin --copy-source-sse-customer-algorithm AES256 --copy-source-sse-customer-key $ckey"
aws s3api copy-object --bucket tls-smoke --key c-clear.bin $src > /dev/null 2>&1 || fail "SSE-C copy to the clear"
aws s3api get-object --bucket tls-smoke --key c-clear.bin got.bin > /dev/null 2>&1
cmp -s got.bin c.bin && pass "SSE-C copied to the clear" || fail "SSE-C copied to the clear"
check "SSE-C copied to SSE-S3" "$(aws s3api copy-object --bucket tls-smoke --key c-s3.bin $src --server-side-encryption AES256 --query ServerSideEncryption --output text)" AES256
aws s3api get-object --bucket tls-smoke --key c-s3.bin got.bin > /dev/null 2>&1
cmp -s got.bin c.bin && pass "SSE-C copied to SSE-S3 reads" || fail "SSE-C copied to SSE-S3 reads"
aws s3api copy-object --bucket tls-smoke --key c.bin $src --sse-customer-algorithm AES256 --sse-customer-key "$other" > /dev/null 2>&1 || fail "SSE-C sealed again under another key"
aws s3api get-object --bucket tls-smoke --key c.bin --sse-customer-algorithm AES256 --sse-customer-key "$other" got.bin > /dev/null 2>&1
cmp -s got.bin c.bin && pass "SSE-C under the new key" || fail "SSE-C under the new key"
check "SSE-C under the old key" "$(code s3api get-object --bucket tls-smoke --key c.bin $sc got.bin)" InvalidRequest
check "a copy without the source's key" "$(code s3api copy-object --bucket tls-smoke --key c-no.bin --copy-source tls-smoke/c.bin)" InvalidRequest

# Reload (ADR-0019): a new certificate and key in place of the old ones are served within a few upkeep rounds, and a
# broken key keeps the certificate that works.
served() {
    "$openssl" s_client -connect "127.0.0.1:$port" -servername localhost < /dev/null 2> /dev/null \
        | "$openssl" x509 -noout -fingerprint -sha256 2> /dev/null
}
first=$(served)
"$openssl" req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=localhost" \
    -keyout new.key -out new.csr 2> /dev/null
"$openssl" x509 -req -in new.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile san.ext \
    -out new.pem 2> /dev/null
cp new.key server.key
cp new.pem server.pem
wanted=$("$openssl" x509 -in new.pem -noout -fingerprint -sha256)
for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(served)" = "$wanted" ] && break; sleep 1; done
[ -n "$first" ] && [ "$first" != "$wanted" ] && [ "$(served)" = "$wanted" ] && pass "certificate reloaded" \
    || fail "certificate reloaded"
check "reload logged" "$(grep -c 'TLS certificate reloaded' server.log)" 1
printf 'not a key\n' > server.key
for i in 1 2 3 4 5 6 7 8 9 10; do grep -q "TLS reload failed" server.log && break; sleep 1; done
# Logged each round until the files are fixed, so only its presence is checked.
grep -q "TLS reload failed, keeping the old certificate" server.log && pass "broken key logged" || fail "broken key logged"
check "still the working certificate" "$(served)" "$wanted"
aws s3 ls s3://tls-smoke > /dev/null 2>&1 && pass "clients still served" || fail "clients still served"

# Refusals.
check "plain HTTP to the TLS port" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")" 000
check "client without the CA" "$(curl -s -o /dev/null -w '%{http_code}' "https://localhost:$port/" 2>&1)" 000
# Unset, not empty: with AWS_CA_BUNDLE set to an empty string, AWS CLI 2.34 accepted the unknown CA.
env -u AWS_CA_BUNDLE aws s3 ls s3://tls-smoke > /dev/null 2>&1 && fail "the AWS CLI must not trust an unknown CA" \
    || pass "the AWS CLI refuses an unknown CA"
check "still serving after refusals" "$(curl -s -o /dev/null -w '%{http_code}' --cacert ca.pem "https://localhost:$port/")" 403

aws s3 rm --recursive s3://tls-smoke/ > /dev/null 2>&1
aws s3api delete-bucket --bucket tls-smoke > /dev/null 2>&1 && pass "delete-bucket over TLS" || fail "delete-bucket over TLS"
kill "$server"
wait "$server" 2> /dev/null
"$bin" fsck store > fsck.out 2>&1 && pass "fsck" || { fail "fsck"; cat fsck.out; }
[ "$failed" = 0 ] && echo "tls smoke: all passed" || echo "tls smoke: FAILED"
exit "$failed"
