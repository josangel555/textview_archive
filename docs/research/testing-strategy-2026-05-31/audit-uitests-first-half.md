Grounding complete. The contrast is clear: `ViewerCoreTests` (119 files) and `ViewerKitTests` (9 files) contain *zero* app-launch / view-hosting / screencapture — they're pure value/logic suites by construction, which is exactly why CLAUDE.md greenlights them on the host. The "UI tests" directory, by contrast, is a mix where most files are *also* pure logic but happen to live there for `@testable import ViewerUI` access.

I have everything I need. Writing the audit.

---

# UI/Live-App Test Tier Audit — First Half (A–M), `Tests/ViewerUITests/`

## The tiering model (derived from the actual harness, not assumed)

Before the table, the mechanism ladder this codebase actually has — because the whole audit turns on understanding that **"screencapture a live window" is two completely different things here**, and the harness deliberately uses the *weaker* one:

| Tier | Mechanism | What runs | Fidelity ceiling | Cost / where |
|------|-----------|-----------|------------------|--------------|
| **L1** | Pure value/logic | A function, a struct, a decoder. No `NSApplication`. | Logic correctness only | Host, ~ms |
| **L2** | `@MainActor` model logic | `DocumentModel`/coordinators with real `DocumentController`, real disk I/O under `/var/folders`. AppKit *linked* but no window. | State-machine + persistence + wiring | Host, ~ms–s |
| **L3a** | In-process `NSHostingView` tree-walk | Hosts `ContentView`/`MarkdownRenderedView`, `layoutSubtreeIfNeeded()`, walks realized `NSView` subtree (`DiagnosticDump.describeView`). **No `NSWindow`, no WindowServer.** | View *realizes*; frames/alpha/opacity/zero-size up to the window boundary. WKWebView is *instantiated* (spawns WebContent procs). | Host (but gated, see #192) |
| **L3b** | In-process `cacheDisplay` PNG | `DiagnosticDump.captureWindowToPNG` → `bitmapImageRepForCachingDisplay` + `cacheDisplay`. Permission-free, **bypasses WindowServer**. | Rasterizes the layer tree the process *thinks* it has — **structurally blind to the compositor sibling-blank bug** (per `visual-smoke.sh` header). | Host/VM |
| **L4** | Real `.app` via `--script` | `AppLauncher.runScript` direct-execs the bundle, `MDV_BACKGROUND=1`, runs step verbs, writes `mdv-step-NN.json` (enriched `model` dict) + a `cacheDisplay` PNG. **Assertions read the JSON, never the PNG.** | Real app process, real `AppDelegate`/`sessions`/`window`, real launch wiring — but state-only assertions. | VM (or host-skips when unbuilt) |
| **L5** | Real `.app` + WindowServer `screencapture(1)` | Only `SourceViewVisualRegressionTests` (2nd half) + `vm-smoke.sh`/`visual-smoke.sh`. True pixel readback through the compositor. | The *only* tier that sees the compositor pathology. | VM with Screen Recording TCC grant |

**Load-bearing consequence:** an L4 `--script` test that asserts on JSON dumps is *not* a visual test. It pays the cost of a real process launch + 0.3s/step + VM-only execution, but every fact it checks lives in `model.*`, which is reachable at L2. The PNG it writes is human-review-only and uses the bug-blind `cacheDisplay` path anyway. That gap is the central finding.

---

## Per-suite table (A–M, alphabetical)

Legend for "Lowest faithful tier": the tier at which the *behavior currently asserted* could be checked with equal fidelity. **▲** = sits higher than necessary.

| Suite | Actually verifies | Runs as | Lowest faithful tier | Verdict |
|-------|-------------------|---------|----------------------|---------|
| **AppLauncher** (harness) | n/a — spawn/poll/collect-dumps machinery | L4 infra | n/a | Keep. But it's the leverage point (see "Underused techniques"). |
| **BookmarkIntegrationTests** | toggle/persist/clear bookmarks via `DocumentModel` + on-disk `BookmarksStore` round-trip | L2 | **L2** | Correct tier. |
| **BookmarkLineCacheTests** | `bookmarkedLines(for:)` memoization + invalidation | L2 | **L2** | Correct. (Two tests reach into `bookmarksStore` directly to dodge `@Published` refresh — coverage is thinner than the names imply, but tier is right.) |
| **BookmarksSectionEmptyTests** | placeholder string constants are stable/non-empty | L1 | **L1** | Correct. Self-documents that it's only in `ViewerUITests` for `@testable` reach. |
| **CodeMirrorBridgeExtendedTests** | `CodeMirrorBridge.decode` negative/forward-compat/Unicode cases | L1 | **L1** | Correct — the highest-value-per-ms suite in the set. |
| **CodeMirrorBundleTests** | bundled HTML/JS/CSS exist, size budgets, **grep the JS/HTML for wiring symbols** | L1 | **L1** | Correct, with a candor caveat: grep-for-`"case \"applyEdits\""` proves the *string is present*, not that the dispatch works. It's a build-integrity tripwire, not behavior. Fine as long as nobody reads it as "Phase 4 works." |
| **ComponentVisualTests** | mode bar / tab bar / hex / empty / error / palette / sidebar *realize* in the NSView tree; some tests are model-only | **L3a, gated #192** | **L3a** (mostly); 4 tests are **L2** | Tier mostly right. ▲ *Mis-grouped*: `test_modeBar_xmlFile_showsModesIncludingFormat`, `test_palette_isPresented_togglesViaModel`, `test_hexView_binaryFile_landsInBinaryState`, `test_errorState_missingFile_landsInErrorState` are pure model assertions paying the WebView-gate tax. The "▲" is the gate, not the host. |
| **ContentViewHostingTests** | after open: 1 loaded tab; hosted tree non-trivial; **markdown embeds a real `WKWebView`** | **L3a, gated** | **L3a** (the WKWebView-presence ones); **L2** for `test_openXML_modelHasOneLoadedTab` | Right tier for the WebView-presence tests — that genuinely needs the host to instantiate WebKit. One test is L2 wearing an L3a jacket. |
| **CrossSearchIntegrationTests** | cross-file search results, case-sensitivity, async settle | L2 (async) | **L2** | Correct, and notably well-built — replaced fixed sleeps with `waitFor` predicates (no flaky timing). |
| **DiagnosticDumpTests** | invisible-content invariants: zero-size, alpha/opacity, hidden-ancestor, **`NSTextView` hosted via controller boundary**, redaction | **L3a, gated, writes PNG** | **L3a** | Correct and the *right* idea — asserts every property up to the WindowServer boundary. Honestly documents its own ceiling ("doesn't exercise the compositor; that's `SourceViewVisualRegressionTests`"). Best-in-class self-awareness. |
| **DocumentModelEditorForwarderTests** | `model.editorX` forwarders ↔ `model.editor.X` round-trip | L2 | **L2** | Correct. |
| **DocumentModelGitPanelTests** | `showGitPanel` bumps nonce + sets desired tab | L2 | **L2** | Correct. Nonce-bump-on-repeat is a real SwiftUI-dedupe correctness check. |
| **DocumentModelLanguageOverrideTests** | per-tab language override logic | L2 | **L2** | Correct (read header only; signals + import are L2). |
| **DocumentModelTabForwarderTests** | tab forwarders ↔ `TabCoordinator` round-trip | L2 | **L2** | Correct. |
| **DocumentModelTests** (872 lines) | open/dedupe/recents/state-machine/tab-republish — the "vanishing tabs" guard | L2 | **L2** | Correct. Header explicitly refuses to mock the controller because the real file path caught the actual bug — good judgment. |
| **DragDropTests** | `DropRouter.handle` accepts/filters/deadline-flushes `NSItemProvider`s | L2 | **L2** | Correct, and a model example: exercises the *production* `DropRouter`, not an inlined copy; uses an actor-backed sink for the `@Sendable` callback. |
| **EditorCoordinatorCleanupTests** | per-tab dict cleanup (the latent leak fix) | L2 | **L2** | Correct. |
| **EditorCoordinatorDiskRoundtripTests** | load→edit→save→re-read disk matches | L2 | **L2** | Correct. |
| **EditorCoordinatorInteractionTests** | cross-coordinator scenarios with test seams for the NSAlert sites | L2 | **L2** | Correct — the `dirtyClosePromptOverride` seam is exactly how to keep an alert-bearing flow headless. |
| **EditorCoordinatorTests** (551 lines) | coordinator state machine in isolation, injected effects | L2 | **L2** | Correct. |
| **EditorRepublishInvariantTests** | `objectWillChange` fires only on real change (REPUB discipline) | L2 (Combine) | **L2** | Correct — this class of test *must* be in-process; it counts publisher emissions. |
| **FileWatcherIntegrationTests** | external write → model reloads within 3s | L2 (real FS events) | **L2** | Correct. Genuinely integration (real `DispatchSource`/FSEvents), can't go to L1. |
| **FindBarTests** | `model.isRenderedFindBarPresented` / query lifecycle | **L3a-gated, but no host call** | **L1/L2** | ▲▲ **Mis-tiered.** Gated behind `MDV_RUN_WEBVIEW_TESTS` and carries `renderHost`/`hostedViews` plumbing **that no test calls** (verified: only the helper *definition* exists). The single test is pure model state. Drop the gate + delete the dead `renderHost`/`hostedViews`/teardown. |
| **FindCoordinatorTests** | find state machine | L2 | **L2** | Correct. |
| **FindMinimapLayoutTests** | minimap layout math | L1/L2 | **L1/L2** | Correct (geometry math, no window). |
| **FindRepublishInvariantTests** | find forwarders + republish discipline | L2 | **L2** | Correct. |
| **FolderStateSymbolTests** | folder open/closed SF Symbol name logic | L1 | **L1** | Correct. |
| **FormatToggleTests** | `supportsFormatToggle`, per-tab format state, `displayText` formatting, mode availability | **L3a-gated, but no host call** | **L1/L2** | ▲▲ **Mis-tiered, same as FindBar.** Every test is model-level (`supportsFormatToggle`, `toggleFormat`, `ViewModeOptions.availableModes`). `renderHost`/`hostedViews` are dead code; the WebView gate is unjustified. Drop gate + delete plumbing. |
| **G12AccessibilityHelpersTests** | CSV cell/column VoiceOver label math, `MotionGate` reduce-motion branch | L1 | **L1** | Correct, with the *right* candor in its own header: the visual A11y parts are VM/eyeball-only; only the branch logic is captured here. |
| **GitPanelPickerTests** | git panel picker selection logic | L1/L2 | **L1/L2** | Correct (header + signals; no host/launch). |
| **GitStatusTabGroupingTests** | grouping tabs by git status | L1 | **L1** | Correct. |
| **GoToPathUITests** | ⇧⌘G prompt: show/dismiss, valid→opens, invalid→error string, **all via `goto-commit` model verbs** | **L4 (real .app)** | **L2** | ▲ **Sits higher than necessary.** The header itself admits the script runner *can't type into the prompt's `@State` TextField*, so it drives `model.commitGoToPath(_:newSession:)` — a pure model method — and asserts on `model.lastGoToError` + window title. Nothing here needs a real process. Faithfully reproducible at L2: construct `DocumentModel`, call `commitGoToPath`, assert `lastGoToError` + `currentURL`. The L4 launch buys only "the verb is wired into `runScriptStep`" — which a 1-line dispatcher test covers more cheaply. |
| **HelpSinkHoverStateTests** | `HelpSink.set` publishes iff value changes | L2 (Combine) | **L2** | Correct. |
| **HelpSinkTests** | basic dedupe/clear | L1/L2 | **L1/L2** | Correct. |
| **HexMatchCapTests** | `HexMatchCap.cap` first-N + flag, VoiceOver label | L1 | **L1** | Correct. |
| **HighlightCacheActorTests** | cache hit/miss, in-flight coalescing, LRU, version bump, **no `objectWillChange` leak** | L2 | **L2** | Correct — the publisher-non-emission invariant pins it in-process. |
| **InteractionDeepTests** | tab cycling, palette toggle, **window resize geometry**, zoom persistence, sidebar set-root | **L4 (real .app)** | **L2** for all but resize; resize is **L4-justified** | ▲ **Mostly over-tiered.** Tab cycling asserts on `windowTitle`/`tabCount` from the JSON `model` dict — pure L2. Palette toggle reads `model.isPalettePresented` — L2. Sidebar set-root reads `model.sidebar.rootURL` — L2. **Genuine L4 exception:** `test_resize_changesWindowGeometry` drives `window.setFrame` and reads back the *real* `NSWindow.frame` (including macOS clamping to display bounds) — that's a real-window property with no in-process equivalent. Split that one out; demote the rest to L2 coordinator/model tests. |
| **InteractionScriptTests** | toggle-view swaps rendered/source + **WKWebView present/absent**; new-tab/close tab count; zoom commands | **L4 (real .app), writes PNG** | **L2** for tab+zoom; **L3a** for the WebView swap | ▲ **Over-tiered.** `tabCount`/`zoom` assertions are model-dict reads → L2. The one thing with teeth is `assertHasWebView`/`assertNoWebView` proving the *view layer caught up to the model* on a real mode toggle — but `DiagnosticDumpTests`/`ContentViewHostingTests` already prove WKWebView realization at **L3a in-process**. To move down: assert the WebView swap by hosting `ContentView` and toggling `currentViewMode`, watching the WKWebView appear/disappear in the realized tree. No real process needed. |
| **LargeFileOpenTests** | large-file read-only open path via **injected tiny soft-watermark** `DocumentController` | L2 | **L2** | Correct — and a *textbook* example of the right technique: shrink the threshold instead of writing a 64 MiB fixture, since the transition logic is size-agnostic. Header correctly notes live huge-file rendering (RSS, scroll frames) stays VM-manual. |
| **LongFlowTests** | 16-step "day in life" + heavy tab churn + **zoom persistence across relaunch**, invariants: non-empty title/frame, sane zoom | **L5-labeled, actually L4**; 90s timeout | **L2** for invariants; **L4-justified** for cross-relaunch persistence | ▲ **Partially over-tiered.** The per-step invariants (title non-empty, zoom in range, frame present) are model-dict reads → L2. The *one* thing only the real app proves is **zoom persistence across separate process launches** via `PreferencesStore` on disk (scenario 2→3 deliberately relaunch). That's a real cross-process persistence contract — keep at L4. Everything else is a long L2 sequence that doesn't need a process per step. Note: labeled "L5" but takes **zero** screenshots that it asserts on — it's L4 by mechanism. |
| **MarkdownRenderedViewTests** | `Coordinator.decide` link-scheme allowlist (javascript:/data:/file: cancelled, http opens external, post-load file-escape cancelled) — **a security boundary** | **L1 (static func)**, but imports WebKit | **L1** | ▲ *Mislabeled, not mis-tiered.* Despite the name and `import WebKit`, it instantiates **no view and no WKWebView** (verified). It's a pure static-function security test — among the most valuable in the set. Tier is already optimal; only the filename oversells it. Not gated (correctly). |
| **MermaidHostingTests** | `renderedHTML` emits mermaid host div + shim CSS + cache-hit; **`.mmd` routes to rendered → real WKWebView** | **L3a, gated** | **L2** for renderedHTML/cache; **L3a** for the `.mmd`→WKWebView routing | Tier mostly right. The HTML-string + cache tests are L2 (string assertions on `renderedHTML`) paying the gate tax; `test_openMmdFile_hostsWKWebView` genuinely needs L3a host. Split: keep one L3a routing test gated, demote the HTML/cache tests to ungated L2. |

---

## Cross-cutting findings (the non-obvious part)

### 1. The `MDV_RUN_WEBVIEW_TESTS` gate is being used as a tier, and it's leaking onto pure-logic suites
The gate exists for a real reason — `WebViewTestTeardown.swift` documents a genuine, nasty failure: an `AG::precondition_failure` in SwiftUI's *process-global* AttributeGraph that a later runloop-spin (`PluginSubprocessHost.call → waitUntilExit`) drains and `abort()`s, truncating the M→Z suite tail. That's a legitimate process-isolation need for suites that *actually host SwiftUI/WebKit*.

But it has spread to suites that **no longer host anything**: `FindBarTests` and `FormatToggleTests` are gated and carry `renderHost`/`hostedViews`/`teardown` plumbing that **no test in the file calls** (verified by grep — only the helper definitions remain). They're paying isolation cost and dropping out of the bare sweep for zero benefit. `MarkdownRenderedViewTests` correctly *isn't* gated, which proves the gate isn't mechanically required for "imports WebKit." **Action:** ungate `FindBarTests` + `FormatToggleTests`, delete their dead hosting plumbing. Re-evaluate the `ComponentVisualTests`/`MermaidHostingTests` model-only tests — split them so only the genuine `NSHostingView`+WKWebView tests stay gated.

### 2. Every L4 `--script` suite in this half asserts on JSON state, never pixels — so most of them are L2 wearing L4 costumes
This is the single biggest tier inflation. `AutomationHost`/`ScriptRunner` enrich each dump with a `model` dict (`zoom`, `tabCount`, `currentViewMode`, `isPalettePresented`, `sidebar.rootURL`, `lastGoToError`, …). The L4 suites (`GoToPathUITests`, `InteractionDeepTests`, `InteractionScriptTests`, `LongFlowTests`) read *that dict*. Each of those fields is set by a `DocumentModel`/coordinator method that an L2 test can call directly and assert on in microseconds, on the host, without the VM, without 0.3s/step, without the 90s `LongFlowTests` timeout.

What the L4 launch *uniquely* buys, and is worth keeping a thin slice for:
- **Real-window geometry** — `InteractionDeepTests.test_resize_changesWindowGeometry` reads back `NSWindow.frame` after `setFrame`, including OS clamping. No in-process equivalent.
- **Cross-process persistence** — `LongFlowTests` zoom-across-relaunch proves `PreferencesStore` survives a real process boundary.
- **Verb-wiring smoke** — that `runScriptStep`'s `case "goto-commit"` etc. dispatch at all. But this is better served by *one* tiny dispatcher table test than by re-launching the app per behavior.

**Counterintuitive recommendation:** keep a *single, deliberately small* L4 "the app launches, opens a file, and dispatches a representative verb without crashing" smoke scenario, plus the resize + relaunch-persistence specials. Migrate the rest of the behavioral assertions to L2. You lose ~nothing in fidelity (the assertions are already state-only) and reclaim the VM round-trip for the whole cluster.

### 3. The harness's PNG path can never catch the bug it looks like it's for — and the codebase already knows this
`ScriptRunner.captureStepArtifacts` writes `mdv-step-NN.png` via `cacheDisplay`. `visual-smoke.sh`'s header is explicit: `cacheDisplay` *bypasses the WindowServer*, and the sibling-blank compositor pathology *only* manifests at WindomServer composition time. So the L4 PNGs are decorative — useful for a human glancing at "did a window draw," structurally incapable of catching the one visual regression the project actually fears. The only thing that catches it is L5 `screencapture(1)` with Screen Recording TCC (`SourceViewVisualRegressionTests`, 2nd half). This is *correctly understood* in the code; the risk is a future contributor seeing "PNG snapshot per step" and assuming visual coverage exists where it doesn't. Worth a one-line note in `AppLauncher` that the per-step PNG is `cacheDisplay` and therefore compositor-blind.

### 4. Tests that genuinely must stay on a real screen (L5) — and why
**None in the A–M half.** The only true L5 in the whole directory is `SourceViewVisualRegressionTests` (S, second half): it's the sole test that drives `screencapture(1)` through the WindowServer and samples per-region pixel variance, with a meta-test (`MDV_ENABLE_BROKEN_RULER`) that deliberately breaks the layout to prove the variance check has teeth. That self-validating meta-test is the gold standard here — it's the one place where "real screen" is non-negotiable, and it earns it. Everything in A–M that *launches* the app is L4-by-mechanism (state dumps), not L5.

### 5. Underused / counterintuitive techniques worth propagating
- **`LargeFileOpenTests`' watermark injection** is the model to copy: shrink the threshold, not the fixture, when the logic is magnitude-agnostic. Apply the same thinking to any "huge file" / "many tabs" test tempted toward L4.
- **`DiagnosticDump.describeView` is an underused L3a superpower.** It already serializes alpha/opacity/hidden-ancestor/zero-size for the *whole* tree in-process. Most of what the L4 suites assert (and more) could be asserted against this JSON from an `NSHostingView` at L3a — same structure as the L4 dumps, no process launch. The infrastructure to demote L4→L3a already exists and is unused for that purpose.
- **The `dirtyClosePromptOverride` test seam** (`EditorCoordinatorTests`) is the right pattern for the *one* class of thing that otherwise forces a real app: modal `NSAlert` sites. Any future "must launch to dismiss an alert" temptation should reach for an injectable prompt closure instead.
- **Publisher-emission counting** (`EditorRepublishInvariantTests`, `HelpSinkHoverStateTests`, `HighlightCacheActorTests`) is the correct *floor* tier for SwiftUI-perf invariants — it cannot move lower (needs Combine in-process) and must not move higher (a real window adds nothing). These are tiered optimally; flag them as "do not 'upgrade' to UI tests."

---

## Concrete move-down list (ranked by payoff)

| Action | Suite(s) | Effort | Why it's safe |
|--------|----------|--------|---------------|
| Ungate + delete dead `renderHost`/`hostedViews` | `FindBarTests`, `FormatToggleTests` | trivial | No test hosts a view; the gate guards nothing. |
| Demote behavioral assertions L4→L2; keep 1 launch-smoke | `InteractionScriptTests`, `GoToPathUITests` | moderate | All assertions read the `model` dict, which L2 sets directly. |
| Split L4 suites: isolate resize + relaunch-persistence, demote rest | `InteractionDeepTests`, `LongFlowTests` | moderate | Only window-geometry + cross-process persistence need a real process. |
| Move WebView-swap proof L4→L3a | `InteractionScriptTests` (`assertHasWebView`) | small | `DiagnosticDumpTests` already proves WKWebView realization in `NSHostingView`. |
| Split gated suites: ungate the model-only tests | `ComponentVisualTests`, `MermaidHostingTests` | small | `renderedHTML`/`availableModes`/`isPalettePresented` are L2; only `NSHostingView`+WKWebView tests need the gate. |
| Rename (not re-tier) | `MarkdownRenderedViewTests` → `MarkdownLinkPolicyTests` | trivial | It's a pure link-scheme security test; the name implies view hosting it doesn't do. |

**Must stay where they are:** all L1/L2 logic + coordinator + republish + cache suites (the majority), the L3a invisible-content/`DiagnosticDumpTests` and WKWebView-realization tests, and the resize/relaunch L4 slices. No A–M suite requires L5.

Files grounding every call: harness at `/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/ViewerUITests/AppLauncher.swift`, `/Users/me/.../Harness/LaunchHarness.swift`, `/Users/me/.../Harness/WebViewTestTeardown.swift`; the interpreter at `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/ScriptRunner.swift`; the two PNG paths at `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DiagnosticDump.swift:263` (`cacheDisplay`) vs `/Users/me/Documents/workspaces/claude/markdown_viewer/scripts/visual-smoke.sh:75` (`screencapture`).