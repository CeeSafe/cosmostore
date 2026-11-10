#!/bin/sh
# The M4 comparison run: CosmoStore, SeaweedFS, Garage and RustFS on the same Linux host, one at a time, each in a
# container with the same CPU limit, its data on the same filesystem, measured by tools/bench from the host.
#
# usage: tools/compare/compare.sh SERVER CONFIG
#   SERVER  cosmostore | seaweedfs | garage | rustfs
#   CONFIG  durable (every fsync option on, compression off) | default (as shipped)
# Environment:
#   WORK      the directory for data and results (default /root/cosmostore-prof/cmp)
#   BENCH     tools/bench built for this host (default $WORK/../bench)
#   COSMOSTORE_BIN  the cosmostore binary (default $WORK/../bins/head); run in debian:trixie
#   CPUSET    cores to pin the server to (e.g. 2,3) instead of a CPU quota; a quota lets a busy server stall
#             for the rest of each 100 ms period, which shows in the p99 (ADR-0035)
#   CPUS (2), SIZES (0,4096,65536,1048576), CONCURRENCY (1,32,128), OPS (2000), READ_REPEAT (3)
# Needs Docker and the images below. Every server listens on loopback only (host network, no proxy).
set -eu
server=$1 config=$2
work=${WORK:-/root/cosmostore-prof/cmp}
bench=${BENCH:-$work/../bench}
cpus=${CPUS:-2}
if [ -n "${CPUSET:-}" ]; then limit="--cpuset-cpus $CPUSET"; else limit="--cpus $cpus"; fi
SEAWEEDFS_IMAGE=chrislusf/seaweedfs:4.53
GARAGE_IMAGE=dxflrs/garage:v2.5.0
RUSTFS_IMAGE=rustfs/rustfs:1.0.4
KEY=AKIABENCH00000000001
SECRET=bench/secret/0123456789abcdef
name=cmp-$server
run=$work/$server-$config
docker rm -f "$name" > /dev/null 2>&1 || true
rm -rf "$run" && mkdir -p "$run/data"

wait_for() { # url
    for _ in $(seq 1 120); do
        if curl -s -o /dev/null "$1"; then return 0; fi
        sleep 0.5
    done
    echo "compare: $server did not start"; docker logs "$name" 2>&1 | tail -20; exit 1
}

case $server in
cosmostore)
    port=19000
    [ "$config" = durable ] || [ "$config" = default ] # one configuration: it always syncs
    echo "$KEY $SECRET" > "$run/credentials"
    docker run -d --name "$name" --network host $limit -v "$run:/run-dir" \
        -v "${COSMOSTORE_BIN:-$work/../bins/head}:/cosmostore:ro" debian:trixie \
        /cosmostore serve /run-dir/data "127.0.0.1:$port" /run-dir/credentials > /dev/null
    wait_for "http://127.0.0.1:$port/"
    proc=cosmostore
    ;;
seaweedfs)
    port=8333
    printf '{"identities":[{"name":"bench","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}\n' \
        "$KEY" "$SECRET" > "$run/s3.json"
    # The image runs as user seaweed and gives it /data only.
    docker run -d --name "$name" --network host $limit -v "$run:/run-dir:ro" -v "$run/data:/data" \
        "$SEAWEEDFS_IMAGE" server -dir=/data -ip=127.0.0.1 -ip.bind=127.0.0.1 -s3 -s3.port=$port -s3.config=/run-dir/s3.json \
        -volume.max=0 -master.volumeSizeLimitMB=1024 > /dev/null
    wait_for "http://127.0.0.1:$port/"
    sleep 5 # the master assigns its first volumes
    if [ "$config" = durable ]; then
        # fsync for everything under /buckets/: volume data and index, and the filer's metadata (SeaweedFS 4.53).
        echo "fs.configure -locationPrefix=/buckets/ -fsync=true -apply" |
            docker exec -i "$name" weed shell -master=127.0.0.1:9333 -filer=127.0.0.1:8888 > "$run/fs.configure.txt" 2>&1
        grep -q '"fsync": *true' "$run/fs.configure.txt" || { echo "compare: fsync rule not applied"; cat "$run/fs.configure.txt"; exit 1; }
    fi
    proc=weed
    ;;
