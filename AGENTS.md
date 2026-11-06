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
- **Toolchain: ceesafec 0.20.0 or later**, which `ceesafe.toml` requires (`ceesafec = ">=0.20.0"`, CeeSafe ADR 0076):
  an older compiler stops at that line. 0.19.1 is the first that accepts `durable.cee`.
- CosmoStore calls no C and has no `unsafe` (since CeeSafe 0.19). A CeeSafe limitation goes in `CEESAFE_GAPS.md`
  (with evidence and a repro) for the CeeSafe repo, not around it with C or `unsafe`.
- CRC32C and MD5 are lib/std's; `src/storage/checksums/checksums.cee` pins the values the on-disk formats use.
- Before finishing: `ceesafec check`, `ceesafec fmt --check`, `ceesafec test` (all pass, no leaks).
