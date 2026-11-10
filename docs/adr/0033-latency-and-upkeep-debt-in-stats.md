# ADR-0033: Request latencies and upkeep debt in the stats endpoint

**Status:** accepted for M4 (`src/s3/latency.cee`, `src/s3/stats.cee`, `src/s3/server.cee`,
`src/store/object_store.cee`), 10 Nov 2026

## Context

- **ROADMAP M4 asks for dashboards:** p50, p99 and p99.9, fsyncs per 1,000 PUTs, write amplification and compaction
  debt.
- **`GET /_cosmostore/stats` (ADR-0021) has the counters** for syncs and write amplification: `journalSyncs`,
  `payloadBytes` and the bytes written by kind. A dashboard derives both from two readings.
- **Latencies came only from `tools/bench`,** at the client. A running server could not tell its p99.
- **Compaction debt was not reported.** The store knows each segment's total and live bytes (ADR-0005), from which
  compaction chooses.

## Decision

1. **Latency histograms per class of request**, in the server, counted with atomics (no lock):
   - the classes: PutObject, GetObject, HeadObject and DeleteObject (a bucket, a key and no query parameters), and
     the rest (listing, multipart, tagging, the stats endpoint itself);
   - each request is timed in `S3Handler.handle`, from before parsing to the end of its response, an error
     response's included;
   - buckets: exact below 16 µs, then 8 per power of two (at most 12.5% wide), to 2^47 µs.
2. **The upkeep debt** (`ObjectStore.upkeepDebt`), read under the store's lock with the other figures:
   - **compaction:** in the segments compaction would choose now (covered by the checkpoint, live share under
     `compactBelowLivePercent`), the bytes it would free and the live bytes it would copy first;
   - **checkpoint:** the journal bytes no checkpoint covers, which recovery replays (T11).
3. **The stats endpoint reports them**, flat like the other fields:

   | Field | Meaning |
   |---|---|
   | `compactionDebtBytes` | journal bytes the compactions due now would free, net of what they copy |
   | `compactionDebtCopyBytes` | live inline payloads those compactions copy first |
   | `uncheckpointedBytes` | journal bytes no checkpoint covers |
   | `<class>Count` | requests of the class since the server started |
   | `<class>P50Micros`, `P99Micros`, `P999Micros` | the top of the histogram bucket holding that rank, in µs: at most 12.5% above the true value |

   `<class>` is `putObject`, `getObject`, `headObject`, `deleteObject` or `otherRequests`. The figures cover the
   server's whole life; a dashboard takes two readings for a window.

## Rejected

- **A dashboard in the server** (an HTML page). The endpoint's JSON is what any dashboard reads; a page would add
  code to the request path for something tools do well.
- **Percentiles per window in the server** (a ring of histograms). Two readings give a window's counts, but not its
  percentiles. Left until a dashboard needs it.
- **Classes per S3 operation** (40 of them). Most are rare; the four that carry small-object load are the ones the
  targets name.

## Consequences

- **Cost per request:** two clock readings and an atomic add. 368 counters (2.9 KiB) per class.
- **A request's time includes waiting for the commit** (group commit, ADR-0022), as the client sees it. It does not
  include the time before the request was read, or in the client's network stack: with `tools/bench` on a loaded
  machine, PUT p50 and p99 agreed with the client's (12.3 ms and 53 ms, against 13.0 ms and 52 ms), while HEAD's 31 µs
  p50 was 0.5 ms at the client.

## Tests

- **`latencyHistogramBuckets`** (`src/s3/s3_unit_tests.cee`): every bucket's top is in that bucket and the next value
  in the next; a bucket is at most 12.5% wide; percentiles of a known distribution; an unknown class counts as other.
- **`upkeepDebtFollowsCheckpointAndCompaction`** (`src/store/checkpoint_tests.cee`): before a checkpoint everything
  is uncheckpointed and nothing is compaction's; after it, most of an overwritten journal is debt with live payloads
  to copy; the compaction frees what the debt said (within 10%), and nothing is due after it.
- **By hand:** `tools/bench` against a fresh server, then the endpoint: the counts match the bench's operations, the
  stats requests count as other.
- `ceesafec test` (134), `tools/s3_smoke.sh`, `tools/tls_smoke.sh`, the s3-tests subset (252), the boto3, Go,
  JavaScript and rclone checks.
