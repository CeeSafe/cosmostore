# ADR-0002: Durability primitives

**Status:** accepted, 6 Nov 2026; **the shim is gone**: since CeeSafe 0.19 (its ADR 0075), `durable.cee` is built
on CeeSafe's own `File.openOrCreate`/`createNew`, `readAt`/`writeAt`, `syncData` (F_FULLFSYNC on macOS), `length`,
`setLength`, `File.rename` and `Directory.sync`, and CosmoStore calls no C. The semantics below still hold.

## Context

CeeSafe 0.18.1's `File` cannot reopen a file for writing, sync it, do positional I/O, learn its size,
truncate it, or rename it (CEESAFE_GAPS.md G1–G5). A storage engine cannot be crash-safe without these.

## Decision

Use a small audited C shim (`durable_shim.c`, POSIX only) behind a documented contract, wrapped by the safe
CeeSafe types `DurableFile` and `Fs`. Nothing else in CosmoStore calls C. When CeeSafe's std gains these
operations, `durable.cee` switches to them and the shim is deleted.

| Operation | POSIX | macOS specifics |
|---|---|---|
| `DurableFile.openRead / openReadWrite / createNew` | `open` + `O_CLOEXEC` (`O_CREAT`, `O_EXCL`) | |
| `readAt`, `readExactAt` | `pread`, retried on `EINTR` | |
| `writeAt` | `pwrite` loop until every byte is written | |
| `syncData` | `fdatasync` (Linux) | **`fcntl(F_FULLFSYNC)`**; `fsync` only if that fails with `ENOTSUP`/`EINVAL` |
| `size`, `truncateTo` | `fstat`, `ftruncate` | |
| `Fs.syncDirectory` | `open(O_DIRECTORY)` + sync | same, with `F_FULLFSYNC` |
| `Fs.rename`, `Fs.unlink`, `Fs.ensureDirectory` | `rename`, `unlink`, `mkdir` | |

Rules every caller follows:
1. Bytes are not durable until `syncData` returns Ok.
2. A new file, or a rename, is not durable until its directory has been synced with `Fs.syncDirectory`.
   `Journal.createSegment` does both.
3. A failed sync is fatal for that file's writer (ADR-0001 §4).
4. Errors carry the operation and the errno (`IoFailure`).

Windows is not supported yet. Its semantics (`FlushFileBuffers`, directory durability, `MoveFileEx` with
`MOVEFILE_WRITE_THROUGH`) must be specified before it is, and guarantees must never be silently downgraded.

## Consequences

- Durability on macOS is real: `F_FULLFSYNC` costs about 4.6 ms on the development laptop, which is why
  group commit matters.
- The fault-injecting I/O layer (ROADMAP M0) will sit behind the same `DurableFile` surface. For now, crash
  tests simulate crashes by truncating and corrupting segment files.
