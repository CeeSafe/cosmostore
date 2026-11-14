# ADR-0058: The journal as the Raft log (M6 item 2)

**Status:** accepted for M6 item 2 (ADR-0056 §3), 14 Nov 2026, as recommended (the owner: "I accept ADR-0058 as recommended"), asked for by the owner ("go ahead with item 2"). Slices a and b are built.

## Context

- **ADR-0056 §3** puts each shard's Raft log in its journal: a replicated record carries its index and term, local
  records carry neither, the index is applied up to the commit index, an uncommitted suffix is cut off, a checkpoint
  is the snapshot. Building it turned up what that sentence leaves out.
- **The LSN is state, not only order.** A version's generation is its record's LSN (`ObjectVersion.lsn`):
  conditional writes compare it, `Relocate` matches it, a completed upload and the event outbox are keyed by it. If
  replicas gave one record different LSNs, they would answer the same request differently. Every replica must give a
  record the same LSN.
- **Local records break that.** Compaction's `Relocate` (ADR-0005) is written by one node for its own segments. It
  takes an LSN, so the next replicated record's LSN would differ from node to node; and written after entries that
  are not yet committed, it could be cut off with them, losing the only copy of a payload whose old segment was
  already deleted.
- **A checkpoint seals the active segment** (ADR-0005 §2) so that every record after its LSN is in a later segment.
  A replica nearly always holds entries it has not applied yet (a follower learns the commit index one round after
  the entries; a leader's last entries wait for a quorum), so the moment when nothing follows the applied index
  rarely comes under load.
- **The core keeps its log in memory** (ADR-0057 consequences): up to a checkpoint's worth (64 MiB) per shard, and a
  node holds a replica of most shards. Too much once there are 16 shards.
- **What the journal already has:** a `term` field in every record (0 so far), a `flags` field in the segment
  header, `truncateTo` through `DurableFile` with the crash model tracking it, LSNs that need only increase.

## Decision

1. **In a cluster shard every record is a Raft entry, and its LSN is its Raft index.** The record's `term` field is
   the entry's term (at least 1). Record layout and record types do not change; the segment header's `flags` bit 0
   marks a Raft log, and opening refuses a segment whose bit differs from the shard's mode, so a single-node journal
   (bit 0 clear, term 0, as today) is never taken for a cluster's or the other way round.
2. **No local records.** Compaction becomes the leader's: it proposes its `Relocate` records like any write, with the
   payloads in them, and every replica applies them to its own copy (the moved version is the same version on every
   replica; only where its payload lands differs). Followers do not compact on their own. Deleting a segment stays
   local: a replica removes a segment that its checkpoint covers and that holds nothing live, as now.
3. **A checkpoint need not seal.** A checkpoint at applied index L records the segment that holds entry L + 1 (or the
   active segment when there is none), and recovery scans from that segment, skipping records up to L. Single-node
   checkpoints keep sealing as before; their files are read the same way. Only segments wholly at or below L may be
   compacted away.
4. **A segment is sealed only when its last entry is committed.** Rotation waits for the commit index
   (`Journal.markCommitted`), so every uncommitted entry is in the active segment, and cutting off a suffix touches one
   file: `Journal.truncateAfter(lsn)` cuts the active segment at the end of entry `lsn`, syncs it, and staging resumes
   at `lsn + 1`. Cutting below the commit index is a bug and panics (ADR-0057's checker forbids it in the simulation).
   The sync comes before any new entry is written: otherwise a crash could keep the new entries and, after them, the
   old suffix's, a log no leader ever had. The crash model treats a truncation as durable at once, so it cannot catch a
   missing sync there; the code has it, and recovery refuses a term that goes down along the log. A leader reads an
   entry for a follower by its LSN (`Journal.entryBytes`): the journal keeps the position of every 64th entry and of
   each segment's first, and reads forward from the nearest.
5. **The hard state is a file of its own** (`src/cluster/hard_state.cee`): records of (sequence, term, vote, CRC32C)
   appended to `raft-state.0` or `raft-state.1` and synced one by one, before any message that depends on them is
   sent; the valid record with the highest sequence in either file is the state, and a torn last record is cut off
   when the file is opened. At 4 KiB the next save starts the other file afresh (created, written, synced, its
   directory synced). Files are only appended to and never renamed, which is what the crash model (ADR-0004) can
   judge: a first design that overwrote two slots in place was a violation of its assumption, and one that rewrote
   through a rename lost the file, since the model drops a renamed file whose directory was not synced. The commit
   index is not synced: a checkpoint's L is a lower bound, and the leader tells the rest.
6. **Recovery** loads the checkpoint, replays and applies the records up to L, and hands the records after it to the
   core as entries that are persisted but not applied; they are applied when the core commits them (they may yet be
   cut off).
7. **The core keeps terms, not entries.** The core holds the term of each entry after its snapshot. Entries to persist
   leave it in the ready (moved, not copied). An append it sends names the range to attach, and the host reads those
   entries from its journal. Committed entries come out as an index range, and the host applies them from its journal.
   Memory is 8 bytes per entry since the last compaction.
8. **The leader decides; replicas apply.** Everything a record's application uses is in the record: a version id, a
   time, an upload id, a lock date. What the write path checks against state (conditions, quotas, object lock,
   versioning) is checked by the leader when it stages the record, against its applied state together with its
   proposed but uncommitted records, as group commit does now with its pending batch (ADR-0022). Upkeep that writes
   (lifecycle, upload expiry, compaction, notifications' outbox cursor) runs on the leader only.
9. **Snapshots** are a leader's checkpoint plus the inline payloads it names. A follower installs one into a fresh
   directory: the payloads go into segments below the checkpoint's segment, which are never scanned and so need no
   Raft index, then the checkpoint file, then the switch, a rename of the directory with a directory sync. A crash
   leaves the old store or the new one.
10. **Extents wait for item 5.** Until extents replicate, a cluster shard refuses what would write one (large PUTs,
    multipart parts) with NotImplemented; everything that lives in records works.

## Slices

| Slice | What | Done when |
|---|---|---|
| a | the core keeps terms only (§7); the simulation's host keeps the log | ADR-0057's simulation and mutants pass unchanged in what they check |
| b | the journal: the Raft-log flag, `truncateAfter`, rotation at a committed entry, checkpoints without sealing, the hard state file (§1, §3–§6) | the journal's fault sweeps pass with truncation and the new start |
| c | the replicated store: a shard replica over the store and the core; leader-only staging and upkeep; replicated `Relocate` (§2, §8) | three replicas in one process, over an in-memory network, agree after the crash model's sweeps |
| d | snapshots (§9) | a replica that fell behind a compaction catches up from a snapshot under the sweeps |

## Consequences

- One code path for single-node and cluster journals, which differ in a flag, the term field, and who may write a
  `Relocate`. Single-node stores open and behave as before; their tests, sweeps and smoke tests are the check.
- Compaction's copies cross the network: a leader that compacts sends the live payloads it copies. That is bounded
  by compaction's own write amplification; a by-reference `Relocate` (each replica copies from its own journal) is a
  later optimization, not this ADR's.
- A segment can grow past its target while its last entry waits for a quorum; by at most what the leader accepts in
  that time.
- The write path's checks see uncommitted records: a conditional PUT behind an uncommitted one sees it, and if that
  one is cut off (its leader deposed), the client of the second got an answer based on a write that did not happen.
  It got no acknowledgement either, since its own record is cut off with it: what is acknowledged is consistent.

## Rejected

- **A Raft index apart from the LSN** (a new field or a format version 2): every replica would still need the same
  generation, so generations would have to be the Raft index anyway, and local records would still be cut off with
  uncommitted ones.
- **Local `Relocate` records outside the log** (a pack file per node): a second place for payloads, a second recovery
  path, and a second format.
- **Waiting for an empty tail to checkpoint:** under load it may never come.
- **The hard state in the journal:** a vote must be durable before the reply, and a record is durable only with its
  batch; a small file synced on its own is simpler and rarely written.
