# CeeSafe gaps found while building CosmoStore

Issues found in CeeSafe 0.18.1 (`ceesafec --version`) while implementing the CosmoStore storage core,
for implementation in `~/dev/CeeSafe`. Each entry has the evidence, what CosmoStore does in the meantime,
and a suggested direction. Per CeeSafe's AGENTS.md, a missing feature is designed there spec-and-ADR first.

Priority: **P0** blocks a correct storage engine without C; **P1** costs correctness or much
boilerplate; **P2** ergonomics.

| # | Pri | Area | Summary |
|---|---|---|---|
| G1 | P0 | std/files | `File` cannot open an existing file for writing (`File.create` truncates) |
| G2 | P0 | std/files | No `fsync`/`fdatasync`/`F_FULLFSYNC`, no directory sync |
| G3 | P0 | std/files | No positional I/O (`pread`/`pwrite`) or seek |
| G4 | P0 | std/files | No file size (`fstat`) and no `truncate` |
| G5 | P0 | std/files | No `rename` |
| G6 | P1 | std/async | `AsyncFiles` has the same gaps as G1-G5 (open/create/read/write only) |
| G7 | P1 | language | `?` never converts error types; `Result` has no methods (`mapErr`, `isOk`) |
| G8 | P1 | std/collections | No ordered map; `String`/`Vector<u8>` are not `HashKey` (and the orphan rule stops users adding it) |
| G9 | P1 | std/crypto | No CRC32C, SHA-256, HMAC-SHA256 or MD5 in std; no CRC/SIMD intrinsics |
| G10 | P1 | std/time | No monotonic high-resolution clock (only `Clock.unixMillis`) |
| G11 | P1 | compiler | N0247 rejects a field of a reference returned by a method: `m.keyAt(0).name.view()` |
| G12 | P2 | language | No `assert`/`panic(message)` |
| G13 | P2 | language | Zero-length arrays rejected (`[0u8; 0]`); no empty-slice constant |
| G14 | P2 | core | Fixed arrays lack `readLE`/`writeLE` (slices have them) |
| G15 | P2 | tooling | `--sweep alloc` reports a test's own `!` unwraps as failures |
| G16 | P2 | tooling | Package C files are compiled from a temp copy, so `#include "x.h"` beside them fails |
| G17 | P2 | diagnostics | An N0247 error elsewhere in a function surfaces as a misleading N0265 (cannot infer `T`) |
| G18 | P2 | core | `Vector` has no `insert(at)`/`remove(at)` (needed for sorted vectors) |
| G19 | P1 | language | No way to move a value out of a `borrow mut` place (no `replace`/`take`/`swap` of values) |
| G20 | P2 | parser | `a as u64 < b` parses `<` as generic arguments (N0100 "expected '>'") |
| G21 | P1 | language/std | No safe process-wide table: arrays of atomics are rejected (N0259) and `Mutex` has no constant constructor |
| G22 | P2 | parser | No explicit dereference: `let id = *m.keyAt(0);` is N0102, even though spec §13.3 writes `*r` |
| G23 | P2 | tooling | `ceesafe.toml` cannot require a compiler version, so an older ceesafec gives type errors instead of "needs 0.19.1". **Fixed in CeeSafe 0.20.0** (ADR 0076): CosmoStore's manifest says `ceesafec = ">=0.20.0"` |

## Status (2026-11-06)

CeeSafe 0.19.0 (its ADR 0075) addressed every finding, and CosmoStore now uses the fixes:
- `durable_shim.c` is gone: `durable.cee` is built on `File`/`Directory` (G1–G5).
- `@from` variants replaced the `jio`/`jalloc`/`sj`/`salloc`/`metaAlloc` adapters (G7). `sio` stays, because it
  maps a corrupt read to `DataCorrupt`.
- lib/std's `Crc32c` and `Md5` replaced CosmoStore's own, and the generated table is gone (G9).
- The fault registry is static arrays of atomics, with no `unsafe` (G21).
- `replace` removed `ObjectWriter`'s copies (G19), arrays call `writeLE` directly (G14), and the benchmark times
  with `Clock.monotonicNanos` (G10).

Where CeeSafe differs from the suggestions below:
- G7 has no `map`/`mapErr`.
- G13 is `[]` as an empty slice, not `[T; 0]`.
- G21 has no `Mutex.constant`.
- G15 counts unwraps anywhere in a test file as the tests' own.

