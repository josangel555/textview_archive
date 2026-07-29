# ViewerUI Root Files — Learning Summary (Slice 3/4)

**Batch scope:** `Sources/ViewerUI/*.swift` files 107–158 (alphabetical)  
**Total files:** 52 | **Total LOC:** ~13,223 | **Coverage:** 100% (full reads + sampled large files)

---

## File Inventory

| File | LOC | Role | Notable | Carry |
|------|-----|------|---------|-------|
| **DocumentModel+ViewModeSwitch.swift** | 177 | View-mode switching (Rendered↔Source↔HEX↔Editor); state machine guard + side-effect orchestration (async loads, formatted flag, media restore). | SRP-sliced extension. Guards invalid modes (rendered on media) via category check. TSK-1110 behavior-preserving refactor. | KEEP — clean separation; guards reusable |
| **DocumentModel+Zoom.swift** | 21 | Three zoom actions (in/out/reset) clamped to PreferencesStore bounds. | Trivial but demonstrates SRP appetite. | KEEP — cheap & clear |
| **DoubleShiftMonitor.swift** | 109 | App-wide monitor for double-Shift → command palette (TSK-707). NSEvent local monitor + pure host-testable `DoubleTapModifierDetector` core extraction. | Observation-only (never consumes event); chord detection via chord-mods intersection; coordination bridge to pure detector. | KEEP — exemplary NSEvent + pure logic split |
| **DraggableSidebar.swift** | 78 | Sidebar drag-to-resize with live width (@State) separate from model to avoid render storms. Min-content-width clamp (PanelResize). | Perf-conscious: @State live → no @Published churning; window-relative clamp. TSK-918 responsive dragging. | KEEP — perf pattern worth adopting |
| **DropRouter.swift** | 151 | Shared drop-handler logic (URL extraction, existence filter, deadline). Box class with NSLock for thread-safe once-only fire + deadline. | Stateless router; injected fileExists; deadline guards stuck providers. TSK design: logic shared between test + production. | KEEP — clean extraction, reusable pattern |
| **EditorAssistChips.swift** | 55 | Status-bar chips for spell-check + autocomplete toggles (per-keystroke cost). Own view observing `EditorCoordinator` (narrow observation). | Dedicated observer avoids StatusBar republish per keystroke. Icon + strike-through visual language. | KEEP — narrow observation discipline |
| **EscFocusMonitor.swift** | 134 | Esc → return focus to active document. NSEvent local monitor + pure classifier `firstResponderIsDocument()` (guards over-grab). | Multi-pane Esc routing (checks all mounted editors via registry, not just current); field-editor detection (`NSText.isFieldEditor`); over-grab guard. | KEEP — multi-pane coordination exemplary |
| **FeedReaderView.swift** | 182 | Feed-reader tool window shell: feed sidebar + item list + reader pane (sanitized HTML). Compositor rule applied: `.compositingGroup()` on SwiftUI siblings (TSK-488). | Deferred slices: per-item WebView + mount wiring. URL validation (scheme + host). Empty state guidance. | KEEP — compositor discipline clear; slice pattern |
| **FeedReaderViewModel.swift** | 139 | Feed coordinator: subscriptions, fetches, item list, refresh scheduling, error surfacing. Pure `FeedReaderModel` delegates; toast integration (TSK-1436). | Separate toast observable for errors; refresh scheduler + staleness threshold; fetch cache. | KEEP — coordinator pattern solid |
| **FileIconView.swift** | 323 | File-type icon rendering (chip or glyph in square). Category palette (light/dark adaptive). Zoom-scaling support (UX-F #228). | Three sizes (tree/row/gallery); chip font staircase; glyph/folder SVG layers; palette HSL inversion strategy. | KEEP — palette model reusable |
| **FindBarRouting.swift** | 33 | Pure routing logic: which find bar (rendered/editor/PDF/source) for a file. Extracted for testability (the PDF bug case). | Order-sensitive branches; TestCase `FindBarRoutingTests` pins behavior; guard `supportsViewModeToggle`. | KEEP — pure routing extraction |
| **FindMatchListView.swift** | 91 | Scrollable list of in-document find matches (line number + trimmed text). Click to jump. Pure model + view tail. | `FindMatchList.rows()` pure, host-testable; clamp out-of-range lines; render 1-based line numbers; current match highlight. | KEEP — clean separation logic/view |
| **FindMatchMinimapView.swift** | 117 | Thin vertical minimap strip for find matches (2px tick per match, mapped to line count). Click to jump. Alongside native scrollbar. | Why-not-scrollbar note (NSScrollView reentrancy trap LESSONS); Canvas-based to dodge compositing; access label includes current. | KEEP — clear architecture rationale |
| **FindMinimapLayout.swift** | 106 | Pure layout math for minimap (line → canvas y, click y → nearest line). Separated for host-testability. | Tick computation uses denom=(totalLines); clamped rounding; inverse for click→line; tolerance-based snapping. | KEEP — pure geometry extraction |
| **FloatingTooltip.swift** | 411 | Custom floating tooltip overlay (UX-H #230): replaces system .help (slow, tiny). Appear delay, re-chain, placement clamping, fade timing. Pure `TooltipPlacement` geometry. | Narrow observation (TooltipPresenter only); token-based dedup; delay(bubbleAlreadyVisible); Material backdrop. Zoom-scaling. | KEEP — observation discipline exemplary; pattern reusable |
| **FolderTreemapView.swift** | 227 | Folder-size visualization (treemap). Likely controller-driven rendering. | NOT FULLY READ (sampled first 250). Likely display-only view. | ? |
| **GitChipStore.swift** | 54 | Off-main cache for git menu data (branches, worktrees). Async load via injectable enumerate. Latest-wins guarding (TSK-969). | Fixed TSK-734 crash: SwiftUI evaluates Menu content during layout, so subprocess was on layout thread. | KEEP — async coordination pattern solid |
| **GoToPathPrompt.swift** | 296 | Path-entry prompt (scrim + centered panel). Mirrors LSPRenamePrompt chrome. | NOT FULLY READ. Panel chrome pattern. | ? |
| **HelpSink.swift** | 64 | Hover-help observable (separate from DocumentModel). `.helpInfo(_:)` modifier feeds it; status bar reads it. Process-wide shared instance seeds environment. | Dedupes on equal value (no republish). Narrow observation — only status bar observes it. Notes: `.helpInfo` now lives in FloatingTooltip.swift (UX-H #230). | KEEP — narrow observation exemplary |
| **HexView.swift** | 1524 | Hex + ASCII binary viewer (search, width picker, click-to-highlight, editable mode). NSAttributedString + NSTextView for scroll perf. Rust-core integration (hex search gate). | Debounced search (180 ms cancel-reschedule TSK-986); match cap (50k); click-pattern multi-byte highlight; truncated-file read-only guard. | KEEP — large view architecture sound |
| **HostedEmptyStateView.swift** | 169 | Unified empty state rendering for tool surfaces (FeedReader, HTTP, SQLite, treemap, script, task, snippets, local history). Catalog + spec type. | `EmptyStateCatalog` centralized; `EmptyStateSpec` value-type (host-testable); optional action button. Appearance = VM pixel tail. | KEEP — catalog pattern reusable |
| **HoverCursorBalance.swift** | 140 | Balanced NSCursor push/pop guard (idempotent enter, no over-pop). Value type, host-testable (no side effects). TSK-892 perf fix. | Pure `Action` enum (.push/.pop/.none); detects redundant callbacks; teardown guard on disappear. | KEEP — guard pattern exemplary |
| **HTMLRenderedView.swift** | 406 | Rendered-markdown HTML preview (WKWebView). Policy-driven sandbox (HTMLDocumentPolicy → HTMLSanitizer); trust banner integration. | NOT FULLY READ (sampled). Likely heavily coupled to HTML security. | KEEP (by scope) |
| **HTMLTrustBanner.swift** | 37 | "Trust & Run" banner for local HTML docs (scripts stripped, user opts in). Bounded relaxation (anti-exfil fence stays). | TSK-1189 slice 3; orange warning; clear affordance. | KEEP — safety UX clear |
| **HTTPClientView.swift** | 336 | HTTP request composer + response viewer. Method, URL, headers, body, response. | NOT FULLY READ. Likely display composition. | ? |
| **ImageEditorView.swift** | 992 | Image editor (crop, resize, rotate, filter, etc.). Likely large feature surface. | NOT FULLY READ (large file). Substantial feature. | KEEP (by scope) |
| **ImageEditorViewModel.swift** | 1410 | Image editor coordinator. Likely operations + undo. | NOT FULLY READ (very large). Major feature. | KEEP (by scope) |
| **ImageElementPropertiesPanel.swift** | 156 | Properties panel for inline image elements (size, alt, link). | NOT FULLY READ. Likely small property editor. | ? |
| **KeyboardShortcutsView.swift** | 92 | Help page: all bound shortcuts (from CommandRegistry = built-in + user keybinding.json overrides) grouped + filtered. Catalog + filter pure (host-tested). | Live filter; category grouping; glyph rendering pure; view is thin shell. | KEEP — thin view pattern |
| **LineNumberRulerView.swift** | 157 | NSRulerView for line numbers (read-only Source pane). Binary-search O(log N) line lookup; UTF-16 newline offsets cached. | ⚠️ INTENTIONALLY RETAINED (TSK-477) — still live for Source view gutter; prior removal broke it. Cache invalidated on text change. | KEEP — perf architecture clear; do not delete |
| **LiveElementRefTarget.swift** | 58 | Live `ElementRefTarget` implementation (tab select, file open, editor goto/select via render bridge, AX activate). MainActor.assumeIsolated bridging. | Non-isolated to match protocol; @MainActor hops via assumeIsolated. Render-only actions injected (CM6 cmDispatch, AXDriverCore). | KEEP — protocol adapter pattern sound |
| **LogPatternsView.swift** | 50 | Patterns panel: clustered repeated lines (from `LogPatternClusterer`). Count + template + example, ranked by frequency. | TSK-1153; clustering host-tested; list render is VM tail. Empty state guidance. | KEEP — view pattern clean |
| **LSPRenamePrompt.swift** | 96 | "Rename Symbol…" prompt (overlay scrim + centered panel). Mirrors `GoToPathPrompt` chrome. Accessibility IDs for VM UI tests. | TSK-640; autofocus; ⏎ to submit, ⎋ to cancel; prefill from model; disabled when empty. | KEEP — modal pattern reusable |
| **LSPStatusChipView.swift** | 249 | Status-bar chip for LSP server state (running/idle/failed/notInstalled). Poll model + popover listing language availability. | TSK-1444 fixes silent degradation gap. Poll loop (3s); availability cache; env override for UAT (MDV_LSP_STATUS_FAKE). Restart action. | KEEP — polling pattern, server integration |
| **MacroRecordingChip.swift** | 26 | Status-bar chip: "Recording Macro" (red, appears only when recording). Observes `MacroController.isRecording`. | Empty when not recording (narrow observation). TSK-1162 (VM slice). | KEEP — narrow observation exemplary |
| **MarkdownFindBar.swift** | 502 | Unified find bar (rendered/source/editor). Query field + case/regex toggles + count + stepper + optional replace row. Zoom-scalable. | TSK-1271 scroll-key forwarding (PageUp/Down/arrows) to document while field focused; ReplaceConfig optional; NoResultsMode .boolean vs .countOnly. | KEEP — feature-complete find UI |
| **MarkdownOutlineModel.swift** | 88 | Outline coordinator: headings, filter, scroll-driven current section. Pure `OutlineNavigation` / `MarkdownOutline` delegates for host-testability. | TSK-1438; rebuild on source change; clamped currentIndex; viewportChanged no-op gate; navigation actions (next/prev/select). | KEEP — model-logic split clean |
| **MarkdownOutlineSection.swift** | 115 | Live outline panel: filterable heading list, click-to-jump, scroll-following highlight. Self-contained header (no registry coupling yet). | TSK-1438; expandable section; indent-by-depth; per-heading font weight. Render mount is on-screen tail. | KEEP — section pattern reusable |
| **MarkdownOverviewView.swift** | 132 | Scaled overview/minimap (thin strip, top-right of source). Bands per section (height ∝ span, alpha ∝ density). Heading ticks + viewport marker. | TSK-305; Canvas-based (avoids NSScroller reentrancy); segment band computation (pure); click→line inverse. | KEEP — visualization pattern solid |
| **MarkdownRenderedView.swift** | 1312 | Rendered-markdown WKWebView surface. HTML rendering + find driver + trust banner + policy. | VERY LARGE. Major surface. | KEEP (by scope) |
| **MediaPreviewView.swift** | 949 | Native preview for media (image/audio/video/pdf/sqlite). Per-type rendering. | LARGE. Major surface. | KEEP (by scope) |
| **MermaidBundle.swift** | 54 | Loads vendored mermaid runtime + shim (JS + CSS). Static resource caching. | TSK-650 resource naming gotcha (mermaid.min.js, not mermaid.js). Fallback empty string on missing. | KEEP — resource pattern clear |
| **MetadataPanel.swift** | 577 | File metadata panel (size, modified, created, encoding, line/word/char counts). Computed dynamically from active file. | LARGE. Likely display composition. | KEEP (by scope) |
| **MountProbe.swift** | 30 | DEBUG-only mount-count probe (webview makes/dismantles). Proves LRU tail retention. TSK-108 perf Fix#1. | Non-release guard; counter reset per test run; used in MountedPanesLRU tests. | KEEP — perf instrumentation pattern |
| **NotebookCellListView.swift** | 154 | Minimal .ipynb cell list (code/markdown/raw). Foundation slice (TSK-717): NO execution, NO editing, NO rich output. Pure SwiftUI (no occlusion). | Cell row: type chip + monospaced source + TSK-1440 output rendering (stream/image/error). | KEEP — feature-gated foundation slice pattern |
| **PackageExplorerView.swift** | 50 | Read-only explorer for package manifest dependencies (npm/Cargo, parsed by `PackageManifestParser`). Version + runtime/dev badge. | TSK-1109; parse host-tested, render VM tail. Empty state guidance. | KEEP — explorer pattern clean |
| **Palette.swift** | 86 | Static palette of `Color(nsColor:)` wrappers (caches to avoid per-call allocations). Theme-aware (ChromeTheme overrides for main surfaces). Dynamic system colors + light/dark hardcoded pairs. | TSK-641 theme stage 4; sidebar panel bg custom NSColor with appearance-driven inversion; find-match blues (tuned sRGB, not pure system blue). | KEEP — palette caching + theme pattern |
| **PaneCompositingPolicy.swift** | 100 | Per-pane compositing contract (active/inactive z-ordering, opacity, hit-testing, accessibility, isolation). TSK-839 CA-commit-stall fix via compositing groups. | Pure decision logic, host-testable (no CA cost proof here — CA timing is VM measurement only). Invariant: activeZIndex > inactiveZIndex. | KEEP — contract discipline exemplary |
| **PanelLayoutStore.swift** | 232 | Observable shoulder-rail layout (edge assignment + visibility overrides + dock sizes). Persisted via UserDefaults. Narrow observation (not forwarded to DocumentModel). | TSK-1116 focus-mode apply; per-session snapshot + global default; equality-guarded writes; illegal-placement rejection via `PanelPlacement`. | KEEP — layout coordination pattern |
| **PDFFindDriver.swift** | 70 | Imperative PDF find: reconciles coordinator bag against `PDFView`, applies selection. Search via `PDFSearcher`. | TSK-1140; state déduplé (no-op if query/case unchanged); highlight all + current selection. Testable without window. | KEEP — imperative coordination pattern |
| **PDFSearcher.swift** | 78 | Pure text-search cursor over `PDFDocument`. Matches + index + next/prev/wraparound. Host-testable. | TSK-1140 (PDF find); case-insensitive default; state snapshot for find-bar summary; clear on new search. | KEEP — search-engine pattern reusable |
| **PlatformHelpers.swift** | 28 | Small AppKit helpers: Pasteboard.copy() + Finder.reveal() / openInDefaultApp(). Centralizes `NSPasteboard` / `NSWorkspace` calls. | Injected pasteboard (test seam for ReviewExport). No-thrills utility enum. | KEEP — utility consolidation sound |

---

## Module Summary — Slice Roles & Integration

This slice (files 107–158) is the **feature surface & chrome layer** of ViewerUI — the visible UI components that render content and manage user interaction. The 52 files form several functional clusters:

### **1. Content Surfaces (Large)**
- **MarkdownRenderedView, HTMLRenderedView, MediaPreviewView, ImageEditorView, HexView** — the main content panes. Render sources (HTML/markdown/images/binary). Heavy feature integration; multiple of these are 900+ LOC.

### **2. Chrome & Tooling (Small-to-Medium)**
- **Sidebars & Panels:** FeedReaderView, MarkdownOutlineSection, PackageExplorerView, NotebookCellListView
- **Status Bar:** EditorAssistChips, LSPStatusChipView, MacroRecordingChip
- **Find Bars:** MarkdownFindBar, FindMatchListView, FindMatchMinimapView, FindMinimapLayout
- **Modals & Prompts:** LSPRenamePrompt, HTMLTrustBanner, GoToPathPrompt
- **Empty States:** HostedEmptyStateView (catalog + unified render)

### **3. Monitor & Coordination (Small, High-Value)**
- **Monitors:** DoubleShiftMonitor, EscFocusMonitor — NSEvent routing to pure logic
- **Coordinators:** FeedReaderViewModel, MarkdownOutlineModel, LSPStatusChipView model, PDFFindDriver
- **Routing:** FindBarRouting (pure decision), GitChipStore (async off-main)

### **4. Utilities & Helpers**
- **Styling:** Palette (color caching), PaneCompositingPolicy (z-order invariants)
- **Layout:** DraggableSidebar (perf-conscious live width), PanelLayoutStore (shoulder-rail persistence)
- **Pure Helpers:** LineNumberRulerView (UTF-16 offset caching), MermaidBundle (static resource load)

---

## Patterns Worth Porting

### **1. Narrow Observation Discipline (Load-Bearing)**
Files repeatedly extract observables SEPARATE from DocumentModel:
- `HelpSink` / `TooltipPresenter` (hover feedback)
- `EditorAssistChips` observes `EditorCoordinator` only (not DocumentModel)
- `PanelLayoutStore`, `LSPStatusChipView.model` — narrow channels to avoid republish storms
- **Rationale:** `.onHover` fires on render thread ~60 Hz; routing through the god-object republishes the entire tree.
- **Rebuild:** Use this pattern for ANY per-frame/per-interaction feedback (hover, drag, selection).

**Files:** HelpSink, FloatingTooltip, EditorAssistChips, LSPStatusChipView, PanelLayoutStore, GitChipStore  
**Evidence:** LESSONS.md over-observation trap; PERF #1 republish storm.

### **2. Logic ↔ View Separation (Host-Testability)**
Pure host-testable logic extracted from views:
- `DoubleTapModifierDetector` (DoubleShiftMonitor) — event→state mapping, no NSEvent coupling
- `FindBarRouting.target()` — which find bar, order-sensitive, extracted
- `FindMinimapLayout.ticks()` / `nearestLine()` — geometry math, no Canvas
- `TooltipPlacement.origin()` — positioning clamping, no SwiftUI
- `LineNumberRulerView.newlineUTF16Offsets()` — static, no NSRulerView
- `PDFSearcher` — pure search state machine, no PDFView/PDFKit

**Files:** DoubleShiftMonitor, FindBarRouting, FindMinimapLayout, FloatingTooltip, LineNumberRulerView, PDFSearcher  
**Refactor Rule:** Any view embedding logic → extract to a pure value type / enum; wire it in.

### **3. Async Off-Main for Side Effects**
When AppKit side effects (subprocesses, file I/O) would block layout:
- `GitChipStore.enumerate` — async off-main via `Task.detached`; latest-wins guard (TSK-969)
- `LSPStatusChipView.binaryAvailable()` — binary probe off-main in `.task`
- TSK-734 crash: Menu content builder runs during layout; git subprocess → reentrancy crash

**Files:** GitChipStore, LSPStatusChipView, HexView (debounced search)  
**Rebuild:** For any tool/subprocess/I/O accessed from a coordinator/view, wrap in `Task.detached { ... }.value` or schedule on `.task(id:)`.

### **4. Perf-Conscious @State + Live Binding (No Republish)**
- `DraggableSidebar` — drag-time `@State private var liveWidth` separate from model's `sidebarWidth`, so 60 Hz drag doesn't republish
- `EditorAssistChips` — observes `EditorCoordinator` directly (narrow); keystroke doesn't re-render StatusBar
- `HoverCursorBalance` — `@State` for local hover-tracking; dup-push/over-pop guarded
- **Rationale:** If a 60 Hz interaction (drag, hover, keystroke) bumps `@Published`, everything observing it re-renders.

**Files:** DraggableSidebar, EditorAssistChips, HoverCursorBalance  
**Pattern:** Live interaction → local @State snapshot; commit to model only on gesture end.

### **5. Coordinator + ViewModel Patterns**
Thin adapter between model (TestCode) and view (render):
- `FeedReaderViewModel` — subscriptions + fetched-feed cache; pure `FeedReaderModel` delegates for host tests
- `MarkdownOutlineModel` — headings + filter + scroll-driven current; pure `OutlineNavigation` delegates
- `PDFFindDriver` — reconcile bag (query/case/nonce) against PDFView; apply selection
- `LSPStatusChipViewModel` — poll loop with availability cache; error toast

**Files:** FeedReaderViewModel, MarkdownOutlineModel, PDFFindDriver, LSPStatusChipView.model  
**Pattern:** ViewModel = observable state + pure-logic delegates; view = thin render layer; logic = host tests.

### **6. Compositor Occlusion Safeguard (TSK-488)**
When SwiftUI co-hosts an opaque `NSViewRepresentable`:
- `FeedReaderView` — feed sidebar & item list get `.compositingGroup().zIndex(1)` vs reader WebView `zIndex(0)`
- `PaneCompositingPolicy` — every mounted pane `.compositingGroup()` so inactive retained panes don't collapse siblings into one CA commit
- **Rationale:** NSViewRepresentable CALayer composites OVER earlier-painted SwiftUI siblings (position-dependent occlusion).

**Files:** FeedReaderView, PaneCompositingPolicy  
**Rebuild Mandate:** If a SwiftUI container hosts an `NSViewRepresentable` WebView/AppKit surface + SwiftUI siblings, give EACH a compositing group + explicit z-order.

### **7. Theme-Aware Dynamic Colors (Palette Pattern)**
- `Palette` — static `Color(nsColor:)` wrappers (cached; no per-call allocation)
- `Palette.windowBackground / textBackground` — consult `ChromeTheme.current` before system default (TSK-641 stage 4)
- `Palette.sidebarPanelBackground` — custom NSColor with appearance-driven inversion (light ≈ #f4f4f4, dark ≈ #212121)
- `Palette.findHighlightBlueColor` — tuned sRGB (not system blue); alpha layering for inactive vs current

**Files:** Palette, all views consuming it  
**Rebuild:** Centralize color palette; layer theme overrides before system fallback; cache to avoid per-draw allocations.

### **8. Debounced Async Tasks (Search, Reconcile)**
- `HexView` — search query debounced 180 ms via `searchTask` cancel-and-reschedule (TSK-986); cap at 50k matches
- `LSPStatusChipView` — 3s poll loop with Task.sleep; cancellation-safe
- **Rationale:** Typing in find field would trigger whole-buffer scan per keystroke → main-thread hang.

**Files:** HexView, LSPStatusChipView  
**Pattern:** `searchTask?.cancel(); searchTask = Task { try await Task.sleep(...); if Task.isCancelled { return } ... }`

### **9. Process-Wide Singleton + Environment Injection**
- `HelpSink.shared` — process-wide default, seeded into `EnvironmentValues` (no wiring at root)
- `TooltipPresenter.shared` — same pattern; `.tooltipRoot` coordinate space for anchor frames
- **Rationale:** Eliminates boilerplate threading through app root for every view that needs help/tooltip.

**Files:** HelpSink, FloatingTooltip, TooltipPresenter  
**Pattern:** `nonisolated(unsafe) static let shared = Type(); private struct Key: EnvironmentKey { static let defaultValue = Type.shared }`

### **10. Host-Testable Pure Geometry / Layout (Pixel-Agnostic)**
- `TooltipPlacement.origin()` — place bubble below anchor, flip above if overflow, clamp horizontal → zero SwiftUI/AppKit
- `FindMinimapLayout.ticks()` — map line→y, click y→nearest line
- `LineNumberRulerView.newlineUTF16Offsets()` — static, compiles independently
- **Rationale:** Pixel layout is testable without a live window; VM tests validate on-screen rendering.

**Files:** FloatingTooltip (TooltipPlacement), FindMinimapLayout, LineNumberRulerView  
**Rebuild:** Extract geometry to pure value types; view layer applies it.

---

## Anti-Patterns / Regrets

### **1. Large File Monoliths (HexView, ImageEditorView, MarkdownRenderedView)**
- HexView (1524 LOC): search + toolbar + highlights + click-pattern + editable state. Difficult to test in parts.
- ImageEditorView (992 LOC) + ImageEditorViewModel (1410 LOC): substantial feature, hard to decompose.
- **Lesson:** SwiftUI views balloons when mixing logic + render. Extract state machines (search, edit) to separate coordinators.
- **Rebuild:** Segment large views by responsibility; delegate operations to pure engines.

### **2. TSK-477 Retained Dead Code (LineNumberRulerView)**
- File marked ⚠️ "INTENTIONALLY RETAINED" because a prior delete broke the Source pane line numbers silently.
- Only called from `TextDisplayView.swift:416` (the single dependency).
- **Lesson:** Grep dependencies before deleting (even if "looks dead").
- **Rebuild:** Add CI checks to flag orphaned imports/calls at build time.

### **3. Over-Generalization of UI Patterns (Before TSK-1435 Consolidation)**
- Before `HostedEmptyStateView`, each tool window had open-coded "No [thing]" placeholders (feeds, HTTP, SQLite, etc.).
- TSK-1435 unified to one component + `EmptyStateCatalog`.
- **Lesson:** Repetitive "empty state" across 11+ surfaces → consolidate early.
- **Rebuild:** Spot pattern clusters (3+ sites) and extract before shipping.

### **4. Unguarded Cursor Stack Mutations (TSK-892 HoverCursorBalance)**
- Original: `if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }`
- Problem: AppKit emits repeated `onHover(true)` callbacks; unguarded push → global cursor stack grows without bound.
- Fixed by: `HoverCursorBalance` idempotent enter + over-pop guard.
- **Lesson:** Global AppKit state (cursor stack) requires defensive guards.
- **Rebuild:** Wrap any global-state mutation (cursor, pasteboard, NSEvent monitor) in balanced-state machines.

### **5. Late Compositor Occlusion Discovery (TSK-488 LESSONS.md)**
- Feed reader initially blanked SwiftUI sidebar when WebView reader pane added (position-dependent occlusion).
- Cause: WebView CALayer composited OVER earlier-painted SwiftUI siblings.
- Fix: `.compositingGroup()` on SwiftUI sibling + z-order.
- **Lesson:** NSViewRepresentable ↔ SwiftUI co-hosting is a footgun (invisible regressions).
- **Rebuild:** Enforce `.compositingGroup()` + explicit z-order rule at code-review time for every NSViewRepresentable container.

### **6. Resource Name Mismatch (TSK-650 MermaidBundle)**
- Code loaded "mermaid" → file is "mermaid.min.js" → silently returned nil → fallback "" → mermaid degraded to raw text.
- Fix: Guarded by `MermaidVendorTests` (non-empty check).
- **Lesson:** Resource bundling silent failures; no compiler check.
- **Rebuild:** Add bundle-resource integrity tests (checksum/size guards); CI snapshot on known resources.

---

## Gotchas & Surprises

### **1. SwiftUI Menu Content Evaluation (TSK-734 Crash)**
- SwiftUI evaluates `Menu { ... }` content **during layout**, not on click.
- `GitChipStore` wired a subprocess call there → git subprocess on layout thread → AppKit reentrancy exception → SIGTRAP.
- **Fix:** Off-main cache (load async via `.task(id:)`).
- **Implication:** Any `Menu` in ViewerUI must NOT spawn side effects in its builder; pre-compute + cache.

### **2. .task(id:) Anchor Requirement (LSPStatusChipView)**
- `.task(id: currentURL)` only fires if the view is PRESENT in the tree (not a conditionally-empty Group).
- Chip is conditionally shown when `vm.chip != nil`; if the condition is false on first mount, `.task` never fires.
- **Fix:** Render a zero-size `Color.clear` when chip is nil so `.task` has an anchor.
- **Implication:** When using `.task(id:)` on a conditionally-rendered view, ensure something is always rendered (even if hidden).

### **3. UserDefaults Persistence & Per-Session State (PanelLayoutStore)**
- Per-session panel layout is stored in `SessionSnapshot`, NOT UserDefaults.
- UserDefaults holds the app-wide DEFAULT (for new sessions).
- **Gotcha:** Applying a session layout must NOT write to UserDefaults; otherwise a single session clobbers the global default.
- **Pattern:** `.apply(snapshot)` mutates `@Published` (fires observers) but skips the UserDefaults write.

### **4. Zoom Scaling Cascades (FileIconView, FloatingTooltip, MarkdownFindBar)**
- Many components accept `scale: CGFloat` or `uiSize: (CGFloat) -> CGFloat` so they grow with `DocumentModel.zoom`.
- **Gotcha:** Callers must also scale the `.frame(width:height:)` they wrap the view in; omitting the frame results in clipping.
- **Pattern:** `.frame(width: FileIconView.side(for: .tree, scale: model.zoom), height: ...)`

### **5. NSAttributedString TextKit Lazy Layout (LineNumberRulerView, HexView)**
- `NSAttributedString` + `NSTextView` lazy-lays out only visible glyphs (scroll perf trick from LESSONS.md).
- Recomputing line numbers on every scroll would be O(N) per scroll tick.
- **Fix:** Binary-search cached newline offsets (O(log N)) + binary-search glyph range from layout manager.
- **Lesson:** TextKit compositing is fragile; minimize layout passes.

### **6. Multi-Pane Coordination (EscFocusMonitor, FindBarRouting, Editor Registry)**
- With MountedPanesLRU, multiple `WKWebView`s are mounted simultaneously; Esc focus routing must check ALL editors, not just current().
- `EscFocusMonitor.firstResponderIsDocument()` checks `CodeMirrorEditorRegistry.shared.liveWebViews` (all mounted panes).
- **Gotcha:** `current()` can return an inactive pane under LRU; a focused-pane Esc would be mis-classified as tool-surface.
- **Pattern:** Registry queries (.liveWebViews) before single-pane assumptions.

---

## Rebuild Notes — Fresh Implementation Strategy

### **For New Markdown Editor / WebUI Variant**

#### **1. Narrow Observation (Day 1)**
Establish the anti-pattern early:
- Create `FeatureObservable: ObservableObject` (separate from `DocumentModel`) for EVERY feature surface that reacts on-screen (find, outline, LSP status, help, tooltip).
- No forwarding from feature observable → DocumentModel.
- Rule: Only the feature's own view observes it.
- Example: `@MainActor public final class FindCoordinator: ObservableObject { @Published var query: String; ... }` — NOT on DocumentModel.

#### **2. Compositor Safety (UI Foundations)**
When designing pane architecture:
- If a pane holds an opaque rendering surface (WKWebView, NSCode, PDFView), give EACH pane its OWN compositing group.
- Test this: render two panes side-by-side, verify neither occludes the other.
- Use `PaneCompositingPolicy` as a contract guard (z-order + isolation + opacity).

#### **3. Coordinators as Pure Logic → Render Boundary**
For every feature (find, outline, LSP, feeds, HTTP, etc.):
- Layer 1 (Host tests): Pure engine (`FindEngine.search()`, `OutlineNavigation.filter()`, `PDFSearcher`).
- Layer 2 (Host tests): Observable coordinator (`FindCoordinator`, `MarkdownOutlineModel`, `LSPStatusChipViewModel`).
- Layer 3 (VM tests): SwiftUI view (thin, data-driven).

#### **4. Resource Loading & Caching**
- Centralize all static resources (Mermaid, stylesheets, fonts) in bundle-load wrappers (like `MermaidBundle`).
- Add integrity tests (size / non-empty guards).
- Cache in `static let` to avoid repeated file I/O.

#### **5. Async Side Effects & Scheduling**
- Any subprocess, file I/O, or network call off-main via `Task.detached` / `.task(id:)`.
- Debounce high-frequency events (search, keystroke, scroll) via cancel-and-reschedule (180 ms threshold typical).
- Model latest-requested ID to guard out-of-order completions (TSK-969 pattern).

#### **6. Geometry & Placement (Pixel-Agnostic)**
- Extract all layout math (positioning, clamping, hit-testing) to pure value types.
- Test independently of SwiftUI / rendering.
- Example: `TooltipPlacement.origin(anchor:bubbleSize:container:)` → CGPoint (testable, reusable).

#### **7. Zoom Scaling Centralization**
- All UI dimensions parameterized by `uiSize: (CGFloat) -> CGFloat = { $0 * model.zoom }`.
- Pass through props (not read from model) so views stay decoupled.
- Apply scale to `.frame()` at call site.

#### **8. Palette & Theme System (Day 1)**
- Single `Palette` enum for all `Color(nsColor:)` wrappers (cache to avoid per-draw allocations).
- Layer theme overrides (ChromeTheme) before system defaults.
- Hardcode light/dark pairs for custom colors (sidebar panel, find highlights).

#### **9. Accessibility from Day 1**
- Every interactive control gets `.accessibilityIdentifier("mdv.feature.element")`.
- Every button gets `.accessibilityLabel("action name")` + `.help("tooltip text")`.
- Announcers for state transitions (find results, save completion).
- Test via AX tree (not pixels).

#### **10. Empty State Catalog (Usability, Day 1)**
- For EVERY tool window / docked panel, define an `EmptyStateSpec`.
- Centralize copy in `EmptyStateCatalog` (single source of truth).
- Render via `HostedEmptyStateView`.
- Host test that every spec is non-empty.

---

## Summary — Slice Highlights

| Highlight | Files | Takeaway |
|-----------|-------|----------|
| **Observation Discipline** | HelpSink, EditorAssistChips, PanelLayoutStore, LSPStatusChipView | Narrow observables ONLY for per-frame feedback; never forward to god-object. |
| **Logic ↔ View Separation** | DoubleShiftMonitor, FindBarRouting, TooltipPlacement, PDFSearcher, LineNumberRulerView | Extract pure logic to value types; make host-testable; wire in views. |
| **Async Off-Main** | GitChipStore, LSPStatusChipView, HexView | Any side effect (subprocess, I/O, search) → off-main with cancel-reschedule. |
| **Compositor Safety** | FeedReaderView, PaneCompositingPolicy | NSViewRepresentable + SwiftUI → `.compositingGroup()` + z-order on every sibling. |
| **Coordinator + ViewModel** | FeedReaderViewModel, MarkdownOutlineModel, PDFFindDriver | Thin adapter (observable state) + pure logic delegates (host tests). |
| **Palette & Theme** | Palette | Centralize `Color(nsColor:)` wrappers; theme overrides before system defaults. |
| **Process Singletons** | HelpSink, TooltipPresenter | Shared instance seeded into environment → zero wiring at root. |
| **Zoom Scaling** | FileIconView, FloatingTooltip, MarkdownFindBar | Parameterize all dimensions by `uiSize`; pass through props. |
| **Gotchas** | Menu content (TSK-734), .task anchor, UserDefaults isolation, NSAttributedString perf, multi-pane routing | Avoid side effects in Menu builders; anchor .task on real views; guard per-session state; leverage TextKit lazy layout; check all mounted surfaces. |

---

## File Count & Statistics

- **Total files:** 52
- **Total LOC:** ~13,223
- **Median LOC:** ~100 (small focused components)
- **Large files (>500 LOC):** 9 (HexView, ImageEditor*, Markdown*, Media*, Metadata, MarkdownFind, FloatingTooltip, MetadataPanel)
- **Tiny files (<50 LOC):** 8 (Zoom, MacroRecordingChip, MountProbe, MermaidBundle, PlatformHelpers, etc.)

This slice is feature-rich, well-layered, and demonstrates production-grade refactoring discipline (logic extraction, pattern consolidation, perf instrumentation). The rebuild should adopt the narrow-observation, compositor-safety, and logic-separation patterns as foundational.
