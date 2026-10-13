# Triage — instrumentation

Two confirmations: `FileTreeRecency.swift` and `SyntaxTheme.swift` import AppKit inside ViewerCore — minor boundary leak worth noting. And the design doc explicitly says **"no telemetry"** as a locked decision. The MCP server has only an optional stderr `logger` closure, no audit/auth/consent. I have everything I need.

# Instrumentation / Observability Suite — Assessment

> **Codebase-wide finding (read first):** There is **no observability subsystem** anywhere in `ViewerCore`. What exists is a scattering of point solutions: `LSPLog` (a static stderr-+-capture buffer, `Sources/ViewerCore/LSP/LSPWorkspaceOverrides.swift:244-272`), one `os.Logger` instance for CodeMirror (`Sources/ViewerUI/CodeMirrorEditorView.swift:268-271`), bare `print` / `FileHandle.standardError.write` in ~11 files, and a debug-only NSView-tree `DiagnosticDump` (`Sources/ViewerUI/DiagnosticDump.swift`). `GrammarLoader.swift:285-287` *deliberately avoids* `os_log`. `BACKLOG.md` confirms LSP warnings "have nowhere to go" — `LSPLog.warn` writes to stderr and an in-memory array no UI ever reads. There are **zero** metrics, **zero** perf capture, and **no** memory introspection (no `task_info`/`footprint` calls — grep confirms). `DESIGN.md:571` locks in **"no telemetry"** as a product decision, which scopes everything below to *local, on-device, user-invoked* diagnostics — not phone-home.

The single highest-leverage item is the **shared core sink** (last section). Everything else hangs off it. I lead with the per-feature items, then the foundation, because the foundation's shape is justified by what the features need.

---

### System logs + a UI to view them

**Status today.** No log facade. `LSPLog` (`LSPWorkspaceOverrides.swift:248-272`) is the closest thing: a `nonisolated(unsafe)` static `[String]` buffer behind an `NSLock`, writing each line to stderr. It's test-only (`captured()` is described as a "test-only seam") and unbounded-but-rare. `MCPServer` takes an optional `logger: ((String) -> Void)?` closure (`MCPServer.swift:24,323-327`) that defaults to nil — so MCP activity is invisible unless wired. CodeMirror has its own `os.Logger` (`CodeMirrorEditorView.swift:268`) routing to the unified system log, which `GrammarLoader.swift:285` explicitly rejects ("os_log routes to a separate stream that's harder to capture"). Net: logs go to **three incompatible places** (stderr, in-memory array, OSLog) and **no UI reads any of them**.

**Root cause / gap.** No common `LogSink` abstraction in `ViewerCore`. Each subsystem invented its own escape hatch. There's nothing to subscribe to, nothing to filter, nothing to render.

**Fix/build sketch.** Build on the core `ObservabilitySink` (below): a ring-buffer log store in ViewerCore (`actor LogBuffer`, fixed cap ~5–10k entries, structured `LogRecord { ts, level, subsystem, message, fields: [String:String] }`). Route `LSPLog`, `MCPServer.logger`, `GrammarLoader`, and the bare `print`s through it. UI is a SwiftUI table observing a `@MainActor` projection: level filter, subsystem filter, text search (reuse `FuzzyMatcher.swift`), copy-to-clipboard, "reveal in Console.app". Optionally also fan out to `os.Logger` so `log stream`/Console still works for field debugging.

**Size. M.** The sink + ring buffer is S; the filterable UI table is M (it's the same shape as the existing `LSPProblemsPanel` / `GitLogTab`, so there's a template). Re-routing the ~5 existing log sites is mechanical.

**Dependencies.** The core `ObservabilitySink` (below) must exist first — don't build a UI against `LSPLog` and then re-plumb.

**Risk / one-way-door.** Low. The one trap: a log buffer that captures `message` strings from LSP/MCP/file paths is a **content-leak surface** the moment it's persisted or exposed via MCP — see the Diagnostic Window item. Keep it in-memory, owner-only, never auto-persisted, and never readable through the automation host.

---

### System metrics + a UI to view them

**Status today.** Nothing. No counters, no histograms, no gauges anywhere (grep for `Metric`/`os_signpost`/`MetricKit` in `Sources/` returns only unrelated `StatusBar` "metrics" = document line/char counts, and the `currentMetrics` memo in `StatusBar.swift:109`). The closest existing "metric" is the cache hit/miss behavior in `StatusBar.metricsCache` and `HighlightCacheActor`, but neither is counted or exposed.

