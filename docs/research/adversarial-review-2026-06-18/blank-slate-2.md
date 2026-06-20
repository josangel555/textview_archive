# Adversarial review — blank-slate-2 (2026-06-18)

Read-only adversarial pass over the Rust FFI boundary, the Swift bridge
(MessagePack decode + remote transport), the file-IO/save paths, the SQLite
reader, the WebView HTML pipeline, and the terminal/PTY + archive subprocess
surfaces. The Rust-Core FFI and the editor-save path are exceptionally
well-audited; the real defects are in the less-trodden corners: a SQLite
use-after-free, an unbounded-recursion DoS reachable from an untrusted remote
server, and a couple of lower-severity hardening gaps.

---

### sqlite3_bind_text holds a dangling pointer (use-after-free)

**Severity:** high

**Location:** `Sources/ViewerCore/SQLite/SQLiteReader.swift:161-168`

**Why:** `schemaFor(_:)` binds the table name like this:

```swift
let bytes = Array(name.utf8CString)
bytes.withUnsafeBufferPointer { buf in
    _ = sqlite3_bind_text(stmt, 1, buf.baseAddress, -1, nil)   // nil destructor = SQLITE_STATIC
}
if sqlite3_step(stmt) == SQLITE_ROW { ... }                     // <-- runs AFTER the closure
```

Passing `nil` as the 5th `sqlite3_bind_text` argument selects `SQLITE_STATIC`,
which is a promise to SQLite that the bound pointer stays valid until the
statement is reset or finalized — SQLite copies nothing, it retains
`buf.baseAddress`. But `buf.baseAddress` is only guaranteed valid for the
duration of the `withUnsafeBufferPointer` closure. By the time
`sqlite3_step` dereferences the bound text (line 165, after the closure has
returned), the backing storage of the `bytes` array may already have been
released or moved by the optimizer/ARC. SQLite then reads freed memory:
classic use-after-free → garbage schema, wrong-row results, or a crash, and
in the worst case a read of attacker-influenced reclaimed heap. `name` comes
from `tableNames()`/`viewNames()` over an *opened SQLite file*, so a crafted
`.db`/`.sqlite` opened in the viewer is the trigger. This is the ONLY
`sqlite3_bind_*` site in the reader, so it's an isolated fix.

**Fix:** Use `SQLITE_TRANSIENT` so SQLite makes its own copy:
```swift
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
_ = sqlite3_bind_text(stmt, 1, buf.baseAddress, -1, SQLITE_TRANSIENT)
```
Or move `sqlite3_step`/column reads *inside* the `withUnsafeBufferPointer`
closure so the pointer outlives the step.

**VERDICT: CONFIRMED** — The only `sqlite3_bind_*` site
(`SQLiteReader.swift:163`) passes `nil` (= `SQLITE_STATIC`), and `sqlite3_step`
(line 165) runs AFTER the `withUnsafeBufferPointer` closure returns.
`withUnsafeBufferPointer` only guarantees the pointer's validity inside the
closure; SQLITE_STATIC then dereferences it on step → genuine UAF. Reachable via
`schemaFor(_:)` on any opened DB (exercised by `SQLiteReaderTests.swift:104`).
Real defect.

---

### MessagePack decoder is unbounded-recursive — stack-overflow DoS from a remote server

**Severity:** high

**Location:** `Sources/RustCore/MessagePack.swift:92-184` (`MsgPackReader.decode` →
`array`/`map` → `decode`); reached from `Sources/RustCore/RemoteTransport.swift:232`
(`readLoop`), `:168-169` (`subscribe`), `:368` / `:395-396` (hello).

**Why:** `decode()` recurses once per level of array/map nesting with no depth
limit. The existing OOM guard only clamps `reserveCapacity`; it does not bound
recursion *depth*. The `array`/`map` element loops happily recurse to whatever
nesting the bytes encode. A frame consisting of ~N copies of the 1-byte
fixarray-of-1 tag `0x91` (or fixmap tag `0x81` pairs) drives N stack frames.
The remote read path accepts frames up to `16 MiB`
(`RemoteTransport.swift:222`), and ~16 million nested `0x91` bytes is trivially
enough nesting to exhaust the reader thread's stack and crash the whole
process — there is no `catch` for a stack overflow.

