# MASTER AUDIT REPORT — TextView / MarkdownViewer (consolidated, 2026-05-30)

## Executive summary

19 review dimensions produced **~210 raw findings**; after cross-dimension dedup, **172 distinct findings** remain. The codebase is in strong shape: the 2026-05-25 review's S1/S2 set is genuinely fixed, layering (ViewerKit←ViewerCore←ViewerUI) holds, there is zero network egress/telemetry, and the persistence/atomic-write/cache-eviction work is solid.

**Launch-blockers cluster in three subsystems:**
1. **LSP lifecycle** — pool reaper never started, `closeAll` never wired to quit, no client `deinit`, no SIGKILL backstop, no `Content-Length` cap → subprocess + fd + memory leaks and a remote-ish DoS. Found independently by 6 dimensions.
2. **Workspace-trust RCE (SEC-001, S0)** — in-repo `lsp.json` runs an arbitrary command on first hover, bypassing every spawn guard, with full unscrubbed env (SEC-002) → one-hover RCE + credential harvest on opening an untrusted repo.
3. **Silent data loss in the editor** — re-opening an already-open dirty tab drops the dirty flag (CORR-1), clean-tab external reload never refreshes the editor buffer (UDC-2), drift-recovery is a no-op (EDIT drift), atomic save strips file metadata.

The big architectural questions (reusable-core / multi-UI, the protocol event stream, the headless-core extraction) are **surface-only** — one-way doors that must not be started pre-launch.

## S0 / S1 list (launch-relevant) with file:line

