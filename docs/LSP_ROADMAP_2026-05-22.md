# LSP_ROADMAP_2026-05-22.md — expanding LSP support in TextView

> Read-only audit + proposal. No code changes. Companion to
> `docs/LSP_DESIGN.md` (canonical architecture, ~1956 lines) and
> `docs/UI_TEST_GAPS_2026-05-22.md` §3 (current UI gaps).
>
> Scope of this doc: answer three questions —
> **Q1** which LSP capabilities to add next, ranked by value × effort
> for a read-only viewer; **Q2** how to add TS / JS / Java / Python;
> **Q3** bundle-vs-PATH distribution per language.

---

## 1. TL;DR

Shipped today: **Swift / sourcekit-lsp only**, with hover popovers,
Cmd-click go-to-definition, hierarchical outline, and a Settings
diagnostics panel. Everything else from `LSP_DESIGN.md` §2 is
implemented at the protocol layer **or stubbed out at the registry**
but not exposed in UI.

Recommended next three features, in priority order:

1. **typescript-language-server** (TS+JS in one server) — `LSPLanguage`
   case + registry entry + PATH discovery. Lights up all four currently-
   wired UI surfaces (hover, jump, outline, diagnostics) for the
   single most-requested language pair. ~1 day.
2. **`textDocument/references` + a results panel** — biggest missing
   reading-mode feature; "where is this used?" is the question viewers
   ask most after "what is this?". ~2 days (panel UI is the real cost).
3. **`workspace/symbol` mode in the command palette** — extend
   `CommandPaletteView` with an `@` / `#` prefix per `LSP_DESIGN.md`
   §5.4. Coordinate with the unified-search panel work in flight; this
   is a natural mode for it. ~1.5 days.

After that: Java (jdtls — heavy, needs design review), then Python
(pyright). Both PATH-discovered. **Do not bundle any LSP server** —
all candidates blow the 35 MB total / 15 MB exec bundle cap once.

---

## 2. Current LSP state

### 2.1 Capabilities matrix

| Feature | LSP method | In `LSPClient`? | In `LSPPool`? | Wired in UI? | Effort to add (incremental) | UI surface needed |
|---|---|---|---|---|---|---|
| Hover | `textDocument/hover` | yes (`LSPClient.swift:401`) | yes (`hover` wrapper, `LSPPool.swift:377`) | **yes**, prod dwell trigger (`LSPHoverAttachment.swift`) | — | NSPopover (done) |
| Go-to-definition | `textDocument/definition` | yes (`LSPClient.swift:416`) | yes (`LSPPool.swift:394`) | partial — Cmd-click monitor installed by `LSPHoverAttachment.bind`; **no menu item, no right-click, no multi-result picker** | small (menu + picker popover) | `DocumentController.openTab(..., scrollTo:)` exists |
| Go-to-declaration | `textDocument/declaration` | no | no | no | small (mirror `definition`) | same as go-to-def |
| Go-to-implementation | `textDocument/implementation` | no | no | no | small | same |
| Go-to-type-definition | `textDocument/typeDefinition` | no | no | no | small | same |
| Find references | `textDocument/references` | no | no | no | **medium** (panel UI is the real cost) | new sliding "References" panel/tab, similar to `CrossSearchPanel` |
| Document symbol (Outline) | `textDocument/documentSymbol` | yes (`LSPClient.swift:435`) | yes (`LSPPool.swift:362`) | **yes** (`LSPOutlineSection.swift` + `SidebarView.swift:541` wrapper) | — | sidebar section (done) |
| Workspace symbol search | `workspace/symbol` | no | no | no | medium | new mode in `CommandPaletteView` (Slack-style `@` / `#` prefix) — **natural fit for the unified-search panel currently being built** |
| Diagnostics (push) | `textDocument/publishDiagnostics` | **no inbound handler** — `dispatchInbound` (`LSPClient.swift:167-200`) drops server-originated notifications | no store | partial — `LSPDiagnosticsView` shows pool *health* only, not per-file LSP diagnostics | medium (notification routing + per-file store + sidebar list) | inline squiggles (NSTextStorage temp attrs) + "Problems" sidebar section |
| Diagnostics (pull) | `textDocument/diagnostic` | no | no | no | medium | same surfaces |
| Code actions / quick-fix | `textDocument/codeAction` | no | no | no | n/a — **out of scope per `LSP_DESIGN.md` §8.1 viewer mandate** | — |
| Rename symbol | `textDocument/rename` | no | no | no | n/a — out of scope | — |
| Formatting | `textDocument/formatting` | no | no | no | n/a — out of scope | — |
| Completion | `textDocument/completion` | no | no | no | n/a — out of scope | — |
| Signature help | `textDocument/signatureHelp` | no | no | no | n/a — out of scope | — |
| Document highlight | `textDocument/documentHighlight` | no | no | no | low value — tree-sitter already does same-identifier highlight locally | — |
| Inlay hints | `textDocument/inlayHint` | no | no | no | medium | text-view attribute decoration |
| Semantic tokens | `textDocument/semanticTokens/full` | no | no | no | large | overlay onto tree-sitter highlight pipeline |
| Folding ranges | `textDocument/foldingRange` | no | no | no | medium | folding UI exists (`FoldRegionTests`, `FoldLineMapTests`) but LSP-fed regions not wired |
| Document links | `textDocument/documentLink` | no | no | no | low value — can do `import` resolution locally | — |

