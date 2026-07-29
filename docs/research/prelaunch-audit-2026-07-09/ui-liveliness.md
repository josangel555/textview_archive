# Pre-launch product review — UI responsiveness / interactivity feel

**Dimension:** UI liveliness — hover highlight, click/pressed feedback, `NSCursor`
pointer changes, tooltips, subtle transitions.
**Owner lens:** "The UI feels DEAD."
**Reviewer:** automated static review of `Sources/ViewerUI/` (read-only).
**Date:** 2026-07-09.

---

## Executive summary

The complaint is **half-true, and the half that's true has a cheap fix.**

The app already ships **good, well-engineered liveliness infrastructure** — a shared
`IconHoverButtonStyle` / `RowHoverButtonStyle` (hover tint + pressed fill + ≤2% scale +
balanced pointing-hand cursor), a `HoverCursorBalance` value type that fixes the
global-cursor-stack churn, `MotionGate` for Reduce-Motion, and a `helpInfo` tooltip model.
The **primary chrome that uses them feels alive**: the tab strip (`TabBar`), the sidebar
file tree (`FileRowView`), the toolbar lens icons (`ContentToolbar`), the command palette,
and cross-search all have hover, cursor, tooltip, and press feedback.

The problem is **adoption, not capability.** These affordances were retrofitted onto the
high-traffic surfaces and then **never propagated to the long tail.** Concretely:

- **84** `.buttonStyle(.plain)` / `PlainButtonStyle` sites exist; the shared hover styles
  are adopted in only ~13 files. **33 files** contain plain buttons with **zero** hover,
  cursor, or press treatment of any kind.
- Two **primary navigation surfaces** — the Markdown outline and the LSP symbol outline —
  render their rows with a bare `.onTapGesture` and **no** hover tint, **no** pointing-hand
  cursor, **no** pressed state, and (for LSP) **no** current-row highlight. They are
  literally inert text that happens to respond to a click. This is the "dead" feeling in its
  purest form.
- The **view-mode segmented control** (the Editor / Preview / … selector — one of the most
  visible controls in the app) gives **no hover feedback on unselected segments**.
- App-wide there are only **~13** `withAnimation` sites across ~71K LOC of UI. Most state
  transitions (panel show/hide, view-mode switch, section expand/collapse) **snap** rather
  than ease, which reads as abrupt/cheap.
- Tooltip coverage is partial: **~498** `Button` sites vs **~203** `helpInfo`/`.help`
  attachments — well under half of buttons expose a hover tooltip, and many icon-only
  buttons (which most need one) have none.

Because the infrastructure already exists and is proven, the remediation is overwhelmingly
**"apply the existing style"** — low-risk, mechanical, and high perceived-quality payoff. No
finding here is a ship-blocker (no data loss / crash / broken flow), but the **cumulative**
effect is exactly the deadness the owner is reacting to, and it is very cheap to fix before
launch.

---

## Methodology

- **What I examined:** `Sources/ViewerUI/` (288 Swift files, ~71K LOC), the SwiftUI/AppKit
  presentation layer. Static analysis only (per constraints — no window-opening tests).
- **How:** `rg`/`grep` census of `onHover`, `NSCursor`, `.help(`/`helpInfo`,
  `buttonStyle`, `.plain`/`PlainButtonStyle`, `RowHoverButtonStyle`, `IconHoverButtonStyle`,
  `hoverCursor`, `onTapGesture`, `withAnimation`, `.transition`, `.disabled`; then `Read` of
  the foundational style files and every surface a finding cites.
- **Cross-referenced set difference:** files that use `.plain` buttons **minus** files that
  use any hover/cursor treatment, to isolate the fully-inert surfaces (33 files).
- **Files read in full or in relevant part:** `RowHoverButtonStyle.swift`,
  `HoverCursorBalance.swift`, `TabBar.swift`, `SidebarView.swift` (FileRowView region),
  `ContentToolbar.swift` (segmented control), `MarkdownOutlineSection.swift`,
  `LSP/LSPOutlineSection.swift`, `StatusBar.swift` (breadcrumb), `Git/DiffView.swift`,
  `RecentlyOpenedSection.swift`.
- **Not run:** any live/VM/UI test (constraint). All findings are verifiable by reading the
  cited file:line and by the census commands above.

Census results (reproducible):

| Metric | Count |
|---|---|
| `.buttonStyle(.plain)` / `PlainButtonStyle` / `BorderlessButtonStyle` sites | 84 |
| Files using a shared hover style or `hoverCursor`/`onHover` | ~22 (only ~13 use a shared style) |
| Files with `.plain` buttons AND **zero** hover/cursor treatment | **33** |
| `Button` sites | ~498 |
| `helpInfo` / `.help(` attachments | ~203 |
| `withAnimation` sites (whole layer) | ~13 |
| `.transition(` sites (whole layer) | 5 |
| Files touching `NSCursor` | 9 |

