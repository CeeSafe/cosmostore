#!/bin/sh
# rclone against `cosmostore serve` (M3 SDK matrix): copy, check, sync, server-side copy and move, modification
# times, multipart (small chunks force it), listing and purge.
# usage: tools/sdk/rclone.sh   (COSMOSTORE, PORT override the binary and port)
. "$(dirname "$0")/common.sh"
export RCLONE_CONFIG_CS_TYPE=s3
export RCLONE_CONFIG_CS_PROVIDER=Other
export RCLONE_CONFIG_CS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export RCLONE_CONFIG_CS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_CS_ENDPOINT="$AWS_ENDPOINT_URL"
export RCLONE_CONFIG_CS_REGION=us-east-1
export RCLONE_CONFIG_CS_FORCE_PATH_STYLE=true
rc() { rclone --config /dev/null --s3-upload-cutoff 6M --s3-chunk-size 5M --s3-copy-cutoff 6M --low-level-retries 1 --retries 1 "$@"; }

cd "$work"
mkdir -p src/a/b
printf 'hello\n' > src/one.txt
head -c 200000 /dev/urandom > src/a/two.bin
head -c 12000000 /dev/urandom > src/a/b/big.bin   # multipart: 3 parts of 5 MiB
: > src/a/zero
printf 'x' > "src/a/sp ace & ü.txt"
touch -t 202001020304.05 src/one.txt

rc mkdir cs:rclone-test > rc.log 2>&1 && pass "mkdir" || { fail "mkdir"; cat rc.log; }
rc copy src cs:rclone-test/tree > rc.log 2>&1 && pass "copy up" || { fail "copy up"; tail -5 rc.log; }
rc check src cs:rclone-test/tree > rc.log 2>&1 && pass "check (sizes and hashes)" || { fail "check"; tail -5 rc.log; }
rc check --download src cs:rclone-test/tree > rc.log 2>&1 && pass "check --download (bytes)" || { fail "check --download"; tail -5 rc.log; }
check "modification time kept" "$(rc lsjson cs:rclone-test/tree/one.txt | sed -n 's/.*"ModTime":"\([^"]*\)".*/\1/p' | cut -c1-19)" "2020-01-02T03:04:05"
check "ls" "$(rc lsf -R cs:rclone-test/tree | sort | tr '\n' ' ')" "a/ a/b/ a/b/big.bin a/sp ace & ü.txt a/two.bin a/zero one.txt "
rc copy cs:rclone-test/tree down > rc.log 2>&1 && diff -r src down > /dev/null 2>&1 && pass "copy down" || { fail "copy down"; tail -5 rc.log; }
rc copyto cs:rclone-test/tree/a/b/big.bin cs:rclone-test/copied/big.bin > rc.log 2>&1 && pass "server-side copy (multipart)" || { fail "server-side copy"; tail -5 rc.log; }
rc cat cs:rclone-test/copied/big.bin | cmp -s - src/a/b/big.bin && pass "copied bytes" || fail "copied bytes"
rc moveto cs:rclone-test/tree/a/two.bin cs:rclone-test/moved/two.bin > rc.log 2>&1 && pass "server-side move" || { fail "server-side move"; tail -5 rc.log; }
check "moved source gone" "$(rc lsf cs:rclone-test/tree/a/ | grep -c two.bin)" 0
rm src/a/zero; printf 'changed\n' > src/one.txt
rc sync src cs:rclone-test/tree > rc.log 2>&1 && pass "sync" || { fail "sync"; tail -5 rc.log; }
check "sync deleted" "$(rc lsf cs:rclone-test/tree/a/ | grep -c zero)" 0
check "sync updated" "$(rc cat cs:rclone-test/tree/one.txt)" "changed"
rc check src cs:rclone-test/tree > rc.log 2>&1 && pass "check after sync" || { fail "check after sync"; tail -5 rc.log; }
check "size" "$(rc size --json cs:rclone-test | sed -n 's/.*"count":\([0-9]*\).*/\1/p')" 6
rc purge cs:rclone-test > rc.log 2>&1 && pass "purge" || { fail "purge"; tail -5 rc.log; }
check "bucket gone" "$(rc lsd cs: | grep -c " rclone-test$")" 0
check "no extents left" "$(ls store/extents | wc -l | tr -d ' ')" 0
finish "rclone"