**Root cause / gap.** No metric registry, no emission points. The interesting numbers already exist as local state — LSP pool size (`LSPPool` actor, keyed `(language, workspaceRoot)`), highlight cache hit rate (`HighlightCacheActor`, per-tab cap 8 per LESSONS:1183), open tab count, subprocess spawn/kill counts (`ProcessRunner` tracks `timedOut`/`truncated`/`killed` in its `Result` but discards them after the call) — but nothing aggregates them.

**Fix/build sketch.** A core `MetricRegistry` (counters + gauges + simple timing summaries; no percentiles needed for a desktop app). Emission points: `ProcessRunner.run` increments `subprocess.spawned` / `.timed_out` / `.killed`; `LSPPool` exposes `lsp.servers.active` as a gauge; `HighlightCacheActor` reports hit/miss; `TabCoordinator` reports `tabs.open`. UI is a simple key→value table refreshed on a timer (1–2 Hz), grouped by subsystem.

**Size. M.** Registry is S. The *value* is in the instrumentation points — each is a one-liner but there are many, and getting them right (not on a hot path; `HighlightCacheActor` and per-keystroke paths are sensitive per LESSONS) takes care. UI is S (reuses the same table as logs).

**Dependencies.** Core `ObservabilitySink`. Sequence **after** logs (same UI chassis, lower urgency).

**Risk / one-way-door.** Low, but: emitting metrics on the keystroke/scroll hot paths re-introduces exactly the `@Published`-cascade republish problem LESSONS:1140-1184 spent effort killing. Metrics must write to a non-`@Published` core actor and the UI must poll, **never** observe-and-republish.

---

### Profiling / perf-data capture

**Status today.** Nothing in-app. The team profiles externally — LESSONS documents using `/usr/bin/footprint -summary <pid>` (LESSONS:718) and `ps aux` manually, and there's a `scripts/vm-smoke.sh` harness, but no in-process capture. No `os_signpost`, no `OSSignposter`, no `XCTMetric`.

**Root cause / gap.** No timing seam. Perf wins in LESSONS (the 1 GB-CSV blowup at :667, the 5 MB/s idle leak at :206) were all found by external tooling + reasoning, not by captured data — so regressions are invisible until a human notices.

**Fix/build sketch.** Two tiers. **Tier 1 (cheap, do this):** add `os_signpost`/`OSSignposter` intervals around the known-expensive spans — TreeSitter tokenize, file load (`TextFileLoader`), git invocation (`GitClient`), markdown render. Zero runtime cost when not tracing; lights up for free in Instruments. **Tier 2 (heavier):** an in-app "capture 10s of timings to JSON" mode feeding the metrics summaries. Don't build a flame-graph viewer — Instruments already exists and is better.

