# LSP own-vs-external + Plugin/Core boundary — spike findings

> **Status:** SPIKE + design (auto-approved, owner 2026-06-13). Read-only
> investigation of the live tree, no code changed. Covers two board tickets:
> **TSK-781** (LSP: own implementation vs external server) and **TSK-779**
> (plugin/core decomposition boundary). Both reach the same conclusion from
> two angles: **the app's job is to own a small, sans-IO, deterministic core
> and broker untrusted/heavy/optional work out across a process boundary.**

Date: 2026-06-13 · Agent: claude-mdv

---

## Part A — TSK-781: LSP own implementation vs external server

### A.0 Recommendation (lead)

**Keep the current posture: own the *client* (the JSON-RPC layer + process
supervision + protocol Codable types), rely on *external, user-installed*
language servers. Do NOT build, bundle, or own a language server.** This is
already what the codebase does, it is the correct call, and the spike found no
reason to change it. The only follow-on work worth filing is hardening +
discoverability, not an architecture pivot.

The framing in the original wishlist ("own it vs external") conflates two
separable layers. Drawing them apart dissolves the dilemma:

| Layer | What it is | Own or external? | Today |
|---|---|---|---|
| **LSP client** (framing, JSON-RPC, lifecycle, pool, position math, edit applier) | ~few hundred lines of Codable + a stdio supervisor | **OWN** (already do) | `ViewerCore/LSP/*` |
| **Language server** (sourcekit-lsp, jdtls, pyright, tsserver) | 10k-100k+ LoC compilers/analyzers per language | **EXTERNAL** (already do) | discovered on `$PATH` / `xcrun` |

"Own the client, rent the servers" is exactly the VS Code / Zed / Neovim
model, and it is what is implemented here.

### A.1 What the current integration actually does (verified in tree)

The integration is real and substantial — not a stub. Spawning is external,
over stdio, lazily, pooled per workspace+language:

- **External process over stdio.** `LSPClient` (`ViewerCore/LSP/LSPClient.swift`,
  ~59 KB) spawns the server with Foundation `Process` (`p.executableURL`,
  `p.run()`), wires `stdin`/`stdout`/`stderr` `Pipe`s, and frames JSON-RPC 2.0
  with LSP `Content-Length` headers (`LSPFraming.swift`). It is an `actor`; the
  blocking stdout `read(2)` runs on a **dedicated `Thread`** (not the
  cooperative pool) to avoid starvation, with a documented macOS-26 FileHandle
  pipe-wedge worked around via raw POSIX `write(2)` + `F_SETNOSIGPIPE`. This is
  battle-scarred, production-grade transport code, not a PoC despite the
  header comment.
- **Process pool + supervision.** `LSPPool.swift` (~38 KB) keys clients by
  `(LSPLanguage, workspaceRoot)`, spawns lazily on first request, reaps idle
  clients (5-min default), and restarts crashed servers with exponential
  backoff (`[250ms, 1s, 5s]`, max 3 attempts, then a 30s dead-cooldown). It
  forwards `publishDiagnostics` pushes into a `@MainActor` store and tracks
  per-file version counters + content hashes (PERF-01: skips re-`didChange`
  when the buffer is byte-identical, e.g. on tab switch). This is the "client
  owns the server lifecycle" doctrine from `LSP_DESIGN.md` §1.2.
- **Discovery is external + user-driven.** `LSPDiscovery.swift` finds servers
  via `xcrun -f sourcekit-lsp` -> `/usr/bin/sourcekit-lsp` for Swift, and a
  generic `locate(binary:)` that walks an augmented `$PATH` (GUI apps don't
  inherit the shell PATH) -> Homebrew/npm prefixes -> `which`. A
  `Contents/Resources/lsp/<binary>` bundle slot exists as a *forward-compat*
  fallback but ships **empty** — nothing is bundled today.
- **Languages onboarded via config, not code.** `LSPLanguage.swift` maps
  Swift->`sourcekit-lsp`, TS/JS->`typescript-language-server`, Java->`jdtls`,
  Python->`pyright-langserver`, with per-language install hints and arg
  construction (e.g. jdtls's required `-data <workspaceDir>`, stored under the
  bundle-id Application Support dir as `jdtls-data/`). `LSPWorkspaceOverrides.swift`
  lets a workspace `lsp.json` override the command/args/`initializationOptions`
  per server (§11) — so a user can point at any server binary.
- **Pure, host-testable seams already isolated.** `LSPTextEditApplier`
  (formatting edits -> text, reverse-document-order, hostile-input-clamped),
  `LSPPositionConverter` (UTF-8/16/32 position encoding negotiation), and the
  `LSPProtocol` Codable structs are pure logic with no I/O — exactly the
  vendored-protocol-types posture the design doc argued for.
