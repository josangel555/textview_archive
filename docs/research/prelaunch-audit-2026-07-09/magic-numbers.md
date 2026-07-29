# Pre-launch product review — Magic numbers & hardcoded assumptions

**Date:** 2026-07-10
**Reviewer lens:** Unexplained constants; hardcoded sizes / timeouts / paths / ports;
assumptions about screen sizes, file sizes, line counts, encodings.
**Scope:** `Sources/**` (Swift) + `rust-core/crates/**` (Rust), read-only static analysis.

---

## Executive summary

This codebase is, on this dimension, **well above average**. The overwhelming majority of
numeric constants are hoisted into **named `static let`s with rationale comments** (e.g.
`runTaskDefaultTimeout`/`runTaskMaxTimeout`, `PanelDockLayout.maxSize`, `SessionStore.maxIndexFileSize`,
`WS_MAX_PAYLOAD`, `MAX_FILE_BYTES`), and the highest-risk assumption class — **text encoding** —
is handled by a single, exemplary, well-documented decode ladder (BOM → UTF-16 → UTF-8 →
CP1252 → Latin-1) that is shared between the whole-file loader and the grep path so they cannot
drift. Save preserves the detected encoding (round-trip safe), and the large-file guard **rejects**
rather than silently truncating.

The findings below are therefore mostly **P2/P3** — no P0/P1 data-loss or crash was found under
this lens. The two items most worth attention before launch:

- **A production, ungated `/tmp/mdv-launch-config.env` reader** that `setenv()`s arbitrary keys
  from a predictable world-accessible temp path (env-injection / subprocess-PATH surface).
- **The `mdv-web` daemon's fixed default port `8765` with no in-use fallback** (hard-fails to
  start if the port is taken).

Everything else is quality/polish: heuristic sniff windows, asymmetric size ceilings, and a
couple of hardcoded `/tmp` paths that violate the repo's own "never write to /tmp" rule.

---

## Methodology

Static analysis via `rg`/`grep`/`Read` (no window-opening tests run). I swept for:

- Hardcoded ports / hosts (`localhost:NNNN`, `127.0.0.1:NNNN`, `bind`, `--port`).
- Timeouts / sleeps / debounces / `asyncAfter` / `Task.sleep(nanoseconds:)` / `DispatchTime`.
- Size & byte limits (`maxBytes`, `maxSize`, `MB`, `1024 *`, `_000_000`, `<< 20`, capacities).
- Encoding assumptions (`String(data:encoding:)`, `String(decoding:as:)`, UTF-8/16 sites).
- Hardcoded absolute paths (`/Users`, `/home`, `/tmp`, `/Applications`, `/usr/local/bin`,
  `/opt/homebrew`).
- Screen / window / frame dimension literals in `ViewerUI` + `MarkdownViewer`.
- Retry / attempt / poll counts, animation durations, terminal default cols/rows.
- Rust-core constants in `serve`, `web`, `ffi`, `core` search paths.

I read the full encoding ladder (`TextDecoder`), the large-file loader (`TextFileLoader`),
the launch-config reader (`main.swift`), the web daemon entry (`web/src/main.rs`), the search
caps (`serve/src/search.rs`), and `ScriptRunner` settle-timing. I verified truncation-flag
surfacing on the Rust search paths and confirmed the editor save path preserves encoding.

**Depth:** ~816 Swift files + Rust workspace grepped; ~15 files read in detail. This is a
representative sweep, not an exhaustive per-file audit (see Coverage gaps).

---

## Findings

### F1 — Production `/tmp/mdv-launch-config.env` reader `setenv()`s arbitrary keys, ungated
- **Severity:** P2
- **File:** `Sources/MarkdownViewer/main.swift:110-124` (defined), invoked unconditionally at
  module scope `Sources/MarkdownViewer/main.swift:4291`
- **Evidence:** `applyLaunchConfigFileIfPresent()` reads a **fixed absolute path**
  `let path = "/tmp/mdv-launch-config.env"` (line 116), splits it into `KEY=VALUE` lines, and
  calls `setenv(kv[0], kv[1], 1)` for each (line 122). It is called at top-level `main.swift`
  execution, **not** behind `#if DEBUG` / `MDV_TEST_INSTANCE` / any VM-lane gate (the nearby
  gates at line 576 guard *other* behavior, not this reader).
