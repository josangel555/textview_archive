# LSP Subsystem — Audit & Productionalization Plan (2026-06-18)

Epic: **TSK-963** — Productionalize the LSP subsystem (discovery, visibility,
integration, organization).

This document is the authoritative audit + plan. The owner's complaint is that
the LSP subsystem is **very disorganized**: discovery is opaque (you can't tell
which servers exist / are installed / are configured, or how they are found and
launched), visibility is thin (no server-status indicator, diagnostics split
across two surfaces, no progress), integration is scattered (completion / hover /
definition / references / rename live as ~20 ad-hoc methods on `DocumentModel`),
and the code itself has no clean facade. It also carries **five confirmed
security/memory findings** from `docs/research/adversarial-review-2026-06-18/`
that must be folded into the productionalization, not patched separately.

---

## 1. Current state

### 1.1 Module map

**Core — `Sources/ViewerCore/LSP/`** (engine; host-testable, no UI):

| File | Responsibility |
|------|----------------|
| `LSPLanguage.swift` | `LSPLanguage` enum (swift/typescript/java/python), `LSPLanguageRegistry` (ext→language + per-language launcher closures), `overrideConfig` (lsp.json → `LSPClient.Config`), the **interim trust gate** (`isOverrideCommandTrusted`, `isPath(_:inSubtreeOf:)`), `scrubbedLaunchEnvironment`, and `languageStatuses` (Settings availability list). **21 KB, the most overloaded file.** |
| `LSPDiscovery.swift` | Binary resolution: `locateSourceKitLSP` (xcrun), `locate(binary:)` (bundle → augmented PATH → which), `isBinarySafeToSpawn` (writable-dir refusal), per-language workspace-root finders, jdtls data dir, process-lifetime cache. |
| `LSPWorkspaceOverrides.swift` | `lsp.json` loader/parser, language-key resolution, `mergedEnvironment`, `LSPLog` (warn sink + test mirror). |
| `LSPClient.swift` | One actor → one server subprocess; JSON-RPC framing over stdio; request/response; hover/definition/declaration/typeDefinition/implementation/references/formatting/rename/completion; position-encoding negotiation; crash callback; shutdown/reap. **59 KB.** |
| `LSPPool.swift` | `actor` keyed by `(language, workspaceRoot)`; lazy spawn, idle reaper, restart-with-backoff, dead-cooldown; `LSPServerStatus` + `StatusSnapshot`; per-file version/hash tracking; `setOnDiagnostics`. **38 KB.** |
| `LSPProtocol.swift` | Wire types: `LSPDiagnostic`, `LSPLocation`, `LSPHover`, `LSPCodeAction`, position/range. |
| `LSPFraming.swift` | Content-Length framing codec. |
| `LSPPositionConverter.swift` | UTF-16 ↔ negotiated-encoding offset translation. |
| `LSPTextEditApplier.swift` | Apply `TextEdit[]` / `WorkspaceEdit` to a buffer (formatting/rename). |
| `LSPDiagnosticsStore.swift` | `@MainActor ObservableObject`, diagnostics keyed by URL (replace-by-URL). |
| `LSPNavigationStore.swift` | References/locations result store for the navigation panel. |
| `CMDiagnosticMapping.swift`, `CMFoldRangeMapping.swift` | CM6 bridge mappings. |

**UI — `Sources/ViewerUI/LSP/`**:

| File | Responsibility |
|------|----------------|
| `LSPProblemsPanel.swift` | Sidebar "Problems" section (flat diagnostics, severity filter, jump). |
| `LSPDiagnosticsView.swift` | Settings → "LSP Diagnostics" sub-page; reads `LSPPool.StatusSnapshot`. |
| `LSPNavigationPanel.swift` | References/go-to results panel. |
| `LSPOutlineSection.swift` | documentSymbol outline. |
| `LSPHoverAttachment.swift` | NSPopover hover for the **Source** (AppKit) view. **PoC — no live callers; carries the leak.** |
| `LSPMarkdownRenderer.swift` | Renders LSP hover markdown. |

**Scattered integration (the disorganization the owner feels):**