| ID | Sev | Title | Location |
|----|-----|-------|----------|
| SEC-001 | S0 | Untrusted in-repo `lsp.json` → arbitrary command on hover (workspace-trust RCE) | `Sources/ViewerCore/LSP/LSPLanguage.swift:283-308` |
| CORR-1 | S1 | Re-open already-open dirty tab drops `isDirty` → close skips save prompt → data loss | `Sources/ViewerCore/TabsState.swift:127-145` |
| UDC-2 | S1 | Clean editor tab shows stale content after external change; reload never refreshes `editorBuffers` → save overwrites newer disk | `Sources/ViewerUI/DocumentModel.swift:1801-1807` |
| EDIT-drift | S1 | `flushChanges` drift-recovery is a no-op (JS `emitChange` short-circuits) → Swift buffer silently diverges, can save corrupt | `Sources/ViewerUI/Resources/codemirror/codemirror.html:105-130,830` |
| EDIT-attrs | S1 | Atomic save drops POSIX perms/owner/ACLs/xattrs (quarantine, Finder tags) | `Sources/ViewerCore/EditorBuffer.swift:191` |
| EDIT-nil-fp | S1 | Nil-fingerprint external-edit check silently reloads over dirty edits | `Sources/ViewerCore/EditorBuffer.swift:94-98` |
| SEC-002 | S1 | LSP child inherits full unscrubbed parent env (token/secret exfil) | `Sources/ViewerCore/LSP/LSPClient.swift:138-140` |
| SEC-003 | S1 | RegexComplexityGuard not applied to source-view find bar (ReDoS on MainActor) | `Sources/ViewerUI/TextDisplayView.swift:1051-1084` |
| LSP-lifecycle | S1 | Pool reaper `start()` never called + `closeAll()` never wired to quit → LSP servers leak whole session/quit | `LSPPool.swift:139-164`, `main.swift:60,362` |
| RC-1 | S1 | `LSPClient` has no `deinit` → dropped client orphans subprocess + 6 fds + reader thread | `Sources/ViewerCore/LSP/LSPClient.swift:128-173,198-246` |
| CR-02 | S1 | `LSPClient.shutdown()` no SIGKILL backstop / no `waitUntilExit` → wedged server leaks | `Sources/ViewerCore/LSP/LSPClient.swift:721-736` |
| PARSE-01/MAGIC-001 | S1 | `LSPFraming.decode` no Content-Length/header cap → OOM + O(n²) CPU from lying server | `Sources/ViewerCore/LSP/LSPFraming.swift:37-81` |
| SQL-01/PARSE-02 | S1 | Arbitrary user SQL runs synchronously on @MainActor, no progress-handler/interrupt → UI freeze DoS | `SQLiteBrowserView.swift:198-207`, `SQLiteReader.swift:143-178` |
| RWC-1 | S1 | `highlightCache` length-keyed → stale syntax spans on same-byte-count reload | `Sources/ViewerUI/Highlight/HighlightCacheActor.swift:136-146` |
| PERSIST-01 | S1 | Session restore applies `selectedTabIndex` against compacted tab list → wrong/no tab focused | `Sources/ViewerUI/Sessions/SessionState.swift:140-161` |
| PERSIST-04 | S1 | Downgrade after fresh install overwrites newer-schema session index (corruption) | `Sources/ViewerUI/.../SessionsCoordinator.swift:79-152` |
| SCALE-1/MAGIC-002 | S1 | 32 MB `TextFileLoader` cap makes the documented 50 MB editor / "GB via Source" story unreachable | `Sources/ViewerCore/TextFileLoader.swift:67-79` |
| SCALE-2 | S1 | git stdout drained with no byte cap → monorepo `status -uall`/`diff` buffers unbounded into RAM | `Sources/ViewerCore/ProcessRunner.swift:225-233` |
| SCALE-3 | S1 | git-status maps every entry with a `resolvingSymlinksInPath()` realpath syscall → 10k syscalls/refresh | `Sources/ViewerUI/SidebarModel.swift:286-303` |
| FW-1 | S1 | DocumentModel `FileWatcher` has no `onLost` → deleted open file becomes silent dead watcher | `Sources/ViewerUI/DocumentModel.swift:1820` |
| FW-2 | S1 | FolderWatcher lacks `WatchRoot` flag → rename/move of watched root silently kills updates | `Sources/ViewerCore/FolderWatcher.swift:122` |
| REPUB-1 | S1 | `SessionState.wireForwarding()` re-introduces banned full-DocumentModel `objectWillChange` forward | `Sources/ViewerUI/Sessions/SessionState.swift:72-76` |
| OBS-1 | S1 | SIGUSR1 diagnostic trap unconditional in release → any same-UID process dumps file content + PNG to world-readable tmp | `Sources/MarkdownViewer/Diagnostics.swift:23-62` |
| DEP-001 | S1 | No aggregated THIRD_PARTY_NOTICES → binary distribution violates BSD/MIT/Apache attribution | `dist/TextView.app/Contents/Resources` |
| SIGN-01 | S1 | notarize script signs/ships the wrong stale bundle (`MarkdownViewer.app` vs built `TextView.app`) | `scripts/sign-and-notarize.sh:42,87,105-145` |
| SIGN-02 | S1 | All inner grammar dylibs stamped with app's bundle id (duplicate code-signing identifiers) | `scripts/build-app.sh:180-185` |
| SIGN-03 | S1 | `LSMinimumSystemVersion=14.0` but compiled for macOS 15 → installable-but-crashing on 14 | `scripts/Info.plist:27-28` |
| TC-01 | S1 | CI runs macos-14 but package targets macOS 15+ → CI validates an env the app never ships to | `.github/workflows/pr.yml:11` |
| PROTO-1..4 | S1 | Protocol boundary: no server→client event stream; `--mcp-stdio` not headless; MainActor serialization choke; no per-request budget/cancel | `MCPServer.swift`, `main.swift:1517-1580` (SURFACE-ONLY) |
| RC-01..04 | S1 | Reusable-core: product-identity one-way door unanswered; cost mis-anchored; multi-client state inversion under-scoped; pre-launch attention conflict | `docs/reusable-core/*` (SURFACE-ONLY) |

## Per-dimension rollup (post-dedup count, notable items)

