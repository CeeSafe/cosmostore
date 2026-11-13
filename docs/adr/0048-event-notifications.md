# ADR-0048: Event notifications through a durable outbox

**Status:** accepted for M5 (item 6), 13 Nov 2026, and built (`src/store/outbox.cee`, `src/store/object_store.cee`,
`src/store/checkpoint.cee`, `src/s3/notifications.cee`, `src/s3/serve.cee`).

## Context

- **What S3 offers.** A bucket's notification configuration names events (objects created, objects removed), a
  filter on the key, and a destination: an SQS queue, an SNS topic or a Lambda function. S3 delivers each event at
  least once.
- **The roadmap** asks for a durable outbox with retry: an acknowledged write's event must not be lost to a crash
  or to a destination that is down.
- **The destination** (chosen with the user, 13 Nov 2026): HTTP webhooks first, a POST of S3's event document,
  since CeeSafe.Web has the client. Queue protocols need clients CeeSafe does not have.
- **What a write already leaves behind.** Every write that changes an object is one journal record, durable
  before the write is acknowledged (ADR-0001) and applied to the index in LSN order, at publish and again at
  recovery: PutInline and PutExtent, UploadComplete, DeleteVersion, DeleteMarker. A checkpoint is the state as of
  an LSN; recovery replays the records after it.

## Decision

1. **A bucket's notification rules** are a `BucketConfig` record of kind 8: for each rule an id, a target, the
   kinds of event and a prefix and a suffix of the key. Put- and GetBucketNotificationConfiguration read and write
   them as S3's `<QueueConfiguration>` elements; a document without any takes the rules off.
   - **Targets** are webhooks `serve` is given in a file (`--notify-targets <file>`: lines of `<id> <url>`,
     `http://` or `https://`). A rule names one as `arn:cosmostore:sqs::<id>:webhook`; an ARN that is no target of
     this server is InvalidArgument. The file is read once, at start.
   - **Events:** `s3:ObjectCreated:*`, `:Put`, `:CompleteMultipartUpload`, `s3:ObjectRemoved:*`, `:Delete`,
     `:DeleteMarkerCreated`. A PUT, a POST upload and a copy write the same record, so `:Post` and `:Copy` cannot
     be told apart from `:Put` and are NotImplemented, as are every other S3 event, topics, functions and
     EventBridge. A copy and a POST upload are reported as `ObjectCreated:Put`; a version a lifecycle rule
     removes, as `ObjectRemoved:Delete`.
2. **The journal is the outbox.** A write's record is its event. When a record is applied, and its bucket has a
   rule for it, the event (what the record says: bucket, key, version, size, MD5, parts, time, LSN, and the rules
   that take it) is queued in memory, in LSN order. Nothing more is written: the event is durable because its
   record is, in the same sync, and there is no window between the write and its event.
   - A DeleteVersion that removes nothing gives no event. Relocate and SetTags records give none.
   - The rules that count are the bucket's when the record is applied, which is the same at publish and at
     recovery: the rules are records of the same journal.
3. **What keeps an undelivered event** across a restart:
   - **the journal**, for records after the newest checkpoint: recovery applies them again and queues their
     events again;
   - **the checkpoint**, for older ones: format 11 writes the events waiting when it starts as entries after the
     uploads (their count in the header's unused word), and a bucket's rules in its entry. Formats 1 to 10 load.
     So segments are compacted and removed as before: no event pins one;
   - **the delivery cursor**, so that what was delivered is not sent again: the LSN of the newest event
     delivered, in a 12-byte file beside the journal (`outbox.cursor`: the LSN and a CRC32C), written to a new
     file, synced, renamed and the directory synced after each batch delivered, before the events leave the
     outbox in memory: if the write fails they stay, in memory and in the next checkpoint. Recovery reads it first
     and passes over events up to it. A cursor that is missing or does not read is 0: events are delivered again, never lost.
4. **Delivery** is a task beside the server and the upkeep. It takes the oldest events (64 at a time), POSTs each
   to each of its targets, and when every target has answered 2xx tells the store, which drops them and writes
   the cursor.
   - **In order, and at least once.** An event that fails is tried again after 1 s, doubling to 60 s, and the
     events behind it wait: one target that is down holds the others' events too. A crash between a 2xx and the
     cursor delivers again; so does a failure at an event's second target, to its first.
   - **Bounded.** The outbox holds 100,000 events. Past that the oldest waiting event is dropped and counted: a
     target down for long enough loses its oldest events, not the store its memory.
   - A request to a webhook has 10 s to connect, 30 s to its first byte and 60 s in all. https targets are
     verified against the system's roots. An event for a target the file no longer has is passed over.
   - The stats endpoint gives `eventsPending`, `eventsQueued`, `eventsDelivered`, `eventsDropped` and
     `eventDeliveryFailures`.
5. **The event** is S3's document with one record: `eventName`, `eventTime` (the record's time), the bucket's
   name and ARN, the object's key (URL-encoded), size and ETag (for an object created), `versionId` (in a bucket
   with versioning), the rule's id as `configurationId`, and `sequencer`, the record's LSN in 16 hex digits: events
   of one key order by it. `eventSource` is `aws:s3`, which is what consumers match on. There is no
   `userIdentity`, `requestParameters` or `responseElements`: a record does not say who wrote it.
6. **The cost.** While no bucket has rules, applying a record costs one comparison (a count of such buckets), the
   delivery task sleeps without touching the store when it has no targets, and otherwise looks at the outbox
   twice a second. In a bucket with rules, applying a record decodes them. Policy actions:
   `s3:GetBucketNotification` and `s3:PutBucketNotification`.

## Consequences

- An acknowledged write in a bucket with rules has its event delivered at least once, whatever crashes, unless
  100,000 events are already waiting.
- Consumers must take duplicates, and order events of a key by `sequencer`, as with S3.
- A store with notification rules, or checkpointed by this build, has checkpoint format 11.
- `serve` now depends on CeeSafe.Web's `web_client`.
- Taking a bucket's rules off does not take back the events already waiting; deleting the bucket does not
  either.
- The cursor file is one more file in the store's directory; `fsck` leaves it alone.

## Rejected

- **An outbox of its own** (a second log, or Event records in the journal): a second write to keep atomic with
  the first, or a record per event to carry through compaction, for what the write's record already says.
- **Events queued by the S3 layer after it acknowledges:** a crash between the acknowledgement and the queue
  loses the event, and writes the S3 layer does not make (lifecycle) have none.
- **Keeping segments until their events are delivered:** a target that is down would fill the disk.
- **A queue per target,** so that one target down does not hold the others: more cursors and more checkpoint
  state; kept for when there is more than one kind of target.
- **The cursor as a journal record:** an idle store would write records to say it delivered; a side file costs
  one small sync per batch delivered and nothing otherwise.
- **`:Post` and `:Copy` reported from a field of the version's metadata:** possible, and one more field every
  object would carry for it.
