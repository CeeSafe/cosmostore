<!--CEESAFE START-->

# Using CeeSafe

This package is written in CeeSafe, a memory-safe systems programming language with C#/TypeScript-style syntax that
`ceesafec` compiles ahead of time to C. Ownership and borrowing are checked at compile time; there is no garbage
collector. CeeSafe is new: code that looks right from C#, TypeScript or Rust often is not CeeSafe. Check every edit with the
compiler, and read the guide for agents: https://ceesafe.github.io/CeeSafe/guide/for-agents (the whole guide and
specification for a model's context: https://ceesafe.github.io/CeeSafe/llms-full.txt).

## The package

- `ceesafe.toml` names the package, its kind (`executable` or `library`) and its dependencies; `ceesafe.lock` pins them.
- The sources are the `.cee` files under `src/`. A program starts at `fn main()`.
- `ceesafec build` writes to `out/`, which is not committed.

## Commands

Run them in the package's directory; without file arguments they use the package.

| Command | What it does |
|---|---|
| `ceesafec check` | parse, type-check and borrow-check; the fastest way to find errors |
| `ceesafec fix` | apply the fixes the compiler is sure of, then check again |
| `ceesafec explain N0249` | what a diagnostic code means |
| `ceesafec run --interp` | run the program in the interpreter |
| `ceesafec build` | compile through C to `out/<name>` |
| `ceesafec fmt` | format in the one canonical style; `ceesafec fmt --check` lists files that would change |
| `ceesafec fetch` | resolve the dependencies and write `ceesafe.lock` |

Add `--diagnostics-format=json` to `check`, `build`, `run` or `fix` for one JSON document with every diagnostic, its
position and its fixes.

## The MCP server

If you have the `ceesafe` MCP server (`ceesafec mcp`), use its tools: `ceesafe_check` after every edit, `ceesafe_fix` for the
fixes it offers, `ceesafe_explain` for a code, `ceesafe_spec_search` and `ceesafe_spec_section` for the rules, `ceesafe_run` to
run code in a sandbox. The specification is embedded in `ceesafec`, so its answers match the compiler.

## Before you finish

- [ ] `ceesafec check` reports no errors (run `ceesafec fix` first).
- [ ] `ceesafec fmt --check` lists no file.
- [ ] The program does what was asked: `ceesafec run --interp`, or `ceesafec build` and run it.

## Common mistakes

- There is no `~`: complement with `x ^ 0xFFFFFFFF`. There are no type aliases or tuples, and no `==` on structs.
- An optional's fallback is `o ?? value`; `o.isSome()` and `o.isNull()` test it. `let _ = f();` discards a value.
- Indexes are `usize`. `0..4` is a `usize` range when the body indexes with its variable, else `i32`; `0..values.length` is `usize`.
- `if` and `match` expressions take expressions, `let s = if (x < 0) -1 else 1;`, or blocks that end with their value
  without `;`; a statement's block has no value.
- A variable that changes is `var`; a `let` cannot be assigned. A `borrow mut` argument is written `mut x`.
- `as` converts only without loss; `truncate<u8>(x)` wraps; `checkedTruncate<i64>(n)` (an optional) and
  `saturatingTruncate<u8>(n)` check or clamp, for integers and floats.
- `for (part in text.split(","))` loops over any value with `fn next(borrow mut this) -> T?`.
- A multi-line string is a raw `"""` literal: the closing `"""` line's indentation is removed, and there are no escapes.
- A function that always exits returns `never`: `fn die(m: StringView) -> never { …; Process.exit(1); }`.
- An `async move` child (`s.spawn`, `set.spawn`, `Async.timeout`/`race`/`all`) owns its captures and may move them.
- A view of a temporary, `make().view()`, lasts until the end of its statement: to keep it, bind the value to a local.
- There is no string interpolation: `"x = {x}"` prints `{x}` (warning N0400); write the value in a call of its own.
- Pass a function or closure as a parameter and call the parameter; a field holding one cannot be called.
- A `StringView` inside an enum or struct needs a region parameter; for fixed messages, use an enum of reasons.
- A method cannot have the name of a field.
- Look a name up before deciding it does not exist: MCP `ceesafe_api` (`TextWriter.decimal`, `Process.argument`), or
  the guide's built-in types page and the lib/core and lib/std API pages. A "did you mean" in an error names the real one.
- A lookup that may find nothing is an optional (`Process.argument(i)`, `StringView.fromUtf8(b)`): `Some`/`null`.
- Some keywords read like names (`own`, `type`, `move`, `drop`, `where`); async code uses `AsyncConsole`, not `Console`.

<!--CEESAFE END-->

