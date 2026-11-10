# Allocations per request, 10 Nov 2026

ROADMAP M4 asks to "profile allocation and copies on the hot path, using arenas per request". This counts the heap
allocations each S3 request makes, finds where they come from, and weighs what they cost.

## Method

- **Counts:** `heaptrack` 1.5.0 on Linux (Debian 13, x86-64, in a container limited to 2 CPUs), CosmoStore `47fb72e`
  built with ceesafec 0.24.2. macOS's `malloc_history` keeps only live blocks, even with `MallocStackLoggingNoCompact`,
  so it cannot see a request's temporary allocations.
- **Workload:** `tools/bench`, 128 B objects, concurrency 4, 5,000 operations a phase. Each run adds one phase to the
  run before (`put`; `put,get`; ...) on a fresh server, so a phase's allocations are its run's minus the previous
  run's. A first run that only creates the bucket made 416.
- **Attribution:** each allocation is charged to the first function above the allocator and the generic vector code
  (`Vector` push, extend, reserve).
- **Cost:** the share of `malloc` and `free` in the CPU profiles taken for ADR-0031 (`sample`, 5 s of 128 B PUTs at
  concurrency 128 on the M1).

## Allocations per request

| Phase | Allocations |
|---|---:|
| PUT | 112 |
| GET | 87 |
| HEAD | 74 |
| PUT over an existing key | 111 |
| DELETE | 83 |

Where a PUT's go (the other operations share the first two rows):

| Allocations | Where |
|---:|---|
| 31 | `S3Request.of`: every header copied into two vectors of its own, the name lowercased one byte at a time (so its vector grows several times), and the path, query, bucket and key |
| about 34 | SigV4: `parseAuthorization` (7, a vector per field), `verify` and `signLines` (the canonical request and the string to sign, grown as they are built), hex encoding (10), the signing key (2) |
| about 15 | the response: the ETag, the checksum headers, the stored extras shown as headers |
| about 15 | the store: key copies for the index, the record's encoding, the segment path at a commit |
| the rest | the body, the writer, `Async.blocking` when a batch is full |

## Cost

- **The allocator is under 1% of the samples:** 23 of 3,899 and 26 of 3,873 in the two profiles after ADR-0031.
  macOS's allocator serves these small blocks from per-thread caches.
- **The loop's overhead is elsewhere:** `Async.blocking`'s thread per call (G28; its stack teardown is the
  `mach_vm_deallocate` in the same profiles) and the `AsyncMutex` wake-up (G30).

## Conclusions

- **No allocation work now.** Halving the count, which the changes below would do, would save under 1% of the
  loop's time on the reference machine.
- **Arenas per request do not fit CeeSafe as it is.** An `Arena` gives scoped slices, which no struct field may hold
  (N0246), and `Vector` cannot allocate from one (an `Allocator` is a struct without fields). A request's data lives
  in structs (`S3Request`, `AuthHeader`) across awaits.
- **If a profile on other hardware shows the allocator,** the changes are known, without arenas:
  - `S3Request.of`: the lowercased names and the values in one buffer, sized once, with offsets per header (about
    31 to 3);
  - `parseAuthorization`: offsets into the header value instead of seven vectors (7 to 0);
  - SigV4's canonical request and string to sign: buffers reserved at their final size (about 15 to 3).
- The 128 B GET and HEAD rows are the floor for a request: 74 to 87, of which about 60 are request parsing and
  SigV4.
