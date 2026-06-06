# Perf Fix#1 — per-tab view retention (instant tab switching, no WKWebView reload)

> ✅ **LANDED 2026-06-06 — commit `39925fd`** (TSK-108 → `fixed`). Approach A shipped
> as designed: `ContentView.content` = ZStack of `MountedPanesLRU`-bounded panes,
> driven from `DocumentModel.updateDerived`. Validated: headless merge gate (3975),
> `MountedPanesWiringTests` (mutation-checked), `PaneRetentionMountProbeTests`
> (A→B→A = 0 WKWebView make/dismantle, overflow = 1), live T4 `ViewModeMatrixSmokeTests`.
> Remaining = human supervised visual/interaction review (review→validated→done).
> The notes below are the original design (kept for context).

> Research synthesis (2026-06-04, workflow `wf_5601f08d`: 1 unprimed + 1 primed
> explorer → ranked synthesis). De-risks the **dominant** screen-gated perf fix.
> Context: `RepublishCountTests` proved the model side is fine (warm `selectTab`
> = 1 republish); the tab freeze is **entirely view-side** — re-creating the
> `NSViewControllerRepresentable` tears down + reloads the `WKWebView` (~1s),
> and A→B→A reloads twice. The fix is to RETAIN a bounded LRU of inactive panes.

## Recommendation — Approach A (ZStack of mounted panes, LRU-bounded)

Replace the single active-tab `content` in `ContentView.bodyRow` with a
`ZStack { ForEach(mountedTabs, id: \.id) { … } }`, each pane gated by
`opacity` / `zIndex` / `allowsHitTesting` / `accessibilityHidden`, the mounted
set capped by an MRU/LRU(~4). Because each pane has stable `ForEach` identity on
`Tab.id`, SwiftUI keeps inactive panes mounted and **never calls
`dismantleNSView`** — so the inactive `WKWebView` keeps its loaded document.
A→B→A becomes pure opacity/zIndex flips: **0 remounts, 0 reload**.
`dismantleNSView` fires only on LRU tail eviction — the one controlled teardown.

This is the only option meeting all four bars: (a) no reload on A→B→A;
(b) bounded memory (LRU cap); (c) least-invasive (one localized swap in
`bodyRow`, reusing the existing per-state `switch` verbatim per-tab, leveraging
every guard already in `MarkdownRenderedView`); (d) directly validatable with
the existing `InteractionProfileHarness` + `RepublishCountTests` rigs.

**Hybrid framing:** retain (A) for the hot LRU set; everything past the cap
falls back to today's rebuild-from-state behavior (Approach C) — which is what
already happens. Large docs already route to cheap placeholders
(`LargeEditorPlaceholderView`, the `markdownRenderMaxBytes`/`codeMirrorEditorMaxBytes`
caps) — they carry no webview cost, so retain them freely; consider excluding
genuinely large *real* docs from retention.

## Approaches compared

| | Approach | Fit | Memory | Verdict |
|---|---|---|---|---|
| **A** | ZStack of ForEach-keyed mounted panes, opacity/zIndex/hitTesting gate, LRU(~4) | **strong** | bounded O(mounted); ~30–80 MB/retained webview → ~90–240 MB floor at N=4 | **CHOSEN** |
| **B** | Manual `[UUID: WKWebView]` cache held outside SwiftUI; representable adopts cached instance | partial | same floor, or lower via 1 warm process + reload (re-adds latency) | **fallback** only if A's identity guarantees prove fragile — fights SwiftUI ownership, re-parenting flirts with the compositor ghost-layer bug (LESSONS.md) |
| **C** | Model-restore (VS Code `getState`): keep parsed HTML + scroll, rebuild view on switch | partial | lowest steady-state | **rejected** for instant-switch (still rebuilds webview → fails the 0-remount probe), but correct for the cold long tail past the LRU + memory-pressure fallback |

## Recommended code shape

> **The LRU model core is already built + tested headlessly:**
> `ViewerCore/MountedPanesLRU.swift` (commit `8e23540`, `MountedPanesLRUTests`,
> 12 tests) — MRU-ordered, capacity-bounded, with `activate`/`remove`/
> `retainOnly`/`trim(to:)` and deterministic eviction (always-retain-active,
> LRU-not-FIFO, prune-on-close, memory-pressure trim-to-1). The live turn just
> holds one on `DocumentModel`, drives it from `selectTab`/`closeTab`, and reads
> `.ids` into the ForEach. The sketch below is now mostly wiring.

```swift
// --- DocumentModel: hold the tested LRU; @Published so ContentView sees it.
//     (Keep it ON DocumentModel, not a narrow store — see RISK #1.) ---
@Published private(set) var mountedPanes = MountedPanesLRU(capacity: 4)

// In selectTab(at:) (DocumentModel.swift:3505), after tabCoordinator.select /
// materializeIfNeeded:   mountedPanes.activate(tabs.selected!.id)
// In closeTab:           mountedPanes.remove(closedID)
// On session switch / bulk close: mountedPanes.retainOnly(Set(openTabIDs))
// On memory pressure:    mountedPanes.trim(to: 1)

var mountedTabs: [Tab] {                       // MRU-first, active included
    mountedPanes.ids.compactMap { id in tabs.tabs.first { $0.id == id } }
}

// --- ContentView.bodyRow: replace the bare `content` (≈line 344) ---
ZStack {
    ForEach(model.mountedTabs) { tab in              // Identifiable on stable Tab.id
        let isActive = tab.id == model.tabs.selected?.id
        tabContent(for: tab)                         // per-tab switch (NOT global currentState)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)              // LOAD-BEARING: events must not leak through
            .zIndex(isActive ? 1 : 0)
            .accessibilityHidden(!isActive)          // LOAD-BEARING: VoiceOver must not leak
    }
}
// tabContent(for:) is today's `content` switch, but reads the PASSED tab's
// state / viewMode / zoom / find — so inactive panes render their OWN content,
// not a mirror of the active doc.
```