- **Impact:** `/tmp` (`/private/tmp`, mode `1777`) is writable by any local user. A local process
  can pre-create `/tmp/mdv-launch-config.env` before the app launches; the shipping app will
  ingest those keys into its own environment. Injected vars flow into every child process the
  app spawns (git, node/LSP, tmux, plugin subprocesses) and into any `getenv`-reading code —
  e.g. a prepended `PATH` could redirect `git`/`tmux`/`node` resolution to attacker binaries, or
  `MDV_ENABLE_BROKEN_*` negative-control keys could deliberately corrupt behavior. It is a
  local-only, file-preplacement vector (not remote), but it runs in the shipped binary. It is
  also a hardcoded-path assumption: the comment justifies `/tmp` for the *VM GUI test lane*, yet
  the code path ships unconditionally.
- **Suggested fix:** Gate the reader behind an explicit test/automation signal (e.g. only when
  `MDV_VM_GUI_SESSION=1` or a compile-time `#if DEBUG`), and/or require the file be
  owned-by-and-only-writable-by the current user (`stat` the path, reject if group/other-writable
  or not owner-owned) before consuming it.
- **Fix size:** S
- **Fix risk:** careful (it is load-bearing for the VM GUI launch lane — must keep that lane
  working while closing the production path)

### F2 — `mdv-web` daemon binds a fixed default port 8765 with no in-use fallback
- **Severity:** P2
- **File:** `rust-core/crates/web/src/main.rs:238` (`let mut port: u16 = 8765;`),
  `rust-core/crates/web/src/main.rs:283` (`TcpListener::bind(("127.0.0.1", port))?`)
- **Evidence:** The default port is the literal `8765`; on `bind` failure the `?` propagates the
  error and `main` returns, so the process exits. There is no "try next port" loop and no
  surfaced hint beyond the raw `io::Error`. Overridable only via `--port N` (line 243).
- **Impact:** A second `mdv-web` instance, or any unrelated process already on 8765, makes the
  daemon fail to start with a bare OS error. For a shared-surface / remote-core tool intended to
  be launchable ad-hoc, "port already in use → hard crash" is table-stakes-missing robustness.
- **Suggested fix:** On `EADDRINUSE`, increment and retry a small range (e.g. 8765–8785), or bind
  port `0` and print the OS-assigned port. At minimum, catch the bind error and emit an
  actionable message ("port 8765 in use; pass `--port`").
- **Fix size:** S
- **Fix risk:** safe

### F3 — `looksBinary` classifies files on only the first 8192 bytes
- **Severity:** P3
- **File:** `Sources/ViewerCore/TextFileLoader.swift:508-514` (`let sample = data.prefix(8192)`),
  used by the decode ladder at `:406`
- **Evidence:** Binary detection scans only `data.prefix(8192)` for a NUL byte. The BOM-less
  UTF-16 probe uses an even smaller `data.prefix(2048)` (`:447`). Both are hardcoded windows.
- **Impact:** A file that is clean UTF-8 text in its first 8 KB but turns binary/NUL-laden later
  (e.g. a text header prepended to a binary blob, a log with an embedded core-dump tail) is
  loaded as **text** and rendered in the text editor. Conversely a genuinely-binary file whose
  first NUL falls past byte 8192 is also mis-read. The 8 KB window is a reasonable perf heuristic,
  but it is an unexplained-vs-derived constant (why 8192 and not, say, a proportion of file size).
- **Suggested fix:** Document the window as a deliberate perf/accuracy trade-off with a named
  constant, and consider scaling the sniff window for small files (sniff the whole file when it is
  ≤ some threshold, since the cost is negligible).
- **Fix size:** S
- **Fix risk:** safe

### F4 — Cross-file search default cap `maxResults = 500` (verify truncation is surfaced)
- **Severity:** P3
- **File:** `Sources/ViewerCore/CrossFileSearch.swift:57` (`maxResults: Int = 500`), walk halts at
  the cap (`:207`, `:221`, `:357`)
- **Evidence:** The Swift cross-file search halts the walk once 500 total matches are reached. The
  Rust search paths (`serve/src/search.rs`, `web/src/main.rs`) correctly carry a `truncated: bool`
  flag through their responses (`search.rs:79,156,176,187`; `main.rs:1003-1031`), but the Swift
  `CrossFileSearch.Options`/results struct exposes no equivalent truncation flag in the sites read.