**Ranking by value × effort for a read-only viewer:**

| Tier | Features | Rationale |
|---|---|---|
| **A — ship next** | `textDocument/references`, `workspace/symbol`, go-to-{declaration, typeDefinition, implementation} | Direct "read unfamiliar code" wins. Refs + workspace-symbol close the two biggest gaps. The three additional jump variants are ~50 LoC each once go-to-def has a picker. |
| **B — ship after A** | `publishDiagnostics` push handler + sidebar list, inline squiggles | Useful read-only signal ("this file has 3 errors") but UI surface is heavier than refs and product value is lower for a viewer than an editor. |
| **C — polish, behind flag** | `inlayHint`, `foldingRange`, `semanticTokens` | Decorative. Semantic-tokens is a known flicker hazard with the tree-sitter pipeline; behind `MDV_LSP_SEMTOK=1` only. |
| **Hard reject** | completion, signatureHelp, codeAction, formatting, rename, linkedEditingRange | `LSP_DESIGN.md` §8.4 viewer-mandate check. Re-rejecting on every PR. |

### 2.2 Language coverage matrix

| Language | Registered? | Server binary | How located | Tested with real server? |
|---|---|---|---|---|
| Swift | **yes** | `sourcekit-lsp` | `xcrun -f sourcekit-lsp`, fallback `/usr/bin/sourcekit-lsp` (`LSPDiscovery.swift:15-29`) | `LSPClientSmokeTests`, `LSPPoolSmokeTests` (host-skipping gates expected) |
| TypeScript | no | `typescript-language-server` (most common) | n/a | n/a |
| JavaScript | no | (same server: `typescript-language-server` reads JS too) | n/a | n/a |
| Java | no | `jdtls` (Eclipse JDT-LS) | n/a | n/a — and `LSP_DESIGN.md` §1.4 explicitly recommends rejecting until Phase ≥3 |
| Python | no | `pyright-langserver` (preferred) or `pylsp` | n/a | n/a |

Registry today (`LSPLanguageRegistry.default`, `LSPLanguage.swift:97-114`)
is **a single entry**: `.swift` → `sourcekit-lsp` via
`LSPDiscovery.locateSourceKitLSP` + `LSPDiscovery.swiftPackageRoot`.
The seam for adding more is clean — one `LSPLanguageEntry` per language,
plus a binary-locator + root-finder pair in `LSPDiscovery.swift`. No
architectural change required.

### 2.3 UI integration audit

| Surface | File | State |
|---|---|---|
| Hover popover | `Sources/ViewerUI/LSP/LSPHoverAttachment.swift` (323 LoC), bound from `TextDisplayView.swift:137` extension `lspTextView` | **Wired**, production dwell trigger (300 ms), `NSPopover.behavior = .transient`. SE-0371 isolated-deinit pattern in place. |
| Markdown rendering for hover | `Sources/ViewerUI/LSP/LSPMarkdownRenderer.swift` (155 LoC) | Wired. |
| Outline sidebar | `Sources/ViewerUI/LSP/LSPOutlineSection.swift` (188 LoC), wrapped by `LSPOutlineWrapper` in `Sources/ViewerUI/SidebarView.swift:541-583` | **Wired**, language-gated (hidden for `.md`/`.txt`). Updates on file switch. |
| Diagnostics panel (pool health) | `Sources/ViewerUI/LSP/LSPDiagnosticsView.swift` (129 LoC), opened from `SettingsView.swift:63` | Wired — but shows pool state only (lang/root/pid/req-count/last-error). **No per-file LSP diagnostic display anywhere.** |
| Cmd-click jump | `LSPHoverAttachment` installs a local NSEvent monitor | Wired but **no menu item, no right-click, no multi-result picker.** Single-result opens via `DocumentController.openTab`. |
| References panel | none | Missing. |
| Workspace symbol palette mode | none | Missing. Existing `CommandPaletteView` is filename-only. |

### 2.4 Test coverage today

All under `Tests/ViewerCoreTests/`:

