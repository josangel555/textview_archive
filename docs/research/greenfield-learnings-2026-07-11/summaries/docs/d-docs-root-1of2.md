# Greenfield Learnings — Top-Level Design Docs Batch 1/2

**Scope:** Exhaustive review of `docs/*.md` (maxdepth 1), slice 1 of 2 (45 files sampled). These are the durable design records and architectural decisions from the markdown_viewer project, created during 8 weeks of intensive development (2026-05-20 to ~2026-07-10).

**Status:** current / live. Most docs were written in the project's final weeks and capture hardened decisions, not brainstorms. A few are "design draft" (AUTOMATION.md, PLUGINS_DESIGN_v2.md) but are feature-complete for v1.

---

## Batch Summary — Key Themes

This batch reveals **four major architectural choices** that define the system:

1. **Rust core with Swift UI shell, connected via MessagePacked frames over FFI** — the engine/adapter/transport split that makes the app portable and testable.
2. **MCP as the primary agent-facing automation surface** — viewer-shaped, read-heavy, typed, language-agnostic.
3. **Three-tier plugin system (JSON config / shell subprocess / sandboxed WebView)** — no native loadable code, ever.
4. **Feature-complete inventory audit with explicit usability state tracking** — distinguishes "built" from "tested" from "usable."

---

## Per-Doc Analysis

### AGENT_PRODUCTIVITY_FEEDBACK_2026-06-20.md
**Status:** current. Post-project retrospective from agent's perspective; grounded in real incidents from a multi-agent parallel run.

**What it is:** Ranked list of 23 blockers that prevented "one-shotting" features (completing them in one agent pass). Separated by root cause: visibility gaps, harness friction, workflow ceremony, code navigation, and clarity.

**Key learnings:**
- **Verification-tier gap is THE dominant blocker.** Agent can host-test model layer but cannot verify render/on-screen behavior without slow VM lane. Host-green ≠ user-visible fix. Agents mis-report "fixed" because their best signal (model tests) is uncorrelated with actual acceptance (pixels). *Fix: build render-verification MCP OR a host-vs-render classifier.*
- **Agents are blind to real machine state** (memory, which agents edit what files, test coverage per symbol). Most other friction stems from this visibility gap.
- **Semantic code navigation is the single most-repeated motion** — "grep to find seam" happens on every task. The app's LSP/tree-sitter core could power this via MCP (who-calls, who-consumes, where-wired).
- **"Render-vs-host acceptance criteria implicit"** — model tests look like success but pixel behavior is the real bar. Need explicit classifier: "host-provable | render-path-only | needs-VM."
- **Built-but-unwired work is expensive to discover** — FolderTreemapView, LocalHistoryStore, etc. existed but agent didn't know. A `find_unwired(symbol)` tool would unlock cheap high-value work.

