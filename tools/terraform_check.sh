#!/usr/bin/env bash
# Terraform against CosmoStore's IAM (ADR-0108 §6, M21's bar): tools/terraform/main.tf's users, keys, groups,
# memberships, managed and inline policies, attachments and a role applied, planned with no change, the key used on
# S3, and destroyed, leaving no IAM record behind; on `serve`, then on a three-node cluster through one node. On
# `serve`, tools/terraform_tables/main.tf's S3 Tables configuration too (ADR-0126 §5).
#
#   tools/terraform_check.sh <cosmostore binary> [port base]
#
# Terraform is downloaded into TERRAFORM_DIR (default: a directory under $TMPDIR, kept between runs) and checked
# against the SHA-256 HashiCorp publishes, pinned below; `terraform init` checks the AWS provider's signature itself.
# It needs the network the first time, and the AWS CLI v2.
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
BIN="${1:?usage: tools/terraform_check.sh <cosmostore binary> [port base]}"
case "$BIN" in /*) ;; *) BIN="$ROOT/$BIN" ;; esac
BASE="${2:-19700}"
TF_VERSION=1.9.8
TF_DIR="${TERRAFORM_DIR:-${TMPDIR:-/tmp}/cosmostore-terraform}"
WORK=$(mktemp -d)
PIDS=()
failed=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
pause() { perl -e "select(undef, undef, undef, $1)"; }

cleanup() {
    exec 2> /dev/null # the shell's word on each node it stops
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    for i in $(seq 1 50); do
        alive=""
        for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
        [ -z "$alive" ] && break
        pause 0.2
    done
    for p in $alive; do kill -9 "$p" 2>/dev/null; done
    wait 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---- Terraform, pinned ----
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=darwin_arm64; sum=873d7b925d08578fb6bb9c12c7cd92ae73e289e07c360f2fdd69f9036b7baaab ;;
    Linux-x86_64) platform=linux_amd64; sum=186e0145f5e5f2eb97cbd785bc78f21bae4ef15119349f6ad4fa535b83b10df8 ;;
    *) echo "terraform check: no pinned Terraform for $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac
TF="$TF_DIR/$TF_VERSION/terraform"
if [ ! -x "$TF" ]; then
    mkdir -p "$TF_DIR/$TF_VERSION"
    zip="$TF_DIR/$TF_VERSION/terraform.zip"
    curl -sSf -o "$zip" "https://releases.hashicorp.com/terraform/$TF_VERSION/terraform_${TF_VERSION}_${platform}.zip" || {
        echo "terraform check: Terraform did not download" >&2; exit 2; }
    got=$(shasum -a 256 "$zip" 2>/dev/null || sha256sum "$zip")
    if [ "${got%% *}" != "$sum" ]; then echo "terraform check: Terraform's SHA-256 is not HashiCorp's" >&2; rm -f "$zip"; exit 2; fi
    (cd "$TF_DIR/$TF_VERSION" && unzip -qo terraform.zip terraform) || exit 2
fi
export TF_PLUGIN_CACHE_DIR="$TF_DIR/plugins" TF_IN_AUTOMATION=1 TF_INPUT=0
mkdir -p "$TF_PLUGIN_CACHE_DIR"

export AWS_ACCESS_KEY_ID=AKIATERRAFORMCHECK01 AWS_SECRET_ACCESS_KEY=terraformchecksecret0123456789 AWS_DEFAULT_REGION=us-east-1
export AWS_MAX_ATTEMPTS=6 AWS_RETRY_MODE=standard
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > "$WORK/credentials"
printf 'sts1 %s\n' "$(head -c 32 /dev/urandom | base64)" > "$WORK/sts.keys"

# The configuration applied, planned again with no change, its key used, and destroyed, against `endpoint`.
run() {
    local what="$1" endpoint="$2" dir="$WORK/tf-$1"
    mkdir -p "$dir" && cp "$ROOT/tools/terraform/main.tf" "$dir/"
    (cd "$dir" && "$TF" init -no-color > init.log 2>&1) && pass "$what: terraform init" || { fail "$what: terraform init"; tail -20 "$dir/init.log"; return; }
    if (cd "$dir" && "$TF" apply -no-color -auto-approve -var "endpoint=$endpoint" > apply.log 2>&1); then
        pass "$what: terraform apply"
    else
        fail "$what: terraform apply"; grep -B2 -A12 "Error" "$dir/apply.log" | head -60
    fi
    (cd "$dir" && "$TF" plan -no-color -detailed-exitcode -var "endpoint=$endpoint" > plan.log 2>&1)
    local planned=$?
    check "$what: a plan after it changes nothing" "$planned" 0
    [ "$planned" != 0 ] && grep -E "^  [#~+-]|will be|must be|Error" "$dir/plan.log" | head -40
    local id secret
    id=$(cd "$dir" && "$TF" output -raw key_id 2>/dev/null)
    secret=$(cd "$dir" && "$TF" output -raw key_secret 2>/dev/null)
    check "$what: the role's ARN, with its path" "$(cd "$dir" && "$TF" output -raw role_arn 2>/dev/null)" "arn:aws:iam::000000000000:role/svc/tf-deployer"
    aws --endpoint-url "$endpoint" s3api create-bucket --bucket tf-bucket > /dev/null 2>&1
    # The key works within an upkeep round (2 s): it lists by its inline policy, reads by its group's AWS policy,
    # writes by its group's and its attached policy, and no more.
    local ok=""
    for i in $(seq 1 30); do
        ok=$(AWS_ACCESS_KEY_ID="$id" AWS_SECRET_ACCESS_KEY="$secret" aws --endpoint-url "$endpoint" s3api put-object --bucket tf-bucket --key tf.txt --body "$ROOT/tools/terraform/main.tf" > /dev/null 2>&1 && echo yes)
        [ "$ok" = yes ] && break
        pause 0.5
    done
    check "$what: its key writes" "$ok" yes
    check "$what: and lists" "$(AWS_ACCESS_KEY_ID="$id" AWS_SECRET_ACCESS_KEY="$secret" aws --endpoint-url "$endpoint" s3api list-objects-v2 --bucket tf-bucket --query 'Contents[].Key' --output text 2>&1)" tf.txt
    check "$what: and no more" "$(AWS_ACCESS_KEY_ID="$id" AWS_SECRET_ACCESS_KEY="$secret" aws --endpoint-url "$endpoint" s3api create-bucket --bucket tf-other 2>&1 | sed -n 's/.*error occurred (\([A-Za-z0-9]*\)).*/\1/p' | head -1)" AccessDenied
    aws --endpoint-url "$endpoint" s3api delete-object --bucket tf-bucket --key tf.txt > /dev/null 2>&1
    aws --endpoint-url "$endpoint" s3api delete-bucket --bucket tf-bucket > /dev/null 2>&1
    if (cd "$dir" && "$TF" destroy -no-color -auto-approve -var "endpoint=$endpoint" > destroy.log 2>&1); then
        pass "$what: terraform destroy"
    else
        fail "$what: terraform destroy"; grep -B2 -A12 "Error" "$dir/destroy.log" | head -40
    fi
    local left
    left="$(aws --endpoint-url "$endpoint" iam list-users --query 'length(Users)' --output text 2>&1) $(aws --endpoint-url "$endpoint" iam list-groups --query 'length(Groups)' --output text 2>&1) $(aws --endpoint-url "$endpoint" iam list-roles --query 'length(Roles)' --output text 2>&1) $(aws --endpoint-url "$endpoint" iam list-policies --scope Local --query 'length(Policies)' --output text 2>&1)"
    check "$what: no user, group, role or policy left" "$left" "0 0 0 0"
}

