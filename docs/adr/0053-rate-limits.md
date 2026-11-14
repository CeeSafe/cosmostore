# ADR-0053: Rate limits

**Status:** accepted for M5 (item 7, fifth part), 14 Nov 2026, and built (`src/s3/rate.cee`, `src/s3/server.cee`,
`src/s3/serve.cee`).

## Context

- **Nothing bounds one client.** A script in a loop, or a key that leaked, takes as many requests as the server
  will give it, and every one of them is parsed, its signature checked and, since ADR-0045, an anonymous one reads
  its bucket's policy and ACL under the store's lock.
- **S3 answers such a client 503 SlowDown,** and its SDKs wait and try again.
- **The request path takes no lock for its own bookkeeping** (ADR-0035, ADR-0050), and async code may not block.

## Decision

1. **Two limits, each a number of requests a second, each off unless given:**
   - `serve --rate-limit-address <n>`: requests from one address, counted before the request is parsed or its
     signature checked. An IPv4 address is itself; an IPv6 address is its first 64 bits, the part a network gives
     one customer. No proxy header is trusted (ADR-0043 §6): behind a proxy every request has the proxy's address.
   - `serve --rate-limit-key <n>`: requests signed by one access key, counted once the signature has checked.
   - A request past either is SlowDown (503) with `Retry-After: 1`, and is counted in the stats (`rateLimited`)
     and, with its result, in the audit log (ADR-0051).
2. **Counted in windows of a second, in atomics.** Each limit has a table of 4,096 slots: a count, the second it
   is of, and whose it is. A request finds its slot (an address by its hash, a key by its place in the
   credentials, which is the same in every set, ADR-0050 §2), starts the count again if the slot's second is over,
   adds one, and is admitted while the count is within the limit. No lock, no allocation.
   - **A window, not a bucket of tokens:** a client may send its limit at the end of one second and again at the
     start of the next. The limit holds over any whole second, and is twice that over the worst two halves.
   - **Two holders that meet in one slot in one second share its count:** they are slowed together, sooner than
     either alone. Never the other way: a collision lets no one past its limit. With 4,096 slots it takes many
     addresses active in the same second.
   - A request refused still counts: a client that does not slow down stays refused.
3. **What is not limited:** nothing by bucket, by bytes or by kind of request; the upkeep, the delivery of
   notifications and the audit log's writer are not requests. A form upload and a preflight meet the address limit
   only, an anonymous request likewise.

## Consequences

- One address or one key can be kept from taking the whole server, with two options and no state on disk.
- The limits are the same for every address and every key: there is no way yet to give one key more.
- A limit is a ceiling on requests, not a share: under it, clients still compete for the store as before.
- Clients behind one address (a NAT, a proxy) share its limit.
- The cost with a limit on is a hash of the address and three atomic operations a request; with both off, two
  comparisons.

## Rejected

- **A token bucket per client,** which smooths the boundary: a refill needs the time of the last one and the
  tokens left to change together, which without a lock is a compare-and-swap loop over a packed word, for a
  boundary effect that is bounded.
- **A map from address to count:** it grows with the addresses seen, needs a lock or a concurrent map lib/std
  does not have, and an attacker chooses how many addresses it sees.
- **Limiting by bucket or by bytes a second:** other questions (a noisy tenant, a full disk) with other answers;
  quotas (ADR-0052) are the first of them.
- **Trusting `X-Forwarded-For`:** any client can send it, and then chooses whose limit it spends.