Not used yet:
- `OrderedMap` (G8), for the LIST index (ROADMAP M4).
- `AsyncFiles` (G6), for the async server.

The migration found that `File`'s positional methods needed `borrow mut this`, which CosmoStore's shared read paths
can't give. CeeSafe 0.19.1 (ADR 0075 §8) relaxes them to `borrow this`, so CosmoStore needs ceesafec 0.19.1 or
later; G23 covers the manifest's missing way to say so.

## Details

### G1–G5: durable file primitives (P0)

**Evidence.** `guide/builtins.md` "`File`, `TcpListener` and `TcpStream`" and `spec/type-system.md` §26.3:
`File.open` (read only), `File.create` (created **or truncated**), `File.remove`, `f.read`, `f.write`.
`File.kind` (§26.8) and `Directory.create/remove/list/temporary/current` (§26.10) exist. There is no way to:
reopen a journal for appending (G1), make data durable (G2), read or write at an offset (G3), learn or set a
file's length (G4), or atomically replace a file (G5). `grep -l "fsync\|pread\|rename" runtime/` finds none.

**Why it matters.** Without G2, no storage engine can promise that an acknowledged write survives power loss.
Without G1/G3/G4, crash recovery can't truncate a torn tail or read a record in place.

**Workaround.** `src/storage/io/durable_shim.c` (about 130 lines, documented contract) plus the safe
wrapper `src/storage/io/durable.cee` (`DurableFile`, `Fs`).

**Suggested API** (ADR-002 in CosmoStore records the semantics that are needed):
```
File.openWith(path, OpenOptions { read, write, create, createNew, append }) -> Result<File, IoError>
f.readAt(mut buffer, offset: u64) -> Result<usize, IoError>
f.writeAllAt(bytes, offset: u64) -> Result<void, IoError>
f.syncData() -> Result<void, IoError>   // fdatasync; F_FULLFSYNC on macOS; FlushFileBuffers on Windows
f.syncAll()  -> Result<void, IoError>   // fsync
f.length() -> Result<u64, IoError>;  f.setLength(n) -> Result<void, IoError>
File.rename(from, to) -> Result<void, IoError>      // atomic replace where the OS supports it
Directory.sync(path) -> Result<void, IoError>       // POSIX: open(O_DIRECTORY)+fsync; Windows: documented no-op or FlushFileBuffers on a dir handle
```
Points that need a spec decision:
- macOS `fsync` does not flush the drive cache, so `syncData` must use `F_FULLFSYNC`, falling back to
  `fsync` only on `ENOTSUP`.
- After a failed fsync, Linux may have dropped the dirty pages ("fsyncgate"). The doc should say a failed
  sync leaves the file's durable contents unknown.
- `EINTR` should be retried inside the runtime.
- Windows semantics need defining.

### G6: async file I/O (P1)

`spec/api/std.md` `AsyncFiles` has only `open`, `create`, `read` and `write`. A storage server on the async
runtime needs G1–G5 as async operations: io_uring `IORING_OP_FSYNC` and positional reads/writes, or a
blocking pool elsewhere. Until then, CosmoStore's journal is synchronous.

### G7: error conversion (P1)

**Evidence.** `spec/type-system.md` around line 889 (N0261: `?` needs the *same* error type). `Result` has no
methods (`error[N0234]: type 'Result<…>' has no methods; 'mapErr' cannot be called on it`). An optional has
no `okOr`.

**Cost.** Every module wraps errors by hand with generic adapters (`jio`, `jalloc` in `journal.cee`; `sj`,
`salloc` in `object_store.cee`; `metaAlloc` in `model.cee`). Code reads as `jio(file.size())?` instead of
`file.size()?`.

**Suggested.** `Result.mapErr(f)`, `isOk()`, `isErr()`, `ok()`; `T?.okOr(e)`. Ideally also a conversion
interface that `?` uses (`interface FromError<E>`), so `?` lifts `IoError` into a caller's error enum.

### G8: ordered map, and hashing strings (P1)