**Carry-forward:** DISTILL. The 8 ranked improvements (#1–8) are a product roadmap for MCP tooling and agent infrastructure. #1 (semantic nav) and #2 (render-verification) are directly portable to the greenfield project's agent strategy.

---

### ARCHITECTURE_LAYERS.md
**Status:** current (2026-06-12). Layer map with deprecation path from Swift engines to Rust core.

**What it is:** Mermaid diagram + table mapping all 9 engine families (CSV, Diff, Hex, Indent, CM Edit, Find, Markdown, Transcript, Fuzzy) showing which are ported to Rust (green), which have adapters wired (yellow), which are deprecated Swift twins (red), which stay Swift (blue). Includes remote-operation future shape.

**Key learnings:**
- **Rust core is deliberately sans-IO.** The engine layer (`mdvcore-core`, forbid(unsafe), no FFI) has zero file/git/network I/O; it takes structured input and produces structured output. IO lives in adapters (Swift-side FFI caller) or in a Rust host layer (`mdv-serve` for remote mode). This split makes the engine simultaneously shippable in the app (local FFI), in a TUI (`mdv-tui`), and in a remote server (`mdv-web`). **Corollary:** every new engine must follow this contract.
- **Capability bitmap (u64 bits 0–8) is the contract.** Bits are assigned per engine, all 9 are shipped and none reserved. Each adapter has an `MDV_RUST_*` env gate (all default OFF) for A/B testing before flip-to-ON. Fallback-on-CoreError pattern is load-bearing; failures don't crash.
- **Deprecation path is phased:** (1) wire the four unwired adapters (find, fuzzy, markdown, transcript), (2) flip gate defaults ON per engine with parity tests as the regression net, (3) bake in (remove gates, delete Swift twins). Swift core shrinks to the five host-coupled subsystems (TreeSitter, Sanitizer, MermaidParser, GitClient, Sessions/LSP/File IO).
- **Remote operation (Rust-only server, thin Swift UI)** is the owner's target for post-launch. The transport seam (`CoreTransport`) unifies local FFI and remote socket, speaking the same MessagePack frames. File read must be windowed (offset+len) to never ship 500 MB whole. File watching must be server-push (duplex channel, not request/response). This drives the current adapter-flip roadmap.

**Carry-forward:** PORT. The layer split (sans-IO engine, adapters, transport abstraction) is the exact pattern to use in greenfield. The capability bitmap contract and gate-driven A/B testing are directly reusable. The remote-operation shape (thin client, Rust server, shared frame format) should be locked in from day one.

---

### AUTOMATION.md
**Status:** design draft (ready for v1). Five candidate architectures evaluated; MCP + App Intents recommended.

**What it is:** Product design for making the app "hackable, controllable, and automatable." Evaluates AppleScript, JS, Lua, MCP, and App Intents; recommends **MCP as primary** (typed tools, language-agnostic, bidirectional, agent-native) with **App Intents as thin facade** (Shortcuts/Spotlight/Siri parity). Includes concrete 10-action priority list + security model + migration path.

**Key learnings:**
- **MCP wins because agents are the primary customer.** AppleScript is macOS-native but shrinking; MCP is the de-facto standard in 2025–2026 (Claude Desktop, Cursor, Zed, VS Code Copilot all speak it). Typed tool defs with JSON schemas give every client autocomplete + validation for free. The vocabulary is language-agnostic.
- **MCP as LOCAL-ONLY, file-system-scoped.** Default transport: Unix socket at `~/.../mcp.sock` (mode 0600, owner-only). TCP is opt-in, loopback only, never `0.0.0.0`. No arbitrary FS reads (only paths user opened), no writes, no shell execution, no network egress. Rate/size limits (10 MB visible text, PNG capped at screen resolution, no verb >100ms main-thread). **Rationale:** untrusted local processes can already do everything MCP can; we're making legitimate automation pleasant, not reducing attack surface.
- **One vocabulary, three transports.** `AutomationHost` protocol unifies MCP, App Intents (thin wrapper), and the legacy `--script` DSL (becomes MCP client internally). Single source of truth for 10 priority actions (open_path, get_state, select_tab, set_view_mode, find, goto_line, get_visible_text, toggle_bookmark + list_bookmarks, snapshot_window, subscribe-to-events).
- **Audit log at `~/Library/Logs/TextView/mcp-audit.jsonl`:** timestamp, tool, args hash, client id. Visible in Settings. First-connect banner (non-modal) for each new client. All-or-nothing per-client grants in v1, no per-tool fine-grain (users can't reason about "allow only hover but not find").
- **App Intents ship in the same release as MCP**, cheap once vocabulary exists. Shortcuts users get Siri/Spotlight/Automator integration without code.

**Carry-forward:** PORT nearly verbatim. The MCP schema, security model, and priority-action list are production-grade. Unix socket default + opt-in TCP are the right defaults. The audit log shape and Settings integration are reusable. Recommend starting with this instead of designing automation from scratch.

---

### FEATURE_INVENTORY.md
**Status:** current (2026-07-02, updated at 2026-07-10). Exhaustive feature audit with completion and usability state tracking.

**What it is:** 12 feature families (Editor, File Nav, Viewing, Markdown Tools, Data Formats, Media, Dev Tools, Automation, Import/Convert, Feeds, Canvas, Chrome) with three columns per sub-feature: **Built** (✅/🟡/📐), **Logic-verified** (✅/➖), **Usable** (✅/🟡/✖, owner-confirmed). Created on owner directive to distinguish "we have code" from "humans can use it without friction."

**Key learnings:**
- **Built ≠ Usable.** Almost all features are built + logic-verified but unusable. Owner: "nearly all of them are unfinished, unpolished or unusable." Editor works, Vim works, file nav mostly works. Everything else falls short on UX. This is the single calibration point for the rebuild.
- **Eight cross-cutting usability gaps recur everywhere:** (1) results dump to modal alerts (need reusable results panel), (2) no empty states, (3) no progress/error surfacing, (4) discoverability (features as verbs only, menus/shortcuts unlabeled), (5) cohesion (overlapping surfaces: script console vs terminal palette, three search UIs), (6) felt latency (DOM-patch TSK-838 gated OFF), (7) unfinished core loops (70% features: SQLite browse but no query→export), (8) on-screen verification debt (pixel/AX tests gated on TSK-1334 screen-recording).
- **Owner decision queue blocks the biggest jumps:** screen-recording grant (TSK-1334 unlocks pixel/AX lane), flip DOM-patch (biggest felt-latency fix), finish-or-cut decisions (RichText, browser, notebook, log-patterns), formula-engine gate flip (spreadsheet becomes real), hex edit + paint persistence (data-editing completeness).
- **Gap-ticket hierarchy is self-documenting.** Every child ticket is a self-contained subagent brief with CONTEXT/FILES/BUILD/VALIDATE/DONE-WHEN. TSK-1411 (usability umbrella) has 4 cross-cutting themes + 10 family epics (1450–1460) with 43 children (1434+, 1461–1482). This structure is portable.

**Carry-forward:** DISTILL + PORT. The three-column grid (Built/Logic/Usable) is the exact audit tool for the rebuild. The eight cross-cutting gaps should inform feature acceptance criteria from day one (commit to results panel before shipping three separate features). The ticket structure (umbrella → themes → families → children) with self-contained briefs is directly reusable for phased feature delivery.

---

### PERFORMANCE_PROFILING.md
**Status:** current (production harness). Documents `os_signpost` instrumentation + Instruments workflow for the shipped app.

**What it is:** TL;DR for running profiling on a release build using `xctrace` with `os_signpost` instrument. Documents seven stages (open, categorize, load, materialize, highlight, render, interact) and their signpost categories. Includes concrete commands, trace modes (open/resize/nav/reopen/debug), and reading the trace output.

**Key learnings:**
- **`MDV_SIGNPOSTS=1` master switch.** PerfSignpost reads the env once at startup and caches it. Unset (normal): every `begin`/`end` is a single branch-and-return, zero overhead, no `OSSignposter` built. Set: lazily constructs one `OSSignposter` per stage (category) and emits real intervals. **No Debug/Release `#if`** — gate is purely runtime env so you profile a fully optimized release bundle (the one whose timings actually matter).
- **Signposts grouped by stage, each stage is one `OSLog` category under subsystem `com.markdownviewer.MarkdownViewer`.** Instruments lanes them separately in the "os_signpost" instrument. Set the lane to the subsystem and you see one row per category.
- **Key intervals for diagnosis:** DocumentModel.openResolved (whole user-facing open span), SourceTextController.apply (source-view paint, NSTextView attributed-string set + layout), TreeSitterEngine.tokenize (off-main via HighlightCacheActor), WKWebView.loadToFinish (spans processes, stitched by signpost ID). The two `render | SourceTextController.apply` intervals per open show plain-text first paint and highlighted second paint — if the second is large (hundreds of ms on large files), that's NSTextView layout, the dominant source-view cost.
- **Materialize intervals span Task boundary** (begin on main actor, end in detached completion); Instruments stitches them by signpost ID so the displayed length is real background latency, not main-thread time. This pattern is load-bearing for accurate off-main profiling.
- **No Instruments lane for "this profiles the headless test" — profile the BUILT APP on real WindowServer.** Headless test probes measure logic-path cost but not live AppKit layout / compositor cost. The honest target is `dist/TextView.app`.

**Carry-forward:** PORT. The signpost infrastructure (seven stages, category names, interval meanings) is directly reusable. The `MDV_SIGNPOSTS=1` switch design (no Debug/Release `#if`, runtime env gate) is excellent. Recommend starting with this harness in greenfield rather than designing a new one. The key intervals for source-view (open, highlight, render) should be instrumented from day one.

---

### LSP_DESIGN.md
**Status:** design (2026-05-22 onward; locking notes from §1 research). Long, comprehensive, "read before shipping Phase 1."

**What it is:** 35-page design for LSP integration (hover, go-to-def, outline, find-refs, workspace-symbols, diagnostics, semantic tokens, inlay hints). Viewer-shaped: reader features only, no completion/formatting/refactor. Phase 1 = sourcekit-lsp hover + go-to-def + outline. Phases 2–3 expand; later phases add other languages.

**Key learnings:**
- **Viewer features only: "what is this?" / "where is it?" / "where is it used?" YES; "how do I change it?" NO.** No completion, no formatting, no code actions, no refactor. This boundary is non-negotiable because every edit feature couples the client to the user's actual code changes, which a pure-viewer app cannot reason about.
- **One process per (workspace-root, language) pair, spawned lazily.** The pool key is the composite. Both Zed and VS Code follow this; sourcekit-lsp tightly couples to a SwiftPM `Package.swift` root and degrades on loose `.swift` files but loses cross-file features.
- **Process lifecycle is client-owned.** The server is dumb about its own lifetime; the client decides spawn, shutdown (request) + exit (notification), SIGTERM on timeout, SIGKILL if SIGTERM fails. Zombie processes are the #1 operational hazard. Use `posix_spawn` + explicit teardown (macOS doesn't have prctl(PR_SET_PDEATHSIG)).
- **Framing is byte-oriented, length-prefixed.** LSP wire format is JSON-RPC 2.0 + HTTP-style `Content-Length: N\r\n\r\n` header (NOT in JSON-RPC spec itself, added by Microsoft for stream transports). Naive line-based parsing breaks on payloads with embedded `\r\n` inside strings (common in `hover.contents` Markdown blocks).
- **Vendor a hand-picked subset of LSP 3.17 protocol types, not a dep.** ChimeHQ's `LanguageServerProtocol` package exists but pulls ~5 kLoC for what we actually use (50 Codable structs). Coupling to their release cadence isn't worth it. **Vendor protocol types under `Sources/ViewerCore/LSP/Protocol/` with upstream-attribution comments.** Don't pull `LanguageClient` (the "RestartingServer" wrapper is 80% useful, we can write simpler in half lines).
- **Request/response correlation via monotonically-increasing UInt64 IDs.** Per-request timeout budget (initialize 30s, hover 3s, definition 5s, references 15s). Cancellation sends `$/cancelRequest` + resumes continuation with `LSPError.cancelled`; late response is discarded by checking ID still in pending. Timeouts per-call, not lifetime (hover after spawn should retry after 500ms backoff; second timeout shows "(no LSP response)").
- **Capability negotiation is precise.** Send `initialize` with curated `ClientCapabilities`, deliberately NOT advertising completion/signature-help/code-action/formatting/rename/refactor/linked-editing/code-lens/workspace-apply-edit. The server gets the message: this client can't accept edits; some servers (rust-analyzer) reduce workload accordingly.
- **Position encoding matters.** LSP defaults to UTF-16 (VS Code). Swift's `String` indexing is grapheme-cluster-based. Must convert positions at the boundary. Newer servers support `utf-8`; prefer that to skip conversion.
- **Workspace-root detection per-language.** Swift: `Package.swift` walking up, else `.xcodeproj`/`.xcworkspace`, else loose-file mode. Rust: `Cargo.toml` walking to outermost (workspace root). Go: `go.mod`. TS/JS: `tsconfig.json`/`jsconfig.json`/`package.json`. Python: `pyproject.toml`/`setup.py`/`setup.cfg`/`Pipfile`. C/C++: `compile_commands.json` (most reliable). Walk stops at home dir or `.git` boundary to avoid monorepo bloat.
- **Concurrency model: MainActor views call LSPPool (actor) which owns LSPClient actors (one per server).** stdout reader Task owns ContentLengthReader and pushes decoded messages into actor. stderr reader drains into ring buffer for dev panel. Sendable boundaries: protocol types are Sendable by construction (value types). `LSPClientHandle` (facade UI code sees) wraps weak reference to actor + Sendable id. Tier is Swift 6's `isolated deinit` for MainActor holders (NSPopover, NSTrackingArea, notification observers).
- **Spawn discipline — three layers of defense:** (1) child setup (executableURL, args, env, pipes), (2) reader tasks (stdout/stderr), (3) termination policy (shutdown → exit → SIGTERM → SIGKILL with 3s/1s/1s/0.5s budgets), (4) crash watcher (resume pending continuations, decide to restart only if crash >10s after spawn, never >3 restarts/60s window), (5) at-process-exit cleanup (AppDelegate.applicationWillTerminate calls LSPPool.shutdownAll(timeout: 3s)).

**Carry-forward:** PORT. This is a near-complete design for the greenfield project's LSP integration. The process pool model, capability boundaries, protocol types (vendor, don't dep), spawn discipline, and concurrency structure are directly reusable. Recommend treating this as the reference and not redesigning.

---

### CODE_REVIEW_DESIGN.md
**Status:** design (2026-05-24 onward). Feature-complete for v1; ready to implement.

**What it is:** Lightweight code review surface (commentable diffs, local-only, single-user v1) that exports to JSON for Claude Code consumption. Data model + JSON export schema + UI design + storage + state machine + test strategy + phasing.

**Key learnings:**
- **Local-first, single-user v1.** No GitHub/GitLab/Phabricator sync, no multi-author threads (replies come later via re-import after Claude Code responds), no provider sync. Multi-provider inbox is a later epic; v1 borrows visual vocabulary (state pills, inline thread cards, severity dots) but keeps data local.
- **Two surfaces required:** (1) Git-panel `Review` tab = index (flat list of active reviews, new-review button), (2) top-level review tab (opens as regular tab like Status diffs so user can split-pane or keep across sessions). Diffs need horizontal real estate; sidebar is too narrow.
- **Data model is persistence-friendly.** `Review` (id, title, description, scope, baseSha, headSha, state, comments, author, exports) + `ReviewComment` (id, parentId, filePath, anchor, severity, body, hunkContext). Comments are flat on disk, threads are soft-linked via `parentId`. `ReviewScope` is a tagged union (workingTree, commit, range, branch). Anchor model maps directly to diff line numbers (side, startLine, endLine, blobSha for staleness detection).
- **Export schema is different from persistence.** Export is file-grouped, self-contained with context inlined. Includes hunk headers + 3-line pre/post context around anchors. Severity stats. Optional instructions block (template: "Please act on each comment"). No internal IDs / timestamps / blob SHAs. Top-level `kind: "textview.code-review"` + `schemaVersion: 1` for format detection.
- **State machine is simple:** draft → inReview (auto on first comment) → complete (manual) → sent (after export) or back to inReview (reopen). State pill (grey/blue/green/purple) appears in index list + review tab header. SENT reviews render read-only; "Reopen for edits" button is escape hatch.
- **Comment affordances:** (1) hover line gutter → `+` button appears, click → inline editor card below line, (2) right-click → "Add review comment", (3) drag-select multiple lines → `+` on last row anchors multi-line. Editor shows severity buttons (info/suggestion/issue/blocker/praise/question) + markdown body + Cancel/Save. Saved comment renders as thread card under the line with Edit/Resolve/Delete buttons.
- **Right-rail comments index** (when window width ≥1200pt) or drawer otherwise. Severity dot + brief (truncated). Click → scroll diff to line, flash thread card. Toggle [Show resolved] + [Filter: severity].
- **DiffView change is minimal additive.** Optional `reviewSession` property; when nil (default), render is unchanged (Status/Log/Stash diffs unaffected). When set, afford affordances activate. Existing `DiffView` rendering path (`lineRow`, `hunkBlock`, `fileBlock`) unchanged.
- **Storage:** one JSON file per review at `~/Library/Application Support/MarkdownViewer/Reviews/<id>.json` (ULID), optional `_index.json` for fast list rendering. `ReviewStore` wraps `JSONFileStore` (already atomic). No new I/O mechanism needed.
- **Test strategy in five layers:** (1) `Review` model (round-trip, schema-version refusal), (2) `ReviewStore` (write/read/delete, atomic contract, schema guard, maxSize guard), (3) Exporter (snapshot tests vs golden, files-with-zero-comments omitted, severity stats, context clipping), (4) DiffView integration (hover affordance, no `+` when reviewSession==nil), (5) anchor stability (staleness detection on diff drift, content mismatch flags stale).
- **Phasing:** Phase 1 data model + storage, Phase 2 exporter, Phase 3 DiffView integration, Phase 4 Git-panel + top-level tabs, Phase 5 export menu + state machine, Phase 6 polish (comments index, severity filter, markdown rendering, keyboard shortcuts).

**Carry-forward:** PORT. This is feature-complete for a greenfield rebuild. The data model (Review, ReviewComment, ReviewScope, LineAnchor), export schema (file-grouped, self-contained, inlined context), storage shape (one JSON per review, ULID filenames), and state machine are directly reusable. The test strategy (five layers, snapshot tests for exporter, round-trip validation) is excellent. Recommend implementing this exactly as designed.

---

### PLUGINS_DESIGN_v2.md
**Status:** design (2026-06-02 onward; final v2 replaces v1 brainstorm). Ready to implement; comprehensive, non-negotiable on several points.

**What it is:** Three-tier plugin system (Tier A: JSON config only, Tier B: shell subprocess, Tier C: sandboxed WebView JS). 19 contribution points (sidebar sections, view modes, git-panel tabs, file icons, menu items, formatters, treesitter queries, themes, LSP discovery, CR templates, palette commands, etc.). Manifest-driven. No native Swift loadable bundles ("never," not "later").

**Key learnings:**
- **Tier A (JSON config, zero code execution):** themes, icons, query files, LSP discovery rules, CR templates, static sidebar bindings. No code. Tier A sidebar sections can bind to host-supplied variables via a tiny expression mini-language (jq-like path syntax, no function calls: `host.git.branch | default("(no repo)")`). Grammar is fixed now; evaluator is v1.1 follow-up.
- **Tier B (shell subprocess per invocation):** formatters, view modes (text/HTML), find providers, sidebar refreshers, walkthrough verbs, MCP tools. Manifest declares commands (executable paths inside plugin folder). Invocation: JSON envelope stdin (`{ "input": base64-or-string, "context": { url, selection, viewMode, args } }`), argv `[<command>, "--invocation-id", "<uuid>"]`, scrubbed env (PATH only + TV_PLUGIN_* vars, no HOME/SSH_AUTH_SOCK/AWS), cwd = plugin folder, stdout = response (format declared in manifest). Lifecycle: spawned per invocation (not daemon), coalesced on rapid repeat calls (latest wins). Resource limits: 5s wall-clock default (manifest can request up to 30s), 512 MB memory (best-effort), 16 MB stdout, ≤4 in-flight across all plugins (queue beyond). Crash isolation: subprocess, nonzero exit = failure, SIGKILL on timeout.
- **Tier C (sandboxed WKWebView JS):** view modes, sidebar widgets, git-panel tabs, render filters, MCP tools (rare), find providers (rich UI), status-bar widgets, walkthrough verbs (rare). HTML/JS bundle in plugin folder. No network access (WKWebView's WKWebpagePreferences blocks navigation), custom URL scheme handler scoped to plugin folder, message bridge (`window.webkit.messageHandlers.tv.postMessage` ↔ host reply via `evaluateJavaScript`). Bridge API surface: `tv.host.getInput()`, `tv.host.getContext()`, `tv.host.read(path)` (if `file.read` cap + path in project root), `tv.host.shell(command)` (if `shell.exec` cap, goes through Tier B machinery), `tv.host.notify(event)`, `tv.host.invokeCommand(id)`, `tv.host.storage.*` (scoped, 10 MB cap per scope), `tv.host.mcp.respond(id)` (for MCP tool response). What JS cannot do: fetch arbitrary URLs (blocked), access localStorage for exfil (per-instance, not persisted), touch other plugins. Crash isolation: WKWebView already separate process (com.apple.WebKit.WebContent); segfault kills renderer not host. Resource limits: postMessage traffic >50 MB per contribution → host kills WebView. WebView destroyed when contribution surface closes (hot-keep one per plugin if profiling demands).
- **Why no Tier D (native Swift loadable bundles), ever.** Five reasons: (1) TCC nightmare (plugin inherits host's entitlements, too broad, users blame app), (2) signing pain (notarization $99/yr if TestFlight path, Gatekeeper disabled otherwise, unsigned-binary loader rejected by App Store), (3) blast radius (plugin can swizzle NSApp, retain-cycle main actor, corrupt DocumentModel, call private APIs; only separation is subprocess which we have in Tier B), (4) ABI churn (Swift module ABI unstable for internal types; either freeze our API or break plugins every release), (5) every feature that needs native (go-to-def, pretty-print, custom view mode) can be Tier B (subprocess) or Tier C (WebView). Cost unjustified. If future plugin needs native (3D viewer?), it's a built-in shipped in ViewerCore, acceptance of maintenance burden.
- **Manifest schema:** id (reverse-DNS), name, version (semver exact), author, homepage, license (SPDX). hostVersion (semver range, evaluated at load; out-of-range = disabled with hint, no silent ignore). manifestVersion (1 in v1; bump on incompatible changes, not additive). capabilities (list, user grants each on install, re-prompt on bump). contributes (≥1 required, else inert). mcpTools (may be empty). Optional signature block (ed25519).
- **19 contribution points:** sidebar section, view mode, git-panel tab, file icon, menu item, keyboard shortcut, treesitter queries (phase 1: queries-only against existing langs; phase 4+: full grammar loading, NOT v1), theme, custom pretty-printer, LSP discovery rule, CR comment template, command-palette command, walkthrough step verb, status-bar item, render filter (markdown AST hook), find provider, custom URL handler sub-path (under `textview://plugins/<id>/<verb>`), session-scoped storage.
- **Registry model:** every contribution point is a registry owned by `PluginRegistry`. Manifest → registry → view code reads registry. No global mutable singletons. Hot-reload re-runs discovery for affected folder only.
- **Permission model is capability-based.** Manifest declares capabilities; user grants per-plugin on install (all-or-nothing in v1, no per-tool fine-grain). Grant store: `~/Library/Application Support/TextView/plugin-grants.json` via JSONFileStore. Per plugin: grantedAt timestamp, grantedFor list, grantedHostVersion, manifestHash. Re-prompt on capability set growth or manifestHash mismatch + capability difference. First-install panel non-modal, shows "This plugin would be able to: [capabilities]" + "This plugin would NOT be able to: [list of denials]" (no network, no files outside project, no modify/delete/rename). Audit log: `~/Library/Logs/TextView/plugins-audit.jsonl` (timestamp, plugin, capability, command, args hash, invocation id, exit code, duration). Settings → Plugins → Activity shows the log.
- **Distribution:** drag-drop `.tvplugin` folder onto app window or Plugins pane. No marketplace, no auto-update, no curl-pipe-sh. Folder name should match plugin id (not enforced; mismatch = warning). Discovery: enumerate `~/.../Plugins/*/plugin.json`, validate schema, check hostVersion (disabled if out-of-range), look up grant record (disabled if capability mismatch, needs-regrant), register contributions (Tier B/C runtimes NOT started here, spun on first invocation). Persist load-result to `.load-log.json` for Settings visibility.
- **Tier 0 (bundled first-party Swift plugins) has a contract, NOT optional.** (1) No `throws` at boundary (pure `(Snapshot) → [Row]`; plugin catches internally, returns `[]`). (2) No `fatalError`/`precondition`/`assertionFailure` on user input (reserved for programmer-error invariants). (3) Wall-clock soft 50ms (yielded cooperatively), hard 500ms (registry timeout). (4) Row cap 1000 (truncate over). (5) Misbehaviour (truncation, budget breach, timeout, exception) → audit log. (6) No state outside plugin's enum-namespaced statics (no NotificationCenter observers, no timers). Deliberately NOT enforced: per-actor panic isolation (Swift has none in 2026), memory cap (first-party code trusted).
- **Tier 0 is NOT open to third-party.** Third-party authors are pushed to Tier B (subprocess isolation, crash doesn't kill host) or Tier C (WebView isolation, separate process). Tier 0 trust == internal code review at PR time.
- **Sample plugins:** (1) com.example.tv.solarized (Tier A theme), (2) com.example.tv.protobuf (Tier B shell-out pretty-printer + view mode), (3) com.example.tv.dashboard (Tier C sidebar widget + WebView). Each is a complete worked example ready to implement.

**Carry-forward:** PORT. This design is comprehensive, non-negotiable on Tier D (no native bundles), and directly reusable. The three-tier model (JSON / subprocess / WebView), contribution points (19 points covering ~all extension needs), permission model (manifest-declared, user-grant per-plugin, audit log), and Tier 0 contract are production-grade. Recommend implementing exactly as specified without redesign.

---

## Summary by Theme

### **Rust-Core Architecture**
- Deliberately sans-IO engine layer, adapters handle I/O.
- MessagePacked frames as transport abstraction (same format for local FFI, remote socket).
- All 9 engines ported with capability-bitmap contract and A/B-test gates.
- Fallback-on-CoreError pattern is load-bearing.
- Remote operation (Rust server + thin Swift client) shapes current deprecation path.

**Status:** LOCKED. The Rust-first strategy paid off; enable it from day one in greenfield.

### **Agent-Native Automation**
- MCP (not AppleScript, not JS, not Lua) is the primary surface.
- Local-only, file-system-scoped, read-heavy, viewer-shaped.
- Typed 10-action priority list: open, get-state, select-tab, set-view-mode, find, goto-line, get-visible-text, bookmark, snapshot, subscribe-to-events.
- Audit log + Settings visibility.
- App Intents as thin facade (same release, no second gate).

**Status:** PROVEN. Use this design without modification.

### **Features Must Be Usable, Not Just Built**
- Feature Inventory audit distinguishes Built / Logic-verified / Usable.
- Usability = "owner-confirmed," not "tests pass."
- Eight cross-cutting gaps recur: alerts, empty states, progress, discoverability, cohesion, felt-latency, unfinished loops, on-screen verification debt.
- Gap-ticket hierarchy with self-contained briefs is reusable.

**Status:** CALIBRATION. Start with explicit usability checklist; avoid the "built but unusable" trap.

### **Plugin System Is Three-Tier, Never Native**
- Tier A: JSON + assets (themes, icons, queries, static bindings).
- Tier B: shell subprocess (formatters, view modes, any "input → output").
- Tier C: sandboxed WKWebView JS (interactive UI, render filters).
- Tier 0 (bundled first-party Swift) has strict contract; third-party never gets native.

**Status:** DEFINITIVE. The "never native" boundary is non-negotiable; the three-tier model is comprehensive.

### **Comprehensive Design Records**
- LSP (hover, go-to-def, outline, find-refs; phases 1–3 mapped).
- Code Review (local-only, JSON export for Claude consumption, state machine, phased implementation).
- Performance (signpost instrumentation + Instruments workflow, 7 stages, real-app profiling).
- Automation (MCP + App Intents, 10 actions, audit log, Unix socket default).

**Status:** READY TO PORT. Each design is feature-complete for v1; minimal redesign needed.

---

## Portable-Artifact Candidates

### **Files Worth Copying Verbatim**

1. **docs/AUTOMATION.md** — MCP server design, security model, audit log, 10-action list, migration path. Adapt bundle ID and subsystem name; everything else is reusable.

2. **docs/LSP_DESIGN.md** — process pool model, capability boundaries, protocol types (vendor strategy), spawn discipline, concurrency structure. Drop-in reference for LSP integration.

3. **docs/CODE_REVIEW_DESIGN.md** — data model, export schema, storage shape, state machine, test strategy, phasing. Implement exactly as written.

4. **docs/PLUGINS_DESIGN_v2.md** — three-tier model, 19 contribution points, permission model, manifest schema, Tier 0 contract, sample plugins. Definitive; don't redesign.

### **Sections Worth Distilling**

1. **ARCHITECTURE_LAYERS.md § Remote operation** — the shape (thin client, Rust server, shared frames) should inform greenfield's transport abstraction from day one.

2. **FEATURE_INVENTORY.md § Eight cross-cutting usability gaps** — bake these into acceptance criteria before shipping features.

3. **PERFORMANCE_PROFILING.md § PerfSignpost infrastructure** — signpost stages + meaning table is directly reusable. Copy the seven stages verbatim.

4. **AGENT_PRODUCTIVITY_FEEDBACK_2026-06-20.md § Ranked improvements #1–8** — semantic code nav and render-verification are agent-roadmap items; port to greenfield's MCP tooling strategy.

### **Patterns Worth Stealing**

1. **Gate-driven A/B testing** (Rust engine gates, all default OFF, flip ON after soak). Applicable to any major subsystem.

2. **Manifest-driven registries** (PLUGINS_DESIGN §2.19 registry model). Useful beyond plugins; consider for command palette, formatters, etc.

3. **Phased-feature breakdown** (CODE_REVIEW_DESIGN §11, SIX phases; PLUGINS_DESIGN phases; LSP phases 1–3). Use this structure for every major feature.

4. **Three-column feature audit** (FEATURE_INVENTORY: Built / Logic / Usable). Bake into CI/sprint planning.

---

## Known Limitations / Gaps

- **LESSONS.md, BACKLOG.md, HANDOFF.md not in this batch** (top-level, not docs/). Contain institutional knowledge, blocking items, current session state.
- **Large docs partially sampled** (LSP_DESIGN is ~35 KB, read first 1.5 KB to outline; full design exists).
- **Docs written 2026-05-20 to ~2026-07-10; some mark as "design draft"** but are feature-complete for v1 and ready to implement.
- **No samples of *running* code** (docs are design-first; implementation in Sources/).
- **Canvas epic (M0–M6) explicitly parked** — don't build without owner approval (FEATURE_INVENTORY §11).

---

## Recommendations for Greenfield

**Adopt wholesale:**
1. MCP as automation surface (docs/AUTOMATION.md)
2. Three-tier plugins (docs/PLUGINS_DESIGN_v2.md)
3. LSP integration (docs/LSP_DESIGN.md)
4. Code review (docs/CODE_REVIEW_DESIGN.md)
5. Performance signposting (docs/PERFORMANCE_PROFILING.md)

**Adapt from this batch:**
1. Feature Inventory audit (add to Definition of Done)
2. Rust-core sans-IO model + adapter split
3. Gate-driven A/B testing
4. Manifest-driven registries
5. Phased-feature breakdown

**Avoid:**
1. Native plugin bundles (ever)
2. "Built" without "usable" confirmation
3. Features without empty states + progress + error surfacing
4. Cohesion gaps (consolidate overlapping surfaces before shipping)

---

## End of Batch 1/2

Remaining batch 2 would cover: AUTONOMOUS_PROGRESS.md, CAPABILITIES.md, CM6_* designs, CODE_FOLDING_*, DAEMON_LIFECYCLE_*, FEATURE_EXPLORATION_*, FOCUS_ROUTING_*, GIT_DESIGN (if exists), HEX_* designs, KEYBINDINGS_*, MEMORY_AND_CPU_*, MERMAID_*, MODERN_LANGUAGE_*, PARITY_AUDIT_*, POC_*, PRELAUNCH_*, PREVIEW_TAB_*, PROJECT_MANAGEMENT_*, and others.