- `LSPFramingTests.swift` — Content-Length framing, ~9 cases per PoC summary.
- `LSPProtocolDecodeTests.swift` — polymorphic hover / definition decoding (the load-bearing `MarkedString-before-MarkupContent` rule).
- `LSPDocumentSymbolDecodeTests.swift` — DocumentSymbol vs SymbolInformation normalization.
- `LSPPositionConverterTests.swift` — UTF-16 ↔ Swift index, including non-BMP coverage.
- `LSPLanguageRegistryTests.swift` — registry lookup and entry shape.
- `LSPDiscoveryTests.swift` — binary locator + walkUp root-finder.
- `LSPCancellationTokenTests.swift` — bind / cancel / fire-on-late-bind semantics.
- `LSPPoolTests.swift` — pool state machine, eviction, restart backoff (mock).
- `LSPClientSmokeTests.swift` — real sourcekit-lsp end-to-end (host-gated; VM in CLAUDE.md flow).
- `LSPPoolSmokeTests.swift` — same, through the pool.

**Gaps** (also called out in `docs/UI_TEST_GAPS_2026-05-22.md` §3):

- No `publishDiagnostics`-inbound-notification test (`dispatchInbound` silently drops them).
- No `$/cancelRequest`-late-response-dropped integration test (only token-level).
- No multi-language registry test (single entry today).
- No UI-level test of hover popover / outline interaction (host-test-blocked per `CLAUDE.md`; needs VM).

---

## 3. Proposed roadmap

```
NOW ──┬─ Phase A ─┬─ Phase B ─┬─ Phase C ─┬─ Phase D ─┬─ Phase E ──> later
      │   TS+JS   │   Refs+   │   Java    │  Python   │  Diags +    │
      │  registry │  Workspace│  (jdtls,  │ (pyright) │  jumps polish│
      │  entry +  │  symbols  │   heavy   │           │             │
      │  hover/   │  + g2def  │   review) │           │             │
      │  outline  │  picker + │           │           │             │
      │  ride for │  3 more   │           │           │             │
      │  free     │  jump     │           │           │             │
      │           │  variants │           │           │             │
```

### Phase A — TypeScript + JavaScript (target: ~1 day)

**Why first.** Lights up four already-wired UI surfaces (hover,
outline, Cmd-click jump, dev panel) for the single most-asked-for
language pair, with no UI changes. Pure registry work.

**Touched files (estimate):**

- `Sources/ViewerCore/LSP/LSPLanguage.swift` — add `.typescript` case
  (covers TS+JS+JSX+TSX; per `LSP_DESIGN.md` §4.1 they share the
  server), with `languageID` returning `"typescript"` /
  `"typescriptreact"` / `"javascript"` / `"javascriptreact"` based on
  extension. This forces splitting the `languageID` accessor to take
  a file URL.
- `Sources/ViewerCore/LSP/LSPDiscovery.swift` — add `locateTSServer()`
  (PATH probe + `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.npm-global/bin`, `npm root -g` parent fallback) and
  `tsWorkspaceRoot(for:)` (walk up looking for `tsconfig.json` /
  `jsconfig.json` / `package.json`).
- `Sources/ViewerCore/LSP/LSPLanguage.swift` registry — add the entry
  with `arguments: ["--stdio"]` per `LSP_DESIGN.md` §6.
- New tests: `LSPLanguageRegistryTests` rows for the new extension
  set; `LSPDiscoveryTests` for tsconfig root-walk.

**No UI changes needed.** Outline, hover, Cmd-click jump, and the
diagnostics panel all read through `LSPPool` and `LSPLanguageRegistry`
— they pick up new languages automatically.

### Phase B — references panel + workspace symbols + jump variants (target: ~3 days)

**Why second.** The biggest reading-mode features still missing.
References answers "where is this used?". Workspace symbols answers
"where is `Foo` defined anywhere in this project?". The three jump
variants (declaration / typeDefinition / implementation) are near-zero
cost once go-to-def has a picker.

**Coordinate with unified-search panel** — `workspace/symbol` is a
natural search mode (`@` / `#` prefix per `LSP_DESIGN.md` §5.4). Don't
build two panels.

**Touched files (estimate):**

- `Sources/ViewerCore/LSP/LSPClient.swift` — add `references(...)`,
  `declaration(...)`, `typeDefinition(...)`, `implementation(...)`,
  `workspaceSymbol(query:)`. Each is ~15 LoC + a decoder. Pool wrappers
  follow the existing `documentSymbol` / `hover` / `definition` pattern.
- `Sources/ViewerCore/LSP/LSPProtocol.swift` — `LSPWorkspaceSymbol`
  type (designed in `LSP_DESIGN.md` §4.1 but not yet vendored).
- `Sources/ViewerUI/LSP/ReferencesPanel.swift` (NEW) — a `SwiftUI.List`
  of `LSPLocation`s, grouped by file URI, with click-to-open via
  `DocumentController.openTab(..., scrollTo:)`. Reuse layout of an
  existing panel (e.g. `CrossSearchPanel`) to stay consistent.
- `Sources/ViewerUI/LSP/JumpToDefinitionMenu.swift` (NEW) — menu
  command + right-click context-menu items + multi-result picker
  popover. Wraps existing `definition` / new `declaration` / etc.
