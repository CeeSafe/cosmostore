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
    # Ten seconds to go; then a process still there is named and killed, so a run never hangs here (one once did,
    # 11 hours, on a node TERM had not stopped).
    for i in $(seq 1 50); do
        alive=""
        for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
        [ -z "$alive" ] && break
        perl -e 'select(undef, undef, undef, 0.2)'
    done
    if [ -n "$alive" ]; then
        echo "cluster smoke: still running after TERM:$alive; killed" >&2
        for p in $alive; do kill -9 "$p" 2>/dev/null; done
    fi
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

# Event notifications (ADR-0078 §4): a webhook the shards' leaders deliver to.
hookport=$((BASE + 40))
: > hook.out
python3 -I "$OLDPWD/tools/webhook.py" "$hookport" "$WORK/hook.out" &
PIDS[9]=$!
printf 'hook http://127.0.0.1:%s/events\n' "$hookport" > targets
# Replication to "another endpoint" (ADR-0078 §4): node 1's own front stands in for one.
printf 'far http://127.0.0.1:%s %s %s\n' "$((BASE + 11))" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" > reptargets
# STS (ADR-0078 §2): the same token keys and roles on every node.
printf 'sts1 %s\n' "$(head -c 32 /dev/urandom | base64)" > sts.keys
cat > roles <<'ROLES'
reader 3600 {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::alpha","arn:aws:s3:::alpha/*"]}]}
ROLES
start() {
    mkdir -p "d$1"
    "$BIN" node "$WORK/d$1" --init --cluster-file cluster.conf --node "$1" --listen $((BASE + 10 + $1)) --credentials credentials --sts-key-file sts.keys --roles-file roles --website-domain web.localhost --notify-targets targets --replication-targets reptargets >> "log$1" 2>&1 &
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

# A bucket's website on a cluster (ADR-0078 §3): configured through one node, served by every one.
on 1 s3api create-bucket --bucket site > /dev/null 2>&1
printf 'home' > home.html; printf 'oops' > oops.html
on 1 s3 cp home.html s3://site/index.html > /dev/null 2>&1
on 2 s3 cp oops.html s3://site/error.html > /dev/null 2>&1
on 3 s3api put-bucket-policy --bucket site --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::site/*"}]}' > /dev/null 2>&1
on 2 s3api put-bucket-website --bucket site --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"error.html"}}' > /dev/null 2>&1 && pass "put-bucket-website through node 2" || fail "put-bucket-website through node 2"
for n in 1 2 3; do
    port=$((BASE + 10 + n))
    check "the site through node $n" "$(curl -s -w ' %{http_code}' -H "Host: site.web.localhost:$port" "http://127.0.0.1:$port/")" "home 200"
done
check "its error document" "$(curl -s -w ' %{http_code}' -H "Host: site.web.localhost:$((BASE + 13))" "http://127.0.0.1:$((BASE + 13))/nothing")" "oops 404"

# Replication on a cluster (ADR-0078 §4): the source's shard's leader sends each replica through its node's front, to
# a bucket of another shard, with the source's version id and ETag; or to another endpoint.
shardOf() { python3 -c 'import hashlib,sys; d=hashlib.sha256(bytes.fromhex("00c1a55e5e0c1a55")+sys.argv[1].encode()).digest(); print(int.from_bytes(d[:8],"big") % 8)' "$1"; }
rdst=""
for c in rdst rdst1 rdst2 rdst3 rdst4 rdst5 rdst6 rdst7; do [ "$(shardOf "$c")" != "$(shardOf rsrc)" ] && { rdst=$c; break; }; done
on 1 s3api create-bucket --bucket rsrc > /dev/null 2>&1
on 2 s3api create-bucket --bucket "$rdst" > /dev/null 2>&1
on 3 s3api create-bucket --bucket faraway > /dev/null 2>&1
n=1
for b in rsrc "$rdst" faraway; do on "$n" s3api put-bucket-versioning --bucket "$b" --versioning-configuration Status=Enabled > /dev/null 2>&1; n=$((n % 3 + 1)); done
rconf='{"Role":"r","Rules":[{"ID":"here","Priority":1,"Status":"Enabled","Filter":{"Prefix":"r/"},"DeleteMarkerReplication":{"Status":"Enabled"},"Destination":{"Bucket":"arn:aws:s3:::RDST"}},{"ID":"far","Priority":2,"Status":"Enabled","Filter":{"Prefix":"f/"},"DeleteMarkerReplication":{"Status":"Enabled"},"Destination":{"Bucket":"arn:cosmostore:s3::far:faraway"}},{"ID":"lost","Priority":3,"Status":"Enabled","Filter":{"Prefix":"lost/"},"DeleteMarkerReplication":{"Status":"Disabled"},"Destination":{"Bucket":"arn:cosmostore:s3::far:nobucket"}}]}'
on 3 s3api put-bucket-replication --bucket rsrc --replication-configuration "${rconf/RDST/$rdst}" > /dev/null 2>&1 && pass "put-bucket-replication through node 3 (to $rdst, shard $(shardOf "$rdst"); the source's is $(shardOf rsrc))" || fail "put-bucket-replication through node 3"
printf 'replicate me' > r1.txt
head -c 9437184 /dev/urandom > r2.bin
on 1 s3api put-object --bucket rsrc --key r/small.txt --body r1.txt > /dev/null 2>&1
on 2 s3 cp r2.bin s3://rsrc/r/multi.bin > /dev/null 2>&1
on 3 s3api put-object --bucket rsrc --key f/small.txt --body r1.txt --metadata colour=blue > /dev/null 2>&1
on 1 s3api put-object --bucket rsrc --key lost/x.txt --body r1.txt > /dev/null 2>&1
status_of() { on "$1" s3api head-object --bucket rsrc --key "$2" --query ReplicationStatus --output text 2>/dev/null; }
replicated() {
    for i in $(seq 1 80); do [ "$(status_of 3 "$1")" = COMPLETED ] && return 0; pause 0.25; done
    return 1
}
for k in r/small.txt r/multi.bin; do
    replicated "$k" && pass "$k replicated" || fail "$k replicated: $(status_of 3 "$k")"
    sv=$(on 1 s3api head-object --bucket rsrc --key "$k" --query '[VersionId,ETag]' --output text 2>&1)
    check "$k keeps its version id and ETag, read through node 2" "$(on 2 s3api head-object --bucket "$rdst" --key "$k" --query '[VersionId,ETag]' --output text 2>&1)" "$sv"
    check "$k is a replica" "$(on 3 s3api head-object --bucket "$rdst" --key "$k" --query ReplicationStatus --output text 2>&1)" REPLICA
done
check "the same status through every node" "$(status_of 1 r/multi.bin) $(status_of 2 r/multi.bin)" "COMPLETED COMPLETED"
check "a multipart ETag" "$(on 1 s3api head-object --bucket "$rdst" --key r/multi.bin --query ETag --output text 2>&1 | grep -c -- '-2"')" 1
check "the multipart replica's bytes" "$(on 3 s3 cp "s3://$rdst/r/multi.bin" - 2>/dev/null | cmp -s - r2.bin && echo same)" same
check "its second part, by number" "$(on 2 s3api head-object --bucket "$rdst" --key r/multi.bin --part-number 2 --query ContentLength --output text 2>&1)" 1048576
marker=$(on 2 s3api delete-object --bucket rsrc --key r/small.txt --query VersionId --output text 2>&1)
for i in $(seq 1 40); do
    got=$(on 3 s3api list-object-versions --bucket "$rdst" --prefix r/small.txt --query 'DeleteMarkers[0].VersionId' --output text 2>/dev/null)
    [ "$got" = "$marker" ] && break
    pause 0.25
done
check "a delete marker replicated with its id" "$got" "$marker"
replicated f/small.txt && pass "to another endpoint: replicated" || fail "to another endpoint: replicated: $(status_of 3 f/small.txt)"
check "its ETag there" "$(on 2 s3api head-object --bucket faraway --key f/small.txt --query ETag --output text 2>&1)" "$(on 1 s3api head-object --bucket rsrc --key f/small.txt --query ETag --output text 2>&1)"
check "its metadata there" "$(on 2 s3api head-object --bucket faraway --key f/small.txt --query Metadata.colour --output text 2>&1)" blue
for i in $(seq 1 60); do [ "$(status_of 2 lost/x.txt)" = FAILED ] && break; pause 0.25; done
check "a destination that refuses: FAILED, through every node" "$(status_of 1 lost/x.txt) $(status_of 2 lost/x.txt) $(status_of 3 lost/x.txt)" "FAILED FAILED FAILED"

# Event notifications on a cluster (ADR-0078 §4): the shard's leader delivers, and a new one goes on.
keys() { python3 -c 'import json,sys
print(" ".join(json.loads(l)["Records"][0]["s3"]["object"]["key"] for l in open(sys.argv[1]) if l.strip()))' hook.out; }
on 1 s3api create-bucket --bucket events > /dev/null 2>&1
on 2 s3api put-bucket-notification-configuration --bucket events --notification-configuration '{"QueueConfigurations":[{"Id":"all","QueueArn":"arn:cosmostore:sqs::hook:webhook","Events":["s3:ObjectCreated:*"]}]}' > /dev/null 2>&1 && pass "a notification rule through node 2" || fail "a notification rule through node 2"
for n in 1 2 3; do on "$n" s3api put-object --bucket events --key "e$n" --body one.txt > /dev/null 2>&1; done
for i in $(seq 1 50); do [ "$(keys)" = "e1 e2 e3" ] && break; pause 0.2; done
check "three writes through three nodes, delivered in order" "$(keys)" "e1 e2 e3"
eventsShard=$(python3 -c 'import hashlib; d=hashlib.sha256(bytes.fromhex("00c1a55e5e0c1a55")+b"events").digest(); print(int.from_bytes(d[:8],"big") % 8)')
eventsLeader=$(status 1 | awk -v s="$eventsShard" '$1 == s { print $4 }')
kill -9 "${PIDS[$eventsLeader]}" 2>/dev/null
wait "${PIDS[$eventsLeader]}" 2>/dev/null
PIDS[$eventsLeader]=""
survivor=$(( eventsLeader % 3 + 1 ))
for i in $(seq 1 25); do on "$survivor" s3api put-object --bucket events --key e4 --body one.txt > /dev/null 2>&1 && break; pause 0.4; done
for i in $(seq 1 100); do keys | grep -q "e4$" && break; pause 0.2; done
check "its leader (node $eventsLeader) killed: the next leader delivers" "$(keys | tr ' ' '\n' | tail -1)" e4
check "and nothing delivered before is lost" "$(keys | tr ' ' '\n' | sort -u | tr '\n' ' ')" "e1 e2 e3 e4 "

echo "cluster s3 smoke: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