# CosmoStore project rules

- Read `ROADMAP.md` (plan and progress log) and `docs/adr/` before changing storage code.
- The ordering rule is absolute: never publish metadata or acknowledge a write before the journal batch
  holding it has been synced (ADR-0001).
- All file and directory I/O goes through `DurableFile`/`Fs` (`src/storage/io/durable.cee`), so the fault
  injector and crash model of ADR-0004 cover it. A durability change needs a fault sweep.
- **Toolchain: ceesafec 0.95.1 or later**, which `ceesafe.toml` requires (`ceesafec = ">=0.95.1"`, CeeSafe ADR 0076):
  an older compiler stops at that line.
  - **What 0.95.1 gives CosmoStore:** lib/std's zstd encoder, `Zstd.compress`: compaction writes a ZSTD table's pages
    in ZSTD at its level, and its manifests in zstandard when the table asks (ADR-0116, CeeSafe ADR 0196 phase 4).
  - **What 0.94.4 gives CosmoStore:** lib/std's `Zstd`: Parquet's ZSTD pages read (PyIceberg's default codec, so its
    tables' files are merged, ADR-0112), and Avro's zstandard blocks (ADR 0196 phase 3).
  - **What 0.94.0 gives CosmoStore:** lib/std's `Snappy`: Parquet's SNAPPY pages read and written (compaction writes
    SNAPPY, ADR-0112), and Avro's snappy blocks read (ADR 0196 phase 2).
  - **What 0.90.0 gives CosmoStore:** lib/std's `Deflate` for Avro's deflate blocks and `Gzip` for the inventory
    reports (G35, ADR 0196); CosmoStore's own inflater is gone.
  - **What 0.87.0 gives CosmoStore:**
    - `Secret.wipe` for every secret it zeroes, since a plain loop of stores is the C compiler's to remove (G43, ADR
      0197);
    - the master key's cells as `[AtomicU64; 4]` (G41, ADR 0198);
    - lib/std's `Crc32` and `Sha1` in place of its own (G26, ADR 0194).
  - **Also since 0.85.1:** `ceesafec test` needs no `-fbracket-depth` (G36, ADR 0195).
  - **CI** installs the release `CEESAFE_VERSION` names (v0.95.1) in every job, and
  CeeSafe.Web's pinned commit (CI's `CEESAFE_WEB_REF`, `ccda03a`, its main) needs 0.53; move both together, after
  `ceesafec check`, `test` and the smokes pass with them. Earlier floors, for the record: 0.94.4 (24 Nov 2026, briefly), 0.94.0 (23 Nov 2026, briefly), 0.90.0, 0.87.0 and 0.85.1 (21 Nov 2026, briefly); 0.54.0 (CI's
  v0.56.0 until 21 Nov 2026); 0.44 (`AsyncError.Closed`,
  CeeSafe ADR 0128; 0.27 made its route handlers `Send + Share`, ADR 0084); 0.30.0 adds `Crc32c` on the CPU's instruction (ADR 0089, G31);
  0.36.0 runs `Async.blocking` on a pool of reused threads (ADR 0094, G28); 0.38.0 resizes into zeroed memory, removes
  more bounds checks and inlines the allocator's fast path (ADRs 0099 to 0101); 0.41.0 lets `serve` raise its open-file
  limit (`ProcessLimits`, `IoError.TooManyOpenFiles`; ADR 0104, G32); 0.45.0 has `Aes256Gcm` for server-side
  encryption (ADR 0135, G33).
- CosmoStore calls no C and has no `unsafe` (since CeeSafe 0.19). A CeeSafe limitation goes in `CEESAFE_GAPS.md`
  (with evidence and a repro) for the CeeSafe repo, not around it with C or `unsafe`. The one C below it is
  CeeSafe.Web's `web_tls` (OpenSSL 3 through its shim) for TLS, a dependency chosen in ADR-0016; building needs
  OpenSSL 3 (Homebrew `openssl@3` on macOS).
- CRC32C and MD5 are lib/std's; `src/storage/checksums/checksums.cee` pins the values the on-disk formats use.
- The S3 layer (`src/s3/`, ADR-0008) uses CeeSafe.Web by path (`../../CeeSafe.Web/packages`). Async code must not
  block (N0295): store calls go through `Async.blocking`, and no `drop` may do I/O or take a lock.
- After changing `src/s3/` or the store's API: `ceesafec build && tools/s3_smoke.sh` (needs the AWS CLI v2), and
  `tools/tls_smoke.sh` after changing how `serve` listens.
- Before finishing: `ceesafec check`, `ceesafec fmt --check`, `ceesafec test` (all pass, no leaks).