- `Sources/ViewerUI/CommandPaletteView.swift` — add `@` / `#` prefix
  detection that switches data source to a new
  `WorkspaceSymbolSearch` helper.
- New tests under `Tests/ViewerCoreTests/`: `LSPReferencesDecodeTests`,
  `LSPWorkspaceSymbolDecodeTests`, mock-server integration tests for
  both methods. **No new live-server tests** — keep Tier 3 limited.

### Phase C — Java (target: ~3 days, **needs design review first**)

`LSP_DESIGN.md` §1.4 currently flags `jdtls` as too heavy and recommends
rejecting through Phase 3. The user's priority list overrides that —
but the heavy parts haven't gone away:

- **Distribution.** `jdtls` is a JDK-21+ jar launched via `java -jar
  ... -configuration <dir> -data <workspace-state-dir>`. No clean
  `brew install jdtls` story; the recommended installer is
  `vscode-java`'s embedded copy or a tarball from Eclipse.
- **Cold-start.** 30–90 s on a typical Maven/Gradle project (mirrors
  sourcekit-lsp's worst-case). Inlay-hints panel will sit empty for a
  while; the existing per-method timeout table needs a Java-specific
  bump.
- **Out-of-tree workspace state.** Unlike all other servers we drive,
  jdtls writes to `-data <path>` (a directory outside the project).
  We need to pick a stable location under `~/Library/Application
  Support/com.markdownviewer.MarkdownViewer/jdtls/<workspace-hash>/`.

**Recommend:** before implementing, open a separate design-review
note (`docs/JDTLS_INTEGRATION.md`?) covering install story + the
`-data` directory placement + a manual-test plan in `MANUAL_TESTING.md`.
~0.5 day of design, then ~2.5 days of registry + spec + smoke.

### Phase D — Python (target: ~1 day)

After Java because the user said "wishlist". Pyright is the easiest
of the four new languages — single binary, no JDK, well-behaved.
Same shape of work as Phase A: one `LSPLanguageEntry`, one
`locatePyright()` discovery helper, one `pythonWorkspaceRoot(for:)`.

The only subtlety is **venv detection** (`LSP_DESIGN.md` §6) — pyright
needs `initializationOptions.python.venvPath`. Phase 1 ships without
venv discovery (server falls back to global Python); a later "venv
discovery" pass can read `.venv` / `venv` / `pyvenv.cfg`.

### Phase E — diagnostics push + UI polish (target: ~2 days)

After languages, fill in the remaining read-only signal.

- `dispatchInbound` (`LSPClient.swift:167-200`) currently drops
  server-originated requests/notifications. Add a notification handler
  that decodes `textDocument/publishDiagnostics` and forwards to a
  per-(client, uri) store on the pool.
- New `Sources/ViewerUI/LSP/DiagnosticsSidebarSection.swift` — a
  "Problems" sidebar list, like the outline section.
- Inline squiggles via NSTextStorage temporary attributes (no NSRulerView
  — keeps clear of the compositor reentrancy hazard noted in `LESSONS.md`
  and reaffirmed in `LSP_DESIGN.md` §8.3).
- Multi-result picker for go-to-def (was a partial item in Phase B; fold
  in here if Phase B shipped with single-result-only).

### Phase F+ — never

Per `LSP_DESIGN.md` §8.1 viewer mandate: completion, signature help,
code actions, formatting, rename, linked-editing, on-type formatting,
`applyEdit`. The viewer-mandate check (§8.4) re-runs on every LSP PR.

---

## 4. Per-feature effort + design notes (top 5)

### 4.1 `textDocument/references` + panel

**Why:** highest-value read-mode feature missing. Closes "who calls
this?" / "who uses this type?".

**Protocol shape.** Request mirrors hover/definition (textDocument +
position) plus `context: { includeDeclaration: Bool }`. Response is
`Location[] | null`. Already trivially decodable via the existing
`parseLocation` / `parseLocationLink` helpers in `LSPClient.swift:525-538`.

**Effort.**

- Client method: ~15 LoC.
- Pool wrapper + telemetry: ~25 LoC (same shape as
  `LSPPool.definition`, `LSPPool.swift:394`).
- UI panel: ~150 LoC SwiftUI. Reuse `CrossSearchPanel` for layout
  consistency.
- Trigger: menu "Find → Find References to Selection" (⌃⇧F? — pick
  one not conflicting with existing find-bar bindings) + right-click
  context-menu item.
- Tests: 1 decode test, 1 mock-server integration test.

**Caveats.** sourcekit-lsp returns Locations across the entire SwiftPM
target — for a moderately-sized package that's hundreds of hits per
identifier. Panel must virtualize (`LazyVStack` / `List`).

### 4.2 `workspace/symbol` + palette mode

**Why:** second-highest read-mode win. "Jump to symbol `Foo`
anywhere" — viewers fundamentally need this for navigating unfamiliar
codebases.

**Protocol shape.** `params: { query: String }`. Server returns
`SymbolInformation[] | WorkspaceSymbol[] | null`. The two response
shapes differ in whether `location` is a full Location or a
URI-only stub (`WorkspaceSymbol` is "resolve me later" — needs a
follow-up `workspaceSymbol/resolve`). Phase B can ship full-Location
only and ignore resolve; pyright + sourcekit-lsp both return full
locations today.

**Effort.**

- Client method: ~20 LoC.
- New `LSPWorkspaceSymbol` Codable type (~25 LoC) — vendor from
  `LSP_DESIGN.md` §4.1 sketch.
- `CommandPaletteView` integration: prefix detection (one regex),
  per-keystroke debounce (80 ms per `LSP_DESIGN.md` §5.4), cross-pool
  fan-out (query every live `LSPClient`).
- Coordinate with the unified-search panel work — share the prefix-
  to-mode logic.

**Caveats.** Server-side debounce: each keystroke fires a new query;
prior queries must be cancelled via `$/cancelRequest` (the
`LSPCancellationToken` plumbing in `LSPProtocol.swift:151-184` already
supports this).

### 4.3 Multi-result go-to-def picker + jump variants

**Why:** completes the navigation set. `definition` returns
multi-result frequently (protocols / interfaces / overloads); the
existing wiring just opens the first result silently.

**Effort.** Mostly UI work.

- New `JumpResultsPicker` popover (~80 LoC) — list with file-relative
  paths + line numbers, keyboard arrows, Enter to open.
- Three new client methods (declaration, typeDefinition,
  implementation) — ~15 LoC each, all using the existing
  `parseLocation` helpers.
- Menu items: "Go → Jump to Declaration / Definition / Type
  Definition / Implementation". Match Xcode bindings where possible.

### 4.4 Diagnostics push handler

**Why:** universal read-only signal. Servers push these unsolicited
on `didOpen` — we're already throwing them away.

**Effort.**

- Handler in `LSPClient.dispatchInbound`: ~30 LoC to match-and-route
  `textDocument/publishDiagnostics` notifications. Other server-
  originated traffic (logMessage, showMessage) keeps the existing
  log-and-drop behavior.
- `LSPProtocol.swift` — vendor `LSPDiagnostic` per `LSP_DESIGN.md` §4.1
  (designed but not yet implemented).
- `LSPPool` — per-(key, uri) diagnostics store; expose
  `diagnostics(fileURL:)` for the UI to read.
- UI: sidebar "Problems" section + inline squiggle attribute. The
  inline-squiggle path is where this earns its medium-effort label
  (NSTextStorage temp-attribute coordination with tree-sitter
  highlight overlay).
- Tests: handler round-trip via mock server pushing a
  `publishDiagnostics` notification.

### 4.5 Workspace-root walker generalization

**Why:** prerequisite work for every new language. Today
`LSPDiscovery.walkUp(from:match:)` (`LSPDiscovery.swift:56-70`) is
already extracted as a public helper — good. But each language needs
its own marker-set and its own "stop at .git" semantics. The Swift
walker accepts `.git` as a root (degrades gracefully); JS / Python
should **not** — they have explicit project markers that, if absent,
should fall back to single-file mode rather than `.git`-anchored mode.

**Effort.** Pure refactor + per-language closure. ~50 LoC of new
discovery helpers (`tsWorkspaceRoot`, `pythonWorkspaceRoot`,
`javaWorkspaceRoot`).

---

## 5. Per-language install / launch notes

### 5.1 TypeScript / JavaScript — `typescript-language-server`

- **What it gives you.** Wraps Microsoft's `tsserver` (the same engine
  VS Code uses for TS/JS) and exposes it as standard LSP. Hover,
  definition, references, workspace symbols, document symbols,
  diagnostics, inlay hints. Used by Neovim, Helix, Sublime LSP. The
  canonical TS LSP server.
