# ADR-0030: p99 regression gates

**Status:** accepted for M4 (`tools/bench/gate`, `tools/perf_gate.sh`, `tools/bench/targets.json`,
`.github/workflows/ci.yml`), 9 Nov 2026

## Context

- **M4's exit asks for p99 regression gates in CI** (ROADMAP). The M4 reference
  (`docs/benchmarks/2026-11-09-m4-reference.md`) is what they guard.
- **The repository had no CI.** The checks of AGENTS.md ("Before finishing") ran by hand.
- **The reference's absolute numbers hold only on the reference machine** (docs/targets.md): an M1 laptop with
  `F_FULLFSYNC`, about 5 ms a sync. A hosted CI runner is a different machine, shared with other jobs, and its
  syncs cost something else. A gate of "p99 ≤ 25 ms" would measure the runner, not the change.
- **Noise on one machine is large and comes in bursts.** A first trial ran one build against a copy of itself:
  3 rounds of 40 phases, a phase failing when the head's median p99 rose more than 30% and 1 ms above the base's
  worst run. It failed 4 phases. The PUT p99 at concurrency 32 was 11 to 13 ms in one run and 24 to 52 ms in another,
  for the same binary, while another session's build ran. The later runs were the disturbed ones, and the head always
  ran second.
- **Short phases are the noisiest.** At 1,000 operations a small GET phase lasts 0.2 to 0.7 s. In later trials the
  same binary's 4 KiB GET had a p50 of 0.14 ms in one run and 0.44 to 0.53 ms in another, with other work on the
  machine (load average 10 to 48): a phase that short is at the mercy of which cores it gets.

## Decision

1. **The CI gate compares two builds, not a build with the reference.** `tools/perf_gate.sh BASE HEAD` runs
   `tools/bench` against each build in turns on the same machine: a round runs both, and the first build of a round
   alternates, so a drift (heat, other load) favours neither. The default matrix is 0 B, 1 KiB, 4 KiB and 1 MiB at
   concurrency 1 and 32, 1,000 operations a phase, 3 rounds. GET and HEAD phases of objects up to 64 KiB go over
   their keys 10 times (`tools/bench -read-repeat`, default 1, so other runs stay comparable), so they last seconds.
2. **Ratios within a round.** For each phase, the head's p99 and throughput are divided by the base's from the same
   round, and the phase's ratio is the median over the rounds. 2 ms is added to both p99s first, so jitter in a
   millisecond read does not count as a doubling.
3. **The gate fails on a group, not a phase.** A group is the phases one kind of change moves together, at one
   concurrency:
   - writes (PUT, overwrite, DELETE);
   - GETs that read a record;
   - metadata reads (HEAD, and GET of an empty object, which reads no record);

   each for small objects (up to 64 KiB) or large. DELETE and the metadata reads move no object bytes and count with
   the small objects at every size. A group fails when the geometric mean of its phases' ratios passes:
   - p99 × 1.25 for writes;
   - p99 × 1.5 for reads, whose p99 is a few milliseconds and, here, swung by up to 45% between identical builds (a
     read regression shows in throughput too);
   - throughput × 0.80 for every group.

   Noise moves single phases; a regression in the store moves a group.
4. **The gate measures its own noise.** Each group's noise is the geometric mean of its phases' spread among the
   base's own runs: the slowest round over the fastest, for p99 and for throughput.
   - A group past its tolerance but within its noise is reported as noisy, not failed.
   - When the median noise over the groups is above 2, the machine was too busy to tell. The run is inconclusive
     (exit 3) unless a phase failed. CI shows it as a warning, not a pass or a failure.
5. **Some checks are per phase, and do not depend on noise.** Any error fails. Syncs per 1,000 writes may not rise
   more than 25% plus 5: they do not depend on the machine's speed, and losing group commit shows there first (64
   becoming 1,000). These fail even in an inconclusive run.