- **Impact:** If the Swift search UI does not surface "showing first 500 of N" when the cap trips,
  users can believe a search is exhaustive when it silently stopped — a correctness-of-UX gap on a
  core flow. The number `500` itself is a fine default; the risk is *silent* truncation.
- **Suggested fix:** Return a `truncated`/`reachedCap` flag from `CrossFileSearch` (mirroring the
  Rust side) and render a "results limited to 500" affordance in the find UI.
- **Fix size:** M
- **Fix risk:** safe

### F5 — Asymmetric hardcoded file-size ceilings (32 MiB editable vs 64 MiB read soft-warn)
- **Severity:** P3
- **File:** `Sources/ViewerCore/EditorBuffer.swift:162` (`TextFileLoader(maxBytes: 32 * 1024 * 1024)`),
  vs `Sources/ViewerCore/TextFileLoader.swift:193` default `softWarnBytes: 64 * 1024 * 1024`
- **Evidence:** The editable path caps hard-read at 32 MiB; the read-only loader default soft-warns
  at 64 MiB. Both are round-number magic constants, not derived from a measured
  memory/latency budget, and the two differ by 2×.
- **Impact:** A 40 MB file is viewable read-only but **rejected** from the editor with `.tooLarge`.
  That is a defensible product choice, but the specific ceilings are unexplained and inconsistent;
  a user hitting "35 MB won't open for editing" has no visibility into why 35 and not 64.