| Dimension | Findings | Highest | Notable (deduped away if merged) |
|-----------|----------|---------|----------------------------------|
| Correctness | 10 | S1 | CORR-1 data loss; CORR-2 = RC-4/UDC-6/TD-05 (merged) |
| Editor stability | 8 | S1 | drift no-op, atomic-attrs, nil-fingerprint |
| Persistence | 10 | S1 | PERSIST-01 restore index; PERSIST-04 downgrade corrupt |
| Cache coherency | 6 | S1 | RWC-1 = MAGIC-002-adjacent; RWC-2 = TD-09 (merged) |
| Concurrency | 11 | S1 | CONC-001 = LSP-lifecycle; CONC-002 setOnCrash; CONC-007 RMW-across-await |
| Crash/recovery | 7 | S1 | CR-01/02 = LSP-lifecycle; CR-04 stale-content; CR-05 process hang |
| Parser fuzz | 8 | S1 | PARSE-01 = MAGIC-001; PARSE-02 = SQL-01 (merged) |
| Security | 8 | S0 | SEC-001 RCE; SEC-002 env; SEC-003 = TextDisplayView ReDoS |
| WKWebView/CSP | 7 | S2 | WV-1/2 sanitizer bypass; WV-3 meta-CSP (one-way) |
| SQLite DoS | 7 | S1 | SQL-01 main-actor freeze; SQL-02 ATTACH scope |
| File-watcher | 13 | S1 | FW-1 onLost; FW-2 WatchRoot; FW-8 = EDIT-nil-fp |
| Performance | 12 | S2 | PERF-01 didChange; PERF-02 converter; PERF-07/SCALE-8 shutdown |
| Republish | 6 | S1 | REPUB-1 banned forward; REPUB-2/3/4 un-split hot fields |
| Scaling | 11 | S1 | SCALE-1/2/3; SCALE-4 mmap (one-way) |
| Resource cleanup | 8 | S1 | RC-1/2 LSP; RC-4 = editorMenuTargets (merged) |
| Undo/clipboard/DnD | 10 | S1 | UDC-2 stale buffer; UDC-1 test drift; UDC-5 folder drop |
| i18n/encoding | 10 | S2 | I18N-01 CP1252; I18N-03 Trojan-Source bidi; I18N-04 = CrossFileSearch CR |
| Accessibility | 16 | S2 | A11Y-01/02 tables; A11Y-04 Dynamic Type |
| UI responsiveness | 14 | S2 | UIRESP-01/02/09 hover/cursor; one shared row style fixes the bulk |
| UX/first-run | 14 | S2 | UX-01 onboarding; UX-02 branding; UX-03 permission UX |
| Dependency/license | 7 | S1 | DEP-001 notices; DEP-004 floating branch |
| Observability/privacy | 6 | S1 | OBS-1 SIGUSR1; OBS-2/3 file perms |
| Signing/distribution | 14 | S1 | SIGN-01..03; SIGN-11 spctl rejected (expected) |
| Build/repo hygiene | 10 | S2 | BR-01 89GB worktrees; BR-02 .claude gitignore; BR-03 dual-app LS collision |
| Tech debt | 12 | S2 | TD-01 forwarder facade; TD-03 = ProcessRunner cap |
| Magic numbers | 6 | S1 | MAGIC-001 = PARSE-01; MAGIC-003 bundle-cap drift |
| API/SemVer | 10 | S1 | API-01 NSColor theme (one-way); API-03/04 test hooks public |
| Protocol boundary | 5 | S1 | PROTO-1..5 (all surface-only) |
| Reusable-core | 8 | S1 | RC-01..08 (all surface-only) |

## Cross-cutting prioritized auto-fix groups (file-disjoint, parallel-safe)

| Group | Subsystem | Key files | Sev span | # |
|-------|-----------|-----------|----------|---|
| G1 | DocumentModel hub (UI orchestration) | `DocumentModel.swift`, `ContentView.swift`, `TabCoordinator.swift`, `HighlightCacheActor.swift` | S1–S3 | 17 |
| G2 | Security — LSP trust + ReDoS guards | `LSPLanguage.swift`, `LSPWorkspaceOverrides.swift`, `TextDisplayView.swift`, `HighlightedText.swift`, `GitClient.swift` | S0–S3 | 6 |
| G3 | LSP pool/client lifecycle + framing | `LSPPool.swift`, `LSPClient.swift`, `LSPFraming.swift`, `LSPProtocol.swift`, `LSPPositionConverter.swift`, `LSPOutlineSection.swift`, `CMDiagnosticMapping.swift`, `CMFoldRangeMapping.swift` | S1–S3 | 11 |
| G4 | Editor save/reliability | `EditorBuffer.swift`, `Coordinators/EditorCoordinator.swift`, `CMEditApplier.swift`, `Resources/codemirror/codemirror.html`, `CodeMirrorEditorView.swift`, `CodeMirrorBridgeV1.swift` | S1–S3 | 9 |
| G5 | Core parsers/loaders | `TextFileLoader.swift`, `CSVParser.swift`, `HexDumpBuilder.swift`, `FindEngine.swift`, `HTMLRenderer.swift`, `HTMLSanitizer.swift`, `CrossFileSearch.swift`, `DiffParser.swift` | S1–S3 | 11 |
| G6 | Persistence/sessions | `Sessions/SessionState.swift`, `Sessions/SessionStore.swift`, `Sessions/SessionsCoordinator.swift`, `HistoryStore.swift`, `Plugins/PluginGrantStore.swift`, `JSONFileStore.swift` (+tests) | S1–S2 | 7 |
| G7 | Watchers + process + SQLite | `FileWatcher.swift`, `FolderWatcher.swift`, `ProcessRunner.swift`, `SQLiteReader.swift`, `SQLiteBrowserView.swift` | S1–S3 | 12 |
| G8 | Sidebar (tree/git/caches) | `SidebarModel.swift`, `SidebarView.swift`, `FileTreeRecency.swift` | S1–S3 | 8 |
| G9 | WebView/render policy | `MarkdownRenderedView.swift`, `TreeSitterEngine+Folds.swift` | S2–S3 | 6 |
| G10 | App entry / argv / diagnostics / observability | `main.swift`, `Diagnostics.swift`, `DiagnosticDump.swift`, `Plugins/PluginSubprocessHost.swift` | S1–S3 | 9 |
| G11 | Hex / binary viewer | `HexView.swift`, `BinaryFileLoader.swift` | S2–S3 | 3 |
| G12 | A11y / UI-liveliness additive modifiers | a11y/hover views (CSV/SQLite/LSP panels, FindBar, palette, TabBar, etc.) — additive only | S2–S3 | ~26 |
| G13 | Drop/clipboard/tab-drag | `DropRouter.swift`, `TabBar.swift` (+DragDropTests) | S2–S3 | 4 |
| G14 | Distribution scripts | `sign-and-notarize.sh`, `build-app.sh`, `verify-app.sh`, `check-bundle-size.sh`, `Info.plist`, `.gitignore`, dist cleanup | S1–S3 | 12 |
| G15 | Build hygiene / deps / Package | `Package.swift`, CTSPatch scanners, `MarkdownRenderedView` alias (note conflict ↓), CI `pr.yml`, license files | S1–S3 | 9 |

