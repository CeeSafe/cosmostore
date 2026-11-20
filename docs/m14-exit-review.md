# M14 exit review: configurations decided at delivery (20 Nov 2026)

**M14's exit (ROADMAP, M14; ADR-0094, proposed):** a user removed, or a policy narrowed, stops its configurations'
writes at the next one, on `serve` and on a cluster.

## How it was checked

- **The evidence:**
  - **Unit tests:** 389, with `configurationsRecordTheirRequester` and `writesDecidedAsTheirRequester`.
  - **The S3 smoke:** a user's replication and logs narrowed under a running server.
  - **The cluster smoke:** 167 checks; the same check across shards.
  - **The SDK matrix.**
- **A review by a reader who had not written the code:** two findings reproduced on `serve`.

## Findings

### A. To fix

1. **Medium: an inventory report on `serve` passes a Deny on a narrower key** (reproduced).
   - **Why:** the report is decided once, on its base prefix, and then every file is written.
   - **Reproduced:** a Deny on `wdst/inv/wsrc/i1/2*` did not stop the manifest.
   - **On a cluster:** each file is decided.
2. **Medium: a multipart replica refused on a cluster leaves its upload behind.**
   - **Why:** the check runs only at CompleteMultipartUpload, and a refused completion is not aborted.
   - **What stays:** the whole object, as an incomplete upload in a bucket the requester may no longer write.
3. **Medium: pending replicas can be written as the account's after the configuration changes.**
   - **Why:** the requester is read from the configuration as it is now. A rule deleted or re-pointed while events
     wait gives an empty requester, which is allowed.
   - **The scenario:** a user who lost the destination deletes its configuration, and the backlog is written.
   - **Also:** a configuration that does not decode also gives none.

### B. Smaller

1. **Low: a condition on a client's facts allows or denies** (reproduced), where ADR-0094 §2 says it neither.
   - **What happens:** a negated operator or `Null` holds for a missing key.
   - **The effect:** a common "deny unencrypted PutObject" policy (`Null s3:x-amz-server-side-encryption`) refused
     every delivery.
2. **Low: AccessDenied from a node's own front is now FAILED for good,** the account's included. That is intended,
   but ADR-0094 should say so, and that a user not yet in the destination leader's users file fails too.
3. **Low: two cases record no requester,** so a write is decided as the account: a role index out of range, and a
   user whose key was revoked during its request. Neither is reachable now; both should fail closed.
4. **Low: lookups are coarse.**
   - **The principal:** a user's last key is taken, so a bucket Deny naming one of its keys may not apply.
   - **Roles:** the roles file is read at start only.
   - **Sessions:** a role session is decided without its session policy, which is the owner's choice.
5. **Low, the ADR:** §4 names `x-cosmo-acting-as`; the field is `x-cosmo-replica-requester`.
6. **Open:** a single PUT replica refused before its body is read may see its connection closed, which reads
   "broken body", tried again for ever.

Checked and right:
- **The requester is recorded** on every put path, and an edit takes the configuration over.
- **Sessions:** a GetSessionToken session records its user, an AssumeRole session its role.
- **Roles:** a role's policy must allow first.
- **The cluster's field cannot be forged:**
  - the front drops it without the stamp;
  - `checkActingAs` wants a long-term key and the field signed;
  - plain `serve` refuses it.
- **The check comes before any state change** for single PUTs, markers, Complete, log objects and inventory files.
- **No stalls on `serve`.**
- **Formats** read older versions; ADR-0094's no-new-record claim holds.

## Verdict

**M14 should not close yet:** A1 to A3 each let a write past the requester's permissions, or leave its data where
it may not be. B1, B3, B5 and B6 are cheap and fixed with them. B2 and B4 go into ADR-0094.

Closing M14 and accepting ADR-0094 are the owner's decisions.

## The fixes (20 Nov 2026)

| Finding | Fix | Shown by |
|---|---|---|
| A1 | an inventory report is decided file by file, before each is written; a refusal stops it before its manifest | S3 smoke: a Deny on the report's dated keys; no manifest is written after it (a check that the count does not grow, as the first report may come before the Deny) |
| A2 | a replica's upload is decided at CreateMultipartUpload, before any part; a refused completion is aborted | (by reading) |
| A3 | each event keeps its targets' requesters, recorded when it is made (checkpoints carry them); a write is decided as that, whatever the configuration became | `eventsKeepTheirTargetsRequesters` |
| B1 | at delivery, a test of a client's fact holds for no write, whatever its operator; only `aws:SecureTransport` is the server's | `writesDecidedAsTheirRequester`: a Null Deny on encryption and a Null Allow on an address, neither applies |
| B3 | a requester that cannot be named records `user ` or `role `, refused; an empty user key matches no account key | `writesDecidedAsTheirRequester` |
| B6 | a 4xx answer is the answer, even with the body cut | (by reading) |
| B2, B4, B5 | in ADR-0094's amendments | |

**Checked after the fixes:** 390 unit tests, the S3 smoke, the cluster smoke (167) and the SDK matrix pass.
**Not done:** a cluster check of a refused multipart replica (A2), which the cluster smoke does not make.

## Closed (20 Nov 2026)

The owner accepted ADR-0094, as amended, and closed M14 ("Accept and close"). **Still recorded:**
- a cluster test of a refused multipart replica (A2's fix was made by reading);
- B4's coarse lookups.
