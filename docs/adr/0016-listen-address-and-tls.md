# ADR-0016: Listen address and TLS

**Status:** accepted for M3 slice 9 (`src/s3/serve.cee`, `tools/tls_smoke.sh`), 8 Nov 2026

## Context

`cosmostore serve` listened on 127.0.0.1 over plain HTTP (ADR-0008 §1). An alpha has to be reachable from other
machines, and safely:
- SigV4 authenticates requests and protects their integrity;
- but over plain HTTP, object bytes and metadata travel in the clear.

CeeSafe.Web has native TLS (`web_tls`, TLS 1.2 and 1.3 from OpenSSL 3). It is a `trusted` package with a C shim.
CosmoStore's rule is that it calls no C and has no `unsafe`.

## Decision

1. **The listen address.** `serve <dir> <[address:]port> …`:
   - a bare port keeps 127.0.0.1, so nothing that worked changes;
   - `0.0.0.0:9000` listens on every IPv4 address;
   - `[::]:9000` listens on IPv6 and, not being v6-only, on IPv4 too;
   - a specific interface address works as well.
   - The startup notice names the address, with IPv6 in brackets.
2. **Native TLS through `web_tls`,** chosen over a reverse proxy, so a single binary serves securely, as MinIO does.
   - `--tls-cert <pem> --tls-key <pem>` takes a chain (leaf first) and its key. Both or neither, or the server
     refuses to start.
   - ALPN offers only `http/1.1`, which is what the S3 layer serves.
   - CosmoStore's own code still calls no C and has no `unsafe`. The C is in a dependency, the same way OpenSSL
     would be behind any TLS library. Building needs OpenSSL 3 (Homebrew `openssl@3` on macOS). AGENTS.md records
     this.
3. **Setup errors stop the server before the store opens,** so a bad certificate costs no recovery:
   - a certificate without its key;
   - a key that is not the certificate's;
   - a file that cannot be read.
   Each gets one line naming the file.
4. **Files** are read through `DurableFile`, as the credentials file is (`readSmallFile`, at most 1 MiB).
5. **Plain HTTP stays the default.** With no certificate, the server is plain HTTP on whatever address it is
   given. Binding a public address without TLS is the operator's choice, and the docs say what it exposes.

## Rejected

- **A reverse proxy only** (Caddy, nginx), as Garage recommends. It keeps C out of the build, but it is a second
  process to run and configure for the common case, and the user chose native TLS.
- **Two builds, with and without TLS.** Twice the configurations to build, test and document.

## Tests

`tools/tls_smoke.sh`:
- **Setup:** a throwaway CA and a server certificate for `localhost` and `127.0.0.1`. The refused setups exit with
  their one-line errors, and leave no store.
- **Over TLS on 0.0.0.0, with each client verifying the CA:**
  - the AWS CLI makes a bucket and copies 12 MB multipart both ways;
  - curl checks the handshake (verification result 0, HTTP/1.1), an anonymous request (AccessDenied), and a
    presigned GET;
  - rclone lists the bucket.
- **Refusals:** plain HTTP to the TLS port, and a client without the CA (curl, and the AWS CLI with its bundle
  unset). The server keeps serving after each.
- **Cleanup:** delete everything, then fsck.

The listen address was also tried by hand: a bare port, `0.0.0.0`, `[::]` (reachable over IPv4 and IPv6) and `[::1]`.

**Measured** (macOS laptop, loopback): `aws s3 cp` of 256 MiB takes 1.3 to 1.5 s up and about 1 s down over TLS,
the same as plain HTTP in alternating runs.

## Not yet

- **Certificate reload without a restart.** `TlsConfig.reload` exists; a trigger such as a signal or a file watch
  does not.
- **SNI** with several certificates (`addName`).
- **Client certificates.**
- **HTTP/2.**