- `DocumentModel.swift` — ~20 LSP entry points: `bootstrapLSP`, `navigateViaLSP(kind:…)`, `navigateViaLSPAtCursor`, `findReferencesAtCursor`, `formatActiveEditorViaLSP`, `renameActiveEditorSymbolViaLSP`, `showLSPRenamePrompt`, CM6 hover/Cmd-click bridges, code-actions state machine, `setEditorDiagnostics`, plus guard predicates. Each re-derives `lspPool.registry.language(for:)`, line/char 1→0 conversion, and async-Task error swallowing **independently**.
- `main.swift` — every menu item + `@objc` shim (`lspGotoDefinition`…`lspCodeActions`, `lspFindReferences`, `lspFormatDocument`, `lspRenameSymbol`), the `validateMenuItem` gate, and the app-quit `closeAll()` budget.
- `SettingsView.swift` — `lspSection` calls `LSPLanguageRegistry.languageStatuses()` from a `.task` (shells out to `xcrun`/`which`).
- `CodeMirrorEditorView.swift` / `EditorCoordinator.swift` / `TextDisplayView.swift` — per-surface wiring.

### 1.2 What works

- The pool lifecycle (lazy spawn, idle reap, restart backoff, dead-cooldown) is solid and tested.
- `LSPClient` framing, position-encoding negotiation, and shutdown/reap are hardened (TSK-139/140/148/485/521 all validated).
- Discovery's writable-dir refusal (`isBinarySafeToSpawn`) and the env scrub (`scrubbedLaunchEnvironment`) show a real threat model.
- The trust gate for the lsp.json **command path** correctly refuses in-workspace / writable-dir binaries.

---

## 2. Problems

### 2.1 Discovery / configuration (opaque)

- The ONLY discovery surface is `Settings → Language servers (LSP)`, which lists the 4 languages + a resolved-path/available flag. It does **not** show: which workspace `lsp.json` override (if any) is in effect, whether an override was **refused** (untrusted) and why, the install hint inline, or the search path that was probed.
- `languageStatuses()` shells out (`xcrun -f` / `which`) synchronously from a SwiftUI `.task` every time Settings opens — no caching beyond the process-lifetime binary cache, and no model the rest of the app can read.
- No single "LSP configuration" model: discovery state, override state, and per-key live state are three disconnected reads (`languageStatuses`, `LSPWorkspaceOverrides.load`, `LSPPool.snapshot`).

### 2.2 Visibility (thin)

- **No status indicator** anywhere in the main UI — the user cannot tell if a server is starting, live, idle, crashed, or dead without opening Settings → LSP Diagnostics. The `LSPServerStatus`/`StatusSnapshot` data exists in the pool but is surfaced only on that one dev page.
- **Diagnostics surfacing is split**: the sidebar `LSPProblemsPanel` (real diagnostics) and the Settings `LSPDiagnosticsView` (server health) are two unrelated views; there is no unified "Problems" model that exposes both counts and per-server health.
- **No progress**: `$/progress` / `window/workDoneProgress` (jdtls cold-start is 30–90 s) is not surfaced at all — the user sees nothing while the server indexes.

### 2.3 Integration (scattered)

- Completion is implemented in `LSPClient` but the editor invocation is incomplete (TSK-463, still `fixed` not validated).
- The 1-based→0-based conversion, `registry.language(for:)` gate, and "swallow errors silently" pattern are copy-pasted across every `DocumentModel` method instead of living behind one façade.
- There is no single object a caller asks "give me hover/definition/references/format/rename for (url, position)"; callers reach into `lspPool` directly and each re-implements the request/decode/apply dance.

### 2.4 Organization (no facade)

- `LSPLanguage.swift` conflates: the language enum, the registry, the override-to-config translation, the security trust gate, and the Settings status list. Five concerns in one 21 KB file.
- No `LSPClient`-facade boundary: UI talks to the `actor LSPPool` for everything, so the position-conversion + decode + edit-apply logic is duplicated in `DocumentModel`.

### 2.5 Confirmed security / memory findings (fold into slices)

From `docs/research/adversarial-review-2026-06-18/`:

