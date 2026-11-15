#!/usr/bin/env bash
# Mutants of the Raft core (ADR-0057 §5): each breaks one rule, and the Raft tests must fail on it. Run after a
# change to src/cluster/raft.cee; a mutant that passes means the simulation or a directed test has lost its teeth.
# A mutant whose pattern no longer matches the source is reported as NOT APPLIED: update its pattern.
#
#   tools/raft_mutants.sh            all mutants
#   CEESAFEC=/path/to/ceesafec tools/raft_mutants.sh
set -u
cd "$(dirname "$0")/.."
C="${CEESAFEC:-ceesafec}"
SRC=src/cluster/raft.cee
KEEP=$(mktemp)
cp "$SRC" "$KEEP"
trap 'cp "$KEEP" "$SRC"; rm -f "$KEEP"' EXIT

survivors=0
mutant() {
    local name="$1" expr="$2"
    cp "$KEEP" "$SRC"
    perl -0pi -e "$expr" "$SRC"
    if cmp -s "$KEEP" "$SRC"; then
        echo "NOT APPLIED  $name"
        survivors=$((survivors + 1))
        return
    fi
    local out
    out=$("$C" test --filter raft 2>&1)
    if echo "$out" | grep -q " 0 failed"; then
        echo "SURVIVED     $name"
        survivors=$((survivors + 1))
    else
        echo "killed       $name: $(echo "$out" | grep -E '^test .* (failed|panicked)' | sed 's/^test //; s/ \.\.\. .*//' | tr '\n' ' ')"
    fi
}

mutant "old-term-commit" 's/if \(n > this\.commit && \(this\.termAt\(n\) \?\? 0\) == this\.term\)/if (n > this.commit)/'
mutant "no-up-to-date-check" 's/(fn isUpToDate\(borrow this, index: u64, term: u64\) -> bool \{)/$1 return true;/'
mutant "two-votes-a-term" 's/\(this\.vote == RAFT_NO_NODE \|\| this\.vote == m\.from\) && //'
mutant "read-before-own-commit" 's/if \(\(this\.termAt\(this\.commit\) \?\? 0\) != this\.term\) \{ return Ok\(false\); \}//'
mutant "commit-past-what-was-sent" 's/let commit = if \(leaderCommit < last\) leaderCommit else last;/let commit = leaderCommit.min(this.lastIndex());/'
mutant "read-unconfirmed" 's/if \(this\.quorum\(\) == 1 && this\.isVoter\(\)\) \{\n(\s*)this\.readyReads/if (true) {\n$1this.readyReads/'
# Membership changes (ADR-0062 §1).
mutant "two-changes-at-once" 's/        if \(this\.lastConfigIndex\(\) > this\.commit\) \{ return Ok\(null\); \}\n//'
mutant "change-before-own-commit" 's/(if \(this\.lastConfigIndex\(\) > this\.commit\) \{ return Ok\(null\); \}\n)\s*if \(\(this\.termAt\(this\.commit\) \?\? 0\) != this\.term\) \{ return Ok\(null\); \}\n/$1/'
mutant "learners-count" 's/(        for \(i in 0\.\.this\.peers\.length\) \{\n)            if \(!this\.peers\[i\]\.voter\) \{ continue; \}\n(            if \(matched\.push)/$1$2/'
mutant "two-voters-at-once" 's/this\.members\.voterChanges\(borrow m\) > 1/this.members.voterChanges(borrow m) > 2/'
mutant "read-on-one-answer" 's/if \(acks < this\.quorum\(\)\) \{ return Ok\(\); \}//'
mutant "snapshot-drops-a-matching-log" 's/if \(\(this\.termAt\(m\.index\) \?\? 0\) == m\.logTerm && this\.termAt\(m\.index\)\.isSome\(\)\)/if (false)/'

if [ "$survivors" -gt 0 ]; then
    echo "$survivors mutant(s) not killed"
    exit 1
fi
echo "all mutants killed"