# S3 Tables' configuration (ADR-0126 §5, tools/terraform_tables): a KMS table bucket with tags, and a tagged table
# taking its encryption, applied, read back through the CLI, planned with no change, and destroyed.
run_tables() {
    local what="$1" endpoint="$2" dir="$WORK/tft-$1"
    mkdir -p "$dir" && cp "$ROOT/tools/terraform_tables/main.tf" "$dir/"
    (cd "$dir" && "$TF" init -no-color > init.log 2>&1) && pass "$what: tables: terraform init" || { fail "$what: tables: terraform init"; tail -20 "$dir/init.log"; return; }
    if (cd "$dir" && "$TF" apply -no-color -auto-approve -var "endpoint=$endpoint" > apply.log 2>&1); then
        pass "$what: tables: terraform apply"
    else
        fail "$what: tables: terraform apply"; grep -B2 -A12 "Error" "$dir/apply.log" | head -60
    fi
    (cd "$dir" && "$TF" plan -no-color -detailed-exitcode -var "endpoint=$endpoint" > plan.log 2>&1)
    local planned=$?
    check "$what: tables: a plan after it changes nothing" "$planned" 0
    [ "$planned" != 0 ] && grep -E "^  [#~+-]|will be|must be|Error" "$dir/plan.log" | head -40
    local barn tarn
    barn=$(cd "$dir" && "$TF" output -raw bucket_arn 2>/dev/null)
    tarn=$(cd "$dir" && "$TF" output -raw table_arn 2>/dev/null)
    check "$what: tables: the bucket's encryption" "$(aws --endpoint-url "$endpoint" s3tables get-table-bucket-encryption --table-bucket-arn "$barn" --query '[encryptionConfiguration.sseAlgorithm,encryptionConfiguration.kmsKeyArn]' --output text 2>&1 | tr '\t' ' ')" "aws:kms arn:aws:kms:us-east-1:000000000000:key/orders"
    check "$what: tables: the bucket's tags" "$(aws --endpoint-url "$endpoint" s3tables list-tags-for-resource --resource-arn "$barn" --query tags.team --output text 2>&1)" data
    check "$what: tables: the table's encryption, its bucket's" "$(aws --endpoint-url "$endpoint" s3tables get-table-encryption --table-bucket-arn "$barn" --namespace sales --name orders --query encryptionConfiguration.sseAlgorithm --output text 2>&1)" aws:kms
    check "$what: tables: the table's tags" "$(aws --endpoint-url "$endpoint" s3tables list-tags-for-resource --resource-arn "$tarn" --query tags.stage --output text 2>&1)" raw
    if (cd "$dir" && "$TF" destroy -no-color -auto-approve -var "endpoint=$endpoint" > destroy.log 2>&1); then
        pass "$what: tables: terraform destroy"
    else
        fail "$what: tables: terraform destroy"; grep -B2 -A12 "Error" "$dir/destroy.log" | head -40
    fi
    check "$what: tables: no table bucket left" "$(aws --endpoint-url "$endpoint" s3tables list-table-buckets --query 'length(tableBuckets)' --output text 2>&1)" 0
}