---

## Findings

### F1 — Primary navigation rows are fully inert (`.onTapGesture`, no hover / cursor / selection)
- **Severity:** P1
- **Files:**
  - `Sources/ViewerUI/MarkdownOutlineSection.swift:76-115` (row `MarkdownOutlineRow`, tap at
    `:84`) — hover shows nothing; only the *current* row (`:111`) gets a background; no
    pointing-hand cursor; no pressed feedback.
  - `Sources/ViewerUI/LSP/LSPOutlineSection.swift:182-220` (row `SymbolRow`, tap at `:185`) —
    **worse:** no hover tint, no cursor, no pressed state, **and no current-symbol highlight
    at all**. It is static text with a tap handler.
- **Evidence:** both rows are built as plain `HStack`s wired with `.onTapGesture` (not
  `Button`), so they can't even inherit `RowHoverButtonStyle`. `MarkdownOutlineRow.body` sets
  `.background(isCurrent ? accent.opacity(0.12) : .clear)` and nothing on hover. `SymbolRow`
  ends at `.contentShape(Rectangle())` with no background/hover/cursor at all.
- **Impact:** The document outline and the code symbol outline are core "jump around the
  file" surfaces. That they don't light up on hover or show a pointing-hand is the single
  most on-the-nose instance of "the UI feels dead" — the user cannot tell the rows are
  clickable until they click.