- **Read-mostly feature scope.** `LSP_DESIGN.md` §0 deliberately scopes to
  viewer features (hover, go-to-def, references, outline, workspace symbols,
  diagnostics, semantic tokens, inlay hints) — explicitly **no completion / no
  code-actions / no refactor**. Formatting + rename landed later (TSK-627
  applier) but the center of gravity is "understand the code," not "be an IDE."
- **Dependency posture is already vendor-it-ourselves.** The design rejected
  ChimeHQ `LanguageClient`/`LanguageServerProtocol` (~25 kLoC supply-chain
  surface) for a few hundred lines of owned Codable + framing. That decision
  holds — the protocol layer is stable (LSP 3.17) and small.
- **A fake server exists for host tests.** `Sources/MDVFakeLSPServer` is an
  in-tree minimal server so the e2e path is exercisable headlessly without a
  real toolchain (TSK-627 injectable registry).

### A.2 Own-vs-external decision matrix (the *server*)

The question only has teeth at the *server* layer. Owning a language server
means shipping/maintaining a compiler front-end per language. The cost is
categorically out of proportion to a viewer:

| Dimension | Own a language server | Rely on external (current) |
|---|---|---|
| **Robustness** | Must track each language's evolving semantics, std-lib, build-system quirks — a perpetual moving target. A bug is *our* bug, in *our* process, with *our* crash blast radius. | Server runs out-of-process; a crash is a nonzero exit the pool restarts with backoff. The server is the same binary the user's editor/CI already trusts. Failures are isolated by the OS. |
| **Speed / latency** | No theoretical edge — these servers are already heavily optimized (incremental compilation, caching). We'd start years behind. | sourcekit-lsp/rust-analyzer/etc. are state-of-the-art. Cold-start is the only tax; PERF-01 hash-skip + the warm pool already amortize it. |
| **Maintenance burden** | Enormous and unbounded — effectively forking N compiler front-ends. Dwarfs the entire rest of the app. | ~few hundred lines of client. Servers update independently via the user's package manager; we inherit fixes for free. |
| **Bundle / process cost** | sourcekit-lsp alone is tens of MB and toolchain-coupled; jdtls drags a JVM. Bundling blows the 48 MB cap many times over and creates a signing/notarization + per-arch maintenance nightmare. | Zero bytes shipped. We spawn what's on the user's machine; `Contents/Resources/lsp/` slot stays empty. |
| **Correctness authority** | We become the source of truth for "is this Swift valid" — a liability we cannot honor. | The canonical server is the authority; we just render its answers. |
| **Supply-chain** | We'd vendor or fork huge codebases. | We vendor only LSP protocol *types* (stable, small). Servers are the user's own trusted installs. |

**There is no dimension on which owning a language server wins.** The robust
*and* fast path is: own a tight client, lean on the canonical servers.

### A.3 Where "own" already correctly applies — and the real risks

We *do* own everything that is small, stable, and security/correctness-
sensitive: framing, lifecycle/supervision, position math, the edit applier,
the protocol types. That is the right line. The genuine risks are operational,
not architectural:

1. **Discovery friction (the #1 real UX gap).** GUI-launched apps don't inherit
   shell PATH; a user with pyright installed via a non-standard prefix sees
   "no server." Mitigation already partly present (augmented PATH + `lsp.json`
   override). *Worth filing:* a Settings -> LSP panel that shows discovered vs
   missing servers with the exact install hint (`LSPLanguage` already carries
   the strings) and a "browse to binary" picker writing `lsp.json`.
2. **Spawning untrusted binaries.** We `Process`-spawn whatever resolves on
   PATH. `LSPDiscovery.isBinarySafeToSpawn` exists; the threat model (a hostile
   `node_modules/.bin/typescript-language-server` in an opened repo) deserves a
   one-time confirmation before first spawn of a workspace-local server — same
   habituation concern as `URLSchemePolicy`. *Worth filing.*
3. **Zombie/lifecycle hazards** (the documented #1 operational hazard,
   `LSP_DESIGN.md` §1.2) — already handled (`F_SETNOSIGPIPE`, explicit
   shutdown->exit->SIGTERM->SIGKILL teardown, `didReap` double-wait guard). Keep
   the host tests that pin this.
4. **jdtls JVM heft + `-data` dir growth** — operational, not architectural;
   the per-workspace data dir under Application Support is already isolated.

### A.4 Bonus framing: LSP as a *plugin contribution* (ties to TSK-779)

The cleanest long-term expression of "external server" is that **a language is
a Tier-A/B plugin contribution**: a manifest declares
`{language, command, args, rootMarkers, initializationOptions}` and the host
registers it into `LSPLanguageRegistry`. `LSPWorkspaceOverrides`'s `lsp.json`
is already 80% of this contract. That makes new-language onboarding a
zero-code, drag-drop act and unifies the two epics. (Not required now — filed
as a future consideration, see §B.6.)

---

## Part B — TSK-779: plugin/core decomposition boundary

### B.0 The principle that draws the line (lead)

> **Core owns determinism, identity, and the security perimeter; plugins own
> optional, IO-bound, or domain-specific surfaces — and everything a plugin
> touches must cross an explicit, capability-gated, OS-enforced process
> boundary.**

Three operational tests, in order. A subsystem is **plugin-able** only if it
passes all three:

1. **Determinism test** — Is it pure, sans-IO, bytes-in/bytes-out compute that
   the document model's correctness depends on? -> **CORE.** (The Rust engines,
   the document/tab model, the security fences.) These cannot be a plugin
   because the host must be able to trust their output unconditionally and run
   them on the hot path with no IPC tax.
