# M10 exit review: table maintenance (19 Nov 2026)

**M10's exit (ROADMAP, M10; ADR-0086, proposed):** a PyIceberg table appended to many times keeps its warehouse
bounded and still reads back, on `serve` and on a cluster. Snapshot management and unreferenced file removal are
AWS's model's. A run that cannot read what it needs deletes nothing.

## How it was checked

- **The evidence:**
  - **Unit tests:** 369, with the inflate decoder against zlib's streams, the Avro reader against PyIceberg's own
    manifests, configurations, expiry, a snapshot management commit, and the unreferenced files' notes and deletes.
  - **`tools/maintenance_check.py`** (15 checks), on `serve` (S3 smoke) and through cluster node 2 (cluster smoke, 134).
  - **The SDK matrix:** Go, JavaScript, Java and .NET take the calls, and boto3 through the check.
- **Two reviews by readers who had not written the code:**
  - **Safety:** any way a live table's file could be deleted or its metadata harmed. Three findings were reproduced
    with scratch tests.
  - **Conformance:** with AWS's `s3tables` model (the AWS CLI's botocore, 2.34.13), the Avro 1.11 spec and RFC 1951.
    Points from memory are marked *memory*.

## The item

| Done when | Evidence | Verdict |
|---|---|---|
| A table appended to many times stays bounded, and reads back | `maintenance_check.py` on `serve` and a cluster | holds for PyIceberg's tables |
| AWS's calls and defaults | the model, every SDK | holds; C3–C5 |
| Nothing deleted that a live table needs; a run that cannot read deletes nothing | — | **does not hold: A1, A2**, A3–A6 |
| No input stops the server | — | **does not hold: B1, B2** |

## Findings

### A. Deleting what a table needs

1. **High: a reference the run cannot place is skipped, and the files behind it are deleted** (both reviews;
   reproduced).
   - **Where:** `metadataKey` takes only `s3://<hidden>/…`, and `addReferenced` ignores any other path
     (`table_unreferenced.cee:73`, `:110`).
   - **What gets skipped:**
     - A manifest list, manifest or data path written `s3a://` or `s3n://`, which S3FileIO and Hadoop take
       (*memory*). Spark's `add_files` can bring such paths in, and `add-snapshot` and UpdateTableMetadataLocation
       take any text.
     - v1 metadata, whose snapshots carry an inline `manifests` array and no manifest list.
     - A `snapshots` member that is not an array.
   - **The effect:** the files behind any of these look unreferenced, and go after 13 days. The job reads Successful.
2. **Medium: one table's references can name another table's files** (`<B-id>/…` in A's metadata: a clone, an
   `add_files`, a registration from copied metadata). Each table sweeps only its own prefix, so A's run never sees
   B's references: when B expires its snapshots, A breaks.
3. **Medium: paths are compared as text.** Iceberg URL-encodes partition values in paths, and Hadoop's FileIO
   decodes them into keys (*memory*). A live object whose key differs from its reference by percent-encoding, or by
   `//`, looks unreferenced.
4. **Medium: expiry's ancestry walk stops at a ref's head.** The cycle check uses the same set as the refs' heads
   (`table_maintenance.cee:343`). An ancestor that a tag names ends the walk, so main keeps fewer than
   `minSnapshotsToKeep` snapshots.
5. **Medium: only main's ancestry gets `minSnapshotsToKeep`.** Every other branch keeps its head only; Iceberg keeps
   the minimum on each branch (*memory*). The per-ref `max-snapshot-age-ms`, `min-snapshots-to-keep` and
   `max-ref-age-ms` are not read, and nothing refuses them.
6. **Low: the sweep acts on the metadata the run read** (`table_unreferenced.cee:sweepUnreferenced`). A commit in
   between that names a noted file again (a restore, a registration) does not save it. Two runs at once, a stale
   leader in a failover, can write stale notes back. The sweep should check that the table's metadata location is
   still the run's.

### B. Stopping the server

1. **High: a crafted manifest panics the server** (both reviews; reproduced). `count = -count` overflows for a
   count of i64's least (`avro.cee:256`, `:290`). Anyone who can commit a snapshot can name such a manifest, and
   the hourly pass then panics, on `serve` and on each new leader of a cluster.
2. **Medium: the decoder's memory has no bound** (reproduced: 60 bytes gave 1,048,576 records).
   - A block's record count is unbounded for a schema of no bytes a record.
   - An array's count is checked against the block, not the bytes left.
   - Every record of every block is kept.

   Under Linux's overcommit that is the OOM killer, every pass.

### C. Conformance

1. **Low: expiry leaves `statistics` and `partition-statistics` entries** for the snapshots it removes, as PyIceberg
   and Java do not.
2. **Low: a failure is not recorded in some cases.** When the metadata cannot be read, or an allocation fails while
   paths are gathered, unreferenced removal records no status, and the last Successful stays. An allocation failure
   becomes an empty path, which is skipped (`table_unreferenced.cee:240`); the notes' days cover it, but it should
   end the run as Failed.
3. **Low: GetTableMaintenanceConfiguration always answers compaction's defaults.** A stored `disabled` value with
   other settings is not echoed back.
4. **Low: a Failed run's message does not name the codec**, as ADR-0086 §4 says it does.
5. **Low: the Avro reader's smaller gaps.**
   - A namespace a named type inherits is not recorded, and a short name matching two full names takes the first.
     Both fail closed.
   - `{"type": {…}}` is refused before the code that would read it.
   - An `int` is not checked to 32 bits.
   - A varint's 10th byte above 1 is taken.