**Size. S** for Tier 1 (signposts are annotations), **L** if anyone insists on an in-app flamegraph UI (don't — one-way-door of maintenance for no gain over Instruments).

**Dependencies.** None for Tier 1 (signposts are independent). Tier 2 wants the MetricRegistry.

**Risk / one-way-door.** Tier 1 none. Building a bespoke profiler UI (Tier 2 maximal) is a classic over-build — flag it as a trap, not a goal.

---

### Status bar: total + per-tab memory

**Status today.** Status bar (`StatusBar.swift`) shows document metrics only (lines/chars/bytes/EOL/encoding/indent). No memory at all. No `task_info`/`mach_task_basic_info` call exists anywhere.

**Root cause / gap — this is the hard one, and LESSONS already nailed why.** Per LESSONS:698-720, **process memory is not the app's memory**. A WKWebView app's footprint is split across XPC helpers Activity Monitor sums under the parent: `com.apple.WebKit.Networking` (~10 MB), `.GPU` (~25 MB), `.WebContent` (30–80 MB *per rendering WKWebView*). LESSONS:711 — once *any* WKWebView is created, Networking+GPU persist for app lifetime. So:

- **Total memory** is gettable but ambiguous. `task_info(TASK_VM_INFO)` `phys_footprint` gives the main process's physical footprint (the number LESSONS:718 calls "the more useful number for our code"), but it **excludes** the WebKit helpers. To match what the user sees in Activity Monitor you'd have to enumerate child XPC pids and sum — which is fragile (private process relationships) and still wrong for shared-cache pages.
- **Per-tab memory is effectively not available.** A tab is not a process. Markdown-rendered tabs each spin a `com.apple.WebKit.WebContent` process (LESSONS:989, 30–80 MB each) — those you *could* in principle attribute per-tab if you tracked which WebContent pid serves which tab, but WKWebView gives you no pid handle. Source/CSV/hex tabs share the main process heap with no per-tab accounting boundary at all. There is no honest per-tab number for the common case.

**Fix/build sketch.** Be honest about the three numbers: (1) **App footprint** — `task_info` `phys_footprint`, labeled "App". (2) **WebKit helpers** — best-effort sum of child `com.apple.WebKit.*` pids' footprints, labeled separately, with a tooltip explaining it's shared. (3) **Per-tab** — *don't claim bytes*. Offer a proxy instead: per-tab content byte size (already in `TextFile.byteCount` / `BinaryFile.totalByteCount`, used in `StatusBar.swift:117,127`) + a boolean "has live WebView". A real per-tab RSS number would be a lie.

**Size. M.** The `task_info` call + child-pid enumeration is S (a small C-interop helper in `ViewerCore`, sampled on a timer off the main thread). The honesty/UI framing and not-misleading-the-user design is where the effort goes.

**Dependencies.** Metrics gauge plumbing (the sampler is a gauge source). The footprint helper belongs in core, surfaced via the sink.

**Risk / one-way-door.** Reputational, not technical: ship a "per-tab: 47 MB" number that's fabricated and a senior user will catch it immediately (the LESSONS author already did the math at :714). Better to show the proxy and a tooltip than a confident wrong number. Sampling `task_info` too aggressively (every render) wastes cycles — cap at ~1 Hz.

---

### Diagnostic window: DocumentModel JSON, temp files, open ports, open FDs

**Status today.** Partial, and DEBUG-gated. `DiagnosticDump.swift` dumps the **NSView tree** (not the DocumentModel) to JSON, invoked via `--diagnose`, `--auto-snapshot`, or SIGUSR1 (`Sources/MarkdownViewer/Diagnostics.swift`). It's already been security-hardened (OBS-1/OBS-2): the SIGUSR1 trap is off in release unless `MDV_ENABLE_DIAGNOSTICS=1` (`Diagnostics.swift:28-34`), content is redacted in release (`Diagnostics.swift:40-46`, `DiagnosticDump.swift:181`), artifacts are written 0600 (`Diagnostics.swift:200-227`), and stale artifacts are swept (`Diagnostics.swift:244-267`). There is **no** DocumentModel-as-JSON, **no** temp-file listing, **no** FD/port listing, and **no** diagnostic *window* (it's all headless stdout/tmpfile).

**Root cause / gap.** `DocumentModel` is a 2731-line god object (`DocumentModel.swift`; the SRP split is mid-flight per BACKLOG and the three coordinators). It has no `Codable` projection. "Open ports/FDs" would mean shelling `lsof`/`proc_pidinfo`; "temp files" means enumerating the per-user tmpdir.

**Fix/build sketch.** A `Cmd-Opt-Shift-D` diagnostic window (DEBUG / `MDV_ENABLE_DIAGNOSTICS=1` only, mirroring the existing gate) with tabs: (1) **State** — a hand-written `diagnosticSnapshot() -> [String:Any]` on DocumentModel/coordinators (do **not** auto-derive `Codable` from the live model — it has closures, stores, NSObjects; a curated snapshot is safer and avoids leaking internals). (2) **Temp files** — enumerate `FileManager.temporaryDirectory` for `mdv-*` artifacts. (3) **FDs** — `proc_pidinfo(PROC_PIDLISTFDS)`. (4) **Subprocesses** — list live LSP servers (`LSPPool` already keys them) + any `ProcessRunner` children.

**Size. M** for the window + state snapshot; **+S** each for temp/FD/subprocess tabs.