2. **Perimeter test** — Is it part of the security boundary itself (sanitizer,
   URL/scheme containment, regex-ReDoS guard, capability/grant store, the
   subprocess host that *enforces* the sandbox)? -> **CORE, always.** A plugin
   cannot own the fence that contains plugins.
3. **Optionality test** — Is it optional, IO-bound, domain-specific, or
   replaceable, such that a crash or absence degrades gracefully rather than
   breaking the viewer? -> **PLUGIN-ABLE**, behind a capability grant + process
   boundary. (SQLite browser, AWS, image editor, media, terminal, extra
   languages, formatters, custom renderers.)

This is **the exact same principle that A.2 reaches for LSP** — own the small
deterministic broker, push heavy/untrusted/optional execution across a process
boundary — which is why these two tickets are one architectural decision.

### B.1 The boundary is already half-built and consistent

The codebase has *already chosen this line* in three independent places, which
is strong evidence it's the right one:

- **Rust core = the sans-IO floor.** `rust-core/crates/core/src/lib.rs` is
  literally documented "the pure, sans-IO functional core." Its FFI surface
  (`dispatch.rs::Method`) is a closed enum of **stateless bytes-in/bytes-out**
  ops: `CmApply, DiffParse, DiffHunkMarks, FuzzyRank, FindSearch,
  MarkdownRender, TranscriptParse, HighlightRuns`. No IO, no UI, no ambient
  state — `call(method, req, aux)` is a pure function. This is the
  non-negotiable core, and the Rust migration policy (owner 2026-06-11) treats
  these engines as the canonical implementations.
