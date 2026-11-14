# Runbooks

How to run a single CosmoStore node: what to do, what to look at, and what each thing costs. Every procedure here
is one the tests exercise (`tools/s3_smoke.sh`, `ceesafec test`); the ADR named beside it says why it works.

In the examples the server listens on `https://s3.example:9000`, its store is `/var/lib/cosmostore`, and

```sh
export AWS_ENDPOINT_URL=https://s3.example:9000 AWS_REGION=us-east-1
ADMIN="cosmostore admin https://s3.example:9000 /etc/cosmostore/credentials"
```

## Starting and stopping

- **Start:** `cosmostore serve /var/lib/cosmostore 0.0.0.0:9000 /etc/cosmostore/credentials [options]`. It reads
  the credentials, the targets file and the certificate, opens the audit log, then recovers the store (the newest
  checkpoint, then the journal after it) and listens. A file it cannot read stops it before recovery, with the
  reason on stderr.
- **Stop:** end the process. There is nothing to flush: a write is acknowledged only after it is synced
  (ADR-0001), so a stop at any moment, a `kill -9` included, loses no acknowledged write. Requests in progress
  fail and their clients retry.
- **Restart:** stop and start. Recovery replays the journal since the last checkpoint: seconds, unless the upkeep
  was failing (see *Watching it*).
- **Options are the command line.** Changing one is a restart. The credentials file and the certificate files
  are the exceptions: they are read again when they change.
- **One process per store.** Nothing else may open the directory while the server runs, `fsck` included.

## Watching it

- **`$ADMIN stats`** prints the server's counters as JSON. The ones that say something is wrong:

  | Field | Should be | If not |
  |---|---|---|
  | `eventsPending` | near 0 | a webhook is down or slow: *Event notifications* |
  | `eventsDropped` | 0 | events were lost to a full outbox: *Event notifications* |
  | `eventDeliveryFailures` | steady | rising: a webhook is failing now |
  | `auditLinesDropped` | 0 | the audit log cannot keep up or cannot be written: *The audit log* |
  | `rateLimited` | as you expect | clients are being slowed: *Rate limits* |
  | `journalRotationFailures` | 0 | the volume or the descriptors are short: *Space*, and ADR-0039 |
  | `uncheckpointedBytes` | under about 64 MiB | the upkeep is not checkpointing: read stderr |
  | `compactionDebtBytes` | not growing without end | the upkeep is behind: read stderr |
  | `volumeAvailableBytes` | well above the reserve (256 MiB) | *Space* |

- **`$ADMIN buckets`** prints every bucket with the versions and bytes it holds, its quota, its versioning, and
  which configurations it has (ADR-0054).
- **stderr** has the server's own events, one line each: the address it listens on, a 5xx it answered (with the
  path), a failed upkeep round, a journal failure (once), a certificate or credentials reload, an audit log that
  cannot be written. Keep it.
- **A 5xx** other than SlowDown is the server's fault and is on stderr. `ServiceUnavailable` on writes with
  reads still working is a failed journal: *Integrity*.

## Access keys

The credentials file has one `access-key secret-key` pair a line. The server reads it again when its modification
time changes, within one upkeep round (10 s unless `--maintain-seconds` says otherwise), and logs
`credentials reloaded: N keys accepted, M revoked` (ADR-0050).

- **Add a key:** append its line.
- **Rotate a key's secret:** change the secret on its line. The old secret stops working at the reload; there is
  no overlap, so update the clients at the same moment, or add a second key, move the clients, then remove the
  first.
- **Revoke a key:** delete its line. Until the reload (up to a round) it still works.
- **Write the file whole:** write a new file and rename it over the old one. A file caught half written is tried
  again the next round, and one with no key at all is refused (`credentials reload failed, keeping the keys in
  use`): the keys in use stay.
- **A policy that names a revoked key** keeps its statement, which then matches no one (ADR-0043).
- A server takes 4,095 reloads in its life; after that it says so and a restart takes the file as it is.
- **The `admin` command signs with the file's first line.** Keep an operator's key there.

## TLS certificates

Replace the certificate and key files in place (both, with the same names). The server loads them within a round
and logs `TLS certificate reloaded`; if they do not load it keeps the old ones and says so (ADR-0019). New
connections get the new certificate; open ones are not closed.

## Encryption keys

- **The key file** (`serve --sse-key-file <file>`, ADR-0046 §4) has one `<key id> <base64 of 32 bytes>` per line;
  `#` starts a comment. Make a key with `head -c 32 /dev/urandom | base64`. Key ids are 1 to 32 of
  `A-Z a-z 0-9 _ -`. The file is read once, at start; a file that does not parse stops `serve`. Without the option,
  a request for SSE-S3 is refused with `InvalidRequest`.