This matters because `RemoteTransport` decodes MessagePack produced by a
**remote `mdv-serve` daemon over a socket**, and the design explicitly treats
client and server as independently-versioned / mutually-distrusting peers
("the ssh tunnel is the trust boundary", `RemoteTransport.swift:16`; protocol
"client and server WILL version independently",
`Sources/RustCore/CoreClient.swift:166`). A malicious or buggy server (or a
MITM inside the tunnel endpoint) can crash the app at will with one frame.
Note the asymmetry: the Rust side decodes via `rmp-serde` into **fixed typed
structs** (`rust-core/crates/core/src/wire.rs`), whose depth is bounded by the
type, so the server is not vulnerable to the inverse — only the Swift generic
`MsgPackValue` tree decoder is.

**Fix:** Thread a depth counter through `decode()` (increment in `array`/`map`
before recursing, throw `MsgPackError.truncated`/a new `.tooDeep` past a sane
cap, e.g. 128). Cheap and total. Optionally also cap total element count.

**VERDICT: CONFIRMED** — `MsgPackReader.decode()` recurses via `array`/`map`
with NO depth cap (the only guard, `reserveCapacity` clamp at lines 167/177,
bounds memory not depth). `readLoop` (`RemoteTransport.swift:232`) decodes
attacker-controlled frames up to 16 MiB (line 222) from a remote `mdv-serve`;
~16M nested `0x91` bytes → stack overflow → uncatchable crash. Path is live
(`RemoteCoreAttach.attachIfConfigured` ← `main.swift:70`, gated on
`MDV_REMOTE_SOCKET`). The "buggy/skewed server crashes the client" robustness
gap is real even under the ssh-tunnel trust model. Real defect (note: opt-in
remote feature, so impact is bounded to remote-attach deployments).

---

### NSRange built from unvalidated remote highlight offsets can crash the text layer

**Severity:** medium

**Location:** `Sources/RustCore/CoreClient.swift:1052-1056`
(`Int(try a[0].u64Value())`), consumed at
`Sources/ViewerCore/RustHighlightAdapter.swift:53-55`
(`NSRange(location: run.start, length: run.len)`).

**Why:** `mdvCoreHighlightRuns` decodes `start`/`len` from the response frame
with `Int(try a[0].u64Value())`. Two problems if the frame comes from a
non-trusted producer (the remote transport — `highlight` is an engine
capability bit, set in both the in-process mask AND a remote hello, so this
path *can* route to a server): (1) `Int(UInt64)` traps at runtime for any
value `> Int.max` — a server returning `start = 2^63` crashes the app; (2) even
in-range-but-wrong offsets become an `NSRange` whose `location + length` can
exceed the text's UTF-16 length, and applying that range to `NSTextStorage` /
attributed-string APIs throws `NSRangeException` (a crash). The in-process
core emits validated UTF-16 offsets so this is latent today, but the adapter is
the boundary that's supposed to be fail-safe ("any bridge fault → Swift",
`RustHighlightAdapter.swift:9`) and it trusts the offsets unconditionally.

**Fix:** Use the non-trapping `Int(exactly:)`/`UInt64`-clamp, and clamp/skip
runs whose `start`/`start+len` exceed `(text as NSString).length` before
constructing the `NSRange`.

**VERDICT: CONFIRMED (partial — defect #1 real, defect #2 refuted)** — Defect #1
is real: `CoreClient.swift:1053-1054` does `Int(try a[0].u64Value())`, and
`Int(UInt64)` traps at runtime for values `> Int.max` (a remote server returning
`start=2^63` crashes the app, pre-clamp, at decode time). Highlight IS a
capability bit so a remote producer can route here. Defect #2 (NSRangeException
from applying an over-long range to `NSTextStorage`) is REFUTED: every apply path
clamps to the text length before building the applied range —
`TextDisplayView.applyAttributedString` (lines 1032-1034: `max(0,…)`/
`min(full.length,…)`/`guard hi > lo`), `TreeSitterEngine.paintOver`
(lines 140-142), and `HTMLRenderer.spanned` (lines 328-329). So no
NSRangeException, but the unchecked `Int(UInt64)` trap stands as a real
remote-triggerable crash. Net: real defect, narrower mechanism than stated.

---

### PTY child does non-async-signal-safe work between forkpty() and execve()

**Severity:** medium

**Location:** `Sources/ViewerUI/Terminal/PTYProcess.swift:89-99` and
`:118-151` (`execLoginShell`).