- **Plugin host = the process-boundary broker.** `PluginSubprocessHost.swift`
  already implements exactly the right enforcement for Tier B: one process per
  call, **env scrubbed to HOME only** (no PATH/USER/`*_TOKEN`/`AWS_*`/
  `OPENAI_API_KEY`), 5s wall-clock hard-SIGKILL timeout, 1 MB stdout cap, and a
  byte-free JSONL audit log (0o600). `PluginManifest`/`PluginRegistry` add
  capability declaration + per-plugin grants + fail-isolation (one bad manifest
  doesn't poison siblings).
- **Plugin design = the same OS-enforced tiers.** `PLUGINS_DESIGN_v2.md`:
  Tier A (JSON config, no code), Tier B (subprocess over stdio JSON/bytes),
  Tier C (sandboxed WKWebView), **no native Swift loadable bundles, ever**
  (§3.4 — TCC/signing/crash-blast-radius/trust-prompt footgun). Crash isolation
  is the OS process boundary in every tier. The normative capability list
  (§5.1) is the grant vocabulary: `shell.exec`, `webview.run`,
  `network.egress`, `fs.read`/`fs.write` (scoped), `ui.*`.

The two halves meet at the principle: **core is the only thing allowed to be
trusted and in-process; everything pluggable is contained.**

### B.2 Per-subsystem classification

Legend — **CORE** (must stay), **PLUGIN** (extractable now/soon), **HYBRID**
(thin core seam + pluggable provider).

| Subsystem | Verdict | Why (which test) |
|---|---|---|
| **Rust engines** — markdown render, syntax highlight, diff, CSV, find/search, fuzzy, transcript parse, cm-edit reducer, hex, indent, JSON | **CORE** | Determinism test. Sans-IO, hot-path, correctness-load-bearing; `dispatch.rs` is the closed pure-fn surface. The whole Rust-split + remote-core goal depends on this staying a tight engine. |
| **Document / tab / buffer model** — `DocumentController`, `Tab`, `TabsState`, `EditorBuffer`, `ViewMode`, `MountedPanesLRU` | **CORE** | Determinism + identity. This is the app's identity & state machine; plugins *contribute into* it, never own it (design: "plugins add entries, they do not replace the host implementation"). |
| **Security fences** — `HTMLSanitizer`, `HTMLDocumentPolicy`, `URLSchemePolicy`, `RegexComplexityGuard`, `PluginGrantStore`, `PluginSubprocessHost` enforcement | **CORE, always** | Perimeter test. A plugin cannot own the fence that contains plugins. The sandbox enforcer is intrinsically host. |
| **Sessions / Workspaces / Bookmarks / History / Recent paths** | **CORE** | Identity test — these *are* the app's persistent state & restore guarantee. Plugins get a *scoped* per-session store (design §2.13), not ownership. |
| **Theme engine** | **HYBRID** | Theme *application* is core (it touches every surface); individual themes are pure data -> **Tier A plugins** (the original "v0 themes-as-JSON", design §0). Themes-as-data ship as the canonical first plugin. |
| **File-icon classifier / language extensions / file-type handlers / classifier rules / palette entries** | **PLUGIN (Tier A)** | Optionality test — pure declarative data, no runtime. The lowest-risk plugin slice; ships first. |
| **Formatters / pretty-printers / jq-style converters** | **PLUGIN (Tier B)** | Optionality + IO. Per-action subprocess, stdin/stdout — the canonical Tier B use case (design §2.x, `format.provide` + `shell.exec`). |
| **SQLite browser** | **PLUGIN (Tier B/C)** | Optionality + domain-specific. `SQLiteReader` is a self-contained read-only reader; a *full browser* (query, schema nav) is the archetypal Tier B/C plugin (cited in TSK-772). Core need only keep the file-type recognition seam. |
| **AWS / cloud integrations** | **PLUGIN (Tier B, `network.egress`)** | Optionality + IO + network. Never core — pulls credentials & network surface; exactly what the env-scrub + `network.egress` grant exist for. |
| **Image editor** — `ImageEditing/*` (Renderer, ImageDocument, EditOps, Histogram, Exporter) | **PLUGIN-ABLE (HYBRID), later** | Optionality. Already a self-contained module with its own document. *Viewing* an image is core (a view mode); *editing* is a candidate plugin surface. Extraction is non-trivial (it's deeply wired into the view-mode + toolbar) so it's a "can be, eventually" not a "should be now." |
| **Media / audio** — `Audio/*`, ffmpeg integration | **PLUGIN-ABLE (Tier B)** | Optionality + IO + external tool. ffmpeg is already an *external host tool* (owner-approved, not bundled) discovered like an LSP server — already on the plugin side of the line conceptually. |
| **Terminal** — `Terminal/*` (ANSIParser, TerminalScreen, PTY) | **CORE (parser) + can't-fully-plugin (PTY)** | The ANSI parser/screen model is pure (sans-IO, core-class). But a terminal *needs* a PTY + raw process I/O the current Tier-B "one process per call, env-scrubbed, 5s timeout, 1 MB cap" host **cannot** provide (it's the opposite of a long-lived interactive PTY). So terminal stays host-owned until/unless a new "Tier D: long-lived interactive" plugin contract is designed. **Flag for owner — see Parked.** |
| **LSP** | **HYBRID -> PLUGIN-contributable** | Client = CORE (small, security-sensitive supervisor). *Servers* = external (Part A). A *language registration* is a natural Tier A/B plugin contribution (§A.4) — the cleanest future expression. |
| **Mermaid / DOT graph rendering** | **HYBRID** | Mermaid render today runs JS in a WebView (already a process boundary) — Tier-C-shaped. The recognition + invocation seam is core; the renderer is pluggable. |
| **Git panel** | **HYBRID** | Core owns the panel + git status model; *tabs within it* are an explicit contribution point (design §2.3, `ui.gitpanel`). |
| **MCP / automation surface** — `Automation/*`, `MCPToolCatalog` | **CORE (the server) + PLUGIN (tool publishers)** | The MCP server + the 10 host verbs (`open_path`, `find`, `goto_line`, `current_state`, `snapshot_window`, ...) are core (they drive the host model). A plugin can *publish* MCP tools under its namespace (design §8) routed into its Tier B/C runtime. |
| **Sidebar sections** | **CORE registry + PLUGIN entries** | `SidebarSectionRegistry` is core; the 5 built-in sections are core; *new* sections are the flagship plugin contribution (`ui.sidebar`, Tier A/B). |

### B.3 The line, stated once

```
                    +-----------------------------------------------+
   PLUGINS          |  Optional . IO-bound . domain-specific         |
 (contained,        |  AWS . SQLite browser . formatters . extra     |
  capability-gated, |  languages . custom renderers . themes-as-data |
  process boundary) |  . image *editing* . media/ffmpeg              |
                    +----------------------^------------------------+
                                           |  capability grant + env-scrub +
                                           |  process boundary + audit log
   ========================== THE LINE ====+============================
                                           |
                    +----------------------+------------------------+
   CORE             |  PERIMETER: sanitizer . URL/scheme policy .    |
 (trusted,          |  ReDoS guard . grant store . subprocess host   |
  in-process,       +------------------------------------------------+
  no IPC tax)       |  IDENTITY: document/tab model . sessions .     |
                    |  bookmarks . history . view modes              |
                    +------------------------------------------------+
                    |  DETERMINISM (sans-IO Rust engines): parse .   |
                    |  highlight . diff . csv . find . fuzzy .        |
                    |  transcript . cm-edit                          |
                    +------------------------------------------------+
```

### B.4 Why a plugin can never own these (the failure modes if it did)

- **A Rust engine as a plugin** -> per-call IPC tax on the render/highlight hot
  path, and the host would have to trust a subprocess's bytes for the very
  output the document model is built on. Defeats the sans-IO/remote-core goal.
- **A security fence as a plugin** -> circular trust: the thing that sandboxes
  plugins would itself be a plugin. A malicious plugin could supply its own
  sanitizer. Non-starter.
- **The document model as a plugin** -> loses single-owner lifecycle; the
  "plugins contribute, never replace" invariant breaks, and crash isolation
  evaporates because the host's own state would live behind IPC.

### B.5 Capability ceiling (what plugins are *allowed* to reach)

The grant vocabulary already defines the reachable surface (design §5.1,
`PluginManifest.Capability`): `ui.sidebar/viewmode/menu/palette/keyboard/
statusbar/gitpanel` (UI contribution), `shell.exec` (Tier B subprocess,
named-commands-only), `webview.run` (Tier C), `network.egress`, `fs.read`/
`fs.write` (scoped to the open project). **Anything a subsystem needs beyond
this ceiling is a signal it belongs in core** (e.g. terminal's PTY, §B.2).

### B.6 Recommended sequencing (no new code in this spike)

1. **Tier A first** — themes-as-data + file-icon/language-extension/classifier
   plugins. Zero runtime risk, validates the manifest/grant pipeline. (Underpins
   TSK-754 menu contributions, TSK-777 PDK.)
2. **Tier B next** — formatters/converters + SQLite-browser-style plugins
   (TSK-772). The subprocess host + audit log already exist.
3. **MCP tool publishing** (TSK-773) — wire plugin-declared MCP tools into the
   existing `MCPServer` under the plugin namespace.
4. **LSP-as-contribution** (§A.4) — make a language a Tier A/B contribution by
   generalizing `lsp.json`. Folds TSK-781's external-server posture into the
   plugin model.
5. **Defer**: image-editor extraction (deeply view-wired), terminal (needs a
   new long-lived-interactive tier — owner decision), Tier C webview plugins.

---

## Cross-ticket conclusion

Both questions resolve to one principle: **own a small, deterministic,
in-process core (sans-IO engines + identity + the security perimeter); broker
everything heavy, untrusted, optional, or domain-specific across an explicit
capability-gated process boundary.** For LSP that means own the client, rent
the servers. For decomposition it means the engines/model/fences are immovable
core and everything IO-bound/optional is plugin-able. The codebase has already
committed to this line in three places (Rust sans-IO core, the Tier-A/B/C
plugin host, the LSP external-server supervisor) — the spike's recommendation
is to **ratify and continue it**, not to repaint it.

### Parked for owner (genuine decisions, not blockers)

- **Terminal tier.** A terminal cannot fit the current Tier-B contract
  (one-shot, env-scrubbed, 5s/1 MB capped). Either it stays host-owned core, or
  we design a new "Tier D: long-lived interactive (PTY/socket)" plugin contract.
  This is a product/architecture call, surfaced via task_park on TSK-779.

### Open follow-ups worth filing as tasks (non-blocking)

- LSP Settings panel: discovered-vs-missing servers + install hints + binary
  picker writing lsp.json (addresses the #1 real UX gap, §A.3.1).
- One-time confirmation before spawning a workspace-local LSP binary (§A.3.2).
- LSP-as-plugin-contribution generalization of lsp.json (§A.4 / §B.6.4).