garage)
    port=3900
    fsync=false compression=1
    if [ "$config" = durable ]; then fsync=true compression='"none"'; fi
    cat > "$run/garage.toml" << EOF
metadata_dir = "/run-dir/data/meta"
data_dir = "/run-dir/data/data"
db_engine = "lmdb"
replication_factor = 1
metadata_fsync = $fsync
data_fsync = $fsync
compression_level = $compression
rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

[s3_api]
s3_region = "us-east-1"
api_bind_addr = "127.0.0.1:$port"
EOF
    docker run -d --name "$name" --network host $limit -v "$run:/run-dir" \
        -e GARAGE_CONFIG_FILE=/run-dir/garage.toml "$GARAGE_IMAGE" /garage server > /dev/null
    wait_for "http://127.0.0.1:$port/"
    g() { docker exec "$name" /garage -c /run-dir/garage.toml "$@"; }
    sleep 2
    node=$(g status 2> /dev/null | grep -oE '^[0-9a-f]{16}' | head -1)
    g layout assign -z dc1 -c 100G "$node" > /dev/null
    g layout apply --version 1 > /dev/null
    g key import --yes -n bench "$KEY" "$SECRET" > /dev/null
    g key allow --create-bucket "$KEY" > /dev/null
    proc=garage
    ;;
rustfs)
    port=19900
    mode=strict # its default; the same for both configurations
    chown -R 10001:10001 "$run/data"
    docker run -d --name "$name" --network host $limit -v "$run/data:/data" \
        -e RUSTFS_ACCESS_KEY="$KEY" -e RUSTFS_SECRET_KEY="$SECRET" -e RUSTFS_VOLUMES=/data \
        -e RUSTFS_ADDRESS="127.0.0.1:$port" -e RUSTFS_REGION=us-east-1 -e RUSTFS_CONSOLE_ENABLE=false \
        -e RUSTFS_DURABILITY_MODE=$mode "$RUSTFS_IMAGE" > /dev/null
    wait_for "http://127.0.0.1:$port/"
    proc=rustfs
    ;;
*)
    echo "compare: unknown server $server"; exit 2
    ;;
esac

pid=$(docker top "$name" -eo pid,comm | awk -v p="$proc" '$2 == p {print $1; exit}')
docker inspect "$name" --format '{{.Config.Image}}' > "$run/image.txt"
# Warm-up, the same for every server: 20 PUTs into the bucket, under keys no phase uses (size 7). SeaweedFS creates a
# bucket's volumes at its first write, which would otherwise land in the first measured phase.
# It is retried for a minute: RustFS answers 503 for a few seconds after it starts listening.
for _ in $(seq 1 60); do
    if AWS_ACCESS_KEY_ID=$KEY AWS_SECRET_ACCESS_KEY=$SECRET "$bench" -endpoint "http://127.0.0.1:$port" -sizes 7 \
        -concurrency 1 -ops 20 -phases put > "$run/warmup.md" 2>&1; then break; fi
    sleep 1
done
AWS_ACCESS_KEY_ID=$KEY AWS_SECRET_ACCESS_KEY=$SECRET "$bench" -endpoint "http://127.0.0.1:$port" -pid "${pid:-0}" \
    -sizes "${SIZES:-0,4096,65536,1048576}" -concurrency "${CONCURRENCY:-1,32,128}" -ops "${OPS:-2000}" \
    -read-repeat "${READ_REPEAT:-3}" -label "$server $config" -json "$run/bench.json" > "$run/bench.md" 2>&1 || status=$?
docker logs "$name" > "$run/server.log" 2>&1
docker rm -f "$name" > /dev/null
rm -rf "$run/data"
echo "$server $config: $(grep -c '^| [0-9]' "$run/bench.md") phases, status ${status:-0}"
exit "${status:-0}"
