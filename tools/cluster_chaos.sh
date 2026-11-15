#!/usr/bin/env bash
# The chaos harness (ADR-0065, M6 item 9): the checker's self-test, then runs of tools/cluster_chaos.py against
# out/cosmostore, each a three-node cluster (five with NODES=5) under kills, pauses and partitions for SECONDS
# seconds, its history checked for linearizability. A failed run keeps its work directory (the nodes' logs, the
# history, the faults' times) and prints it.
#
#   tools/cluster_chaos.sh                      one run of 60 s
#   RUNS=5 SECONDS_EACH=120 NODES=5 tools/cluster_chaos.sh
set -u
cd "$(dirname "$0")/.."
RUNS="${RUNS:-1}"
EACH="${SECONDS_EACH:-60}"
NODES="${NODES:-3}"
python3 -I tools/cluster_chaos.py --self-test | tail -1 || exit 1
failed=0
for r in $(seq 1 "$RUNS"); do
    seed=${SEED:-$RANDOM$RANDOM}
    if ! python3 -I tools/cluster_chaos.py --binary "${COSMOSTORE:-out/cosmostore}" --seconds "$EACH" --nodes "$NODES" \
        --seed "$seed" --port-base "${COSMO_PORT_BASE:-20100}"; then
        failed=$((failed + 1))
    fi
done
echo "cluster chaos: $((RUNS - failed)) of $RUNS runs linearizable"
[ "$failed" -eq 0 ]
