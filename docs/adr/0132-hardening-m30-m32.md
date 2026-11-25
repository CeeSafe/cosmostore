# ADR-0132: Hardening, M30's to M32's recorded Lows (M33)

**Status:** proposed, 25 Nov 2026. M33 is ADR-0131's item A (the owner: "A: hardening").

## Context

The Lows below are each exit review's B items: `docs/m30-exit-review.md`, `m31-exit-review.md` and
`m32-exit-review.md`. Each is decided here: fixed with a test, or kept with its reason.

## Decision (proposed)

### Slice 1: tags and configuration (M30's B2–B9)

| Low | Decision |
|---|---|
| M30 B2: configuration records orphaned | **Fix.** createTable removes its record on every failure after it is written. A staged create that replaces an earlier one of its name removes the earlier id's record. A staged create never committed keeps its one record per name, bounded as its reservation is. |
| M30 B3: tag keys differing only in case | **Fix, per the owner's choice below.** |
| M30 B4: tag lengths counted in bytes, character set unchecked | **Fix.** Lengths in characters (UTF-8 code points), as AWS counts them. Keys and values limited to AWS's set: letters, digits and spaces in UTF-8, and `+ - = . _ : / @`. |
| M30 B5: a pre-M30 table's storage class follows its bucket's current one | **Fix.** A table without a configuration record is STANDARD, the only class there was at its create. |
| M30 B6: `aws:ResourceTag` refused in identity policies | **Per the owner's choice below.** |
| M30 B7: a tag call on a table reads every table record of its bucket | **Fix.** Its configuration record (every table made since M30 has one) is looked for first, and the scan is kept only for older tables. |
| M30 B8: configuration writes unconditional | **Keep: not a race.** On `serve` the read and the write are one request under the store's lock. On a cluster a request runs only when its shard has applied everything (`stepReady`, `leadWrite`: applied = last), so it reads every earlier request's write. The exit review checks the reasoning again. |
| M30 B9: a sealed manifest under a key not held is reported as missing | **Fix.** The unreferenced sweep says it could not be opened. |

### Slice 2: clusters (M31's B1–B6)

| Low | Decision |
|---|---|
| M31 B1: deletes and other setters in a staged bucket | **Fix.** Deletes take a staged bucket as `checkPut` does (a delete in a bucket its request made deletes nothing, and is not refused). The setters already go through `setBucketConfig`. |
| M31 B2: the IAM bucket's `NotReady` workaround and `appliesOnCommit` | **Fix.** The IAM API makes its bucket in the request that first needs it, as a staged bucket lets it. `appliesOnCommit` goes, since `isReplica` is the same. |
| M31 B3: the compaction permit is not fair | **Fix.** A ticket semaphore: each compaction takes a ticket and runs once the tickets before it are within `--tables-compactions` of those released, in order. |
| M31 B4: the two-shard check's margin | **Keep.** The choice of shards is deterministic since M32. The margin is 15 s against a hold of 20 s, and the check took 1 to 2 s on every run. |
| M31 B5: the staged workload not swept for torn and sticky faults | **Fix.** Both sweeps added. |
| M31 B6: no test of `--tables-compactions` | **Fix.** The ticket semaphore is unit-tested (order, bound, release), and so are the option's limits. |

### Slice 3: logging (M32's B1–B6)

| Low | Decision |
|---|---|
| M32 B1: record expiration routed to shard 0 on a cluster | **Fix.** Routed by its `tableArn`, as GetTable is. |
| M32 B2: requests refused before their caller is known are not logged | **Fix.** A request refused before routing (no key, a refused signature, an Express token) is logged when it names a table bucket. Its requester and operation are `-` and its status is 403, as AWS logs a refused request. |
| M32 B3: a warehouse record's namespace and table name, and every record's bytes and size | **Keep.** Looking a table up by its id on every data request would cost a scan. Bytes sent and object size are `-` in S3's lines here too (ADR-0072). |
| M32 B4: the per-request cost on a cluster | **Keep.** A cluster's shards take some bucket to log (ADR-0078 §4), so each request reads its bucket's logging. That is S3's design, unchanged by M32. |
| M32 B5: a downgrade reads a partitioned logging value as none | **Keep.** A downgrade across a format change is not supported. A partitioned configuration is then off, never misread. |
| M32 B6: the Java SDK pinned in the matrix has no logging calls | **Fix.** The pin moves to the first release with them, if its other checks pass. If none passes, kept with that reason. |

### Slice 4: the exit review

## For the owner to decide

- **Tag keys differing only in case (M30 B3):**
  - **refused (recommended):** a tag whose key equals another's but for case is BadRequestException. Then
    `aws:ResourceTag/<key>`, which IAM matches without case, finds exactly one;
  - **kept, matched without case:** both are kept, and a condition finds the first.
- **`aws:ResourceTag` in identity policies (M30 B6):**
  - **kept refused (recommended):** an identity policy is also decided for S3 calls, which give no resource tags. A
    Deny on a tag would then never hold for those calls, so the condition is refused, never ignored;
  - **taken for S3 Tables' actions only:** the policy is parsed with tag conditions, and a statement naming S3
    actions with one is refused.

## Consequences

- **The recorded Lows of M30 to M32 are each closed,** fixed or kept with their reasons.
