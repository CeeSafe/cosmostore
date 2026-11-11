# Profile of 1 MiB GETs on ceesafec 0.36.0, 11 Nov 2026 (ADR-0037)

The first profile (`2026-11-11-get-1mib-profile.md`) found a thread started per `Async.blocking` read (G28) and
fresh body buffers (ADR-0036). CeeSafe 0.36.0 (its ADR 0094) pools the threads. This is the same profile again.

## Environment

| | |
|---|---|
| Host | The Debian server (Xeon E3-1245 V2), `cosmostore-prof` container, no CPU quota; load average under 2 |
| Build | `a84b9e1`, ceesafec 0.36.0, CeeSafe.Web `82a3a73` |
| Placement | server `taskset -c 2,3`, `tools/bench` `taskset -c 0,1,4,5` |
| Load | 1,000 objects of 1 MiB, then GETs at concurrency 32, `-read-repeat 60` |
| Sampling | 60 stacks of every thread with `gdb -batch` (`thread apply all bt 30`), 0.2 s apart |

## Where the time goes

**CPU, per core, over 10 s of GETs:** server cores 63% and 82% (78% and 49% before), client cores about 80% (55%).

**The event loop's thread (60 samples).** No sample found it in `epoll_wait`.

| Samples | Share | Where | Before (0.30.0) |
|---:|---:|---|---:|
| 35 | 58% | `sendmsg`: writing the response into the socket | 52% |
| 9 | 15% | `OwnedBuffer.append` in `Exchange.write`: copying the body into the 16 KiB write buffer | in "the rest" |
| 6 | 10% | `ceesafe_async_blocking_start`: waking a parked pool worker (`futex`) | 15%, starting a thread |
| 10 | 17% | the rest: request parsing, SigV4, allocations, `Exchange.sendPending` | 18% |
| | | a fresh 1 MiB buffer, zeroed | 15% (ADR-0036) |

**The worker threads:** the process had 16 to 24 threads a sample, the pool's almost all parked; 12 samples in
`pread64`, 12 in `Crc32c`.

## Throughput

Alternating rounds, 1,000 operations a phase, placement as above, 3 rounds:

| Build | GETs/s, c32 | GETs/s, c128 |
|---|---:|---:|
| `b712ef8`, ceesafec 0.31.0 (a thread per call) | 839 to 847 | 730 to 785 |
| `a84b9e1`, ceesafec 0.36.0 (the pool) | 1,012 to 1,079 | 753 to 823 |

## What followed

The write buffer: a body goes out 16 KiB at a time, so a 1 MiB GET makes 64 copies and 64 `sendmsg` calls.
ADR-0037 sets it to 64 KiB: 1,290 to 1,322 GETs/s at concurrency 32 and 911 to 1,011 at 128.
