# M33 exit review: hardening, M30's to M32's recorded Lows (26 Nov 2026)

**M33's exit (ADR-0131 item A; ADR-0132, with the owner's choices):** each of the twenty Lows M30, M31 and M32
recorded is fixed with a test, or kept with its reason.

## How it was checked

- **Unit tests:**
  - `tagRules` and `tableConfigurationRecords` (including a rename);
  - `compactionPermitsAreFair`;
  - `stagedBucketsFaultsSticky`, `stagedBucketsFaultsTorn`, and `stagedBucketsAreForWritesOnly` (a delete in a
    staged bucket);
  - `encryptedTableCompacted`: without the key, over plain metadata and sealed manifests, the job is Failed.
- **`iceberg_check.py`** (on `serve` and through a cluster's node): a refused call and a record expiration call in the
  table bucket's logs.
- **The maintenance smoke:** `--tables-compactions` 0 and 65 refused.
- **The Java SDK matrix** on 2.58.0, with logging.
- **The smokes and CI:** 547 unit tests, the cluster smoke (214), the maintenance smoke and the S3 smoke. Slice 3's
  perf gate failed once on the runner's noise, and passed on its rerun.
- **The review:** one agent read ADR-0132 and the code without my notes, and judged each Low closed or not. Its
  findings come from reading.

## Findings

### A. Fixed before closing

1. **Medium: M30 B9's fix silenced compaction.** The warehouse read that tells the unreferenced sweep a manifest did
   not open is compaction's too. Compaction then passed the error up, so a table whose manifests are sealed under a
   key not held failed with no job status.
   - **Fixed:** compaction takes that error as a missing manifest again, and its job is Failed.
   - **Test:** `encryptedTableCompacted`'s keyless run, over plain metadata so that the run reaches the manifests.
     It fails with the fix taken out.
2. **Low: a staged create's replacement removed the earlier configuration before writing its reservation.** A
   failed reservation write could leave the earlier staged table without its configuration. The reservation is now
   written first.
3. **Low: a rename left the configuration's name behind,** so the lookup by name always fell back to the scan. A
   rename now updates it.
4. **Low: leftovers of the IAM change.** The unreachable `NotReady` answer is removed, and two doc comments are back
   on their functions.
5. **The review's missing tests:** a delete in a staged bucket, a rename's name, and the keyless compaction above.

### B. Recorded, not fixed

1. **M30 B2's cleanup does not reach a cluster:** a create that fails after writing its configuration cannot delete
   it in the same request, as the record is not applied yet. It is rare (a metadata write failing), and the
   configuration is removed with its table bucket.
2. **Tag keys are matched without case in ASCII only:** `Env` and `env` are one key, `Ä` and `ä` two. This is as
   policy conditions match them.
3. **A refused request naming any table bucket that logs** is written into that bucket's logs, as S3 logs a refused
   request to a logged bucket.
4. **A compaction permit held by a cancelled task is never released.** Only the node's stop cancels one today. A
   future caller that times out a compaction would have to release it.
5. **M31 B4's margin** was not measured again. It took 1 to 2 s on each run here.

## The twenty Lows

- **M30:**
  - **Closed:** B2 (on `serve`; B1 above for a cluster), B3, B4, B5, B7 and B9.
  - **Kept with their reasons:** B6 and B8.
- **M31:**
  - **Closed:** B1, B2, B3, B5 and B6.
  - **Kept:** B4.
- **M32:**
  - **Closed:** B1, B2 and B6.
  - **Kept:** B3, B4 and B5.
