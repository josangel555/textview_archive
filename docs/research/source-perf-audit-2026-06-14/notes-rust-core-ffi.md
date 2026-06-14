# Rust-core / FFI boundary notes

Covers the `extern "C"` boundary, the Swift receive side, the wire codec,
dispatch, and the engine ports (find, markdown, transcript, highlight, fuzzy,
diff, hex). **This is the highest-leverage area** because every ported engine
funnels through one seam, and the migration is actively moving more load here.

## Already good (do NOT re-file)

- **Rust encode is single-allocation.** `wire::encode_frame` reserves a 4-byte
  length placeholder and serializes the body *in place* behind it, then backfills
  the prefix — no encode-then-copy of a separate body `Vec` (`wire.rs:194-223`).
  Byte-identity with the old path is pinned by a test.
- **Rust decode borrows from the frame.** `decode_frame_borrowed` /
  `decode_borrowed` let `#[serde(borrow)] Cow<'a, str>` request fields point
  straight into the frame bytes (`wire.rs:163-179`), so the whole-document
  request payloads (find/markdown/transcript/highlight) are NOT copied out on
  the Rust side. The find/highlight/transcript request structs all use
  `#[serde(borrow)]` correctly.
- **Snapshot/table serialize from arena borrows.** `session.snapshot_frame()` /
  `table_frame()` serialize the visible rows straight from borrows of the table
  arena — no per-pull owned-row clone (`ffi/src/lib.rs:817-820`, `:911-917`).
- **`find_engine::search`** does one byte-match pass then a *single monotonic
  sweep* to convert to UTF-16 + line/column — O(N), explicitly avoiding the
  O(M·N) per-match re-scan (`find_engine.rs:87-166`). Good.
- **Dispatch is one safe-Rust entry**, reused by FFI/TUI/web; raw-output methods
  (hex render, indent) skip the frame wrapper to avoid double-encoding an 18 MB
  dump (`dispatch.rs`, `lib.rs:554-572`). The `aux` bulk side-channel carries
  multi-MiB inputs zero-copy (borrowed `&[u8]`), frame-cap-exempt. Good design.

## Findings

### #1 — FFI **receive-side** response double-copy (extends TSK-564)
`Sources/RustCore/CoreClient.swift:102, 302, 401, 564, 588, 621` — **obvious;
profile to rank the magnitude.**

Every response crosses as `MdvBuf{data, len}`, and **every** Swift exit point
does:

```swift
let frame = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))  // COPY #1
defer { mdvcore_buf_free(&buf) }
return try CsvSession.unframe(frame)        // (TSK-564 made unframe zero-copy via offset)
// → MsgPackReader(frame).decode()          // re-walks the [UInt8]
```

TSK-564 already addressed the `frame[4...]` *body slice* copy (via
`frameBodyStart` + `MsgPackReader(_:startingAt:)`). But the **bigger** copy is
the very first line: `Array(UnsafeBufferPointer(...))` copies the entire response
frame from the C buffer into a fresh Swift `[UInt8]` **before** anything is
decoded. This happens at 7 sites — the envelope call, the session snapshot
window, `callBuf`, `mdvFrameCall`, `mdvEnvelopeCall`, and `mdvEnvelopeCallAux`.

The blast radius is largest where the response is large:
- **hex render** (`mdvCoreHexRender`) returns ~18 MB of dump text for a 4 MB
  file — copied whole into a Swift `[UInt8]`, then `String(decoding:)`'d (another
  pass) at `CoreClient.swift:849`.
- **markdown render** / **transcript parse** / **highlight runs** can each return
  multi-MB frames on large documents.

**Fix:** decode **directly from the `MdvBuf` pointer**, before `mdvcore_buf_free`.
`MsgPackReader` could take an `UnsafeBufferPointer<UInt8>` (or
`UnsafeRawBufferPointer`) bounded by `buf.len` instead of an owned `[UInt8]`.
Then the response frame is never copied into Swift heap at all — decode reads it
in place out of the Rust-owned buffer, and `mdvcore_buf_free` runs after decode
completes. For the raw-output methods (hex render / indent) that return a UTF-8
string, `String(decoding: UnsafeBufferPointer..., as: UTF8.self)` reads the
buffer directly (one pass, no intermediate `[UInt8]`).

**Caveat:** the lifetime discipline must be airtight — the reader must finish
(and any borrowed `String`s be materialized) **before** `mdvcore_buf_free`. The
current `defer { mdvcore_buf_free }` ordering already runs the free after the
return value is built, so this is a mechanical change, but it touches the
unsafe seam. **Effort M, risk M** (unsafe-pointer lifetime), **measure first**
to rank vs #2. This single change benefits *every* port simultaneously.

### #6 — `highlight::runs_utf16`: `String` alloc per run
`rust-core/crates/highlight/src/runs.rs:188` — **obvious, micro→felt on large
files.**

```swift
_ => runs.push(Run { start: cur_u16, len: body_u16, kind: kind.to_string() }),
```

`kind` is a `&'static str` (from `APP_CAPTURES`), but each run clones it into an
owned `String`. A 5k-token source file makes ~5k throwaway `String`s, then
serializes them (rmp-serde re-copies into the frame anyway). The `Run.kind`
field is `String` because it's `Serialize`/`Deserialize`, but internally it
could hold `&'static str` (or `Cow<'static, str>`) and only materialize at
encode time — or, since there are ~20 distinct kinds, intern them.

**Fix:** change `Run.kind` to `Cow<'static, str>` (`#[serde(borrow)]` not even
needed for serialize; the static strs serialize fine) so `kind.to_string()`
becomes a zero-cost `Cow::Borrowed`. **Effort S, risk low** (the wire bytes are
identical — a `Cow<str>` serializes as a string; pinned by the existing
round-trip tests). Bundle into the micro-opt ticket.

### #7 — `HTMLRenderer.spanned`: per-run `lowercased()` + `NSString.substring`
`Sources/ViewerCore/HTMLRenderer.swift:331-336` — **obvious, micro→felt on
fence-heavy markdown.** (This is Swift-side, listed here because it's the
companion to the highlight port.)

```swift
out += "<span class=\"tok-\(run.kind.rawValue.lowercased())\">"  // alloc per run
let chunk = ns.substring(with: NSRange(location: lo, length: hi - lo))  // alloc per run
```

`run.kind.rawValue.lowercased()` produces the same string for every run of a
given `TokenKind`, recomputed per run. With many runs (a large highlighted code
fence) that's a `lowercased()` allocation per token.

**Fix:** precompute `static let tokClass: [TokenKind: String]` (or store the
lowercased class on `TokenKind` itself) and look it up. The `ns.substring(with:)`
per run is harder to avoid here (the splice needs the substring to escape), but
note this whole path **retires when the TSK-660 highlight port + chunk splice
fully replaces the Swift visitor** — so weigh effort against that timeline.
Effort S.

### #11 — Swift `MsgPackReader` response-map dict rebuild
`Sources/RustCore/MessagePack.swift:195-204` — covered in the parsers note;
it's on every ported-engine response decode. Micro; bundle.

## Not findings (checked, fine)

- The Rust per-engine `*_wire` functions that `.collect()` into a response `Vec`
  (e.g. `find_engine::search_wire` mapping `EngineMatch` → `WireEngineMatch`,
  `find_engine.rs:224-233`) allocate one result vec — unavoidable, it's the
  serialize input, and it's sized with `with_capacity`. Fine.
- `escape_literal` (`find_engine.rs:51`) reserves `pattern.len() * 2` up front.
  Fine.
- The capability/method-id tables are `const`/`match` — zero runtime cost.