> **Note on a deliberate overlap**: a handful of low-risk cleanups (`MarkdownStylesheet.load()` alias in `MarkdownRenderedView.swift`, the ruler/selector dead code in `ContentView.swift`/`LineNumberRulerView.swift`) are claimed by both a tech-debt finding and a hub group. To preserve disjointness they are assigned to whichever group already owns that file (G9 owns `MarkdownRenderedView.swift`; G1 owns `ContentView.swift`); `LineNumberRulerView.swift` is doc-comment-only and parked in G1.

## Surface-only / decisions (NOT auto-fixed)

These require a product/architecture decision, are one-way doors, or are not host-verifiable AND risky. See `surface_only` array for the full list with rationale. Headlines:

- **SEC-001 (S0 RCE)** — fix requires a *workspace-trust UX decision* (prompt model + persistence). The safe interim (ignore `command` for untrusted roots / allowlist + `isBinarySafeToSpawn`) is auto-fixable and IS placed in G2; the trust-UI is surface-only.
- **Reusable-core epic (RC-01..08) + Protocol boundary (PROTO-1..5)** — product-identity one-way door; do NOT start pre-launch. Adopt only the no-regret boundary-hardening prerequisites (de-NSColor theme API-01/02/09, Codable `FindMatch`, de-Combine 3 Core types) opportunistically *after* launch.
- **API-01/02/09 (NSColor in ViewerCore)** — touches the published `.library` API shape; one-way-door API break; needs the ThemeColor decision.
- **WV-3 (header-CSP via WKURLSchemeHandler)** — changes base-URL/relative-image semantics; architecture decision.
- **SCALE-4 / SCALE-11 (mmap pager)** — large architectural feature; DESIGN claim should be downgraded vs built.
- **DEP-002 (app's own LICENSE)** — legal/product decision (proprietary vs OSS).
- **PERSIST-05 (v1→v2 migration)** — needs product answer on whether any build reached real users.
- **CR-03 / OBS-4 (MetricKit/crash hooks)** — telemetry-policy decision (DESIGN Phase 9).
- **UX-11 (security-scoped bookmarks)** — depends on sandboxing decision.
- **I18N-03 (Trojan-Source bidi)** / **I18N-06 (localization)** — product policy (strip vs visualize; English-only at launch?).
- **SIGN-08/09/10/11 (—deep, DMG, Sparkle, Developer-ID)** — Phase-9 public-ship prerequisites, deferred by design.
- **Risky-UI-judged-visually** items (e.g. UIRESP-12 making timeline clickable) — additive low-risk hover/cursor is auto-fixed in G12 with `visual_verify_needed`; behavior-changing UI is surfaced.
