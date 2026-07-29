# Pre-launch Product Review — Accessibility, Tooltips, Keyboard Navigation (v2)

> Note: a prior `accessibility.md` already existed in this directory; per safe-write
> policy this independent pass is written as a sibling `.v2.md` rather than
> overwriting it.

**Dimension:** AX identifiers/labels coverage, VoiceOver usability, full-keyboard
operation & focus order, `.help` tooltip coverage, contrast.
**Reviewer:** automated code audit (static analysis, read-only).
**Date:** 2026-07-09.
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`

---

## Executive summary

The app has a **genuinely above-average accessibility posture for a native macOS
app of this scale**, but it is uneven and carries one systemic hazard: the team has
invested heavily in `accessibilityIdentifier` (99 occurrences) to feed its own
AX-automation driver, and that investment can be mistaken for *user-facing*
accessibility. **`accessibilityIdentifier` is invisible to VoiceOver** — it is a
test/automation handle only. Actual VoiceOver-visible naming (`accessibilityLabel`,
30 occurrences) is far sparser, and it is precisely the icon-only controls (no
visible text) that most often carry an identifier but no label.

The strongest surfaces (tab strip, file rows, CSV table, hex view, the `helpInfo`
tooltip system) are well-labeled. The gaps cluster in secondary editors (image
editor shape tools, HTTP client, terminal favorites, snippet manager, toasts) and
in **system-accessibility accommodations the app does not consult at all**:
`accessibilityReduceTransparency`, `accessibilityShouldIncreaseContrast`, and
`accessibilityDifferentiateWithoutColor` appear **zero times** in the codebase,
despite pervasive translucency (200+ material/blur/opacity sites), heavy use of
low-contrast `.secondary`/`.tertiary`/`.quaternary` foregrounds (113 sites), and
color-only status signaling (git dirty dots, diff add/remove, LSP severity).

No findings rise to P0/P1 (nothing blocks a sighted keyboard/pointer user; core
flows work). Findings are P2 (quality/table-stakes AX) and P3 (polish). The single
most valuable fix is to stop treating `accessibilityIdentifier` as coverage and
label the icon-only controls, followed by adding the three system-accommodation
environment reads.

**Positive callout worth preserving:** full-keyboard tab navigation *does* exist
(`⌘⇧[` / `⌘⇧]`, wired in the AppKit menu, `Sources/MarkdownViewer/main.swift:1528`);
markdown image `alt` text *is* preserved through the Rust renderer
(`rust-core/crates/core/src/markdown.rs:380`); `reduceMotion` *is* honored in the
animation-heavy surfaces via a shared `MotionGate`.

---

## Methodology

**What I examined (static, read-only):**

- Counted and located every accessibility API across `Sources/`:
  `accessibilityLabel` (30), `accessibilityIdentifier` (99), `accessibilityHint`
  (1 direct + via `helpInfo`), `accessibilityHidden` (15), `accessibilityElement`
  (15), traits/value/element-contain family (~40), `.help(` (51) and the custom
  `.helpInfo(` tooltip modifier (75).
- Wrote a Python scan over all 288 `Sources/ViewerUI/*.swift` files to isolate
  **icon-only buttons** (`Button { … } label: { Image(systemName:…) }` with no
  `Label`/`Text` and no nearby `accessibilityLabel`/`.help`/`.helpInfo`), then
  hand-verified the survivors against wider context windows to drop false positives.
- Read the tooltip system (`FloatingTooltip.swift`) to confirm what `helpInfo`
  wires (it sets `.help` + `accessibilityLabel` + `accessibilityHint`).
- Inspected the primary content surfaces: CodeMirror editor host
  (`CodeMirrorEditorView.swift`), rendered markdown/HTML preview WebViews, hex
  view, CSV table, sidebar file tree (`SidebarView.swift`/`FileRowView`), tab strip
  (`TabBar.swift`).
- Checked keyboard operation: SwiftUI `keyboardShortcut` (51 sites) *and* the
  AppKit menu-bar shortcuts in `main.swift` (tab nav, move tab, etc.).
- Checked system-accommodation reads and color-only signaling in git/diff/LSP views.
- Verified the Rust markdown renderer preserves `alt` text.

**What I did NOT do:** run VoiceOver live; run any window-opening UI test; measure
actual contrast ratios against WCAG thresholds; exhaustively read all 288 views;
audit the web-embedded Canvas/Mermaid/CodeMirror internals for ARIA.

---

## Findings

### F1 — Icon-only controls carry automation identifiers but no VoiceOver name
**Severity: P2** · **Fix size: S** · **Fix risk: safe**

**Evidence.** These icon-only buttons expose only `accessibilityIdentifier`
(automation handle, *not* read by VoiceOver) or nothing, with a bare
`Image(systemName:)` label (no text). VoiceOver announces them as an unnamed
"button":

- `Sources/ViewerUI/HTTPClientView.swift:149` — add-header `plus` (id
  `mdv.http.addHeader`, no label).
- `Sources/ViewerUI/HTTPClientView.swift:165` — remove-header `minus.circle`.
- `Sources/ViewerUI/HTTPClientView.swift:157` — `Toggle("", isOn:)` with
  `.labelsHidden()` — an **unnamed toggle** for enable/disable header.
- `Sources/ViewerUI/ImageEditorView.swift:562,566,570,574,578` — the Draw shape
  buttons (`rectangle`/`circle`/`line.diagonal`/`arrow.up.right`/`trash`) use bare
  `Image(systemName:)` + identifier only — **inconsistent** with the Geometry
  buttons directly above (lines 478-532) which correctly use
  `Label("Rotate", systemImage:)`.
- `Sources/ViewerUI/ToastOverlayView.swift:84` — toast dismiss `xmark`
  (id `mdv.toast.dismiss`, no label).
- `Sources/ViewerUI/TerminalFavoritesEditor.swift:76,81,86` — move up/down/delete.
- `Sources/ViewerUI/SnippetManagerView.swift:127` — clear `xmark.circle.fill`.
- `Sources/ViewerUI/Observability/LogsView.swift:84` — clear `xmark.circle.fill`.
- `Sources/ViewerUI/TabBar.swift:464` — the per-tab **close** button (`xmark`) has
  no `accessibilityLabel`, though the neighboring dirty/disk/bookmark indicators
  *are* labeled.

**Impact.** VoiceOver users cannot identify these controls; the header toggle and
the tab close are actionable-but-unnamed. Because the app leans on
`accessibilityIdentifier` so heavily, the gap is easy to miss (the identifier
*looks* like coverage in a grep).

**Suggested fix.** Add `.accessibilityLabel("…")` — or better, migrate to the
existing `.helpInfo(title:)` modifier (label + hint + tooltip in one call;
`FloatingTooltip.swift:388`). Prefer `Label("Action", systemImage:)` +
`.labelStyle(.iconOnly)` so the name travels with the control.

---

### F2 — No support for Increase Contrast / Reduce Transparency / Differentiate Without Color
**Severity: P2** · **Fix size: M** · **Fix risk: careful**

**Evidence.** The three system-accessibility environment values are consulted
**zero times** in `Sources/`, while:

- **Translucency is pervasive:** 200+ sites of `Material`/`.blur(`/`.opacity(` in
  `Sources/ViewerUI`. Floating tooltip + toast overlays composite over material.
  A user with "Reduce transparency" enabled gets none of it.
- **Color-only status signaling:** git status, diff add/remove, and LSP severity
  are conveyed by color with no shape/text differentiator, e.g.
  `Sources/ViewerUI/Git/DiffView.swift` (9 `.red/.green/...`),
  `Sources/ViewerUI/LSP/LSPProblemsPanel.swift` (5),
  `Sources/ViewerUI/LSP/LSPDiagnosticsView.swift` (3). Tab dirty dot
  (`TabBar.swift:420`, accent) vs disk dot (`:434`, red) differ only by hue +
  tooltip (the tooltip text partially mitigates).

**Impact.** Users who enable macOS's contrast/transparency/color accommodations get
no adaptation; low-vision and color-blind users lose status information.

**Suggested fix.** Add `@Environment(\.accessibilityReduceTransparency)`,
`\.colorSchemeContrast` (or `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`),
and `\.accessibilityDifferentiateWithoutColor`; swap materials for solid fills and
boost contrast when set; add a glyph/shape (not just hue) to git/diff/LSP status.
Stage it (transparency first, color second).

---

### F3 — Pervasive low-contrast secondary/tertiary/quaternary text, no high-contrast path
**Severity: P2** · **Fix size: M** · **Fix risk: safe**

**Evidence.** 113 `.tertiary`/`.quaternary` foreground sites and 99 `.opacity(0.0–0.4)`
sites across `Sources/ViewerUI`. Combined with F2's missing `increaseContrast` read,
text like non-selected tab titles (`TabBar.swift:413`, `.secondary`), the
command-palette glyph (`ContentToolbar.swift:153`, `.secondary`), and countless
captions render at system-secondary contrast with no lever to raise it. Many are
further shrunk by the custom `uiSize()` scaling.

**Impact.** Sub-WCAG contrast for low-vision users; no remediation path.

**Suggested fix.** When `accessibilityShouldIncreaseContrast` is on, promote
`.tertiary`/`.quaternary` → `.secondary`/`.primary` and clamp minimum opacity. Audit
the smallest-font + lowest-contrast combinations first. (Exact ratios not measured —
see coverage gaps.)

---

### F4 — Sidebar file tree is a `LazyVStack`+`ForEach`, not a native `List`/`OutlineGroup`
**Severity: P2** · **Fix size: L** · **Fix risk: careful**

**Evidence.** The file tree renders rows as a custom `LazyVStack { ForEach { FileRowView } }`
(`Sources/ViewerUI/SidebarView.swift:640,648`), each row flattened with
`.accessibilityElement(children: .ignore)` + `.accessibilityAddTraits(.isButton)`
(`:1563-1565`). The per-row label is actually **good** — it announces folder
expanded/collapsed, name, git status, and currently-open
(`SidebarView.swift:1669-1682`).

**Impact.** Not being a `List`/`OutlineGroup`, VoiceOver gets a flat sequence of
buttons with **no tree semantics**: no "row N of M", no hierarchical level, no native
`AXOutline`/disclosure role. For a file browser (navigation is the primary job),
losing depth/position cues degrades VoiceOver navigation of nested folders.

**Suggested fix.** Either move to `OutlineGroup`/`List` (large; the code at
`SidebarView.swift:626-640` explains LazyVStack was chosen for perf — a real
trade-off), or inject level/position into the label (e.g. "level 3, item 4 of 12")
and add disclosure traits. Validate scroll perf after.

---

### F5 — CodeMirror editor & rendered-preview WebViews expose no `accessibilityLabel`/role
**Severity: P3** · **Fix size: S** · **Fix risk: safe**

**Evidence.** The primary editor WebView sets only
`webView.setAccessibilityIdentifier("mdv.editor.webView")`
(`Sources/ViewerUI/CodeMirrorEditorView.swift:302`) — no label. The rendered
markdown/HTML preview hosts (`MarkdownRenderedView.swift`, `HTMLRenderedView.swift`)
set no accessibility label. CodeMirror 6 supplies its own web ARIA
(`role=textbox` contenteditable) so editing is reachable, and the preview exposes
its HTML — so nothing is broken — but the host containers are unnamed and there is
no AppKit-level label giving the editor a spoken identity.

**Impact.** VoiceOver users hear a generic web-area with no "Markdown editor" /
"Rendered preview" identity; harder to orient.

**Suggested fix.** `setAccessibilityLabel("Markdown editor")` on the editor host and
"Rendered preview" on the preview host. Cheap and safe.

---

### F6 — `reduceMotion` honored in only 3 files; remaining animations ungated
**Severity: P3** · **Fix size: S** · **Fix risk: safe**

**Evidence.** `accessibilityReduceMotion` is read in exactly 3 files
(`FloatingTooltip.swift`, `RowHoverButtonStyle.swift`, `CommandPaletteView.swift`)
via the shared `MotionGate` helper — the right pattern, applied to the
animation-heavy surfaces. But 13 `withAnimation` + 15 `.animation(` sites live
across 9 files, and only those 3 consult the setting.

**Impact.** Minor; residual motion for motion-sensitive users.

**Suggested fix.** Route the remaining `withAnimation`/`.animation` sites through the
existing `MotionGate`.

---

### F7 — `accessibilityHint` coverage is effectively only whatever `helpInfo` provides
**Severity: P3** · **Fix size: S** · **Fix risk: safe**

**Evidence.** A single direct `accessibilityHint` exists outside the tooltip system
(`FloatingTooltip.swift:365`, emitted by `helpInfo`). Controls that got a plain
`.accessibilityLabel` (not via `helpInfo`) have no hint describing the action.

**Impact.** Minor; VoiceOver users get the name but not the affordance on
directly-labeled controls.

**Suggested fix.** Standardize on `.helpInfo(title:description:)` (it already emits
label + hint + tooltip), retiring bare `.accessibilityLabel` + `.help` pairs.

---

## Positive observations

- **`helpInfo` is an excellent pattern** (`FloatingTooltip.swift:388-410`): one
  modifier wires native `.help` + `accessibilityLabel` + `accessibilityHint` + a
  fast custom floating bubble. 75 usages. Most fixes above reduce to "use it more
  consistently."
- **Tab strip is well-labeled:** dirty dot, disk-change dot, bookmark star, split
  indicator all carry `accessibilityLabel` + `helpInfo` (`TabBar.swift:415-462`);
  only the close button (F1) is missing.
- **CSV table has real cell semantics:** column-header labels, per-cell
  `accessibilityLabel` (column/header/value), formula-cell labels
  (`CSVTableView.swift:892,1025-1026,1049`) + `accessibilityElement(children:.contain)`.
- **Hex view sets an AX label** ("Hex dump", `HexView.swift:555,604`).
- **File rows carry a rich composed label** (`SidebarView.swift:1669-1682`).
- **Full-keyboard tab navigation exists** via the AppKit menu (`⌘⇧]`/`⌘⇧[`,
  `⌘⌥[`/`⌘⌥]`, `Sources/MarkdownViewer/main.swift:1528-1557`). Note: a
  SwiftUI-only `keyboardShortcut` grep understates the keyboard surface because the
  menu bar is AppKit-built.
- **Markdown image `alt` text is preserved** end-to-end by the Rust renderer
  (`rust-core/crates/core/src/markdown.rs:380`, golden-tested at `:776,781,815`).
- **Sheet dialogs have proper default/escape keys** (`.defaultAction` on Apply,
  e.g. `ImageEditorView.swift:118,159`).

---

## Coverage gaps (what I did NOT examine)

- **No live VoiceOver run.** Findings are from static evidence about the AX tree's
  contents; I did not hear announcements, focus order, or rotor behavior (no
  window-opening tests permitted).
- **No numeric contrast measurement.** F3 flags usage patterns, not measured WCAG
  ratios against the actual light/dark palette.
- **Focus order / focus-ring / Full Keyboard Access** not verified live — confirmed
  shortcuts + `@FocusState`/`.focused` (11 files) exist but did not trace Tab-key
  traversal or confirm absence of keyboard traps in modals.
- **Web-embedded surfaces' internal ARIA** (CodeMirror 6, Mermaid, Canvas web host,
  rendered-preview HTML) not audited beyond host-container labels.
- **Terminal, Audio editor, Walkthrough player, Review, Plugins, Settings** only
  sampled (288 views total; ~30 read in depth).
- **Automation/MCP AX driver** (`Automation/UIEventSynth.swift`) is agent-facing, not
  user VoiceOver — confirmed orthogonal, not audited as user accessibility.
- **Dynamic Type / text-size scaling:** app uses custom `uiSize()` zoom rather than a
  system text-size setting; interaction with AX text scaling not evaluated.