- **Suggested fix:** Centralize the ceilings as documented, named constants with the perf rationale
  (ideally tied to the CM6/WKWebView editor's measured limit), and make the editor's "too large"
  message state the ceiling.
- **Fix size:** S
- **Fix risk:** safe

### F6 — Hardcoded `/tmp/mdv-lsp-seed-<sev>.swift` path in automation verb dispatch
- **Severity:** P3
- **File:** `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift:497`
- **Evidence:** `let url = URL(fileURLWithPath: "/tmp/mdv-lsp-seed-\(severity.rawValue).swift")` —
  a synthetic diagnostics-seed URL built on a fixed `/tmp` path.
- **Impact:** This is an automation/test seed verb (not a normal user path), so blast radius is
  low, but it (a) hardcodes an absolute `/tmp` path — the repo's own CLAUDE.md rule is "never write
  to `/tmp`" — and (b) uses a predictable shared name that two concurrent automation runs would
  collide on. It is a synthetic URL (not actually written here), so the risk is naming/consistency
  rather than data loss.
- **Suggested fix:** Build the synthetic URL under `FileManager.default.temporaryDirectory` with a
  per-run unique component, matching the rest of the codebase's temp-scratch convention.
- **Fix size:** S
- **Fix risk:** safe

### F7 — Hardcoded tool-search bin directories assume a fixed macOS/Homebrew layout
- **Severity:** P3
- **File:** `Sources/ViewerCore/Git/GitClient.swift:1274-1275`,
  `Sources/ViewerCore/LSP/LSPDiscovery.swift:194-196`,
  `Sources/ViewerCore/Audio/FFmpegLocator.swift:17-18`,
  `Sources/ViewerCore/Terminal/TmuxControllerCore.swift:328`,
  `Sources/ViewerCore/JQRunner.swift:40`,
  `Sources/ViewerCore/CLILauncher.swift:18`
- **Evidence:** Multiple locators embed the literal list `/opt/homebrew/bin`, `/usr/local/bin`,
  `/usr/bin` to find `git`/`tmux`/`ffmpeg`/`jq`/node. Each is independently maintained (no shared
  "known bin dirs" source), so they can drift.
- **Impact:** Non-standard installs (MacPorts `/opt/local/bin`, Nix `/run/current-system/sw/bin`,
  asdf/mise shims, custom `$PATH`) are missed unless the code also consults `$PATH`. This is an
  environment assumption baked as a constant. Blast radius is a degraded-but-not-broken experience
  (the feature reports "tool not found"), and several call sites do fall back to `$PATH`, so it is
  quality-tier.
- **Suggested fix:** Extract a single shared `KnownBinDirs` constant + a `$PATH`-first resolver and
  route all locators through it, so adding MacPorts/Nix is a one-line change and behavior is
  consistent across tools.
- **Fix size:** M
- **Fix risk:** safe

### F8 — `serve` daemon 15-minute idle auto-shutdown is a fixed, non-configurable constant
- **Severity:** P3
- **File:** `rust-core/crates/serve/src/lifecycle.rs:16`
  (`pub const IDLE_THRESHOLD_MS: u64 = 15 * 60 * 1000;`)
- **Evidence:** The mdv-serve daemon self-terminates after 15 minutes idle, hardcoded.
- **Impact:** Reasonable default, but not overridable via env/flag. A client that reconnects on a
  17-minute cadence would find the daemon gone; there is no knob to extend for long-lived sessions.
- **Suggested fix:** Allow override via an env var / CLI flag while keeping 15 min as the default;
  document the value.
- **Fix size:** S
- **Fix risk:** safe

---

## Positive observations

The following are genuinely well-handled and worth preserving:

- **Encoding ladder is exemplary.** `TextDecoder.decode` (`TextFileLoader.swift:389-426`) documents
  and orders BOM → BOM-less-UTF-16 escape hatch → strict UTF-8 → **CP1252-before-Latin-1** (so the
  common Windows smart-quote/em-dash case decodes correctly instead of C1 control garbage) →
  Latin-1 total fallback. Shared between whole-file open and grep so the two can't drift. This is
  the single highest-risk assumption in the whole dimension and it is handled with care.
- **Save preserves the detected encoding** (`EditorBuffer.swift:169,183` thread `file.encoding`
  through), so a CP1252/Latin-1 file is not silently transcoded to UTF-8 on save — no round-trip
  data corruption.
- **Large-file guard rejects, never truncates.** `TextFileLoader` throws
  `.tooLarge(bytes:ceiling:)` (`:229`) rather than silently reading a prefix.
- **Constants are overwhelmingly named + commented with rationale**, e.g.
  `MCPToolCatalog.runTaskDefaultTimeout/MaxTimeout` (120/600 s, `:319-320`),
  `RemoteTransport.byteCap` (8 MiB, `:101`), `SessionStore.max{Index,Snapshot}FileSize`,
  `PanelDockLayout.maxSize` (100_000, `:51`), `web/src/main.rs` `MAX_INFLIGHT`/`RECENT_CAP`/
  `WS_MAX_PAYLOAD`/`MAX_HEADER_BYTES`, `search.rs` `MAX_FILE_BYTES`/`MAX_MATCHES`/`MAX_FILES`.
- **Rust search caps surface a `truncated` flag** (`serve/src/search.rs`, `web/src/main.rs`) — the
  right pattern; the Swift twin (F4) should match it.
- **Defensive clamps on user/geometry input**: `TerminalScreen.init` does `max(1, rows/cols)`
  (`:82-83`); `PanelDockLayout.clamp` handles NaN; `ScriptRunner.settleNanos` clamps `delay` to
  `[0.3s, 30s]` against malformed args (`:84`).
- **UI animation durations are small and consistent** (0.08–0.2 s via a shared `MotionGate`), and
  window default sizes (900×650, min 600×360) are sensible and restored from saved geometry rather
  than assumed each launch.

---

## Coverage gaps (not examined in depth)

- **`rust-core/crates/core` engine internals** (markdown, csv, formula, diff, nav, hex, json,
  canvas DSL) — I grepped the FFI/serve/web surfaces but did not audit each engine's internal
  constants (parse-table sizes, canvas layout defaults, formula recursion depth).
- **Canvas DSL** magic numbers (grid sizes, default node dimensions, z-index ranges) — not read.
- **Highlight / tree-sitter** grammar-loading size assumptions and the "16 MB double-carry" figure
  referenced in comments — not verified against actual behavior.
- **Whether F4's Swift cross-file-search truncation is surfaced in the SwiftUI find UI** — I
  confirmed the model-layer cap but did not trace it to the view (would need a UI read, avoided per
  the no-window constraint).
- **LSP / Git subprocess timeout defaults** — `statusTimeout` is threaded as an optional param;
  I did not trace every default it resolves to at each call site.
- **Audio PCM / image-editing pixel-format assumptions** (sample rates, channel counts, bit
  depths) beyond the `BlankImageCreator.maxPixels = 64_000_000` guard, which is well-commented.
- **Plugin manifest `timeoutMs`** defaults when omitted — the decode path is present but I did not
  trace the fallback value applied when a manifest omits it.