**Why:** After `forkpty()` the child (still a multi-threaded address space until
`execve`) runs Swift code before exec: `ProcessInfo.processInfo.environment`,
Swift `Dictionary` construction + `.map`, `strdup`/`malloc`, and Swift String
bridging (`withCString`). In a multi-threaded process, only async-signal-safe
functions are legal between `fork` and `exec`; if any *other* thread held the
malloc lock (or a Swift runtime lock) at the instant of fork, the child can
deadlock forever holding the PTY, or corrupt runtime state. The app is heavily
multi-threaded (FSEvents callbacks, the RemoteTransport reader thread,
DispatchQueues, WebKit), so this is a real (if intermittent) hang risk on
terminal spawn. The code comment already flags it as "async-signal-safe-ish".

**Fix:** Pre-compute everything (env strings, argv, `strdup`'d C arrays, the
resolved shell path) in the PARENT before `forkpty`, and in the child do only
async-signal-safe calls (`chdir`, `execve`). Better still, replace `forkpty` +
hand-rolled exec with `posix_spawn`/`posix_openpt`+`grantpt` which avoids the
fork-without-exec window entirely.

**VERDICT: CONFIRMED** — The child branch (`PTYProcess.swift:89-99`) and
`execLoginShell` (118-151) run after `forkpty` and before `execve`:
`ProcessInfo.processInfo.environment` (119, 127), Swift `Dictionary.map` (130),
`strdup`→`malloc` (134-137), and `withCString` String bridging (139) — none
async-signal-safe. The process is heavily multi-threaded (RemoteTransport reader,
FSEvents, DispatchQueues, WebKit), so the classic "another thread held the malloc
lock at fork" deadlock window is real. The code comment itself concedes
"async-signal-safe-ish". Intermittent but genuine latent hang/corruption. Real
defect.

---

### Remote-transport call-id space monotonically grows and is never reset; nextId starts at 2

**Severity:** low

**Location:** `Sources/RustCore/RemoteTransport.swift:34,109` (`nextId`).

**Why:** `nextId` starts at 1 and the first `callInner` does `nextId &+= 1`
*before* using it, so the first real call uses id 2 — id 1 is never used as a
call id, and id 0 is used only for hello. Harmless functionally, but the `&+=`
wraparound means after `UInt64.max` calls the ids wrap to 0/1 and could
theoretically collide with an in-flight hello-era id; far more importantly the
off-by-one (`&+=` before read instead of post-increment) is a latent foot-gun
if anyone later assumes call ids start at 1. Pure correctness/clarity nit on an
otherwise careful concurrency design (the reader/writer split, deadline, and
slot signalling all look right).

**Fix:** Post-increment (`let id = nextId; nextId &+= 1`) and document that 0 is
reserved for hello, so the first call is id 1.

**VERDICT: CONFIRMED (cosmetic — no functional bug)** — Factually accurate:
`nextId = 1` (line 34); `callInner` does `nextId &+= 1` BEFORE reading
(lines 109-110), so the first call uses id 2 and id 1 is never used; hello uses
id 0 (line 363). No correctness or concurrency impact today (ids only need to be
unique among in-flight calls, which they are). It is a real clarity/latent-
foot-gun nit, not a defect — kept at low severity per its own framing.

---

## Notes on areas reviewed and found SOUND (no action)

- **Rust FFI (`rust-core/crates/ffi/`)** — handle registry (TSK-541) closes the
  free-vs-call UAF correctly; `MdvBuf` round-trips cap properly; hex width is
  clamped to avoid the `handle_alloc_error`→abort vector; every extern fn nulls
  its out-params before any early return. Genuinely well-audited.
- **Editor save (`Sources/ViewerCore/EditorBuffer.swift:245-364`)** — temp-write
  + atomic `rename(2)` on the same volume, O_NOFOLLOW symlink classification,
  mode/owner/xattr replay even on the EACCES (unreadable-but-exists) path,
  BOM re-emission for explicit-endianness UTF-16. No data-loss window found.
- **HTML/markdown WebView pipeline** — strict CSP (`default-src 'none'`,
  no `script-src`) on both the markdown (`HTMLRenderer.renderPage`) and raw-HTML
  (`HTMLDocumentPolicy`) paths, DNS-prefetch disabled, allowlist sanitizer as
  defense-in-depth, depth-bounded markdown AST visitor. The
  `allowsContentJavaScript = true` on the markdown view is safe because the CSP
  blocks page-authored scripts.
- **Archive extraction (`ArchiveCatalog`)** — members stream over stdout
  (`unzip -p` / `tar -O`), entry name never becomes a write path, args passed
  as arrays (no shell). Path-traversal contained.
- **`XattrIO`, `SpectrumAnalyzer` vDSP rebind, `ClaudeLogParser`,
  `FolderWatcher` FSEvents callback, image-histogram raw pointer** — all bounds-
  correct.
