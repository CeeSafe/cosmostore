# ADR-0068: A forwarded write is done once: request ids and their answers in the log (M6 exit gap)

**Status:** proposed, 15 Nov 2026, for the gaps of the M6 exit review (`docs/m6-exit-review.md`), which the owner
asked to fix before closing M6 ("Fix all those gaps before closing").

## Context

- A node that takes an S3 write forwards it to its shard's leader (ADR-0060). When the exchange fails after the
  leader got it (a partition drops the answer, a leader is cut off mid-write), the write may have been done. Sending
  it again did it twice, the second time after later writes (the chaos harness found it, ADR-0065), so since then a
  forwarded write is sent again only when it was certainly not done, and otherwise the client gets 503 and does not
  know.
- The Raft thesis (§6.3) gives the way to exactly once: each request carries an id, and the replicated state keeps the
  ids it has done, with their answers, so that a request again is answered and not done again.

## Decision

1. **An id at the door.** The node that takes a client's write gives it a request id (its node id, a random number
   it picked at start, a counter: 16 bytes) in an `x-cosmo-request` header of the forwarded request. A client's own
   `x-cosmo-*` headers are taken off first, so no client can name another's id.
2. **The answer in the log.** The leader, having done a write that staged entries, stages one more: a `Session`
   record (type 18) holding the id and the S3 answer as the shard's S3 server gave it (status, headers, body). It is
   proposed with the write's entries, after them, so it commits exactly when they do (a commit is a prefix). An
   answer over 256 KiB is recorded as done without it.
3. **The table.** Applying a Session record, every replica puts the id and its answer in a table of the shard's
   state, the 16,384 most recent by index (the same on every replica, since it follows the log), which checkpoints
   keep (format 18) and snapshots carry.
4. **Asked again.** A leader that gets a write whose id the table has (it waits, as every write does, until it has
   applied all it holds) answers with the recorded answer and does nothing; one recorded without its answer gets 503,
   and is still not done again.
5. **So a forwarded write is sent again** whenever the exchange fails, as a read is, for as long as the node waits
   for a leader (FRONT_WAIT_MS).

## Consequences

- Writes through a node other than the leader no longer turn a lost answer into a 503, and none is done twice.
- A write takes one more record (about the size of its answer, a few hundred bytes).
- A client's own retry is still a new write, as S3 has it: the id is the node's, for its own sending.

## Rejected

- **Ids from clients:** S3 has no such header; clients that retry would need to send one.
- **Keeping answers in the leader's memory:** a new leader would not have them, and that is when they are needed.