6. **CI** (`.github/workflows/ci.yml`, on pushes to main and on pull requests, macOS 15 like the reference):
   - `check`: `ceesafec check`, `fmt --check`, `test`, then `build`, `tools/s3_smoke.sh` and `tools/tls_smoke.sh`;
   - `perf`: builds the head and the base (a pull request's base, or the commit before a push) and runs
     `tools/perf_gate.sh`. The report goes to the job's summary, and the results and the servers' logs are kept as
     an artifact.

   The compiler (`v0.24.2`) and CeeSafe.Web (by commit) are pinned, since `ceesafe.toml` uses CeeSafe.Web by path.
7. **The targets stay checkable on the reference machine.** `tools/bench/targets.json` writes docs/targets.md's
   T1 to T12 as data, and `gate -targets tools/bench/targets.json -run matrix.json -scale DIR` checks a run of the
   whole matrix and a `tools/scale.sh` run against them. On the M4 reference it gives what the reference's report
   says: T1 short at 4 KiB (2,908/s), T7 over in one phase (53.1 ms), T12 1.09 for the run, everything else met.

## Rejected

- **Absolute thresholds in CI.** They test the runner. A self-hosted runner on the reference machine would make them
  meaningful, but that machine is a shared laptop, and its own noise (above) is as large as most regressions.
- **A gate per phase.** With 40 phases and a tolerance one noisy run can pass, some phase fails on most runs.
- **p99.9 in the CI gate.** At 1,000 operations it is the slowest request or two. T7 stays a check of the reference
  run.
- **More rounds by default.** Each round takes about 4 to 5 minutes here, and more rounds do not help when a whole
  stretch of the run is disturbed. `ROUNDS` raises it.
- **Failing a run that is too noisy.** On a busy runner it would fail changes that are fine, and a gate that fails
  without cause is soon ignored.

## Consequences

- **The gate catches a regression of about a quarter in a group, not a few percent.** Smaller drifts show in the
  report's ratios, and the reference run, repeated at milestones, measures them.
- **On a busy runner, a regression in p99 or throughput alone passes as inconclusive,** with a warning. Losing group
  commit, or errors, still fail.
- **The tolerances come from this laptop under other sessions' load,** not from the CI runner. The first runs in CI
  measure the runner's noise (in each report), and the tolerances may move with them.
- **A push to main takes about 25 minutes of CI** for the gate, beside the checks.
- **The gate needs a base that builds:** with CeeSafe.Web and the compiler pinned, a base that needs newer ones
  fails the job (the pins move with such a change).

## Tests

The trials ran this machine's build (`7e99bb0`'s code) against a copy of itself, and against slice 3 (`767a811`):
from before inline reads left the store's lock (ADR-0024) and before deletes went through group commit (ADR-0025).
Each trial's results were scored again as the method changed.

| Trial | Load average | Groups | Verdict |
|---|---|---|---|
| Same build; 0 B, 4 KiB, 1 MiB; no read repeat | 3 to 6 | all within tolerance; noise 1.3 | passed |
| Same build; 4 sizes, no read repeat | 6 to 12 | two past tolerance, both within their noise; noise 2.8 | inconclusive |
| Same build; final settings | 19 to 48 | one past tolerance and its noise; noise 2.8 | inconclusive |
| Slice 3; 0 B, 4 KiB, 1 MiB; no read repeat | 3 to 12 | small writes at c32: p99 × 2.62, ops/s × 0.34; small GETs at c32: ops/s × 0.58; deletes at 1,000 syncs per 1,000; noise 1.5 | failed |
| Slice 3; final settings | 29 to 50 | small writes at c32 past ops/s and its noise (× 0.38); small GETs at c32 noisy (ops/s × 0.50 within a spread of 3.1); noise 3.3, so the groups are not trusted; deletes at 1,000 syncs per 1,000 | failed, on the syncs |

- **Targets mode** on the M4 reference (`2026-11-09-m4-reference.json` and `-1m.json`, and the scale run as
  `tools/scale.sh` leaves it in a directory): as stated in Decision 7.