- **Install.** `npm i -g typescript-language-server typescript` —
  the `typescript` peer is required (the wrapper exec is the LSP
  shim; `typescript` ships `tsserver` itself). Per `LSP_DESIGN.md`
  §1.4, `tsserver` crashes occasionally and the wrapper restarts it;
  our pool's restart-backoff (`LSPPool.Config.restartBackoff =
  [.milliseconds(250), .seconds(1), .seconds(5)]`,
  `LSPPool.swift:33-46`) already handles this.
- **Spawn.** `typescript-language-server --stdio`.
- **Root markers.** Walk up looking for, in order:
  `tsconfig.json`, `jsconfig.json`, `package.json`. Fallback: file's
  parent directory (single-file mode). Stop at `.git` boundary.
- **Position encoding.** UTF-16 (server doesn't advertise utf-8).
  Existing `LSPPositionConverter` handles it.
- **Cold-start.** ~1–3 s on a small repo; longer on a `node_modules`-
  heavy project (server walks the tree on init).
- **Quirks.** Won't return useful results for files outside the
  detected project (no cross-project navigation). Servers occasionally
  emit `window/showMessageRequest` — we'd be silently dropping those
  today (fine).

### 5.2 Java — `jdtls` (Eclipse JDT-LS)

- **What it gives you.** Full Java LSP — hover with javadoc, definition,
  references, workspace symbols, diagnostics (compile errors), inlay
  hints, semantic tokens. Used by `nvim-jdtls`, VS Code's `Language
  Support for Java(TM) by Red Hat`, Helix.
- **Install.** No clean Homebrew formula. Options:
  1. Tarball from Eclipse: `https://download.eclipse.org/jdtls/snapshots/`,
     extract to a stable directory, launch via `java -jar
     plugins/org.eclipse.equinox.launcher_*.jar -configuration
     config_mac -data <workspace-state-dir>`.
  2. `brew install jdtls` (community-maintained tap exists but is not
     official Eclipse).
  3. Reuse a `vscode-java` installation's embedded copy under
     `~/.vscode/extensions/redhat.java-*/server/`. Fragile.
