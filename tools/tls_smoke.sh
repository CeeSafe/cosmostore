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
    2> server.log &
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
