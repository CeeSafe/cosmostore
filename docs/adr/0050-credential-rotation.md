# ADR-0050: Credential rotation

**Status:** accepted for M5 (item 7, second part), 14 Nov 2026, and built (`src/s3/request.cee`,
`src/s3/serve.cee`).

## Context

- **The credentials file** (ADR-0008) is read once, when `serve` starts. Adding a key, changing a secret or taking
  a key away meant a restart, which drops every connection and runs recovery.
- **Certificates already reload** (ADR-0019): the upkeep looks at the files' modification times each round and
  loads them again when they change, keeping the old ones if the new do not read.
- **Requests read the credentials on every signature check,** from many threads, without a lock, and remember a
  key by its place in the list: a policy's decision names the requester by it (ADR-0043).
- **What CeeSafe gives for sharing:** atomics, `Arc`, a blocking `Mutex` (not for async code), and `OnceLock`, a
  cell written once and read without a lock. No lock for readers and writers, no atomic swap of an owner.

## Decision

1. **The upkeep reloads the file when it changes.** Each round (`--maintain-seconds`, 10 s by default) it reads
   the file's modification time, and when that has changed reads and parses the file, on a worker thread.
   - A file that does not read, or holds no key, changes nothing: the keys in use stay. It is reported once and
     tried again each round, so a file caught half written is picked up when it is whole.
   - A file that holds the same keys and secrets changes nothing and is not reported.
   - A reload is reported on stderr with how many keys are accepted and how many are revoked, never a key.
2. **A reload makes a new set from the old one,** keeping every key's place:
   - a key of the old set that the file still has stays in its place, with the file's secret;
   - one the file no longer has stays in its place *revoked*: its secret is dropped and nothing it signs is
     accepted (InvalidAccessKeyId), nor may a policy name it when the policy is put;
   - the file's new keys follow, in the file's order. A revoked key that comes back takes its old place.
   - So a place taken from one set means the same key in every later set: a request that authenticated just
     before a reload is still that key when its policy is read after it.
3. **Sets are written once and never changed.** The server holds 4,096 cells, empty but the first; a reload
   writes the next cell and then stores its number, which is what a request reads to find the current set. A
   request under way keeps reading the set it began with. Old sets are kept until the process ends: a few hundred
   bytes each.
   - After 4,095 reloads no cell is left: the reload is refused and reported, the keys in use stay, and a restart
     takes the file as it is.
4. **What a change takes effect on:** requests that begin after the reload. A request already past its signature
   check finishes; a new secret needs no new connection. Each set has its own signing-key caches (ADR-0035).

## Consequences

- A key is added, rotated or revoked by editing the file: within one upkeep round, no restart.
- A revoked key stops being accepted at most one round after the file changes, not at once.
- The modification time is what is watched: a file replaced within the clock's resolution by another of the same
  time is not seen until it changes again.
- A policy that names a revoked key keeps the statement, which matches no one (ADR-0043 §3), until the key comes
  back.
- The 4,096 sets bound a server's reloads: one an hour is five months, one a day eleven years.

## Rejected

- **A lock around the credentials:** a blocking lock in async code, on every request; an async one, a suspension
  point on every request.
- **Swapping one list in place:** there is no primitive for it without a lock, and a place would mean one key
  before the swap and another after.
- **Removing a key's place when it is revoked:** every later key would move, and a request between its signature
  and its policy would become another key.
- **A signal or an admin call to reload:** something to send, where the certificates need nothing; the admin API
  of item 7 may add one.
- **Watching the file with the system's notifications:** lib/std has none, and a round of the upkeep is soon
  enough.