> **Why `opacity:0`, not `.hidden()` / `isHidden`:** the unprimed research
> surfaced cmux PR #1228 — toggling a `WKWebView` to hidden fires WebKit's
> in-window lifecycle (`visibilitychange`), which can make the page **self-reload**
> — defeating the whole point. `opacity:0` keeps it "visible" to WebKit (just
> background-throttled), so no visibilitychange, no reload. (cmux #3085 also
> documents a ghost remote-layer when WKWebViews are hidden.)

## Risks (and how the guards catch them)

1. **PRIMARY — observation timing (dead-toggle class, LESSONS.md:201-209).**
   If `mountedTabIDs`/active-id live on a *new narrow store* (to avoid
   republishing the god-object), `ContentView` must also observe that store or
   the opacity gate goes dead (active pane never reveals / new webview never
   focuses) — the exact prior dead-toggle bug. **Mitigation: keep
   `mountedTabIDs` `@Published` directly on `DocumentModel`** (a tab switch
   already republishes it once — `RepublishCountTests` baseline). Narrow only if
   the republish-count probe shows a regression, and then add the
   `childStore.objectWillChange → model.objectWillChange.send()` pipe + pin it.
2. **ForEach keyed on index** (not `Tab.id`) tears down the wrong pane on
   close/reorder → probe asserts the exact eviction set, no collateral remounts.
3. **Missing `allowsHitTesting(false)`/`accessibilityHidden(true)`** → events /
   VoiceOver leak through the stack — headless-assertable.
4. **`tabContent` reading global `model.currentState`/`currentViewMode`** instead
   of the passed `tab` → inactive panes mirror the active doc — caught by a
   per-pane content assertion.
5. **Inactive Mermaid/rAF panes** may keep compositing despite `opacity:0`
   (WebKit ignores `isHidden` for remote layers) → verify idle CPU with
   `mem-profile`/powermetrics; only if it shows, deactivate animations via JS on
   blur (don't detach — re-attach forces a repaint).

## Validation plan (screen-unlock / `--diagnose` turn)

1. **Mount-count probe (headline gate).** Debug-gated static counter in
   `MarkdownRenderedView.makeNSView`/`dismantleNSView` (+ the CodeMirror
   representable). Headless `HeadlessUITestCase` reusing `InteractionProfileHarness`
   (`host(_:size:)`): open A,B, force layout, drive `selectTab` A→B→A
   (`tab.switch.cycle`). **Assert 0 additional make/dismantle.** Then overflow
   LRU(4) → assert exactly one `dismantleNSView` for the evicted tail.
2. **Republish-count guard.** Extend `RepublishCountTests`: record the new warm
   `selectTab` baseline; fail on an order-of-magnitude balloon; assert the active
   flip propagates (no dead toggle).
3. **Interaction timing (offscreen).** `MDV_PROFILE=1 swift test --filter
   InteractionProfileHarness`; compare `tab.switch.cycle` median before/after
   (expect sharp drop for the hot set; watch N-pane layout cost).
4. **Live footprint.** `mem-profile` at N=1/2/4 mounted panes; confirm the
   ~30–80 MB/webview floor; wire memory-pressure → collapse cap to 1 + trim.
5. **Headless gate** stays green (new probes are T1m, no window). Real in-process
   WKWebView reload-avoidance + ghost-layer + idle-CPU checks go to the VM/nightly
   lane, not the merge gate.

## Key change sites
- `ContentView.swift` ~344 (`bodyRow` — the single swap), ~446-487 (`content`
  switch → `tabContent(for:)`), 489-613 (`loadedView` — thread `tab.viewMode`/
  zoom/find per-tab).
- `DocumentModel.swift` 2518/2520 (`currentState`/`currentViewMode`), 3505-3528
  (`selectTab` — `noteTabActivated` hook).
- `MarkdownRenderedView.swift` 54 (shared `WKProcessPool`), 178 (`lastHTML`
  reload-guard — retains across opacity flips), 246 (`dismantleNSView`).
- `Tab.swift` 27 (`id: UUID` — the ForEach key).
- Guards to extend: `RepublishCountTests.swift`, `InteractionProfileHarness.swift`.

## Sources
- **Unprimed:** cmux PR #1228 (hide → visibilitychange → self-reload), cmux #3085
  (ghost WKWebView remote layer), VS Code `retainContextWhenHidden` vs `getState`,
  web.dev bfcache.
- **Primed:** WWDC21-10022 *Demystify SwiftUI* (identity drives lifetime; prefer
  inert modifier over branch), Hossli *Lifecycle bugs in SwiftUI TabView*
  (ZStack-opacity = TabView's own trick), Massicotte (coordinator/parent
  staleness), firefox-ios #10287 (no public WKWebView suspend API), MDN Page
  Visibility (background throttling is automatic).
