#!/usr/bin/env bash
# S3 on a three-node cluster (ADR-0060, ADR-0061, M6 items 4 and 5): every call through one node and its effect seen through the
# others; a conditional write that sees the write before it, through another node; versioning, tags, copies, a
# batch delete; ListBuckets merged across shards, the same from every node; then the leader of a bucket's shard
# killed, and the run going on through the other nodes, every acknowledged write still there.
# Large objects (extents, ADR-0061): a 20 MB PUT and a 40 MB multipart upload through two nodes, read through a third;
# every node ends with every extent; they survive the leader's loss.
#
#   tools/cluster_s3_smoke.sh                ports 19500 and up
#   COSMO_PORT_BASE=29500 tools/cluster_s3_smoke.sh
set -u
cd "$(dirname "$0")/.."
BIN="$(pwd)/${COSMOSTORE:-out/cosmostore}"
BASE="${COSMO_PORT_BASE:-19500}"
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
cd "$WORK"

pass() { echo "ok   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1"; failed=$((failed + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
pause() { perl -e "select(undef, undef, undef, $1)"; }

export AWS_ACCESS_KEY_ID=AKIACLUSTERSMOKE0001 AWS_SECRET_ACCESS_KEY=clustersmokesecret0123456789 AWS_DEFAULT_REGION=us-east-1
export AWS_MAX_ATTEMPTS=6 AWS_RETRY_MODE=standard
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > credentials
head -c 32 /dev/urandom | base64 > cluster.key
cat > cluster.conf <<EOF
cluster 00c1a55e5e0c1a55
shards 8
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
EOF

# STS (ADR-0078 §2): the same token keys and roles on every node.
printf 'sts1 %s\n' "$(head -c 32 /dev/urandom | base64)" > sts.keys
cat > roles <<'ROLES'
reader 3600 {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::alpha","arn:aws:s3:::alpha/*"]}]}
ROLES
start() {
    mkdir -p "d$1"
    "$BIN" node "$WORK/d$1" --init --cluster-file cluster.conf --node "$1" --listen $((BASE + 10 + $1)) --credentials credentials --sts-key-file sts.keys --roles-file roles >> "log$1" 2>&1 &
    PIDS[$1]=$!
}
# The AWS CLI against node n's S3 port.
on() { local n="$1"; shift; aws --no-cli-pager --endpoint-url "http://127.0.0.1:$((BASE + 10 + n))" "$@"; }
code() { local n="$1"; shift; on "$n" "$@" 2>&1 | sed -n 's/.*error occurred (\([A-Za-z0-9]*\)).*/\1/p' | head -1; }
status() { "$BIN" cluster-status --cluster-file cluster.conf --node "$1" 2>/dev/null | tail -n +2 | grep -v "^#"; }

for n in 1 2 3; do start "$n"; done
# Every shard has a leader.
for i in $(seq 1 100); do
    leaders=$(status 1 | awk '$1 != 65535 && $4 != 0' | wc -l | tr -d ' ')
    [ "$leaders" = "8" ] && break
    pause 0.2
done
check "every shard has a leader" "$leaders" "8"

printf 'small object one' > one.txt
printf 'small object two' > two.txt
check "CreateBucket through node 1" "$(on 1 s3api create-bucket --bucket alpha --query Location --output text 2>&1)" "/alpha"
check "CreateBucket through node 2" "$(on 2 s3api create-bucket --bucket beta --query Location --output text 2>&1)" "/beta"
check "CreateBucket again through node 3" "$(code 3 s3api create-bucket --bucket alpha)" "BucketAlreadyOwnedByYou"
for n in 1 2 3; do
    check "ListBuckets through node $n, merged across shards" "$(on "$n" s3api list-buckets --query 'Buckets[].Name' --output text 2>&1)" "alpha	beta"
done

etag=$(on 2 s3api put-object --bucket alpha --key k/one --body one.txt --query ETag --output text 2>&1)
check "PutObject through node 2" "$etag" "\"$(md5 -q one.txt 2>/dev/null || md5sum one.txt | cut -d' ' -f1)\""
check "GetObject through node 3 sees it" "$(on 3 s3api get-object --bucket alpha --key k/one got.txt --query ETag --output text 2>&1 && cat got.txt)" "$etag
small object one"
check "HeadObject through node 1" "$(on 1 s3api head-object --bucket alpha --key k/one --query ContentLength --output text 2>&1)" "16"
check "If-None-Match * through node 1 sees the write through node 2" "$(code 1 s3api put-object --bucket alpha --key k/one --body two.txt --if-none-match '*')" "PreconditionFailed"
check "If-None-Match * on a new key" "$(on 3 s3api put-object --bucket alpha --key k/two --body two.txt --if-none-match '*' --query ETag --output text 2>&1 | wc -c | tr -d ' ')" "35"
check "ListObjectsV2 through node 2" "$(on 2 s3api list-objects-v2 --bucket alpha --query 'Contents[].Key' --output text 2>&1)" "k/one	k/two"

on 1 s3api put-bucket-versioning --bucket beta --versioning-configuration Status=Enabled > /dev/null 2>&1
check "versioning through node 1, seen through node 3" "$(on 3 s3api get-bucket-versioning --bucket beta --query Status --output text 2>&1)" "Enabled"
on 2 s3api put-object --bucket beta --key v --body one.txt > /dev/null 2>&1
on 3 s3api put-object --bucket beta --key v --body two.txt > /dev/null 2>&1
check "two versions, written through two nodes" "$(on 1 s3api list-object-versions --bucket beta --query 'length(Versions)' --output text 2>&1)" "2"
on 2 s3api put-object-tagging --bucket alpha --key k/one --tagging 'TagSet=[{Key=colour,Value=green}]' > /dev/null 2>&1
check "tags through node 2, read through node 1" "$(on 1 s3api get-object-tagging --bucket alpha --key k/one --query 'TagSet[0].Value' --output text 2>&1)" "green"
on 3 s3api copy-object --bucket alpha --key k/copied --copy-source alpha/k/two > /dev/null 2>&1
check "CopyObject within a bucket" "$(on 2 s3api get-object --bucket alpha --key k/copied got2.txt > /dev/null 2>&1 && cat got2.txt)" "small object two"
check "CopyObject between buckets of two shards: not yet" "$(code 1 s3api copy-object --bucket beta --key copied --copy-source alpha/k/two)" "NotImplemented"
check "DeleteObjects through node 1" "$(on 1 s3api delete-objects --bucket alpha --delete 'Objects=[{Key=k/two},{Key=k/copied}]' --query 'length(Deleted)' --output text 2>&1)" "2"
check "the delete seen through node 3" "$(code 3 s3api head-object --bucket alpha --key k/two)" "404"

# Large objects: extents pushed to a majority before their records are proposed (ADR-0061). A follower of alpha's shard
# is down while they are written, so it must fetch them when it comes back.
md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }
aShard=$(status 1 | awk '$1 != 65535' | sort -k7 -n -r | head -1 | awk '{ print $1 }')
aLeader=$(status 1 | awk -v s="$aShard" '$1 == s { print $4 }')
down=$(( aLeader % 3 + 1 ))
up=$(( down % 3 + 1 ))
[ "$up" = "$aLeader" ] || up="$aLeader"
kill -9 "${PIDS[$down]}" 2>/dev/null
wait "${PIDS[$down]}" 2>/dev/null
PIDS[$down]=""
live=()
for n in 1 2 3; do [ "$n" != "$down" ] && live+=("$n"); done
head -c 20000000 /dev/urandom > big.bin
head -c 41943040 /dev/urandom > huge.bin
check "node $down down: a 20 MB PUT through node ${live[0]}" "$(on "${live[0]}" s3api put-object --bucket alpha --key big --body big.bin --query ETag --output text 2>&1)" "\"$(md5of big.bin)\""
on "${live[1]}" s3 cp huge.bin s3://alpha/huge > /dev/null 2>&1
check "a 40 MB multipart upload through node ${live[1]}" "$(on "${live[0]}" s3api head-object --bucket alpha --key huge --query ContentLength --output text 2>&1)" "41943040"
on "${live[1]}" s3api get-object --bucket alpha --key big big.got > /dev/null 2>&1
check "the 20 MB object read through node ${live[1]}" "$(md5of big.got)" "$(md5of big.bin)"
on "${live[0]}" s3 cp s3://alpha/huge huge.got > /dev/null 2>&1
check "the multipart object read through node ${live[0]}, by ranges" "$(md5of huge.got)" "$(md5of huge.bin)"
extents() { find "d$1" -name 'ext-*.ce' | wc -l | tr -d ' '; }
check "the extents are on the two live nodes" "$([ "$(extents "${live[0]}")" -ge 6 ] && [ "$(extents "${live[0]}")" = "$(extents "${live[1]}")" ] && echo yes)" "yes"
start "$down"
for i in $(seq 1 75); do
    [ "$(extents "$down")" = "$(extents "${live[0]}")" ] && break
    pause 0.2
done
check "node $down back: it fetched the extents it missed" "$(extents "$down")" "$(extents "${live[0]}")"

# The leader of alpha's shard goes down; the others go on.
# Find alpha's shard by asking every node's status for the shard that has applied the most entries.
alphaShard=$(status 1 | awk '$1 != 65535' | sort -k7 -n -r | head -1 | awk '{ print $1 }')
leader=$(status 1 | awk -v s="$alphaShard" '$1 == s { print $4 }')
kill -9 "${PIDS[$leader]}" 2>/dev/null
wait "${PIDS[$leader]}" 2>/dev/null
PIDS[$leader]=""
other=$(( leader % 3 + 1 ))
third=$(( other % 3 + 1 ))
check "node $leader killed: a write through node $other goes on" "$(on "$other" s3api put-object --bucket alpha --key k/three --body two.txt --query ETag --output text 2>&1 | wc -c | tr -d ' ')" "35"
check "every acknowledged write is there, through node $third" "$(on "$third" s3api list-objects-v2 --bucket alpha --query 'Contents[].Key' --output text 2>&1)" "big	huge	k/one	k/three"
check "and its tags" "$(on "$third" s3api get-object-tagging --bucket alpha --key k/one --query 'TagSet[0].Value' --output text 2>&1)" "green"
check "ListBuckets with a node down" "$(on "$other" s3api list-buckets --query 'Buckets[].Name' --output text 2>&1)" "alpha	beta"
rm -f big.got huge.got
for i in $(seq 1 25); do
    on "$third" s3api get-object --bucket alpha --key big big.got > /dev/null 2>&1 && [ "$(md5of big.got)" = "$(md5of big.bin)" ] && break
    pause 0.4
done
check "the 20 MB object survives the leader's loss" "$(md5of big.got)" "$(md5of big.bin)"
on "$other" s3 cp s3://alpha/huge huge.got > /dev/null 2>&1
check "and the multipart one" "$(md5of huge.got)" "$(md5of huge.bin)"

# It comes back and serves too.
start "$leader"
for i in $(seq 1 50); do
    got=$(on "$leader" s3api head-object --bucket alpha --key k/three --query ContentLength --output text 2>/dev/null)
    [ "$got" = "16" ] && break
    pause 0.2
done
check "node $leader back: it serves the write made while it was down" "$got" "16"

# STS on a cluster (ADR-0078 §2): a session made through one node signs through the others, and a role narrows it.
read -r sk ss st <<< "$(on 1 sts get-session-token --duration-seconds 900 --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)"
check "get-session-token through node 1" "${sk:0:4}" ASIA
check "its session writes through node 2" "$(AWS_ACCESS_KEY_ID="$sk" AWS_SECRET_ACCESS_KEY="$ss" AWS_SESSION_TOKEN="$st" on 2 s3api put-object --bucket beta --key by-session --body one.txt --query ETag --output text 2>&1 | wc -c | tr -d ' ')" 35
read -r rk rs rt <<< "$(on 3 sts assume-role --role-arn arn:aws:iam::000000000000:role/reader --role-session-name smoke --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1)"
check "assume-role through node 3" "${rk:0:4}" ASIA
check "the role reads through node 1" "$(AWS_ACCESS_KEY_ID="$rk" AWS_SECRET_ACCESS_KEY="$rs" AWS_SESSION_TOKEN="$rt" on 1 s3api head-object --bucket alpha --key k/three --query ContentLength --output text 2>&1)" 16
check "but does not write through node 2" "$(AWS_ACCESS_KEY_ID="$rk" AWS_SECRET_ACCESS_KEY="$rs" AWS_SESSION_TOKEN="$rt" code 2 s3api put-object --bucket alpha --key no --body one.txt)" AccessDenied
check "nor read beta" "$(AWS_ACCESS_KEY_ID="$rk" AWS_SECRET_ACCESS_KEY="$rs" AWS_SESSION_TOKEN="$rt" code 1 s3api head-object --bucket beta --key by-session)" 403

echo "cluster s3 smoke: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
