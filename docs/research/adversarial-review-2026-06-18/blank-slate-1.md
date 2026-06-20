# Adversarial review — blank-slate-1 (2026-06-18)

Read-only adversarial pass over the Swift (`Sources/`) and Rust (`rust-core/`)
trees, prioritising the FFI boundary, file/subprocess I/O, hostile-input
parsers, the remote-core network path, and the recently-churned terminal +
editor code.

**Overall:** the codebase is unusually well hardened. The Rust FFI boundary
(registry handles, panic guard, wire-length caps), the regex ReDoS guard, the
LSP `Content-Length` framing, the JSON depth cap, the markdown `safe_url`
scheme allowlist, the git option-injection guards, and the session-store
clobber guard are all real, thoughtful defenses with teeth. The findings below
are the residual gaps I could substantiate — none is a slam-dunk RCE; the most
material is a remote-core memory-exhaustion path and a small set of
defense-in-depth holes.

---

### Remote-core: unbounded orphan-event dictionary keyed by attacker-chosen `sub` id

**Severity:** medium

**Location:** `Sources/RustCore/RemoteTransport.swift:40`, `:282-296` (the
`route(_:)` event arm), cap constant at `:52`.

**Why:** Inbound `event` frames are routed by `event.sub`. When no handler is
registered yet, the event is buffered in `orphanEvents[event.sub]`. The
**per-subscription** list is capped (`orphanBufferCap = 256`), but the **number
of distinct `sub` keys is not bounded** — `orphanEvents` is a
`[UInt64: [RemoteEvent]]` with no cardinality limit and no eviction of keys
that are never subscribed. A buggy or compromised `mdv-serve` can stream
`event` frames with monotonically increasing `sub` ids (none of which the
client ever subscribed to), creating an unbounded number of dictionary
entries. Each retained `RemoteEvent` also carries a `body: [UInt8]` up to the
16 MiB frame cap, so the growth is fast: the reader thread keeps appending
until the process OOMs. The framing layer correctly caps a single frame
(`:222`), but nothing caps the *aggregate* orphan-buffer footprint across keys.
The documented trust model treats the ssh tunnel as the boundary, so this is a
robustness/DoS gap against a misbehaving-but-authenticated server rather than
an anonymous-attacker hole — but a long-lived remote session is exactly where
a slow leak bites.