**Risk / one-way-door — FLAG, this is the most dangerous item in the suite.** This window is a **content + path exfiltration surface**:
- A DocumentModel dump leaks: every open file's **absolute path**, recent files (`recents`), bookmarks (`bookmarks`), git roots, cross-search queries, and — unless explicitly redacted — document **content** (the existing dump already had to redact `string_head` for exactly this reason, `DiagnosticDump.swift:181`).
- "Open FDs" via `lsof`/`proc_pidinfo` enumerates **every file the app has open** — paths the user may not realize are exposed.
- **The exfil channel is real and already half-built.** The MCP automation host (`MCPServer.swift`, `MCPToolCatalog.swift`) is scriptable and already exposes `current_state` (tab list, paths), `visible_text` (document content), `list_bookmarks` (all bookmark paths, `MCPToolCatalog.swift:276-288`), and `snapshot_window` (PNG of content, :298-313). **It has no auth, no audit log, and no first-connect consent** — `MCPServer.swift` has only an optional stderr `logger` closure; BACKLOG confirms "audit log + first-connect prompt" was explicitly **cut**. If a `diagnostic_dump` tool is ever added to the MCP catalog, an unprivileged local script that can speak to `MarkdownViewer --mcp-stdio` gets a full state/path/content exfil in one call.

  **Hard requirements:** (a) the diagnostic dump must **never** be added to `MCPToolCatalog`; (b) the window stays behind the existing DEBUG/env gate; (c) reuse `DiagnosticDump.Options.redactContent` semantics — redact content + consider redacting absolute paths (`/Users/me/...` reveals username + project layout) in any artifact that can leave the process; (d) write 0600 like the existing path (`Diagnostics.swift:200`). Revisit the MCP "no audit, no consent" cut *before* exposing any richer state tool.

---

### Terminal tool window with tabs ("a must")

**Status today.** Does not exist. Grep confirms no pty/`openpty`/`forkpty`/shell-spawn-for-interactive anywhere. There **is** a "Open in Terminal" context-menu action (BACKLOG, commit `7530130`) but that shells out to **Terminal.app** — it's not an embedded terminal. `ProcessRunner` (`ProcessRunner.swift`) runs one-shot drain-to-EOF processes, the opposite of an interactive pty.

**Root cause / gap.** No PTY layer, no terminal emulator, no ANSI/VT parser. This is a from-scratch subsystem, not an extension of anything present.

**Fix/build sketch.** This is the **largest** item by far and the one most likely to bust the budget. A real embedded terminal needs: `forkpty`/`posix_spawn` + master fd, a VT100/xterm escape-sequence parser (cursor movement, SGR colors, scroll regions, alt-screen, mouse, resize/SIGWINCH), a grid/scrollback model, and an NSView renderer. Tabs sit on top. Two honest paths:
- **Vendor SwiftTerm** (the de-facto Swift terminal emulator) — but that's a **non-trivial dependency** (a full VT emulator + renderer) and per the project's hard rule and the 37 MB / 16 MB-exec bundle caps (CLAUDE.md), it needs explicit approval and a size measurement first. Given the "minimal dependencies / explicit approval" stance, this is a decision-gate, not a code task.
- **Roll our own** — months of work and a perpetual correctness tail (escape-sequence edge cases are endless). Not justified for a markdown viewer.

**Size. L (the largest in the suite).** Realistically a multi-week subsystem regardless of build-vs-vendor.

**Dependencies.** Independent of the observability sink — it's a feature, not instrumentation. Needs a dependency decision (SwiftTerm vs vendor vs build) and a bundle-budget check (`scripts/check-bundle-size.sh`) **before** any code.

**Risk / one-way-door — HIGH, both security and architecture.**
- **Security:** an embedded terminal is an **arbitrary-code-execution surface inside the app's TCC/entitlement context**. Anything the app is granted (Documents access, network) the spawned shell inherits. If the MCP host or a plugin can ever drive the terminal, that's RCE-as-a-feature. This deserves its own threat model before a line is written.
- **Architecture:** a PTY + emulator is inherently AppKit/process-coupled and does **not** belong in the Rust-core split — it's a UI/host concern. Putting it in `ViewerCore` would contaminate the "no SwiftUI/AppKit" boundary. Keep it in `ViewerUI`/host.
- **Scope:** flag plainly that "a must" + the bundle cap + the minimal-dependency rule are in tension; this needs an explicit owner decision, not silent implementation.

---

### The shared foundation: one core observability sink

This is the keystone. **Build this first; everything above plugs into it.** Today's fragmentation (`LSPLog` stderr buffer, CodeMirror's `os.Logger`, bare `print`s, the in-memory `LSPLog.captured` array no UI reads) exists *because there is no sink*. BACKLOG's "LSP warnings have nowhere to go" is the symptom.

