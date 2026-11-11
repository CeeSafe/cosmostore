# Profile of 1 MiB GETs at concurrency 32, 11 Nov 2026 (ADR-0036)

The pinned comparison run (`2026-11-11-comparison-pinned.md`) left 1 MiB GETs at 0.59 to 0.67 times SeaweedFS and
RustFS. This profile looks for what bounds them.

## Environment

| | |
|---|---|
| Host | The Debian server of the comparison runs (Xeon E3-1245 V2, data-center SSD), `cosmostore-prof` container, no CPU quota; load average under 2 |
| Build | `d509388`, ceesafec 0.30.0, CeeSafe.Web `82a3a73` |
| Placement | server `taskset -c 2,3`, `tools/bench` `taskset -c 0,1,4,5`: other physical cores (cpu N and N+4 share one) |
| Load | 1,000 objects of 1 MiB, then GETs at concurrency 32 for about 85 s. A copy of `tools/bench` applied `-read-repeat 60` to 1 MiB objects too; the repo's version repeats only objects up to 64 KiB |
| Sampling | 60 stacks of every thread with `gdb -batch` (`thread apply all bt 30`), 0.2 s apart |

## Where the time goes

**CPU, per core, over 10 s of GETs** (from `/proc/stat`):

| Cores | Busy |
|---|---:|
| 2, 3 (server) | 78%, 49% |
| 0, 1, 4, 5 (client) | 55% each |
| 6, 7 | 2% |

**The event loop's thread (60 samples).** No sample found it in `epoll_wait`: it never waited for work.

| Samples | Share | Where |
|---:|---:|---|
| 31 | 52% | `sendmsg`: writing the response into the socket (`Transports.writeAllVectored`) |
| 9 | 15% | `takeBodyBuffer`: a fresh 1 MiB `Vector<u8>`, zeroed |
| 9 | 15% | `clone` and `pthread_create`: starting the worker thread of an `Async.blocking` call (G28) |
| 11 | 18% | the rest: `Exchange.sendPending`, buffer appends, request teardown |

**The worker threads** read the extent (`pread64` in `DurableFile.readExactAt`, 11 samples) and check its CRC32C
(`Crc32c.update`, 6). One of them exists for each read and ends with it, so the server had one to five threads
per sample.

## Why the buffer costs

- **The pool held 4 buffers** (`BODY_BUFFERS`, ADR-0034). At concurrency 32, most GETs found it empty and allocated.
- **glibc returns a freed 1 MiB block to the system** (it is above its `mmap` threshold). So each miss maps a new
  block and faults in its 256 pages, which the zeroing touches first.
- **Allocating on the worker instead,** inside the first `Async.blocking` call, gained nothing: 669 to 693 GETs/s,
  against 664 to 715 with 4 buffers. The cost is the fresh pages, wherever they are touched; only reuse avoids it.

| Pool | GETs/s, c32 | GETs/s, c128 | Idle RSS after c128 |
|---:|---:|---:|---:|
| 4 | 664 to 715 | 591 to 632 | 98 MiB |
| 16 | 826, 828 | 644, 678 | 186 MiB |
| 32 | 819 to 859 | 643 to 794 | 220 MiB |
| 128 | 835, 858 | 837, 855 | 251 MiB |

Rounds alternate between builds, server and client placed as above, 1,000 operations a phase.

## What is left

- **The response copy** (`sendmsg`, half the event loop) is the kernel copying 1 MiB into the socket. The only
  ways to lower it are a second event loop, or `sendfile`, which would skip the CRC check on reads (ADR-0034,
  rejected).
- **A thread per read** (15%) is CeeSafe's G28: `Async.blocking` has no pool. The next step is a CeeSafe ADR.
