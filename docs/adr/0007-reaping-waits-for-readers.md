# ADR-0007: Reaping waits for in-flight readers

**Status:** accepted (implemented in `src/store/pins.cee`, `ObjectStore.reapExtents`/`reapDeferred`), 7 Nov 2026

## Context

ADR-0003 unlinks a retired version's extent files as soon as the record that retires it is durable.
- An `ObjectReader` is an owned value: it does not borrow the store. So a caller can open a reader, overwrite or
  delete the key, and then go on reading.
- A reader keeps reading an extent it already has open (POSIX keeps an unlinked file's data while a descriptor is
  open). But it opens each extent lazily, and the next one is already gone: the GET fails half way with `NotFound`.
- Today this needs an interleaving caller. The S3 layer (M3) streams GETs while PUTs commit, so it will be the
  normal case. ROADMAP M2 asks for reaping that waits for in-flight readers.

Inline objects are not affected: `openReader` copies an inline object's bytes when it opens, so compaction may
remove its segment at any time.

## Decision

1. **Readers pin their extents.** The store owns an `ExtentPins`, which is a reference count per extent id
   (`Arc<Mutex<HashMap<u64, u32>>>`).
   - `openReader` pins the version's extents before it returns. The store is borrowed while it looks the version up
     and pins it, so no reap can come between.
   - The reader holds a `ReadPin`. Dropping the reader (finished, abandoned or failed) drops the pin, which counts
     each extent down and forgets it at zero.
   - The lock makes this safe when a reader is dropped on another thread. The pin's drop does no I/O.
2. **Reaping skips pinned extents.** When `reapExtents` finds a retired extent pinned, it does not unlink it. It
   moves the extent to the store's deferred list instead.
   - `reapDeferred` unlinks every deferred extent whose pins are gone. It runs at the start of every reap (every
     commit) and in `maintain`, so a deferred file goes on the first commit or maintenance pass after its last
     reader closes.
   - All unlinks stay on the store's thread and go through `Fs` (ADR-0004).
3. **Deferred extents count as used space.** Their file bytes are added to `usedBytes` until they are unlinked
   (ADR-0006), so admission does not count space that readers are still holding.
4. **fsck does not call them orphans.** `orphanExtents` leaves out deferred extents: they are known garbage waiting
   for readers, not leaks.
5. **A crash forgets the list.** The deferred list is not journaled and needs no recovery: the files are not
   referenced by any live version, so the orphan sweep at open removes them.
   - If the deferred list cannot grow (out of memory), the extent is left on disk. It becomes an orphan for the next
     open's sweep, rather than being unlinked under its reader.

### Rejected

- **A grace period** (unlink N seconds after retirement). A slow client streaming a large object outlives any fixed
  delay, so it would fail anyway.
- **A pin count in `ObjectVersion`.** Versions live in the index and in checkpoints and are copied by recovery. A
  separate table keyed by extent id keeps that state free of runtime-only fields.
- **Unlinking in the pin's drop.** That would put file-system calls, and their failures, on whatever thread drops a
  reader, outside the store's fault injection and ordering.

## Tests

`src/store/pin_tests.cee`:
- A reader opened before an overwrite and before a delete reads the old bytes to the end, CRC-checked.
- The old extents stay on disk and in `usedBytes` while the reader is open, and go on the next commit or `maintain`
  after it is dropped.
- A reader dropped half way releases its pins.
- Two readers of the same version keep its extents until both are closed.
- fsck (`verify`) reports no orphans while extents are deferred.
- A reopen with deferred extents left on disk sweeps them.

## Consequences

- One lock and one map update per extent-backed `openReader` and per reader drop. Inline GETs are unchanged.
- A reader that is never dropped holds its extents' space until the process exits. The S3 layer must drop readers
  when a client disconnects (M3).

## Amendment (7 Nov 2026): pins that never block

The S3 layer (ADR-0008) drops readers in async code, and an async fn must not block (CeeSafe N0295). The compiler
refused the first design: `ReadPin`'s drop took a `Mutex`, which may sleep.

- **Pins are atomic counts.** There is one `Arc<AtomicU64>` per pinned version, reachable from each of its extent
  ids in the store's own map, so no lock is needed.
  - A reader's drop only counts down. Pins are made only by the store, under `borrow mut` (`openReader`), so once the
    store sees zero no reader can raise it again.
  - Idle entries are pruned in `maintain`, and when the map passes 4096 entries.
- **`openReader` takes `borrow mut this`.** fsck and `getObjectRange` read through `openUnpinned`: they finish
  before they release the store, so no reap can come between.
- **Abandoned writers work the same way.** An unfinished `ObjectWriter` used to unlink its extents in its drop. It
  now queues their ids on the store's `Channel<u64>` (`trySend` has no effect), and the next reap or `maintain`
  removes them. If the queue is full, they stay until the orphan sweep at open.