**Design constraints, from the actual code:**
- **Must live in `ViewerCore` and be Foundation-only.** ViewerCore has no SwiftUI/WebKit (confirmed) — though note **two existing AppKit leaks** to clean up while you're here: `FileTreeRecency.swift` and `Highlight/SyntaxTheme.swift` both `import AppKit` inside ViewerCore. The sink must not add a third.
- **Must survive the Rust-core split** (MEMORY: "Rust core decided 2026-05-30; compact binary RPC, no JSON; SwiftUI↔Rust FFI is the key path"). So the sink's *event model* must be expressible over an FFI boundary: flat, value-typed, `Sendable`, no closures-as-payload, no Foundation-only types in the record shape (use primitives + `[String:String]` fields, not `NSAttributedString`/`URL` — pass paths as `String`). The Swift implementation is a placeholder for what becomes a Rust ring buffer the host reads over RPC.
- **Must not republish.** Per LESSONS:1140-1184, it cannot be a `@Published`-cascading `ObservableObject` that fans into DocumentModel. It's a core actor; the UI gets a `@MainActor` *projection* it polls or that publishes its own coarse `version: Int` (the `HighlightCacheActor` pattern, LESSONS:1177).

**Proposed shape (sketch, not final):**

```swift
// ViewerCore — Foundation-only, FFI-friendly value types.
public enum ObsLevel: UInt8, Sendable { case trace, debug, info, warn, error }

public struct ObsEvent: Sendable {           // flat → crosses FFI cleanly
    public let tsUnixNanos: UInt64
    public let level: ObsLevel
    public let subsystem: String              // "lsp", "mcp", "grammar", "process", "git"
    public let message: String
    public let fields: [String: String]       // structured, string→string only
}

// One emit path for the whole core. Logs, metric-as-event, warnings all go here.
public protocol ObservabilitySink: Sendable {
    func emit(_ event: ObsEvent)
    func counter(_ name: String, _ delta: Int64, _ tags: [String: String])
    func gauge(_ name: String, _ value: Double, _ tags: [String: String])
}

// Default impl: an `actor` ring buffer (bounded) + optional os.Logger fan-out.
// A `nonisolated(unsafe)` global `Obs.shared` install point so ViewerCore code
// far from any DI seam (GrammarLoader, ProcessRunner) can emit without threading
// a handle through every call. Tests swap in a capturing sink (the LSPLog pattern,
// generalized).
```

**Migration:** collapse `LSPLog.warn` → `Obs.shared.emit(.init(level: .warn, subsystem: "lsp", ...))`; route `MCPServer.logger`, `GrammarLoader`'s stderr writes, and the bare `print`s through it. Status-bar warnings, the LSP "Problems" pill, the log UI, and the metrics UI all become *consumers of one stream* instead of bespoke channels.

**Size. S–M.** Sink + ring buffer + global install is S. Migrating the ~5 existing emit sites and adding the test seam is M. This is the cheapest item with the highest leverage — **it is the prerequisite that makes logs/metrics/warnings each S-to-M instead of each re-inventing a channel.**

**Dependencies.** None — it's the root.

**Risk / one-way-door.** The event-record shape **is** a one-way door once subsystems emit against it and (eventually) the Rust core serializes it over RPC. Get the FFI-friendliness right now: primitives + `[String:String]`, no Foundation/AppKit types, no closures in the payload. Cost of changing the record shape later = touching every emit site + the RPC schema. Also: a sink that buffers `message` strings is the same content-leak surface as the diagnostic window — bound it, keep it in-memory, owner-only, and **never** expose it through the MCP host.

---

### Build order (dependency-sorted)

```
1. ObservabilitySink (core)         ── S–M ── root, unblocks everything
2. System logs + UI                 ── M   ── first consumer; reuses LSPProblemsPanel chassis
3. os_signpost annotations          ── S   ── independent, free in Instruments
4. System metrics + UI              ── M   ── same UI chassis as logs
5. Status-bar memory (honest)       ── M   ── needs metrics gauges + task_info helper
6. Diagnostic window                ── M   ── SECURITY-GATED; never goes through MCP
─────────────────────────────────────────────
7. Terminal tool window             ── L   ── independent feature; needs dependency
                                              decision + bundle-budget check + threat
                                              model BEFORE code. Not part of the
                                              observability foundation.
```

**Three things to escalate to the owner before coding:** (1) the embedded **terminal** is a dependency + bundle-cap + RCE-surface decision, not a task; (2) the **MCP host has no auth/audit/consent** (`MCPServer.swift`, confirmed cut in BACKLOG) and richer diagnostic state must not be exposed through it until that's revisited; (3) the **per-tab memory** number cannot be made honest — ship a proxy + tooltip, not a fabricated byte count.