- **Keep it off the data's volume**, readable only by the server's user, and backed up apart from the data:
  whoever has both reads everything, and losing a key loses every object sealed under it.
- **Rotate:** put a new line first and keep the old ones, then restart. New objects are sealed under the first
  key; every key in the file opens what it sealed. An object stays under its key until it is written again.
- **An object whose key is not in the file** cannot be read: `InternalError`, and stderr says
  `an object is sealed under a master key that is not in the key file: <id>`. Put the key back and restart.
- `fsck` checks a sealed object's length and its extents' CRCs without the keys; its MD5 is the plaintext's, which
  only a GET checks, and every GET checks each chunk it reads.

## Space

- **The store refuses a write that would take the volume into its reserve** (256 MiB) with `InsufficientStorage`
  (507), before a byte is written (ADR-0006, ADR-0040). Deletes still work: a full store can always be emptied.
- **Find what uses it:** `$ADMIN buckets` gives each bucket's bytes. Those are the objects' sizes; `usedBytes` in
  the stats is what the store occupies, which is more: noncurrent versions, unfinished multipart uploads
  (`uploads` in the stats; aborted after `--upload-expiry-hours`, 168 by default), and space compaction has yet
  to give back (`compactionDebtBytes`).
- **Free it:** delete objects; in a bucket with versioning delete the *versions* (a delete without a version id
  only adds a marker), or put lifecycle rules for noncurrent versions (ADR-0042). Space returns as the upkeep
  compacts, over the next rounds.
- **Keep a bucket to a size:** `$ADMIN quota photos 107374182400 0` (100 GiB, any number of objects);
  `$ADMIN quota photos` shows the limits and the use; `$ADMIN quota photos off` takes it off (ADR-0052). Past it
  a write is `QuotaExceeded` (403); deletes are never refused. A quota below what the bucket holds deletes
  nothing: the bucket takes no more until it is under.

## Who can read a bucket

- **Is it public?** `aws s3api get-bucket-policy-status --bucket photos` answers for its policy and its ACL
  (ADR-0044, ADR-0045). `$ADMIN buckets` shows which buckets have a policy or an ACL at all.
- **Close it without touching its policy or ACLs:**

  ```sh
  aws s3api put-public-access-block --bucket photos --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  ```

  From the next request on, a public policy and public ACLs open nothing, the ACLs of single objects included
  (`IgnorePublicAcls`); keys are not affected. A policy that allows only fixed addresses is not public, and goes
  on working: remove it if those addresses should be closed too.
- **A policy that locks every key out** can still be replaced: a key is never refused the policy calls.
- **An anonymous request for a key that is not there** is 404 for a requester who may list the bucket and 403
  for one who may not; that is S3's behaviour, not a fault.

## Object Lock

- **A locked version cannot be removed through the API** until its retention ends and its legal hold is off:
  `AccessDenied`, for a delete that names it and for lifecycle rules alike (ADR-0047). A delete without a
  version id still succeeds: it writes a delete marker, and the version is still there.
- **See why:** `aws s3api get-object-retention --bucket b --key k --version-id v` and `get-object-legal-hold`.
- **Governance retention** gives way to `--bypass-governance-retention` on the delete, or on a
  `put-object-retention` that shortens it. **Compliance retention gives way to nothing,** for anyone, until its
  date: check a default retention's mode before you set one on a bucket.
- **The clock is the server's.** A server whose clock is wrong ends retentions early or late.
- **A bucket with locked versions cannot be deleted** until they can be. Its versioning cannot be suspended, and
  object lock cannot be taken off it.

## Event notifications

Rules live on the bucket (`put-bucket-notification-configuration`, queue configurations whose ARN is
`arn:cosmostore:sqs::<id>:webhook`); the webhooks they may name are the lines `<id> <url>` of the file given to
`--notify-targets`, read at start (ADR-0048).

- **Delivery is at least once, in order.** A webhook must answer 2xx; anything else is tried again after 1 s,
  doubling to 60 s. Consumers must accept an event twice, and order events of a key by `sequencer`.
- **A webhook is down:** `eventsPending` grows and `eventDeliveryFailures` rises. Nothing is lost while fewer
  than 100,000 events wait, across restarts and crashes too. **Events for other webhooks wait behind it:**
  delivery is one queue. Bring the webhook back, or remove the rules that name it (events already waiting for it
  still wait).
- **`eventsDropped` is above 0:** the outbox was full and the oldest events went. They are not recoverable from
  the server; list the bucket to find what changed.
- **Change the targets:** edit the file and restart. A rule whose target is no longer in the file stays, and its
  events are passed over.
- **`outbox.cursor`** in the store's directory says how far delivery has got. Leave it alone. Without it (deleted
  while the server is stopped) nothing is lost, and the events since the last checkpoint are delivered again.

## The audit log

