# ADR-0019: Certificate reload, and upkeep options for `serve`

**Status:** accepted for M3 slice 12 (`src/s3/serve.cee`), 9 Nov 2026

## Context

- **Certificates expire.** With ACME (Let's Encrypt and the like), every 90 days or less. ADR-0016 read the
  certificate once, so renewing it meant restarting the server.
- **The upkeep was fixed.** Its interval (10 s) and the upload expiry (7 days, ADR-0017) could not be changed without
  rebuilding.
- **lib/std has no signal handling,** so SIGHUP cannot trigger a reload.

## Decision

1. **Reload by watching the files.** The TLS server's upkeep loop compares the certificate's and the key's modified
   times with those of the last good load, every round.
   - When either changes, it reads both and calls `TlsConfig.reload`. New connections get the new certificate, and
     open connections keep theirs.
   - **A failed reload** (a certificate written before its key, or a key that does not match) keeps the old
     certificate. It is logged as `cosmostore: TLS reload failed, keeping the old certificate: …` and tried again
     next round. A good one is logged as `cosmostore: TLS certificate reloaded`.
   - **No async I/O.** The stat and the reads block, so they run on a worker thread (`Async.blocking`). N0295 refused
     the first version, which did them in async code.
   - **`Fs.modifiedMillis`** (in `durable.cee`, as all file access is) wraps `File.modified`. It changes nothing a
     crash could lose, so it is not a fault point, and the fault sweeps' operation counts stay the same.
2. **Plain and TLS serving are two functions** (`servePlain`, `serveTls`). Each races the HTTP server against its
   upkeep loop; only the TLS loop also watches certificates.
3. **New options for `serve`:**
   - `--maintain-seconds <n>`: the upkeep interval, 1 to 86,400 s (default 10);
   - `--upload-expiry-hours <n>`: the age at which uploads are aborted (default 168; 0 for never).
   - Bad values stop the server before the store opens.

## Rejected

- **SIGHUP.** CeeSafe has no signal API. It would be a gap to log, not a reason to wait, and watching the files also
  covers ACME clients that only replace them.
- **An admin endpoint to trigger a reload.** It is a second, privileged API surface for one action.

## Tests

`tools/tls_smoke.sh`, 23 checks, the server with `--maintain-seconds 1`:
- a new certificate and key are served within a few rounds, compared by fingerprint through `openssl s_client`, and
  the reload is logged;
- then a broken key: the failure is logged, the working certificate is still served, and clients are still served.

The options were tried by hand: zero, a non-number, a negative number, an unknown option and a missing value are all
refused before the store opens, and valid values serve.

## Not yet

- Several certificates by SNI (`TlsConfig.addName`).
- Reloading the credentials file.
