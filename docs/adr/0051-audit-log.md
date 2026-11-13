# ADR-0051: The audit log

**Status:** accepted for M5 (item 7, third part), 14 Nov 2026, and built (`src/s3/audit.cee`, `src/s3/server.cee`,
`src/s3/serve.cee`).

## Context

- **Who did what is not recorded.** The server logs errors of its own (a 5xx, a failed upkeep) on stderr, and the
  stats count requests by class (ADR-0033). Nothing says which key deleted an object, or that an anonymous request
  was refused.
- **Since M5 there is more to ask about:** policies and ACLs let anonymous requests in (ADR-0043, ADR-0045), keys
  come and go (ADR-0050), and a locked version can be asked to go (ADR-0047).
- **A request's handler is async code and must not block** (ADR-0008): it cannot write and sync a file itself.

## Decision

1. **`serve --audit-log <file>`** appends a line for every request the S3 handler answers, after its response.
   Without the option nothing is recorded and nothing is spent.
2. **A line is one JSON object:**
   - `time` (when the response was finished), `id` (the `x-amz-request-id`), `remote` (the peer's address, no
     port; no proxy header is trusted, as in ADR-0043 §6);
   - `requester`: the access key that signed, `anonymous` for a request without credentials, `-` for one that was
     not authenticated: a signature that did not check, a preflight, a form upload (whose signer is in its form);
   - `method` and `path` as the request gave them, and `query`: **the names of its parameters, never their
     values.** A presigned URL's values are its signature and its credential scope, good for as long as it
     lasts; a log that kept them would be a file of credentials;
   - `result`: `ok`, or the S3 error's code with its `status`, or `aborted` for a request whose connection
     failed before an answer; `micros`, the time to the last byte of the response.
   - No header, body, key or secret is logged.
3. **Written by a task beside the server.** The handler makes the line and puts it in a queue of 8,192 lines; a
   task takes what is waiting, up to 256 KiB, and appends it to the file with one write and one sync, on a worker
   thread. The file is opened for each batch, so a log renamed away by a rotation is begun again under its name.
   - **A full queue drops the line and counts it** (`auditLinesDropped` in the stats): a request is never held, or
     refused, for the log.
   - A write that fails loses its batch; it is reported on stderr once, until a write succeeds again.
   - `serve` stops at start if the file cannot be opened for writing.
4. **What it promises:** every request answered is logged within moments, in the order the responses finished,
   unless the queue was full or the file could not be written. A crash loses the lines still in the queue.

## Consequences

- An operator can answer who read, wrote and deleted what, and from where, by reading a file with any tool that
  reads JSON lines.
- **It is not a tamper-proof record, nor a complete one under overload:** it is written after the response, so a
  request can succeed and its line be lost to a crash or a full queue. A log that must lose nothing has to be
  written before the response, at the cost of a sync per request or a batch's wait.
- The log grows with the requests; rotation is the operator's (rename the file; the next batch begins a new one).
- Each request with the log on costs the line's formatting and one push onto a queue, both without the store's
  lock. With it off, one check.
- A form upload's line has `-` for its requester, and a successful request's line has no status code (the handler
  does not see which 2xx or 3xx was sent).

## Rejected

- **Logging the query's values with the signature removed:** a list of names to strip that has to be kept in step
  with every way of signing; names alone need no such list.
- **Holding a request until its line is durable:** an audit trail that strong belongs with the write itself, in
  the journal, and costs every request a wait. Kept for when someone needs it.
- **S3's server access log format, delivered to a bucket:** a second writer into the store, with its own keys and
  its own failure modes, for a format made for another service's fields.
- **stderr:** it is where the server's own errors go, unbuffered and unsynced, and mixing the two makes both
  harder to read.
