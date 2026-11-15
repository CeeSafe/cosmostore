# ADR-0063: Scrub, repair from a replica, health, rolling restarts (M6 item 7)

**Status:** proposed for M6 item 7 (ADR-0056 §8, item 7), 15 Nov 2026, under the owner's standing go-ahead; built
(`ObjectStore.scrubStep`, `repairRecord`, `quarantineExtent`, `Journal.repairAt`; `scrubForever` and
`/record-fetch` in the node; `cosmostore node --scrub-seconds`).

## Context

- **What a replica may hold that is wrong without knowing it:** a bit flipped in an extent file, or in a record of a
  sealed segment, after it was written and synced. Reads catch it (every record and every extent carries a CRC32C:
  ADR-0001, ADR-0003), but only when they happen, and only on the replica that answers. `cosmostore fsck` (ADR-0006)
  checks a single node's store whole, offline.
- **On a cluster every committed record and every extent is on a majority of replicas, byte for byte** (ADR-0058:
  followers write the leader's records as they are; ADR-0061: extents are copied whole). A damaged copy can be put
  right from another replica's.
- **Done when** (ADR-0056 item 7): a damaged extent or segment is found and repaired from a replica.

## Decision

1. **Scrub:** each replica walks its live versions in steps (a few hundred at a time, its store locked for each step
   only): an inline version's record is read and verified (header, body CRC, trailer), an extent read whole and
   checked against its manifest (its header, its length, the CRC32C of its bytes). Every `--scrub-seconds` (an hour
   by default) a node starts a pass over each of its replicas.
2. **An extent found damaged** is removed: the replica then lacks it, and fetching what is missing (ADR-0061 §3) puts
   a good copy back from another replica, checked against the manifest before it is installed.
3. **A record found damaged** is asked of the shard's other replicas (`POST /record-fetch`: the shard, the version's
   bucket, key and id, the record's length): a replica answers with its own live record of that version when it is
   whole and of that length. The record's bytes are the same on every replica (ADR-0058 §1), so the answer is written
   over the damaged one at its place in the segment, and synced. The answer is checked first: a valid record of that
   length whose payload has the version's MD5 (or, for a sealed object, whose length is the sealed length).
   This is the one write below a segment's synced end: a crash during it leaves the record damaged as it was, or
   repaired; the crash model (ADR-0004) assumes appends and is not asked to judge it.
4. **Health:** the status (ADR-0059 §7) adds a line per node, `# scrub <versions checked> <found damaged>
   <repaired>`, and a replica whose journal failed shows as `failed` (ADR-0001's fail-stop), as before.
5. **Rolling restarts:** nodes are restarted one at a time, each once the status shows its replicas caught up (their
   applied index the leader's); a cluster of three keeps a majority throughout. Every format a node reads loads its
   older versions (checkpoints 1 to 16, segments and records of format 1), so a node of a newer build reads an older
   one's files; a newer node's records an older build does not know (a Config record, say) it refuses rather than
   misreads, so a cluster is upgraded forwards, not back.

## Consequences

- A damaged copy is put right within a scrub pass, without an operator; a damage on every replica at once is still
  lost, as it would be on one node, and the scrub's log line says so.
- Scrub reads everything once an hour: about 1 MiB/s for 3.5 GiB a replica.

## Rejected

- **Rebuilding a damaged replica from a snapshot:** a voter that forgets its log can lose an entry a majority held;
  it would first have to leave its group and come back, a full copy for one bad record.
- **Repairs written as new records:** a Raft log has no local records (ADR-0058 §2).