**Fix:** Bound the orphan store globally, not just per-key: cap the number of
distinct un-subscribed `sub` keys (e.g. drop/ignore events whose `sub` was
never subscribed and isn't already buffered once a small key-count ceiling is
hit), and/or cap total retained orphan bytes. Better still, only buffer events
for `sub` ids that are *pending subscription* (track the set of ids passed to
`subscribe` that haven't yet seen their first event), and discard events for
genuinely-unknown subs immediately.

**VERDICT: CONFIRMED** — `orphanEvents` (`:40`) is `[UInt64: [RemoteEvent]]`; `route(_:)`'s event arm (`:291-294`) caps each list at `orphanBufferCap=256` but creates a new dictionary entry for ANY unseen `event.sub` with no cap on the number of distinct keys and no eviction of never-subscribed keys, so a server streaming events with ever-increasing `sub` ids grows the dict unboundedly (each entry up to ~16 MiB body).

---

### Markdown `safe_url` is bypassable by intra-scheme whitespace that WebKit strips

**Severity:** low (defense-in-depth only — the navigation delegate independently blocks it)

**Location:** `rust-core/crates/core/src/markdown.rs:505` (`safe_url`), reached
from the `Link`/`Image` tag handlers at `:332` and `:344`; markdown WebView runs
with `allowsContentJavaScript = true` (`Sources/ViewerUI/MarkdownRenderedView.swift:120`).

**Why:** `safe_url` finds the first `:` and validates the prefix is a pure
`[alnum + . - +]` scheme before checking it against the allowlist
(`http/https/mailto` for links). A href like `java\tscript:alert(1)` or
`java\nscript:alert(1)` has a tab/newline *before* the colon, so `prefix_raw`
(`"java\tscript"`) fails the `is_scheme` test and the function returns the URL
**verbatim, treated as a relative path** — it is not rewritten to `about:blank`.
WebKit, however, strips tab/newline/CR from URLs *before* scheme resolution, so
the emitted `<a href="java\tscript:alert(1)">` becomes a live `javascript:` URL
in the DOM. `escape()` only HTML-entity-encodes; it does not neutralise the
control chars (a tab/newline survive as themselves inside the attribute value).
In practice the navigation delegate
(`MarkdownRenderedView.swift:813-820`, "javascript:/vbscript: cancelled
regardless of nav type") catches the *click* because WebKit re-normalises the
scheme to `javascript` before `decidePolicyFor` sees it — so this is a
defense-in-depth hole, not a confirmed XSS. But relying on the delegate means
the `safe_url` barrier the module advertises ("malicious markdown can't smuggle
them", `:502-503`) is not actually airtight.

**Fix:** Before scheme extraction, strip ASCII tab/LF/CR (and ideally other C0
controls) from `raw` — matching WHATWG URL parsing — so `java\tscript:` is
recognised and rewritten. Alternatively, reject any href containing a C0
control character outright.

**VERDICT: CONFIRMED (defense-in-depth only, as stated)** — `safe_url` (`:505`) uses `trim()` (Unicode edge-whitespace only, not internal tab/LF/CR), so `java\tscript:` makes `prefix_raw="java\tscript"` fail `is_scheme` (`:517-520`) and the URL returns verbatim (`:522`); `escape()` (`:545`) does not strip the control char. The `safe_url` barrier is genuinely not airtight. Severity correctly low: the nav delegate (`decide`, `:864`/`:868`/`:880`) cancels `javascript:`/`vbscript:` for both `.linkActivated` and `.other` after WebKit re-normalises the scheme, and a no-script-src CSP is in force — so no confirmed XSS.

---

### Archive entry names passed as positional `unzip`/`tar` args without a `--` option terminator

**Severity:** low

**Location:** `Sources/ViewerCore/Archive/ArchiveCatalog.swift:109`
(`unzip -p <archive> <name>`) and `:111`
(`tar -x… -O -f <archive> <name>`).

**Why:** Entry names originate from the archive's *own* listing (parsed from
`unzip -l` / `tar -t`), i.e. attacker-controlled data inside a hostile archive.
They are then handed straight back as positional member-selector arguments with
no `--` separator preceding them. The module's zip-slip reasoning is sound (the
name never drives a *write* path — extraction streams over stdout into an
app-chosen temp file), but a member name beginning with `-`/`--` can be
re-interpreted by the tool as an *option* rather than a member pattern.
`unzip` in particular is permissive about leading-dash arguments. The blast
radius is limited (output is captured to a temp file, env is the parent's, no
shell is involved, and a bad option mostly yields a non-zero exit → caught),
so I could not turn it into a concrete exploit on macOS bsdtar — but the
pattern is exactly the option-injection shape the sibling `GitClient` is
careful to terminate with `--` everywhere.

**Fix:** Insert a `--` option terminator before the entry name:
`["-p", url.path, "--", name]` for unzip and `["-x"+flag, "-O", "-f", url.path, "--", name]`
for tar (verify bsdtar accepts `--` in the member position; if not, at minimum
reject member names beginning with `-` before invoking the tool).

**VERDICT: CONFIRMED** — `extractEntry` passes `name` (parsed from the archive's own `unzip -l`/`tar -t` listing, attacker-controlled) as a trailing positional arg with NO `--` separator at `:109` (`["-p", url.path, name]`) and `:111` (`[..., "-f", url.path, name]`); `run` uses a `Process` args array (no shell, `:176-179`) and there is no leading-dash rejection on the name. Latent option-injection shape; blast radius correctly assessed as limited (no write path, output to app temp), so low.

---

### Terminal `eraseLineFromCursor` can trap on an inverted Range in a 1-column screen after a wide glyph

**Severity:** low

**Location:** `Sources/ViewerCore/Terminal/TerminalScreen.swift:289`
(`for c in cursor.col..<cols`), in combination with the wide-char advance in
`write(_:)` at `:246-258`.

**Why:** `write` advances the cursor by a glyph's display width (1 or 2). In the
degenerate `cols == 1` case, writing a double-width glyph wraps to col 0, stamps
the cell, skips the trailer (`cursor.col + 1 < cols` is false), then does
`cursor.col += 2`, leaving `cursor.col == 2` while `cols == 1`. If a CSI `K`
(erase-to-end-of-line) then arrives, `eraseLineFromCursor` runs
`for c in 2..<1`, which is an invalid `Range` (`lowerBound > upperBound`) and
**fatally traps**. The sibling editors (`deleteChars`, `eraseChars`) defend with
explicit `count > 0` / `cursor.col < end` guards; `eraseLineFromCursor` and
`eraseLineToCursor` only guard the *row* (`cells.indices.contains(cursor.row)`),
not the column. Reachability requires a 1-column terminal, which the UI does not
normally produce, so severity is low — but a malformed PTY resize or a future
caller could hit it, and it's a hard crash, not a render glitch.

**Fix:** Clamp the column in these erase functions:
`for c in min(cursor.col, cols)..<cols` (and symmetrically bound
`eraseLineToCursor`). More robustly, normalise `cursor.col` back into
`0...cols` at the end of `write` for the degenerate-width case, or guard the
loop with `guard cursor.col < cols else { return }`.

**VERDICT: CONFIRMED** — `cols==1` is constructible (`init`/`resize` clamp to `max(1, …)`, `:83`/`:123`). Trace: write a width-2 glyph at col 0 → wrap (`:248-250`) sets `col=0` + `lineFeed` (which does NOT reset col, `:198-205`) → stamp `:252`, skip trailer (`0+1<1` false, `:253`) → `cursor.col += 2 = 2` (`:257`). Then `eraseLineFromCursor` (`:289`) runs `for c in 2..<1`, a `lowerBound>upperBound` Range that fatally traps; only the row is guarded (`:288`), not the column, unlike `eraseLineToCursor` (`:295`, clamps with `min`) and `eraseChars`/`deleteChars` (count/col guards). `eraseScreenFromCursor` (`:272`) inherits the crash. Low: needs a 1-column terminal.

---

### `git diff`/`git show` revision args bypass the `isSafeRevision` option-injection guard on two paths

**Severity:** low

**Location:** `Sources/ViewerCore/Git/GitClient.swift:221-223`
(`cumulativeDiff(baseRef:tipRef:)`) and `:1030-1037` (`commitDiff(sha:)`); the
guard helper is at `:1151` and is applied on the sibling `diff(from:to:path:)`,
`mergeBase`, `revParse`, `blobSha` paths.

**Why:** `isSafeRevision` (rejects empty / leading-`-`) is the codebase's
documented defense so a revision token can't be parsed as a git option (e.g.
`--output=…` on `git show`, which would write to an arbitrary path). It is
applied consistently across most diff entry points — but `cumulativeDiff` feeds
`baseRef`/`tipRef` directly into `git diff --no-color <baseRef> <tipRef>` with
no `isSafeRevision` check and no `--`, and `commitDiff` feeds `sha` into
`git show … <sha>` likewise. In the present call graph these values come from
parsed `git log` output (40-hex SHAs / range selections), which cannot begin
with `-`, so there is no live exploit. But the guard's whole point is to be a
*uniform* boundary that survives a future caller wiring a less-trusted ref in;
two unguarded holes in that boundary are a latent option-injection footgun
(the protective `-c core.pager=cat` etc. flags do not cover `--output`-style
write primitives).

**Fix:** Gate both methods through `isSafeRevision` (return `""` on failure),
matching the rest of the diff API, and add a `--` terminator after the
revisions where the git subcommand accepts one.

**VERDICT: CONFIRMED** — `cumulativeDiff` (`:221-223`) feeds `baseRef`/`tipRef` into `git diff` with no `isSafeRevision` and no `--`; `commitDiff` (`:1030-1037`) feeds `sha` into `git show` likewise — both unguarded, unlike `diff(from:to:path:)` which gates both refs (`:1055-1056`). `--output=<file>` IS a real `git show`/`git diff` write primitive that the protective `-c pager/hooks/editor` flags (`:1160`) do not cover. No live exploit (refs are 40-hex SHAs / ranges from parsed `git log`), so latent + low, as stated. (Note: `fileDiff` at `:1020` is similarly unguarded but the finding scoped to these two — accepting the stated scope.)

---

## Notable areas reviewed and found solid (no finding)

- **Rust FFI** (`rust-core/crates/ffi/`): registry-backed opaque handles close
  the free-vs-call UAF (TSK-541); `catch_unwind` panic guard; out-param
  null/empty defaults; `MdvBuf` cap-preserving free; hex-width clamp guarding
  `handle_alloc_error`-abort.
- **Wire framing** (`wire.rs`): `MAX_FRAME_LEN` (16 MiB) checked against the
  *actual* buffer before any allocation; declared-vs-actual length mismatch
  rejected — remote-decode-safe.
- **LSP framing** (`LSPFraming.swift`): `Content-Length` capped *before*
  buffering the body; unterminated-header cap; O(n) header scan.
- **JSON parser** (`json.rs`): hard `MAX_DEPTH = 128` — no stack overflow on
  `[[[[…`. **CM edit apply** (`cm_edit.rs`): exhaustive UTF-16 bounds/overlap
  validation, lone-surrogate-rejecting decode.
- **RegexComplexityGuard**: ReDoS shape rejection + `boundedMatches` wall-clock
  deadline; the `(?:…)`/`(?<name>…)` prefix-skip fix is correct.
- **Image header parser** (`image.rs`): every access via `slice::get` /
  `checked_add`; JPEG marker walk strictly advances (no infinite loop).
- **GitClient**: minimal env allowlist (no `GIT_*`/secret leakage), protective
  `-c` flags, `/dev/null` stdin, `--` terminators on path args.
- **Subprocess runners** (JQRunner, AudioExporter): args arrays (no shell),
  RLIMIT_CPU/FSIZE/NOFILE caps, output-byte caps, wall-clock timeouts.
- **SessionStore**: serial write queue + coalescing; the
  `wouldClobberLiveSnapshots` guard that refuses to persist an empty index
  while snapshots live on disk (the session-tab-vanish fix).