6. **Low: leftovers.**
   - A table dropped during a run gets its notes and status written after its records were removed.
   - Time is the wall clock's, and a cluster's day is whichever node serves the request.
   - `sortedInsert` is O(n) a path.

Checked and right (both reviews):
- **The calls against the model:** the calls, paths and status codes; the types at each level; `value`, `status`,
  the settings union and its ranges; the answers' members; the job status enum and its fields.
- **The defaults:** 1 and 120, 3 and 10 (*memory*).
- **The Avro container:** the magic, the metadata map, the sync after each block, unions, enums, fixed, logical
  types read as their base; deflate as raw RFC 1951; other codecs refused.
- **Inflate:** stored LEN/NLEN, the fixed tables, the dynamic header's limits, repeat codes, over-subscribed codes,
  end of block, length 285, distances within the output, the output limit.
- **Expiry:** keeps every ref's head and the current snapshot, and commits by If-Match, a lost race retried.
- **Unreferenced removal:** reads every entry status, the delete manifests, deletion vectors' puffin files and
  statistics. A missing, unreadable, oversized or other-codec manifest ends the run Failed with nothing deleted.
  Notes start each file's clock; settings and days are bounded.
- **The catalog:** its keys are out of S3's reach, so notes cannot be forged.
- **`maintenance-run`:** authorized.
- **The cluster:** one job a request, signed and routed to the leader.

## The findings, closed (the owner: "continue")

| Finding | What closed it | Evidence |
|---|---|---|
| A1 references skipped | References are placed: `s3://`, `s3a://`, `s3n://` of this bucket read the same; another bucket's passed by. Anything else (another scheme, a key of no table, format 3, `snapshots` not a list, a snapshot with neither list nor manifests) ends the run Failed, nothing deleted. Format 1's inline `manifests` are read | `unreferencedRefusesWhatItCannotPlace`; `unreferencedFilesNotedThenDeleted` (an `s3a://` reference keeps its file) |
| A2 other tables' files | A reference into another table's prefix pins it (`shared/<its id>/<this id>`). A pinned table deletes nothing while the pinning table is there; a stale pin goes | `unreferencedPinsOtherTables` |
| A3 forms of a key | A key matching a referenced one percent-decoded, or with `//` made `/`, is referenced | `unreferencedFilesNotedThenDeleted` (`a%20b` keeps `a b`) |
| A4 the walk stopping at a ref | A visited set of its own; refs' heads held apart | `snapshotsThatExpire` (a tag on the parent: main still keeps three) |
| A5 other branches | Every branch keeps its newest `minSnapshotsToKeep`, and those younger than its age, honouring the ref's own `min-snapshots-to-keep` and `max-snapshot-age-ms`. `max-ref-age-ms` is not applied (refs never expire here; ADR-0086 §2) | `snapshotsThatExpire` (a `dev` branch keeps three) |
| A6 a commit during the run | The sweep re-reads the table under the store: a table dropped or changed since the run read it gets nothing done | `unreferencedSweepWaitsForACommitMeanwhile` |
| B1 i64's least | Refused before it is negated, in every block count (`blockCount`) | `avroRefusesHostileCounts` |
| B2 memory | A count is at most the bytes left; a block's records at most its bytes; a file's blocks decode to 64 MiB at most | `avroRefusesHostileCounts` (the million records of no bytes, an array past its bytes) |
| C1 statistics | `remove-snapshots` drops their `statistics` and `partition-statistics` entries | `snapshotManagementCommits`, the smokes |
| C2 failures not recorded | A run whose metadata cannot be read records Failed. An allocation failure ends the run with nothing deleted, never an empty path. A dropped table gets no status | `unreferencedRefusesWhatItCannotPlace` |
| C3 compaction's answer | The stored value is echoed | the SDK checks |
| C4 the codec's name | The Failed message names it | `failRun` |
| C5 the Avro reader | Inherited namespaces; an ambiguous short name refused; `{"type": {…}}` read; `int` checked to 32 bits; a varint's 10th byte checked | `avroRefusesHostileCounts` |
| C6 leftovers | A dropped table gets no notes or status. References are sorted once (no O(n²)). Days are the wall clock's, and a cluster's nodes should share `--tables-day-seconds` (ADR-0086 §6) | the unit tests |

**After the fixes:** 373 unit tests pass. The S3 smoke (the maintenance check's 15, PyIceberg's 23) and the cluster
smoke (134, both checks through node 2) pass.

## Verdict

**M10 should not close yet**, and unreferenced file removal, enabled by default, should not run on real tables until
A1 and B1 are fixed.
- **A1** deletes live files of tables PyIceberg did not write.
- **B1** lets anyone who can commit a snapshot crash the server every hour.
- **A2 to A5 and B2** are each a way to the same two outcomes.

**The recommendation:** fix A and B first, each with a test. Unreferenced removal should end Failed, deleting
nothing, on any reference it cannot place: another scheme, a path outside the table's own prefix, v1 inline
manifests, metadata not of format 2, or a path that differs only by encoding. The Avro reader should have a decoded
size budget, and checked counts. Then fix C, and run the smokes and the SDK matrix again.

Closing M10 and accepting ADR-0086 are the owner's decisions.

**After the fixes:** every finding is closed with its test.
- **Unreferenced removal** deletes only what it can show no reference names: a reference it cannot place, a manifest
  it cannot read, a pin from another table, or a commit during the run each leave the warehouse as it was.
- **The Avro reader** refuses the counts and sizes that panicked it or ran it out of memory.
- **Expiry** keeps what Iceberg's own keeps on every branch.

M10's "done when" holds, and M10 can close on the owner's word.

**Closed** by the owner, 19 Nov 2026 ("Accept and close"), with ADR-0086 accepted.