- **Spawn.** Verbose launch command (see install option 1). Requires
  JDK 21+. The `-data` argument points to a per-workspace state
  directory — TextView would write this under
  `~/Library/Application Support/com.markdownviewer.MarkdownViewer/jdtls/<workspace-hash>/`.
- **Root markers.** `pom.xml` (Maven), `build.gradle` /
  `build.gradle.kts` (Gradle), `settings.gradle`, `.project` (Eclipse
  project descriptor). Stop at `.git`.
- **Position encoding.** UTF-16.
- **Cold-start.** 30–90 s typical, more on huge multi-module Maven
  projects. The per-method timeout table needs Java-specific overrides:
  hover 8s (default 3s), definition 10s (default 5s).
- **Quirks.** Heavy. ~500 MB–1 GB RSS once indexed. The `-data`
  directory grows large (workspace cache + index). Multi-workspace
  support exists but is uneven; one process per `(root, language)`
  remains the right partition.

### 5.3 Python — `pyright-langserver`

- **What it gives you.** Microsoft's Python static analyzer exposed as
  LSP. Hover, definition, references, workspace symbols, document
  symbols, diagnostics, inlay hints, semantic tokens. Used by VS Code
  (via Pylance, the proprietary superset), Neovim, Helix. Strict and
  fast.
- **Install.** `npm i -g pyright` (preferred — bundled binary; same
  npm install pattern as typescript-language-server, so users likely
  have one if they have the other). `pip install pyright` also works
  but produces a slower-starting wrapper.
- **Spawn.** `pyright-langserver --stdio`.
- **Root markers.** `pyproject.toml`, `pyrightconfig.json`,
  `setup.py`, `setup.cfg`, `Pipfile`. Stop at `.git`.
- **Position encoding.** UTF-16.
- **Cold-start.** ~1–2 s. Pyright is the fastest of the four new
  servers.
- **Quirks.** Strict about virtualenv detection — if it can't find a
  venv it falls back to the global Python interpreter, which means
  hover types for third-party imports come back as `Unknown`.
  Phase D ships without venv discovery; a Phase D-plus pass can read
  `.venv` / `venv` / `pyvenv.cfg` per `LSP_DESIGN.md` §6 init-options.

---

## 6. Distribution policy

The bundle size cap is **35 MB total / 15 MB exec**
(`scripts/check-bundle-size.sh`). All four candidate servers blow
this cap individually:

| Server | Single-server size | Bundle delta |
|---|---|---|
| `typescript-language-server` + `typescript` | ~50 MB (`typescript` package alone is ~30 MB) | **Over cap on its own.** |
| `jdtls` distribution | ~120 MB (tarball, with its own embedded Eclipse runtime) | **3.5× cap.** |
| `pyright` (npm package) | ~25 MB | At cap on its own. |
| `sourcekit-lsp` | already system-provided | n/a |

**Recommendation: PATH for everything.** No server gets bundled.

**Implications:**

- `LSPDiscovery` does layered PATH probing (`/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.npm-global/bin`, `~/.cargo/bin`, `~/go/bin`,
  `~/.local/bin`) — the design doc §6 already specifies this. GUI-
  launched processes don't inherit the user's shell `$PATH`, so the
  augmented list is load-bearing.
- When discovery fails: status-bar warning + a docs link.
  **No modal** (per `LSP_DESIGN.md` §8.3).
- A future `~/Library/Application Support/.../lsp.json` override file
  (designed in `LSP_DESIGN.md` §11, not implemented) lets users point
  at a custom-installed binary.

**Per-`MANUAL_TESTING.md`-style notes for the install commands:**

