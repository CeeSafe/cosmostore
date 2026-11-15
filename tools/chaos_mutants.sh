#!/usr/bin/env bash
# Mutants of the cluster's read path (ADR-0065 §6): each serves reads a way that can be stale, and a run of the chaos
# harness must find a history that is not linearizable. Run after changing the harness or how reads are served. A
# mutant whose pattern no longer matches the source is reported as NOT APPLIED: update its pattern. The source is put
# back, and out/cosmostore rebuilt from it, at the end.
#
#   tools/chaos_mutants.sh            all mutants, 45 s of chaos each
#   CEESAFEC=/path/to/ceesafec SECONDS_EACH=60 tools/chaos_mutants.sh
set -u
cd "$(dirname "$0")/.."
C="${CEESAFEC:-ceesafec}"
EACH="${SECONDS_EACH:-45}"
SRC=src/cluster/front.cee
KEEP=$(mktemp)
BINS=$(mktemp -d)
cp "$SRC" "$KEEP"
restore() {
    cp "$KEEP" "$SRC"
    rm -f "$KEEP"
    rm -rf "$BINS"
    "$C" build > /dev/null 2>&1 || echo "the original did not build again: run ceesafec build"
}
trap restore EXIT

survivors=0
mutant() {
    local name="$1" nemesis="$2" expr="$3"
    cp "$KEEP" "$SRC"
    perl -0pi -e "$expr" "$SRC"
    if cmp -s "$KEEP" "$SRC"; then
        echo "NOT APPLIED  $name"
        survivors=$((survivors + 1))
        return
    fi
    if ! "$C" build > "$BINS/$name.build" 2>&1; then
        echo "NOT BUILT    $name: $(grep -m1 error "$BINS/$name.build")"
        survivors=$((survivors + 1))
        return
    fi
    cp out/cosmostore "$BINS/$name"
    local out
    out=$(python3 -I tools/cluster_chaos.py --binary "$BINS/$name" --seconds "$EACH" --seed 11 --nemesis "$nemesis" 2>&1)
    if echo "$out" | grep -q "not linearizable"; then
        echo "killed       $name: $(echo "$out" | grep -m1 -A 12 "not linearizable")"
    else
        echo "SURVIVED     $name"
        survivors=$((survivors + 1))
    fi
}

# A leader that answers reads from its own store, with no ReadIndex round: an old leader cut off answers stale.
mutant "leader-reads-without-readindex" "isolate-leader" 's/(    let slot = borrow shared\.slots\[at\];\n    let id = shared\.readIds\.fetchAdd\(1\) \+ 1;\n)/$1    if ((await viewOf(slot)?).leads) { return await exchangeRaw(shared, slot.s3url.view(), raw, null, raw.body.view()); }\n/'
# Any replica answers a read from its own store: one cut off, or behind, answers stale.
mutant "replica-reads" "isolate,split,pause" 's/(    var turn = 0usize;\n    while \(true\) \{\n)/    if (!isWriteMethod(raw.method.view())) {\n        match (slotOf(shared, shard)) {\n            Some(at) => { return await exchangeRaw(shared, shared.slots[at].s3url.view(), raw, null, raw.body.view()); }\n            null => {}\n        }\n    }\n$1/'

if [ "$survivors" -gt 0 ]; then
    echo "$survivors mutant(s) not killed"
    exit 1
fi
echo "all mutants killed"