There is `HashMap` but no ordered map (B-tree or skip list). S3 listing needs ordered prefix and range
iteration, so CosmoStore v0 scans and sorts the whole index for each LIST (`listObjects` in
`object_store.cee`). Separately, `String` and `Vector<u8>` don't implement `HashKey` (`lib/std/collections.cee`
around line 129 lists only integers and bool). The orphan rule (`guide/generics.md` "An impl lives in the
package that declares the interface or the type") stops a user package from adding it, so every user writes
a wrapper struct (`IndexKey`, `BucketKey`).

**Suggested.** `impl HashKey` for `String`, `Vector<u8>` (and arrays of bytes), plus `BTreeMap<K, V>`
with `range(from, to)`, `seek(key)` and ordered iteration.

### G9: checksums and crypto (P1)

S3 needs CRC32C and CRC64NVME (checksum headers), MD5 (ETag, Content-MD5), SHA-256 and HMAC-SHA256 (SigV4).
`grep -rli sha256 lib/` finds nothing. CosmoStore has software CRC32C (slicing-by-8) and MD5. A std
implementation could use SSE4.2 `crc32` / ARMv8 `crc32c` instructions, which would need an intrinsics story.

### G10: monotonic clock (P1)

`Clock.now()` / `Clock.unixMillis()` and `UnixTime.millis()` are wall-clock milliseconds. Latency histograms
(p99 targets) and deadlines need a monotonic nanosecond clock, e.g. `Clock.monotonicNanos()`.

### G11: borrowing a field through a returned reference (P1, compiler)

Minimal repro (CeeSafe 0.18.1):
```ceesafe
struct K { name: Vector<u8>; }
impl HashKey<K> for K {
    fn hash(borrow this, h: borrow mut Hasher) { h.bytes(this.name.view()); }
    fn sameAs(borrow this, other: borrow K) -> bool => this.name.view() == other.name.view();
}
fn main() {
    var m = HashMap<K, u32>.create();
    var n = Vector<u8>.create();
    n.push(1)!;
    m.put(K { name: n }, 7)!;
    let length = m.keyAt(0).name.view().length;   // error[N0247]
    Console.writeLine(length);
}
```
`keyAt` returns `borrow(this) K`, so `m.keyAt(0).name` *is* "a place reached through a reference", which the
diagnostic itself says is allowed. Workaround: `let k = m.keyAt(0); k.name.view()`.

### G12–G18 (P2)

- **G12.** No `assert(cond)` or `panic("msg")`. Invariants become `checkedTruncate<u32>(x)!` or are only
  documented.
- **G13.** `[0u8; 0]` is N0259; an empty slice is spelled `buf[0..0]`.
- **G14.** `[u8; 64]` has no `readLE`/`writeLE` (N0234). You must write `let w = borrow mut h[..]; w.writeLE(…)`.
- **G15.** `ceesafec test --sweep alloc` treats a test's own `!` unwraps as sweep failures (580 of 639 runs for
  the store tests). Real leaks or crashes are hidden in the noise. Suggestion: report panics whose location is
  in the test function itself separately, or offer `Check`-style helpers that pass `AllocError` through.
- **G16.** C files listed in `c = [...]` are compiled from a temporary copy, so `#include "durable_shim.h"`
  next to the `.c` file fails until `include-dirs` names the source directory. Either compile in place or
  document it in `guide/packages.md`.
- **G17.** In `object_store.cee`, N0247 errors in one function also produced `error[N0265]: cannot infer 'T'
  for 'salloc'` on unrelated lines. Writing `salloc<void>` was then N0226, which has no way out. The N0265
  disappeared once the N0247s were fixed, so this is a cascade, and those follow-on diagnostics should be
  suppressed.
- **G18.** `Vector` has `push`, `pop`, `truncate` and `swap`, but no `insert(at, x)` or `remove(at)`.

### G19: moving out of a mutable place (P1)