# ---- serve ----
printf 'orders %s\n' "$(head -c 32 /dev/urandom | base64)" > "$WORK/kms.keys"
printf 'k1 %s\n' "$(head -c 32 /dev/urandom | base64)" > "$WORK/sse.keys"
"$BIN" serve "$WORK/store" "$BASE" "$WORK/credentials" localhost --maintain-seconds 2 --sts-key-file "$WORK/sts.keys" --sse-key-file "$WORK/sse.keys" --kms-key-file "$WORK/kms.keys" 2>> "$WORK/serve.log" &
PIDS[0]=$!
for i in $(seq 1 50); do aws --endpoint-url "http://127.0.0.1:$BASE" s3api list-buckets > /dev/null 2>&1 && break; pause 0.2; done
run serve "http://127.0.0.1:$BASE"
run_tables serve "http://127.0.0.1:$BASE"

# ---- a cluster, through node 1 ----
head -c 32 /dev/urandom | base64 > "$WORK/cluster.key"
cat > "$WORK/cluster.conf" <<EOF
cluster 00c1a55e5e0c1a56
shards 4
replicas 3
secret-file $WORK/cluster.key
node 1 peer=127.0.0.1:$((BASE + 1)) domain=a
node 2 peer=127.0.0.1:$((BASE + 2)) domain=b
node 3 peer=127.0.0.1:$((BASE + 3)) domain=c
EOF
for n in 1 2 3; do
    mkdir -p "$WORK/d$n"
    "$BIN" node "$WORK/d$n" --init --cluster-file "$WORK/cluster.conf" --node "$n" --listen $((BASE + 10 + n)) --credentials "$WORK/credentials" --sts-key-file "$WORK/sts.keys" --domain localhost >> "$WORK/log$n" 2>&1 &
    PIDS[$n]=$!
done
for i in $(seq 1 100); do
    leaders=$("$BIN" cluster-status --cluster-file "$WORK/cluster.conf" --node 1 2>/dev/null | tail -n +2 | grep -v "^#" | awk '$1 != 65535 && $4 != 0' | wc -l | tr -d ' ')
    [ "$leaders" = "4" ] && break
    pause 0.2
done
check "cluster: every shard has a leader" "$leaders" 4
run cluster "http://127.0.0.1:$((BASE + 11))"

if [ "$failed" = 0 ]; then echo "terraform check: all passed"; else echo "terraform check: FAILED"; fi
exit "$failed"