- **Suggested fix:** Add `.hoverCursor(isHovering: $isHovering)` (already in-tree) + a
  hover-driven `rowBackground` (mirror `FileRowView`'s pattern, `SidebarView.swift:1554-1593`).
  For `SymbolRow`, also add a current-symbol highlight. Prefer converting the tap to a
  `Button { … }.buttonStyle(RowHoverButtonStyle())` so hover/press/cursor come for free.
- **Fix size:** M · **Fix risk:** safe

### F2 — Broad adoption gap: 33 files of plain buttons with no hover/press/cursor feedback
- **Severity:** P1
- **Files (representative, all verified to contain `.buttonStyle(.plain)` with no hover
  treatment):** `Git/DiffView.swift`, `Git/GitLogTab.swift`, `Git/GitPanelView.swift`,
  `Git/GitWorktreesTab.swift`, `Git/GitStashTab.swift`, `Git/GitRemotesTab.swift`,
  `Git/GitPanelSection.swift`, `SettingsView.swift`, `KeyboardShortcutsView.swift`,
  `Review/CommentCards.swift`, `Review/ReviewIndexTab.swift`,
  `ClaudeMonitor/ClaudeMonitorView.swift`, `LSP/LSPNavigationPanel.swift`,
  `Observability/LogsView.swift`, `PluginSidebarSections.swift`, `SpreadsheetView.swift`,
  `FeedReaderView.swift`, `AnnotationsView.swift`, `ToastOverlayView.swift`,
  `StatusBar.swift`, `RecentlyOpenedSection.swift`, `MarkdownOutlineSection.swift` (headers),
  `LSP/LSPOutlineSection.swift` (headers), `StructuralSearchView.swift`,
  `TerminalCommandPaletteView.swift`, `CodeActionPicker.swift`, `EditorAssistChips.swift`,
  `FindMatchListView.swift`, `SecretWarningBanner.swift`, `SourceGutterView.swift`,
  `ToolResultsPanel.swift`, `LSPStatusChipView.swift`, `Canvas/CanvasSidePanels.swift`.
- **Evidence:** set difference of `rg -l 'buttonStyle(.plain)|PlainButtonStyle'` **minus**
  `rg -l 'RowHoverButtonStyle|IconHoverButtonStyle|hoverCursor(|onHover'` → 33 files. The
  shared styles' own header comments (`RowHoverButtonStyle.swift:4-20`, `:112-131`) state
  they were built precisely to replace these inert `.plain` sites — but the migration
  stopped after the top surfaces.
- **Impact:** Whole feature panels (Git, Review, Settings, Claude Monitor, LSP nav, plugins,
  spreadsheet, feed reader) are visually inert on hover. A user who came from the alive tab
  strip / file tree perceives the rest of the app as a lower-quality, unresponsive shell —
  the inconsistency itself amplifies the "dead" read.
- **Suggested fix:** Sweep: replace `.buttonStyle(.plain)` with `RowHoverButtonStyle()` for
  list rows and `IconHoverButtonStyle()` for icon/chip controls. Both are drop-in and
  already handle cursor balance + Reduce-Motion. This is the highest-leverage single change
  for the owner's complaint.
- **Fix size:** L (many sites, but each is trivial) · **Fix risk:** safe

### F3 — View-mode segmented control: no hover feedback on unselected segments
- **Severity:** P2
- **File:** `Sources/ViewerUI/ContentToolbar.swift:272-301` (`segment(_:selected:)`).
- **Evidence:** the label's `.background(selected ? accent.opacity(0.18) : .clear)` (`:295`)
  fills only the selected segment; the button carries `.buttonStyle(.plain)` (`:300`) with no
  hover state. Hovering "Editor" / "Preview" / etc. when they're not selected produces zero
  visual change.
- **Impact:** This segmented control is one of the most-used, most-visible controls in the
  window. A native macOS segmented control highlights on hover; this one doesn't, so the
  primary mode switcher reads as static.
- **Suggested fix:** Add a hover fill on unselected segments (e.g. `IconHoverButtonStyle`
  with `isSelected: selected`, which already deepens an accent-tinted resting fill on hover),
  or an inline `@State private var hovering` → `Color.primary.opacity(0.06)`.
- **Fix size:** S · **Fix risk:** safe

### F4 — StatusBar path breadcrumb segments read as static text
- **Severity:** P2
- **File:** `Sources/ViewerUI/StatusBar.swift:150-176` (`pathBreadcrumb`, button at `:165`).
- **Evidence:** each clickable segment is `Button(seg.name) { model.revealInSidebar(...) }`
  with `.buttonStyle(.plain)` and no hover/cursor. It looks identical to the non-clickable
  `›` separators around it.
- **Impact:** A path breadcrumb is a discoverability affordance — the user should feel that
  each segment is clickable. Without hover underline/tint or a pointing-hand cursor, the
  interaction is invisible.
- **Suggested fix:** `.hoverCursor()` + a hover underline or `.foregroundStyle` shift on the
  hovered segment.
- **Fix size:** S · **Fix risk:** safe

### F5 — Git DiffView find-nav / clear buttons inert (inconsistent with the main find bar)
- **Severity:** P2
- **File:** `Sources/ViewerUI/Git/DiffView.swift:144-166` (prev `:149`, next `:157`,
  clear `:165`).
- **Evidence:** three icon buttons (`chevron.up`, `chevron.down`, `xmark.circle.fill`) all
  `.buttonStyle(.plain)`, no hover/cursor. The find bar in the main editor
  (`MarkdownFindBar`) *does* use `IconHoverButtonStyle`, so this is an inconsistency the user
  can feel when moving between the two find UIs.
- **Impact:** Inconsistent, inert secondary chrome in a feature panel.
- **Suggested fix:** `IconHoverButtonStyle()`.
- **Fix size:** S · **Fix risk:** safe

### F6 — Very few transitions app-wide; most state changes snap
- **Severity:** P2
- **Files (evidence of scarcity):** only ~13 `withAnimation` and 5 `.transition(` sites in
  the whole `Sources/ViewerUI/` layer (census above). Present ones are good and localized
  (`TabBar.swift:248` scroll-to-selected, `SidebarView.swift:827,959`,
  `MarkdownFindBar.swift:275`, `CommandPaletteView` via `MotionGate`).
- **Impact:** Panel show/hide, right-pane split appearance, section expand/collapse, and
  view-mode switches mostly toggle instantly. Instant hard cuts read as abrupt and "cheap"
  next to a native macOS app's easing. This is a subtler contributor to the "dead" feel than
  hover, but real.
- **Suggested fix:** Gate a handful of high-visibility structural changes (sidebar
  collapse, panel/split show-hide, section expand) through `withAnimation(MotionGate.animation(
  .easeInOut(duration: 0.15), reduceMotion:))` — the Reduce-Motion helper already exists so
  this stays accessible. Do **not** blanket-animate; pick the 5–8 changes the user watches.
- **Fix size:** M · **Fix risk:** careful (over-animating can feel worse; keep it subtle and
  respect Reduce-Motion, which the codebase already supports)

### F7 — Tooltip coverage is partial (<~40% of buttons)
- **Severity:** P3
- **Evidence:** ~498 `Button` sites vs ~203 `helpInfo`/`.help(` attachments. Icon-only
  controls — the ones most in need of a tooltip because their meaning isn't spelled out —
  are frequently bare (e.g. the Git/DiffView find buttons in F5, LSP nav rows, plugin
  section chevrons). The `helpInfo` model (`TabBar`, `ContentToolbar` use it well) is the
  right vehicle; it just isn't applied broadly.
- **Impact:** Hovering an unlabeled icon and getting nothing is both a discoverability gap
  and part of the "unresponsive" perception (a native app surfaces a tooltip on hover-dwell).
- **Suggested fix:** Add `helpInfo(title:description:)` to icon-only buttons as part of the
  F2 sweep — it also feeds the status bar + VoiceOver from one source, so the payoff is
  multi-tier.
- **Fix size:** M · **Fix risk:** safe

### F8 — Section-header expand/collapse buttons are inert (inconsistent with the FILES header)
- **Severity:** P3
- **Files:** `Sources/ViewerUI/MarkdownOutlineSection.swift:38-59`,
  `Sources/ViewerUI/LSP/LSPOutlineSection.swift:150-170`,
  `Sources/ViewerUI/RecentlyOpenedSection.swift:40-51`.
- **Evidence:** each collapsible section header is a `Button { isExpanded.toggle() }` with
  `.buttonStyle(.plain)` and no hover feedback. (`SidebarView`'s FILES header, by contrast,
  adopted `.hoverCursor(isHovering: $filesHeaderHovering)` at `:849` — so this is an
  inconsistency, not a capability gap.)
- **Impact:** Sidebar section headers — clicked constantly — don't acknowledge hover, so the
  collapse affordance feels dead and slightly uncertain.
- **Suggested fix:** `.hoverCursor()` + a faint header hover tint, matching the FILES header.
- **Fix size:** S · **Fix risk:** safe

---

## Positive observations

- **The core liveliness infrastructure is genuinely good and reusable:**
  - `RowHoverButtonStyle` + `IconHoverButtonStyle` (`RowHoverButtonStyle.swift`) — hover
    tint, pressed fill, ≤2% scale, Reduce-Motion-gated animation, balanced pointing-hand
    cursor, selected-state accent tint. This is the right design.
  - `HoverCursorBalance` (`HoverCursorBalance.swift`) — a host-testable value type that fixes
    the process-global `NSCursor` push/pop churn (TSK-892), the exact bug that was making the
    file tree feel "laggy." Careful, correct engineering.
  - `MotionGate` — a clean Reduce-Motion gate so animations stay accessible.
  - `helpInfo` — a unified tooltip / status-bar-description / VoiceOver model from one source.
- **The highest-traffic surfaces already feel alive:** `TabBar` (hover background, fade-in
  close button with eased opacity, dirty/disk/split badges, tooltips on every glyph),
  `FileRowView` (hover tint + balanced pointing-hand cursor), the toolbar lens icons and
  format menu (`IconHoverButtonStyle` + `helpInfo`), the command palette, and cross-search.
- **Cursor-stack discipline is documented and enforced** — the balance guard is factored,
  commented, and unit-tested, so fixes that adopt it inherit correctness for free.
- **Reduce-Motion is respected** where animation exists — accessibility is not an
  afterthought.

Net: this is a codebase with the *right tools already built* and a *stalled rollout*, not
one that needs new infrastructure.

---

## Coverage gaps (what I did NOT examine)

- **No live/VM/pixel verification.** All findings are static (per task constraints). Whether
  a given hover tint is *perceptible* on-screen (contrast against its background — cf. the
  CLAUDE.md warning about `selectedContentBackgroundColor` going grey) was **not** validated
  with real pixels. The recommended fixes should be VM-confirmed per the render-confirm
  directive.
- **CodeMirror / Mermaid / Canvas web surfaces.** The in-WebView editors and renderers
  (CM6, Mermaid, Canvas JS/CSS in `Resources/`) own their own hover/cursor behavior in
  JavaScript/CSS; I reviewed only the Swift host wiring, not the bundled web assets' liveliness.
- **Terminal surface.** `Terminal/TerminalView.swift` uses `NSCursor`/`onHover` but its
  interactive feel (selection, link hover) wasn't deeply audited.
- **AppKit `NSViewRepresentable` internals** (CSV table, hex view, spreadsheet grid cell
  hover) — I confirmed `CSVTableView` touches `NSCursor` but did not audit per-cell hover
  quality.
- **`.disabled` visual treatment.** 78 `.disabled(` sites exist; I did not verify each
  renders an obviously-dimmed state vs. silently-inert (a disabled button that looks enabled
  is its own "dead" trap) — worth a follow-up pass.
- **Menus / context menus.** Native menu hover is OS-provided; not assessed.
- **Focus rings / keyboard-driven hover-equivalents.** I focused on pointer affordances; the
  keyboard-focus visibility story (which also affects "responsiveness feel") is a separate
  audit.
- **Timing/latency of feedback** (does hover light up within a frame under load) — cannot be
  measured statically.