1. **[SEC, medium] lsp.json override injects untrusted `args` + `env` into the TRUSTED discovered server.** `LSPLanguage.swift:387-392` — on the untrusted-command fallback the code still spawns the discovered trusted binary with `arguments: defaultArguments + entry.arguments` and the override's merged `env`. Many servers honor `--require`/`--plugin`/config-path flags and `NODE_OPTIONS` env → repo-controlled code load on a trusted binary. Fix: on the untrusted-command fallback, use ONLY `defaultArguments` + `scrubbedLaunchEnvironment()`; honor repo `args`/`env` only when the **command itself** passed the trust gate.
2. **[SEC, low] `isBinarySafeToSpawn` applied inconsistently.** `LSPDiscovery.swift` — the check runs on augmented-prefix candidates (`:84`) and the `which` result (`:96`) but NOT on either `locateSourceKitLSP` path (the `xcrun -f` result `:22-28` or the `/usr/bin/sourcekit-lsp` fallback `:30-33`); it also inspects only the immediate parent dir, not ancestors. Fix: apply the check to every resolved server path (incl. xcrun) and walk ancestor dirs.
3. **[MEM, high-in-code/PoC] `LSPHoverAttachment` NSPopover + observer leak.** `LSPHoverAttachment.swift:192-209` registers two `NotificationCenter` block observers that capture `HoverState` **strongly**; removal is deferred into an unstructured `Task { @MainActor }` in `LSPHoverToken.deinit` (`:56-71`) that may never run. Related: `ChainedMonitor.deinit` (`:421-430`) calls `NSEvent.removeMonitor` off the main actor. Currently no live callers (opt-in PoC) — but the code is the leak. Fix: weak `state` capture + a synchronous `@MainActor invalidate()`.
4. **[SEC, low] ffmpeg locator** (`FFmpegLocator.swift`) skips the same writable-dir check — adjacent, out of LSP scope; tracked but NOT in these slices.
5. The HTMLSanitizer / export-XSS findings are unrelated to LSP — separate epic.

---

## 3. Proposed clean structure

Target: a thin **facade** + a single **configuration/status model**, leaving the
pool/client engine intact (it works). No blind cross-cutting rewrite — the facade
is additive; callers migrate behind it incrementally.

```
ViewerCore/LSP/
  Discovery/
    LSPDiscovery.swift            (binary + root finding; safety check applied uniformly)
    LSPWorkspaceOverrides.swift   (lsp.json loader)
  Config/
    LSPLanguage.swift             (enum ONLY — id, displayName, installHint, binaryName)
    LSPLanguageRegistry.swift     (ext→language + launchers; split out of LSPLanguage.swift)
    LSPOverrideResolver.swift     (overrideConfig + trust gate; split out — the security surface)
    LSPConfiguration.swift        (NEW: one snapshot of discovery+override+status per language)
  Engine/
    LSPClient.swift  LSPPool.swift  LSPProtocol.swift  LSPFraming.swift
    LSPPositionConverter.swift  LSPTextEditApplier.swift
  Stores/
    LSPDiagnosticsStore.swift  LSPNavigationStore.swift
  Facade/
    LSPService.swift              (NEW: the one object DocumentModel talks to —
                                   hover/definition/references/format/rename/completion
                                   given (url, position); owns 1→0 conversion + decode + apply)
```

UI consolidates the two diagnostics surfaces against one model and gains a
status indicator driven by `LSPConfiguration` + `LSPPool` snapshots.

**Migration discipline:** the file moves + `LSPService` facade are the documented
END STATE. The parallel slices below DO NOT move files (avoids collisions); each
adds host-testable model/logic in its own file(s). The facade extraction + file
re-org is a single-owner follow-up after the slices land, tracked under this epic.

---

## 4. Parallel slices (minimally file-overlapping)

These five are independent, host-testable, and touch disjoint files so worktree
agents don't collide. (a) and (c) both touch `LSPLanguage.swift`/`LSPDiscovery.swift`
— (c) lands first (security) or they coordinate; (a) otherwise adds a NEW file.

- **(a) Discovery + config + status MODEL** — NEW `LSPConfiguration.swift`: a
  pure, injectable snapshot (per language: installed? resolvedPath, search paths
  probed, active override + whether it was honored/refused+reason, live pool
  status). Host-test with injected resolvers/overrides; no UI.
- **(b) Diagnostics / Problems VISIBILITY model** — a unified problems/server-health
  view-model bridging `LSPDiagnosticsStore` + `LSPPool` snapshots; host-test
  counts, grouping, per-server health rollup, and the "not analyzed vs clean"
  distinction. New file under `Stores/` or UI.
- **(c) SECURITY fixes** — gate lsp.json `args`+`env` to the binary trust gate;
  apply `isBinarySafeToSpawn` consistently (incl. xcrun) + ancestor walk. Edits
  `LSPLanguage.swift` + `LSPDiscovery.swift`; host-test the fallback config.
- **(d) Hover leak fix + LSPService facade seam** — fix `LSPHoverAttachment`
  (weak capture + synchronous `invalidate()`, main-actor monitor teardown); add
  the `LSPService` facade skeleton with the (url,position)→request methods + the
  centralized 1→0 conversion. Host-test the conversion + facade dispatch.
- **(e) Integration consolidation** — route the scattered `DocumentModel` LSP
  methods through `LSPService` (or wire completion, TSK-463). Host-test the
  dispatch/guard logic. Touches `DocumentModel.swift` only.

See the board (TSK-963 children) for the per-slice notes.
