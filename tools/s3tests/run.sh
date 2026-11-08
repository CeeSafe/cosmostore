#!/bin/sh
# The Ceph s3-tests subset (M3 exit, ADR-0014) against `cosmostore serve`: the tests in tools/s3tests/subset.txt,
# all of which must pass, then fsck.
#
# usage: S3TESTS_DIR=<ceph/s3-tests checkout> S3TESTS_PYTHON=<python with its requirements> tools/s3tests/run.sh [all]
#   The checkout should be at the pinned commit below. With `all`, it instead runs every test outside the
#   out-of-scope markers and reports the counts, for reviewing the subset.
set -u
pinned=5b3987116eca0b4b8fa57d6b10f3db57bab196b6
here=$(cd "$(dirname "$0")" && pwd)
bin=$(cd "$(dirname "${COSMOSTORE:-out/cosmostore}")" && pwd)/$(basename "${COSMOSTORE:-out/cosmostore}")
port=${PORT:-9511}
tests=${S3TESTS_DIR:?set S3TESTS_DIR to a ceph/s3-tests checkout}
python=${S3TESTS_PYTHON:?set S3TESTS_PYTHON to a python with s3-tests requirements}
work=$(mktemp -d)
trap 'kill "$server" 2>/dev/null; rm -rf "$work"' EXIT

at=$(git -C "$tests" rev-parse HEAD 2>/dev/null)
[ "$at" = "$pinned" ] || echo "note: s3-tests is at $at, the subset was chosen at $pinned"

# The users s3-tests expects (its own sample keys), all known to the server.
cat > "$work/s3tests.conf" <<CONF
[DEFAULT]
host = 127.0.0.1
port = $port
is_secure = False
ssl_verify = False
[fixtures]
bucket prefix = cs3t-{random}-
[s3 main]
display_name = M. Tester
user_id = testid
email = tester@ceph.com
api_name =
access_key = 0555b35654ad1656d804
secret_key = h7GhxuBLTrlhVUyxSPUKUV8r/2EI4ngqJxD7iBdBYLhwluN30JaT3Q==
[s3 alt]
display_name = john.doe
email = john.doe@example.com
user_id = 56789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234
access_key = NOPQRSTUVWXYZABCDEFG
secret_key = nopqrstuvwxyzabcdefghijklmnabcdefghijklm
[s3 tenant]
display_name = testx\$tenanteduser
user_id = testx\$9876543210abcdef0123456789abcdef0123456789abcdef0123456789abcdef
access_key = HIJKLMNOPQRSTUVWXYZA
secret_key = opqrstuvwxyzabcdefghijklmnopqrstuvwxyzab
email = tenanteduser@example.com
tenant = testx
[iam]
email = s3@example.com
user_id = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
access_key = ABCDEFGHIJKLMNOPQRST
secret_key = abcdefghijklmnopqrstuvwxyzabcdefghijklmn
display_name = youruseridhere
[iam root]
access_key = AAAAAAAAAAAAAAAAAAaa
secret_key = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
account_id = RGW11111111111111111
user_id = RGW11111111111111111
email = account1@ceph.com
[iam alt root]
access_key = BBBBBBBBBBBBBBBBBBbb
secret_key = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
account_id = RGW22222222222222222
user_id = RGW22222222222222222
email = account2@ceph.com
CONF
printf '%s\n' "0555b35654ad1656d804 h7GhxuBLTrlhVUyxSPUKUV8r/2EI4ngqJxD7iBdBYLhwluN30JaT3Q==" \
    "NOPQRSTUVWXYZABCDEFG nopqrstuvwxyzabcdefghijklmnabcdefghijklm" \
    "HIJKLMNOPQRSTUVWXYZA opqrstuvwxyzabcdefghijklmnopqrstuvwxyzab" \
    "ABCDEFGHIJKLMNOPQRST abcdefghijklmnopqrstuvwxyzabcdefghijklmn" > "$work/credentials"

"$bin" serve "$work/store" "$port" "$work/credentials" 2> "$work/server.log" &
server=$!
sleep 1

# Features outside M3's scope (ADR-0014): auth v2, policies, encryption, IAM and STS, lifecycle, object lock,
# versioning, websites, Select, SNS, storage classes, and RGW-only behaviour (tagging is in since ADR-0017).
outside="auth_aws2 or bucket_policy or bucket_encryption or bucket_logging or bucket_logging_cleanup or cloud_transition or cloud_restore or encryption or fails_on_aws or group or group_policy or iam_account or iam_cross_account or iam_role or iam_tenant or iam_user or lifecycle or lifecycle_expiration or lifecycle_transition or object_lock or object_ownership or role_policy or session_policy or s3control or s3select or s3website or s3website_routing_rules or s3website_redirect_location or sns or sse_s3 or storage_class or test_of_sts or user_policy or versioning or webidentity_test or abac_test or appendobject or delete_marker or token_claims_trust_policy_test or token_principal_tag_role_policy_test or token_request_tag_trust_policy_test or token_resource_tags_test or token_role_tags_test or token_tag_keys_test"
cd "$tests"
if [ "${1:-}" = all ]; then
    S3TEST_CONF="$work/s3tests.conf" "$python" -I -m pytest -q -p no:cacheprovider -m "not ($outside)" \
        s3tests/functional/test_s3.py s3tests/functional/test_headers.py 2>&1 | tail -1
    status=0
else
    # shellcheck disable=SC2046
    S3TEST_CONF="$work/s3tests.conf" "$python" -I -m pytest -q -p no:cacheprovider $(cat "$here/subset.txt") \
        > "$work/pytest.out" 2>&1
    status=$?
    tail -1 "$work/pytest.out"
    [ "$status" = 0 ] || grep -E "^(FAILED|ERROR)|Error" "$work/pytest.out" | head -20
fi
kill "$server"
wait "$server" 2> /dev/null
"$bin" fsck "$work/store" > "$work/fsck.out" 2>&1 || { echo "FAIL fsck"; cat "$work/fsck.out"; status=1; }
if grep -q "Internal\|Unavailable" "$work/server.log"; then echo "FAIL server logged errors"; grep "Internal\|Unavailable" "$work/server.log" | sort | uniq -c; status=1; fi
[ "$status" = 0 ] && echo "s3-tests subset: all passed" || echo "s3-tests subset: FAILED"
exit "$status"