```text
TypeScript / JavaScript:
  npm i -g typescript-language-server typescript
  # Verify: typescript-language-server --version

Python:
  npm i -g pyright
  # Verify: pyright-langserver --help

Java:
  # Option 1 (recommended): community Homebrew tap
  brew install jdtls
  # Option 2: download the Eclipse tarball, extract, and set the
  # custom path in ~/Library/Application Support/com.markdownviewer.
  # MarkdownViewer/lsp.json (override file — see LSP_DESIGN.md §11)

Swift:
  # No install — sourcekit-lsp ships with the Swift toolchain.
  # Verify: xcrun -f sourcekit-lsp
```

---

## 7. Risks

### 7.1 Known LSP-server quirks

| Server | Risk | Mitigation |
|---|---|---|
| `typescript-language-server` | `tsserver` child crashes; wrapper restarts but the LSP layer sees response gaps | Pool's existing restart-backoff (`LSPPool.swift:236-313`) already handles this. Tests: kill the child mid-request, assert request errors with `transportClosed` and the pool transitions to `.cold`. |
| `jdtls` | 30–90 s cold-start exceeds `initialize` 30s timeout (`LSPClient.swift:353`) | Bump initialize timeout to 120 s for `.java`; per-method timeouts also need Java overrides. |
| `jdtls` | `-data` directory grows unbounded | Place under app support; document a clean-up path in `MANUAL_TESTING.md`. |
| `pyright` | Wrong types when venv not detected | Document; Phase D-plus to add venv discovery. |
| Servers proactively send `applyEdit` requests | Could wedge waiting for our reply | We deliberately don't advertise `workspace.applyEdit` (`LSPClient.swift:328-350`). Already mitigated. |
| Servers send unknown server→client requests | We silently drop today (`LSPClient.swift:197-200`) | Per `LSP_DESIGN.md` §8.3, should respond with `methodNotFound` — not done yet. Phase E follow-up. |
| `publishDiagnostics` push not handled | Notifications dropped | Phase E — add the handler. |

### 7.2 Security — running arbitrary binaries

PATH-discovery means we execute whatever the user has installed at
`typescript-language-server` etc. That's the standard model for every
LSP-using editor (VS Code, Neovim, Helix all do the same), but it's
worth surfacing:

- We resolve the binary path **before** spawning and log it. The
  diagnostics panel (`LSPDiagnosticsView`) already shows
  `lastError` and could be extended to show the resolved binary path
  for each live server.
- The future `lsp.json` override (`LSP_DESIGN.md` §11) lets advanced
  users pin a specific binary — a positive for security-conscious
  users, but the default remains PATH-discovered.
- No additional sandbox containment around the child. macOS app
  sandboxing rules apply (child inherits our entitlements); since
  TextView is not currently sandboxed (per `CLAUDE.md`'s
  TCC-stable bundle-id note), the child runs with the user's full
  privileges. **Worth documenting**: a user running TextView from
  a managed Mac with a hijacked PATH could spawn a hostile binary
  under the guise of `typescript-language-server`. Mitigation: when
  shipping public (currently local-signing only per `CLAUDE.md`),
  consider an allowlist or a "trust this binary?" prompt on first
  discovery of a non-system path.

### 7.3 macOS sandboxing / Gatekeeper / `--deep` codesign

