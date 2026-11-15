# ADR-0064: Erasure-coded extents (M6 item 8)

**Status:** proposed for M6 item 8 (ADR-0056 §9), 15 Nov 2026, under the owner's standing go-ahead.

## Context

- **ADR-0056 §9:** a sealed segment whose live bytes are cold is encoded into k+m pieces across failure domains, its
  replicas dropped only once the pieces are synced and verified, the switch one committed record; extents follow the
  same rule. **Done when** k+m pieces survive m lost nodes.
- **Today** every extent is whole on every replica of its shard (ADR-0061): three copies, 3× its size. A shard's
  group is its failure domains (one replica per domain, ADR-0059 §2), and Raft keeps the shard while a majority is up.
- **Segments are harder:** inline payloads are read from them by their locators, and compaction moves them. Extents
  are whole files, written once, read whole or by range.

## Decision

1. **Extents first.** A cold extent (older than `--code-after-seconds`, by default a day) of a shard whose group has
   at least three voters is coded into k+m pieces with k+m the voters' count and m = (voters − 1) / 2: 2+1 for three
   voters, 3+2 for five. It survives what the group survives (m lost nodes), at (k+m)/k of its size instead of k+m
   times. Segments stay replicated; coding sealed packs is later work.
2. **The code:** Reed-Solomon over GF(2^8) (polynomial 0x11D), systematic, from a Cauchy matrix (every k×k submatrix
   invertible): pieces 0 to k−1 are the extent's bytes in k slices (the last padded with zeros), k to k+m−1 parity.
   `src/storage/erasure/rs.cee`, CeeSafe only.
3. **The switch is one record:** the leader proposes a `Coded` record (type 17): the extent's id, k, m, its length,
   the piece length, the node holding each piece (the group's voters in order) and each piece's CRC32C. Applying it,
   each replica writes its own piece from its full copy (`piece-<id>-<i>.cp`, synced, its directory synced) and only
   then removes the full copy; a replica without the full copy notes the piece as missing. The leader proposes the
   record only when its own full copy is whole (checked against the manifest), so the CRCs it names are of the right
   bytes.
4. **Missing pieces are rebuilt:** fetching what is missing (ADR-0061 §3) asks the other holders for k pieces
   (`POST /piece-fetch`), decodes, and writes the piece it holds, checked against its CRC.
5. **Reads:** a read of a coded extent this replica has no full copy of fails, the store noting the extent as wanted;
   the front answers 503, which S3 clients retry. The fetch task decodes a wanted extent from k pieces into a full
   copy again (an extent file as before, checked against the manifest), and the retried read finds it. Upkeep removes
   such copies an hour after they were made.
6. **Scrub** (ADR-0063) checks pieces too: a damaged piece is removed and rebuilt (§4).

## As built

- **The leader** (`src/cluster/coding.cee`, `codeForever`) looks every 2 s, behind the shard's write gate, for live
  extents whose files are older than `--code-after-seconds`, at most 512 index keys a look (`codingCandidates` keeps
  its place), and codes up to 4 a look, one Coded record each, waiting for each to be applied. It checks its whole
  copy against the manifest (length, header, CRC) before naming CRCs; an extent coded already is not coded again.
- **Applying the record** (`convertToPiece`) writes this replica's piece from its whole copy, synced with its directory,
  then removes the copy, unless a read has it pinned (then upkeep removes it later). A copy that cannot be read, or a
  piece that cannot be written, is an error, and the copy stays: removing it with no piece written would lose this
  replica's share. A crash between the record and the piece leaves the copy, and the piece is made from it when it is
  next found missing. Fault sweeps (`codedFaultsOnce`, `codedFaultsCrash`) check that after any one failure or crash
  the replica has its piece or can make it.
- **Missing pieces** are found by their files' lengths (a stat each); their CRCs are scrub's to check. A damaged piece
  scrub finds is removed (with any decoded copy), and then rebuilt (§4).
- **A read** wants every coded extent of the version it lacks at once, so one retry finds them all; reads of whole
  objects in memory (`getObjectRange`, copies) do the same. fsck skips a coded extent with no whole copy: its pieces
  are on several nodes, which scrub checks.
- **Checkpoint format 17** adds the coded extents after the events: an entry of kind 5 (their count), then one of kind 6
  each. A node reads formats up to 17; an older node does not read 17 (upgrade forwards).
- **A whole extent is in memory** while it is coded, decoded or a piece is rebuilt, as it is when it is pushed or
  fetched (ADR-0061): at most 64 MiB, with its pieces.
- **Tests:** `rs_tests.cee` (the field; every choice of k pieces of 2+1, 3+2 and 4+2 decodes; refusals);
  `codedExtentsTurnIntoPieces` (the store's side, through a checkpoint and a reopen); the two fault sweeps;
  `tools/cluster_ec_smoke.sh` (14 checks): a 10 MB object coded into three 5 MB pieces, one per node, the whole copies
  gone; read back by decoding; read back with the shard's leader down, from the two pieces left; a deleted piece
  rebuilt, and a damaged one found by scrub and rebuilt, byte for byte; a deleted object's pieces reaped.

## Consequences

- A cold large object costs 1.5× its size on three nodes instead of 3×; a read of one costs, the first time, the
  transfer of k pieces and a decode.
- A shard of fewer than three voters keeps its extents whole.

## Rejected

- **Coding at write time:** every write would wait for k+m pieces on k+m nodes; hot data is read, rewritten and
  deleted, and coding it only to decode it again costs more than the copies save.
- **Decoding inside the store's read:** the store does no network I/O; the read fails, and the node's fetch task does
  the network part, as it does for a missing extent.
