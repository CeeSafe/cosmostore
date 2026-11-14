# ADR-0054: An admin API and CLI

**Status:** accepted for M5 (item 7, last part), 14 Nov 2026, and built (`src/s3/admin.cee`, `src/s3/stats.cee`,
`src/store/object_store.cee`, `src/main.cee`). It closes item 7.

## Context

- **What an operator can ask a running server today:** its stats, a JSON document at `/_cosmostore/stats`
  (ADR-0021), and, bucket by bucket, each configuration through its S3 call. A bucket's quota and use have calls
  of their own that no S3 tool sends (ADR-0052).
- **What needs a tool to ask:** every call is signed with SigV4. `curl` cannot; the AWS CLI can, for S3's calls
  only. The smoke script signs the others with a Python script (`tools/s3_raw.py`).
- **The binary has what a client needs:** the server's own canonical request and signing key (ADR-0008), and
  since ADR-0048 CeeSafe.Web's HTTP client.
- **The choice made with the user** (14 Nov 2026): start small. The stats and a few signed calls, not a second
  API beside S3.

## Decision

1. **The admin API is the `_cosmostore` endpoint,** for a signed key only, as the stats are (ADR-0043 §5: no
   bucket policy reaches it, and an anonymous request is refused). One call is added:
   - `GET /_cosmostore/buckets`: every bucket, in the order of their names, as JSON: its name and creation time,
     the versions and bytes it holds, its quota (`maxBytes`, `maxObjects`, 0 for none), its versioning (`Off`,
     `Enabled`, `Suspended`), and whether it has a policy, an ACL other than the private one, a public-access
     block, object lock, lifecycle rules, notification rules and CORS rules. No object is read: it is the
     buckets' entries.
   - What is set on a bucket stays where S3 puts it: its own calls. The admin API does not repeat them.
2. **`cosmostore admin <endpoint> <credentials-file> <command>`** sends one request, signed with the file's first
   key, and prints the answer:
   - `stats`: `GET /_cosmostore/stats`;
   - `buckets`: `GET /_cosmostore/buckets`;
   - `quota <bucket>`: the bucket's limits and use; `quota <bucket> <max-bytes> <max-objects>` sets them (0 for
     no limit of that kind); `quota <bucket> off` takes the quota off (ADR-0052 §3).
   - The endpoint is `http://host[:port]` or `https://host[:port]`; an https one is verified against the system's
     roots. The answer goes to stdout and the exit status is 0 for a 2xx; any other answer goes to stderr with
     status 1; a command there is not prints the usage, status 2.
   - It signs as the server checks: the same `canonicalRequest`, `signingKey` and `seedSignature`, over `host`,
     `x-amz-content-sha256` and `x-amz-date`, region `us-east-1`.
3. **It is a client like any other.** It needs no access to the store's directory, runs from any host that can
   reach the server and has a credentials file, and is subject to the policies' Deny statements, the rate limits
   (ADR-0053) and the audit log (ADR-0051) as every request is.

## Consequences

- An operator sees every bucket's size, limits and configuration in one call, and sets a quota from a shell,
  with the server's own binary and no other tool.
- There is still no call to change the server's own settings (its options are its command line), to force an
  upkeep round or a credentials reload (both happen within a round, ADR-0050), or to look into the outbox beyond
  its counts in the stats.
- The first key of the credentials file is the CLI's: a file made for the server works for it as it is.
- The CLI adds a second user of the HTTP client and the first of the signing code as a signer; a change to
  either is now tested from both sides.

## Rejected

- **A separate admin listener** on another port, with its own authentication: a second thing to secure, where
  the S3 listener already has TLS, keys, policies' Deny, rate limits and an audit log.
- **Admin commands that open the store's directory:** the store has one writer, the server; `fsck` is the
  command for a store that is not being served.
- **Repeating every bucket configuration call in the CLI** (policies, CORS, lifecycle…): the AWS CLI and every
  SDK already send them.
- **JSON for the quota calls too:** they are a bucket's subresource beside its other subresources, which are XML.