`--audit-log /var/log/cosmostore/audit.log` appends a line of JSON for every request: `time`, `id` (the
`x-amz-request-id` the client saw), `remote`, `requester` (an access key, `anonymous`, or `-` for a request that
was not authenticated), `method`, `path`, `query` (the parameters' names only), `result` and `micros`
(ADR-0051).

- **Who deleted it?** `grep '"method":"DELETE"' audit.log | grep '"path":"/photos/cat.jpg"'`.
- **What did a key do?** `grep '"requester":"AKIA…"' audit.log`.
- **What was refused?** `grep '"result":"AccessDenied"' audit.log`.
- **Rotate it:** rename the file. The next batch begins a new one under the old name; no signal is needed.
- **It is written after the response.** A crash loses the last moments' lines, and a queue of 8,192 lines that
  fills drops lines and counts them (`auditLinesDropped`). If that count moves, the log's volume is too slow or
  full; `the audit log could not be written` on stderr says the writes are failing.
- **It holds no secret,** but it holds every key name and address: protect it as such.

## Rate limits

`--rate-limit-address <n>` and `--rate-limit-key <n>` set the most requests a second from one address and by one
access key (ADR-0053). Past them a request is `SlowDown` (503) with `Retry-After: 1`; the AWS SDKs wait and try
again by themselves.

- **Clients report SlowDown:** `rateLimited` in the stats counts them, and the audit log shows who
  (`grep '"result":"SlowDown"'`). Raise the limit (a restart) or slow the client.
- **Clients behind one address** (a NAT, a proxy) share its limit. No proxy header is trusted.
- The limits are the same for every key and address.

## CORS

A browser needs the bucket's CORS rules to allow the page's origin, the method and the headers the script sets
(`put-bucket-cors`, ADR-0049).

- **A preflight answered 403** means no rule allows that origin, method and those headers together; 400 means
  it sent no `Origin` or no `Access-Control-Request-Method`. Reproduce it:

  ```sh
  curl -i -X OPTIONS -H 'Origin: https://app.example' -H 'Access-Control-Request-Method: PUT' \
       -H 'Access-Control-Request-Headers: content-type' https://s3.example:9000/photos/cat.jpg
  ```

- **The request works from `curl` and not from the page:** CORS is the browser's to enforce. The server never
  refuses a request for its origin; it only leaves the `Access-Control-Allow-Origin` field out.

## Integrity

- **After a crash or a power loss:** start the server. Recovery is the normal start.
- **To check a store,** stop the server and run `cosmostore fsck /var/lib/cosmostore`. It reads every live
  object and checks its records, extents, size and MD5; it changes nothing and exits 1 if anything is wrong
  (ADR-0006).
- **The journal failed** (a write or sync error: stderr says so once, and writes answer `ServiceUnavailable`
  while reads go on): the store has stopped itself rather than acknowledge what it cannot make durable. Find the
  cause on the volume, then restart. Out of descriptors is not this: those requests get 503 and the store goes
  on (ADR-0039).
- **A read answers `InternalError`, or breaks off partway,** and stderr names the path: an object's bytes did
  not check. Run `fsck` to
  see how far it goes, and restore that object.

## Upgrades

- **A newer build reads an older store.** It writes its own checkpoint format at its next checkpoint (within
  minutes under load, or at 64 MiB of journal).
- **An older build does not read a newer store.** It refuses a newer checkpoint, and a journal with records it
  does not know (an ACL or a lock set on an object, a newer bucket configuration). Going back means restoring a
  backup taken before the upgrade.
- **So:** back up, upgrade, run `fsck` if you can afford the stop, and keep the backup until you are sure.
- The checkpoint format of each feature is in its ADR (formats 7 to 13 are ADR-0043 to ADR-0052).

## Backup

There is no backup command and no replication yet (M6).

- **A copy of the stopped store's directory** is a backup: stop, copy `/var/lib/cosmostore` whole, start.
- **A snapshot of the volume** taken while the server runs is what a crash would leave, which recovery is built
  for: restore it and start. Copying the directory file by file while the server runs is *not* a backup: the
  files change under the copy.
- Back up the credentials file, the targets file and the certificates beside it; they are not in the store.

## Not yet

- **Encryption at rest** is SSE-S3 on PutObject, GetObject and HeadObject (ADR-0046), with `serve --sse-key-file`.
  Multipart uploads, copies of a sealed object, POST forms, a bucket's default and SSE-C are not served yet: a
  request that asks for them is refused with `NotImplemented`, never stored in the clear. Keys, metadata, sizes and
  the ETag (the plaintext's MD5) are not encrypted; for those, encrypt the volume too.
- One node: no replication, no failover.
- No call to force a credentials reload or an upkeep round (both come within a round), nor to change an option
  without a restart.
