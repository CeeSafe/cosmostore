# ADR-0025: Deletes through group commit

**Status:** accepted for M4 slice 5 (`src/store/object_store.cee`, `src/s3/server.cee`), 9 Nov 2026

## Context

- **ADR-0022 left DELETE out of group commit.** Each DeleteObject committed under the store's lock with a sync of its
  own (`deleteObject` calls `commitStaged`, then `commitOne`). That gave about 200 deletes/s at any concurrency, and a
  p99 of 600 to 800 ms at 128 clients.
- **It also held the lock across a sync,** so every request behind it waited about 5 ms, PUTs and GETs included.
- **A delete is a record like a PUT.** `DeleteVersion` is staged and applied by the same code (`stageDelete`,
  `applyRecord`), and a delete of a missing key applies as nothing.

## Decision

1. **`deleteObjectDeferred` stages a delete without committing it,** as `putFinishedDeferred` stages a PUT, and
   returns its record's LSN. The S3 handler acknowledges the delete (204) once `awaitPublished` says it is published.
   So deletes share leaders, batches and syncs with PUTs, and the lock is never held across their sync.
2. **The index shows only published writes,** so a key missing from it may still have a PUT staged or in flight. If
   anything is staged or in flight, the delete is written whether or not the key is in the index. It then applies
   after that PUT, in LSN order, and wins.
3. **Nothing to write is nothing to wait for.** If the key is missing and nothing is staged or in flight, the delete
   returns at once with no record, as before.
4. **Staging follows ADR-0022:** a full batch or a full segment is committed first (`stageDelete` now checks
   `needsRotation` as well as `wouldOverflow`).
5. **DeleteObjects (the batch, ADR-0010) still commits at once, under the lock.** It is one sync per request already.
   Staged together with other requests' records, a failure part way through would leave some of its deletes
   durable, and ADR-0010 promises that on an error none of them is.

## Rejected

- **Checking the staged records for the key** before writing a delete. That needs an index of the staged batch. A
  delete record of a key that turns out to be missing costs one small record, and only when other writes are
  pending.
- **Deferring DeleteObjects** with its records staged as one unit (all or none in a batch). The journal writes a
  batch as one write, but it has no notion of a unit inside it, and a torn write can keep a prefix.

## Consequences

- Deletes scale with concurrency like PUTs, and a delete no longer stalls the requests behind it.
- Bucket deletion, lifecycle expiry and the other mutations still commit under the lock, and take any batch in flight
  with them (ADR-0022), so a bucket is never found empty with a delete still unpublished in it.
- **Results** are in `docs/benchmarks/2026-11-09-group-deletes.md`.

## Tests

- `deferredDeletesFollowUnpublishedWrites` (`src/store/group_tests.cee`):
  - a delete of a missing key, with nothing staged, writes nothing;
  - a delete after an unpublished PUT of the same key is written after it, published with it, and wins;
  - a delete staged behind a batch in flight is published by the next commit, in order;
  - all of it survives a reopen.
- **Fault sweeps:** the group-commit workload (ADR-0022) now stages a delete while another batch syncs, and that
  delete is then taken in flight by `commitStaged`. Run once, sticky, torn and crash; the model acknowledges the
  delete exactly when the store says it is published.
- `ceesafec test` (113), `tools/s3_smoke.sh`, `tools/tls_smoke.sh`, the s3-tests subset, and the SDK checks.
- `tools/bench`, with fsck clean afterwards.