Per `docs/PARALLEL_WORK_STATUS.md` (the "Unexpected gotcha — codesign +
SwiftPM resource bundles" section): per-dylib `codesign --options
runtime` walked into SPM-resource-bundle signing issues; the project
reverted to a single `codesign --deep` pass — which is
deprecation-flagged for public Developer-ID distribution but is the
practical option for local-signing today.

**Implication for LSP work:** none directly — LSP children are
PATH-discovered external binaries, not bundled, so codesign / Gatekeeper
of our own bundle doesn't touch them. But:

- If/when a future "bundle a fallback server" idea resurfaces, it
  would re-open the codesign question — every embedded binary in
  `Contents/Resources/lsp/` needs its own signature, and `--deep`
  may or may not catch them depending on layout.
- Spawning a child process from a sandboxed app would need a
  Spawning-services entitlement — irrelevant today (not sandboxed),
  but a future blocker if sandbox adoption is considered.

### 7.4 TCC + child-process file access

The child LSP server inherits TextView's TCC permissions (and
therefore can read whatever TextView can — `Documents`, granted-
folder bookmarks, etc.). For a user with broad-folder access granted,
that means the LSP server can read freely within those folders, which
is exactly what we want for cross-file navigation.

For a user with narrow access: the LSP server may try to read files
outside the granted scope and fail silently (returning no
definition / references / symbols). The pool's `recordRequest` /
`recordCrash` telemetry will show that requests are returning fast
with no data — useful for diagnosing.

---

## 8. Recommendation

**Build next, in order:**

1. **Phase A: TS+JS** — registry entry + discovery helpers. ~1 day.
   - `Sources/ViewerCore/LSP/LSPLanguage.swift` — new case + registry
     entry.
   - `Sources/ViewerCore/LSP/LSPDiscovery.swift` — `locateTSServer()`,
     `tsWorkspaceRoot(for:)`.
   - Tests under `Tests/ViewerCoreTests/`: extend
     `LSPLanguageRegistryTests`, `LSPDiscoveryTests`.
   - No UI changes — outline / hover / Cmd-click / diag panel all
     pick up the new language via the pool automatically.
   - Update `MANUAL_TESTING.md` with the `npm i -g
     typescript-language-server typescript` setup step.

2. **Phase B: refs panel + workspace symbols + jump variants** —
   biggest reading-mode wins. ~3 days.
   - `Sources/ViewerCore/LSP/LSPClient.swift` — add `references`,
     `declaration`, `typeDefinition`, `implementation`,
     `workspaceSymbol` methods. Mirror the existing `definition`
     wrapper pattern. `LSPPool` wrappers follow `LSPPool.swift:362-409`.
   - `Sources/ViewerCore/LSP/LSPProtocol.swift` — vendor
     `LSPWorkspaceSymbol` per `LSP_DESIGN.md` §4.1.
   - `Sources/ViewerUI/LSP/ReferencesPanel.swift` (NEW).
   - `Sources/ViewerUI/LSP/JumpToDefinitionMenu.swift` (NEW) — multi-
     result picker + menu wiring.
   - `Sources/ViewerUI/CommandPaletteView.swift` — `@` / `#` prefix
     mode. **Coordinate with the unified-search panel currently in
     flight** — share the prefix-to-mode dispatch.
   - Tests: mock-server integration tests per new method.

3. **Phase C: Java (jdtls)** — heavy. Open a design-review note first.
   - Before any code: draft `docs/JDTLS_INTEGRATION.md` covering the
     `-data` directory placement, JDK-21 discovery, install story,
     and updated per-method timeouts.
   - Then registry + discovery + smoke. ~3 days post-design.

4. **Phase D: Python (pyright)** — ~1 day. Same shape as Phase A.

5. **Phase E: diagnostics push + UI polish** — ~2 days. Wire the
   `publishDiagnostics` notification handler (`LSPClient.swift`
   `dispatchInbound`), add a "Problems" sidebar section, inline
   squiggles via NSTextStorage temp attrs.

**Concrete seams for each phase:**

- New language: `LSPLanguage.swift:97-114` registry array — append one
  `.init(language:, fileExtensions:, rootFinder:, serverLauncher:)`.
- New discovery helper: `LSPDiscovery.swift:8` enum — add `locate<X>()`
  + `<x>WorkspaceRoot(for:)` static methods.
- New LSP method: `LSPClient.swift:401-446` — add async wrapper
  following the existing `hover` / `definition` / `documentSymbol`
  pattern; matching pool wrapper at `LSPPool.swift:362-409`.
- New inbound notification handler: `LSPClient.swift:167-200`
  (`dispatchInbound`) — branch on `obj["method"]` for known
  notifications (`textDocument/publishDiagnostics`,
  `window/showMessageRequest`).
- New language ID per file extension (TypeScript needs this): change
  `LSPLanguage.languageID` accessor to take a `URL` parameter, threading
  through the callers in `LSPPool.ensureOpened`
  (`LSPPool.swift:189-211`).
- New UI panel: under `Sources/ViewerUI/LSP/`, sibling to the
  existing four files.

**Don't build (re-confirm reject list per `LSP_DESIGN.md` §8.1):**
completion, signature help, code actions, formatting, rename, linked-
editing range, on-type formatting, `workspace.applyEdit` handling.
Run the §8.4 viewer-mandate check on every PR that touches
`Sources/.../LSP/`.

---

## 9. Open questions for the orchestrator

1. **Unified-search panel coordination.** Workspace-symbol mode is a
   natural addition there. Is the unified-search panel API stable
   enough to add a new mode against, or should we sequence Phase B
   behind that work? (Current assumption: build alongside; minor
   merge cost.)
2. **Java in scope of v1?** `LSP_DESIGN.md` §1.4 currently lists jdtls
   as deferred. User priority list says required. Picking the answer
   determines whether Phase C runs at all or whether we ship A+B+D+E
   first and revisit Java separately.
3. **lsp.json override.** Designed in `LSP_DESIGN.md` §11, not
   implemented. Worth ~0.5 day if any of the four new servers ships
   with a non-default install path (jdtls especially). Recommend
   landing the override file before Phase C.
4. **Per-method timeout overrides per language.** Today they're hard-
   coded in `LSPClient.swift` (`.seconds(3)` for hover, `.seconds(5)`
   for definition, etc.). Java needs longer; surface the dial through
   the `lsp.json` config sketch or via a `LSPLanguageEntry.timeouts`
   field?

---

*End of roadmap. ~570 lines.*