Repro (0.18.1):
```ceesafe
struct W { buf: Vector<u8>; }
fn takeIt(w: borrow mut W) -> Vector<u8> {
    let held = w.buf;              // error[N0251]: cannot move a 'Vector<u8>' out of the value 'w' refers to
    w.buf = Vector<u8>.create();
    return held;
}
```
Vectors have no `swapWith`, and there is no `replace(place, value)` or `take(place)` (the equivalent of
Rust's `mem::replace`/`mem::take`). A type with a `drop` block also can't give fields up by value (N0252), so
a consuming `finish(this)` is impossible. `ObjectWriter.finish` (`src/storage/extent/extent.cee`) therefore
**copies** its inline buffer (up to 128 KiB) and extent list instead of moving them. Suggested: a built-in
`replace(borrow mut place, value) -> T` (with `take` for types that have a default), which is sound because
the place is never left empty.

### G20: `as` followed by `<` (P2)

`fn f(a: usize, b: u64) -> bool => a as u64 < b;` is `error[N0100]: expected '>', found ';'`: the `<` after the
type is read as the start of generic arguments. `(a as u64) < b` works. Either parse `as T <` as a
comparison when `T` takes no type parameters, or give a diagnostic that suggests the parentheses.

### G21: a process-wide table without `unsafe` (P1)

Repro (0.18.1):
```ceesafe
static SLOTS: [AtomicU64; 4] = [AtomicU64.constant(0); 4];
// error[N0259]: array and slice elements must be Copy types in v0; 'AtomicU64' is not Copy
static TABLE: Mutex<Vector<u64>> = Mutex<Vector<u64>>.create(Vector<u64>.create());
// error[N0205]: expected 'Mutex<Vector<u64>>', found 'Result<Mutex<Vector<u64>>, AllocError>'
```
Scalar statics of atomics work (`static N: AtomicU64 = AtomicU64.constant(0)`). But a *table* of shared state has
two ways in, and both are blocked: an array of atomics, or a `Mutex` around a collection. Neither is a static
initialiser (spec §39.4). CosmoStore's fault-injection registry (`src/storage/io/faults.cee`, ADR-0004) is
therefore a `static mut` struct of plain arrays. Every access goes through an accessor whose `unsafe` block argues
single-threaded use. That argument is true today, but it is what CeeSafe exists to check.

Suggested:
- allow arrays of non-`Copy` element types in statics when the repeat operand is a `@constant` call (each element
  is built at compile time, so there is no copy);
- give `Mutex<T>` an `@constant` constructor for a `T` that has one. An empty `Vector` needs no allocation, so
  `Vector.empty()` could be `@constant`;
- or offer `@threadLocal static` for single-thread state like this.

### G22: explicit dereference (P2)

```ceesafe
var m = HashMap<u64, bool>.create();
m.put(7, true)!;
let id = *m.keyAt(0);          // error[N0102]: expected expression, found '*'
let id: u64 = m.keyAt(0);      // works: auto-deref where a u64 is expected (§13.3)
```
Auto-deref covers most cases. But copying a `Copy` value out of a reference into an un-annotated `let` needs a
type annotation, which is easy to miss because the spec's own prose spells the read as `*r`. Suggested: accept
prefix `*` on a reference to a `Copy` type, or add a diagnostic that suggests the annotation.

### G23: a package cannot require a compiler version (P2)

Found with CeeSafe 0.19.1 on 2026-11-06. CosmoStore needs 0.19.1, because `File.readAt` and the others take
`borrow this` from that release on. With 0.19.0, `ceesafec check` reports 12 errors in `src/storage/io/durable.cee`,
the first being `error[N0248]: cannot borrow 'this.file' as mutable: it is behind a shared reference`. Nothing in them
says that a newer compiler would accept the package. The manifest's `[package]` keys are `name`, `version`, `kind`,
`profile`, `float`, `kernel`, `trusted`, `sources`, `tests` and `c` (`src/packages/manifest.cee` around line 316).
None of them names a compiler version.

Repro: run `~/.ceesafe/bin/ceesafec-0.19.0 check` in this repository at f5a3d9f.

Suggested: a `ceesafec = ">=0.19.1"` key in `[package]`. A compiler older than the requirement then stops with one
diagnostic naming both versions, before checking anything. `ceesafec fetch` could also check it for dependencies.

## Not gaps (checked)

Things that worked well and are worth keeping:
- `extern "C"` with `@effects()` and the `Safety:` rule.
- `drop` blocks for file descriptors.
- `HashMap` with insertion-ordered iteration.
- `sortBy` with closures.
- `wrappingAdd`/`wrappingMul` and `checkedTruncate`.
- `@test` with leak detection, which caught nothing because nothing leaked.
- `ceesafec fmt`.
- Closures that capture state mutably across `Journal.open`'s replay callback.
- Scalar `static` atomics as failpoints (`static ARMED: AtomicU32 = AtomicU32.constant(0)`): no `unsafe`, and
  `ceesafec test` runs each test in its own process, so they don't leak between tests.
- `ceesafec check` checks `@test` functions too.
- Passing a named function as a `fn(StringView, borrow mut T)` parameter: this is how the fault sweeps take
  their workload.
- Moving a field out of a local struct that has no `drop` (`state = loaded.state`).
