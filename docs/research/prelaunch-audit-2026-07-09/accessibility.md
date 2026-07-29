# Pre-launch audit — Accessibility, tooltips, keyboard navigation (2026-07-09)

Dimension lens: AX identifiers/labels coverage, VoiceOver usability, full-keyboard
operation and focus order, `.help` tooltip coverage, contrast.

## Executive summary

The app's accessibility posture is **well above typical for a pre-1.0 indie macOS app** —
there has clearly been a deliberate a11y pass (the `A11Y-01..16` audit trail from the
2026-05-30 pre-launch audit, the `HelpInfo`/`.helpInfo` unified tooltip+label system, the
`AXIdentifierCatalog` addressing contract with a drift-guard test, AX-hidden inactive
panes via `PaneCompositingPolicy`, Reduce-Motion gating via `MotionGate`, and semantic
`NSColor`-backed palettes). ~520 `accessibilityIdentifier`s, ~85 explicit
`accessibilityLabel`s, ~80 `.helpInfo` and ~123 `.help` sites across ViewerUI.

The gaps that remain cluster into four themes:

1. **The terminal content grid is a VoiceOver black hole** — a custom-drawn `NSView`
   with zero `NSAccessibility` adoption (P1).
2. **Overlay pseudo-modals (command palette, cross-search, go-to-path, LSP rename,
   code-action picker) don't declare modality** — VoiceOver can wander into the
   scrimmed-out background; nothing in the app posts a VoiceOver announcement, so
   toasts/banners/find-counts are silent (P1).
3. **The keyboard story is strong for power users but partly invisible to the AX
   layer** — sidebar arrow-key navigation is an NSEvent monitor, not focus; the four
   `Focus <pane>` commands ship unbound; palette selection changes are unannounced (P2s).
4. **A likely CSS bug makes rendered-markdown links visually indistinguishable from
   body text** (invalid `-apple-system-*, #hex` color values; WCAG 1.4.1) — needs a
   VM pixel check to confirm on-screen (P2, PLAUSIBLE).

No P0s. Nothing here blocks core flows for sighted mouse+keyboard users; the P1s
block VoiceOver users from two whole surfaces (terminal output, and reliable modal
navigation).

## Methodology

Static analysis only (per constraints — no UI tests were run, no windows opened):

- `rg` sweeps over `Sources/ViewerUI` (~71k LOC), `Sources/MarkdownViewer/main.swift`
  (menu bar), `Sources/ViewerCore/Automation` (AX driver/catalog), web resources
  (`Resources/markdown.css`, `codemirror/`, `canvas/canvas.js`, `mermaid/`), and
  `rust-core/crates/core/src/markdown.rs` (HTML emission semantics).
- Full reads of: `AXIdentifierCatalog.swift`, `FloatingTooltip.swift` (the `.helpInfo`
  modifier), `SidebarKeyMonitor.swift`, `TabBar.swift` + `SessionTabBar.swift` row AX,
  `SidebarView.swift` file-row AX + labels, `ContentView.swift` overlay/mounted-pane
  composition, `TerminalNSView.swift`, `CommandPaletteView.swift` keyboard handling,
  `StatusBar.swift`, `DiffView.swift` / `GitStatusBadge`, `markdown.css`,
  `main.swift:2388-2432` (focus commands).
- Test-side: `TerminalAccessibilityTests.swift`, `G12AccessibilityHelpersTests.swift`,
  `AXIdentifierCatalogTests.swift`, `SurfaceCoverageMatrixTests.swift` (existence +
  scope).
- Metrics gathered: 520 `accessibilityIdentifier` / 85 `accessibilityLabel` /
  80 `.helpInfo(` / 123 `.help(` / 661 `Button` occurrences in ViewerUI;
  7 `MotionGate` references vs 35 raw `withAnimation`/`.animation(` sites;
  0 `NSAccessibility.post` sites; 0 `isModal` traits; 0
  `accessibilityDisplayShouldIncreaseContrast` / `differentiateWithoutColor` reads.

Anything that requires runtime observation (actual VoiceOver output, WindowServer
pixels, focus-ring behavior, WKWebView AX bridging) is listed under Coverage gaps and
flagged per finding.

---

## Findings

### A11Y-F1 (P1) — Terminal content grid has zero NSAccessibility adoption; output is unreadable by VoiceOver

- **File:** `Sources/ViewerUI/Terminal/TerminalNSView.swift` (whole file, 667 lines;
  class decl at line 21, custom `draw(_:)` at line 360)
- **Evidence:** `rg -n "accessibility|Accessibility" TerminalNSView.swift` returns
  nothing. The view is a first-responder (`acceptsFirstResponder` line 103) custom-drawn
  grid (`attr.draw(at:)` line 462) with mouse/key/drag handling — but no
  `NSAccessibilityStaticText`/`NSAccessibilityTextArea` conformance, no
  `accessibilityRole`, no `accessibilityLabel`, no `accessibilityValue`. The terminal
  *chrome* is well covered (`TerminalView.swift:146-497` — `mdv.terminal.pane`,
  `.newTab`, `.close`, per-tab ids) and `TerminalAccessibilityTests.swift` pins the tab
  strip's AX tree — but the tests only cover the strip, not the grid.
- **Impact:** A VoiceOver user can *type into* the terminal (it takes first-responder)
  but can never *read* any output — the whole surface reads as an empty unlabeled
  group. This makes an entire feature unusable non-visually, and also blinds the
  agent-UAT AX lane to terminal content.
- **Suggested fix:** Adopt `NSAccessibilityStaticText` (or role `.textArea`): expose the
  visible grid text (the model already has row strings for `draw`) as
  `accessibilityValue`, set role + label ("Terminal"), and post
  `.valueChanged`/`.selectedTextChanged` notifications on grid updates (throttled —
  reuse the existing redraw coalescing). Follow-on: a live-region-style announcement on
  bell/exit.
- **Fix size:** M · **Fix risk:** careful (notification storm can degrade VO; throttle)

### A11Y-F2 (P1) — Overlay pseudo-modals never declare modality; VoiceOver can wander behind the scrim

- **File:** `Sources/ViewerUI/ContentView.swift:324-386` (palette 324-331, cross-search
  333-340, GoToPath 359-366, LSP rename 369-376, code-action picker 379-386)
- **Evidence:** Each overlay is `Color.black.opacity(0.18)` + panel in the root ZStack.
  `rg -n "isModal" Sources/ViewerUI` → zero hits. The background content is not
  `accessibilityHidden` while an overlay is up (contrast: the *mounted-panes* ZStack
  does gate `.accessibilityHidden(render.accessibilityHidden)` per pane,
  `ContentView.swift:747`). Scrim dismissal is `onTapGesture` only (`:327,336,362,372,382`).
- **Impact:** With the command palette (the app's primary launcher) open, the VoiceOver
  cursor can move into the dimmed background content; VO users get no "modal" context,
  and the visual scrim contradicts the AX tree. Keyboard users are fine (Escape is
  bound, `CommandPaletteView.swift:68`), but the AX-cursor experience is broken.
- **Suggested fix:** On each overlay panel add
  `.accessibilityAddTraits(.isModal)` (SwiftUI maps this to AX modality and prunes
  background content), or gate `.accessibilityHidden(true)` on the sibling content
  stack while any overlay flag is set. Five call sites, one shared pattern —
  consider extracting an `OverlayScrim` helper so future overlays inherit it.
- **Fix size:** S · **Fix risk:** safe

### A11Y-F3 (P1) — Zero VoiceOver announcements app-wide: toasts, banners, find counts, and palette selection are silent

- **File:** app-wide; concrete emitters: toast/progress overlay
  `Sources/ViewerUI/ContentView.swift:388-392` (ToastCenter, TSK-1436),
  `DiskConflictBanner` (`ContentView.swift:774-779`), `SecretWarningBanner`
  (`ContentView.swift:784-787`), find-count text `MarkdownFindBar.swift:226-238`,
  palette selection `CommandPaletteView.swift:57-117` (focus pinned to the TextField
  while `selectedIndex` moves).
- **Evidence:** `rg -n "NSAccessibility\.post|AXAnnouncement|announcementRequested" Sources`
  → zero hits.
- **Impact:** Every async/transient state change is invisible to VoiceOver: a save
  toast, a secret-detected banner, a disk-conflict banner, "3 of 41 matches", and the
  highlighted row while arrowing through the command palette. The information *exists*
  in the AX tree (labels are good) but nothing directs attention to it — the user must
  hunt for it after every action.
- **Suggested fix:** One `AXAnnouncer` helper
  (`NSAccessibility.post(element:notification:userInfo:)` with
  `.announcementRequested`, priority medium/high) called from: ToastCenter show,
  the two banners' `onAppear`, find-count changes (debounced), and palette
  `selectedIndex` changes (announce the row title). ~5 call sites.
- **Fix size:** M · **Fix risk:** safe

### A11Y-F4 (P2, PLAUSIBLE — verify on VM) — markdown.css color custom properties are invalid CSS; links likely render indistinguishable from body text (WCAG 1.4.1)

- **File:** `Sources/ViewerUI/Resources/markdown.css:5-15` (definitions), `:53`
  (`a { color: var(--mdv-link); text-decoration: none; }`)
- **Evidence:** `--mdv-fg: -apple-system-label, #1d1d1f;` (and `--mdv-fg-secondary`,
  `--mdv-bg`, `--mdv-link`) use a comma "fallback list" — that is **not** CSS syntax
  (fallbacks belong in `var(--x, fallback)`, not in the property value). At
  substitution, `color: -apple-system-label, #1d1d1f` is invalid-at-computed-value-time
  → the property computes as `unset`. For `a { color: … }` that means **inherit** —
  links get the body text color, and with `text-decoration: none` they are
  distinguishable only on hover. Body text itself survives by luck (`unset` → inherit →
  `CanvasText` via `color-scheme: light dark`, line 6). `mermaid-shim.js` also consumes
  the raw invalid string (`cs.getPropertyValue('--mdv-link').trim() || fallback` — the
  non-empty invalid value wins over the sane fallback).
- **Impact:** If confirmed on-screen: rendered-markdown links fail WCAG 1.4.1 (color/
  affordance-free links) for all users, not just AX users; secondary-label styling on
  h5/h6/blockquote/del silently doesn't apply; Mermaid theme derivation feeds an
  invalid color into the diagram theme.
- **Suggested fix:** Use real CSS system colors with proper fallback:
  `--mdv-fg: CanvasText;`, `--mdv-bg: Canvas;`, `--mdv-link: LinkText;` (all supported
  by WebKit and appearance-aware), or plain hex pairs under
  `@media (prefers-color-scheme: dark)`. Add underlines or a `:where(a)` accent to
  restore a non-color link affordance. **Per the render-confirm directive: verify the
  current behavior and the fix on the VM (T5/webview lane) before claiming fixed** —
  this analysis is static.
- **Fix size:** S · **Fix risk:** careful (visual change across every rendered doc;
  pixel-lane goldens may need re-baselining)

### A11Y-F5 (P2) — 123 `.help()`-only sites leave icon buttons without explicit AX labels; the app's own `.helpInfo` standard is only ~40% adopted

- **File (examples):** `Sources/ViewerUI/Observability/LogsView.swift:101-111`
  (`doc.on.doc` copy / `trash` clear buttons — `.help` only),
  `Sources/ViewerUI/ToolResultsPanel.swift:39-49` (copy-all / close),
  `Sources/ViewerUI/TabBar.swift:191` (overflow menu). Standard defined at
  `Sources/ViewerUI/FloatingTooltip.swift:388-394` ("the single tooltip entry point the
  whole app should use") — it sets `.help` + floating bubble + status-bar feed **+
  `accessibilityLabel` + `accessibilityHint`** (`:352,364-365`).
- **Evidence:** counts: 123 `.help(` vs 80 `.helpInfo(` in ViewerUI. `.help()` maps to
  `accessibilityHelp`, *not* the label; an `Image(systemName:)`-only button then falls
  back to the SF Symbol's built-in description, which is unreliable ("doc.on.doc" is
  not "Copy visible log lines").
- **Impact:** VoiceOver reads vague or wrong names for dozens of icon-only controls in
  the observability views, tool panels, Git tabs, and misc sheets — precisely the
  surfaces the curated `helpInfo` migration hasn't reached.
- **Suggested fix:** Mechanical sweep: migrate remaining `.help("x")` on interactive
  controls to `.helpInfo(title: "x")` (title-only overload exists,
  `FloatingTooltip.swift:408`). Keep `.help` for non-interactive info glyphs. A lint
  guard (grep-based test, same pattern as the catalog drift guard) can pin "no bare
  `.help(` on a Button in ViewerUI".
- **Fix size:** M (many sites, trivially mechanical) · **Fix risk:** safe

### A11Y-F6 (P2) — Sidebar keyboard navigation is an NSEvent monitor, not focus; selection state is invisible to AX

- **File:** `Sources/ViewerUI/SidebarKeyMonitor.swift` (whole file);
  `Sources/ViewerUI/SidebarView.swift:1563-1565` (row exposes only `.isButton` — no
  `.isSelected` for the keyboard-cursor row and no per-row focusability)
- **Evidence:** Arrow/Return/F2 keys are intercepted by
  `NSEvent.addLocalMonitorForEvents` whenever first-responder isn't a text view
  (`SidebarKeyMonitor.swift:52+`). The highlighted row is model state
  (`rowBackground`), not AppKit focus. The AX label (`SidebarView.swift:1669-1682`)
  covers name/folder-state/git/"currently open" — but not "selected" for the keyboard
  cursor.
- **Impact:** VoiceOver and Full Keyboard Access users can't perceive or drive the
  sidebar's keyboard cursor: VO focus and the app's arrow-key cursor are two unrelated
  positions. Sighted keyboard users are actually well served (this is a deliberate,
  documented design — CRIT-6); the gap is purely the AX reflection of it.
- **Suggested fix:** (a) add `.accessibilityAddTraits(.isSelected)` (or
  `.accessibilityAddTraits` conditional) on the cursor row; (b) announce row changes
  when the monitor moves the cursor (ties into A11Y-F3's announcer); (c) longer-term,
  consider making the row cursor a real `@FocusState` so FKA/VO track it natively.
- **Fix size:** S (a+b) / M (c) · **Fix risk:** safe (a+b), careful (c — the monitor
  interplay is subtle, TSK-1280 class)

### A11Y-F7 (P2) — The four `Focus <pane>` commands ship with no default key equivalents

- **File:** `Sources/MarkdownViewer/main.swift:2390-2430`
- **Evidence:** "Focus shortcuts (TSK-937) … No default key-equivalents — the obvious
  keys clash with existing bindings (the TSK-936 concern) … the user can bind keys via
  keybinding.json." All four (`Focus Terminal`, `Focus File Navigator`, `Focus Git
  Panel`, `Focus Active File`) have `keyEquivalent: ""`.
- **Impact:** Keyboard-only pane movement — the backbone of full-keyboard operation in
  a multi-pane app — requires menu diving (or hand-editing keybinding.json) out of the
  box. Every comparable editor binds these by default (VS Code ⌘0/⌘1, Xcode ⌘J/⌘1).
- **Suggested fix:** Do the clash audit TSK-936 deferred and bind non-conflicting
  defaults (⌥⌘0..3 or ⌃⌘←/→ family are free in the current `Shortcut` map); keep
  keybinding.json as the override. Surface them in the palette (already done) and the
  Keyboard Shortcuts help page (auto — it renders bound shortcuts).
- **Fix size:** S · **Fix risk:** careful (must not shadow existing bindings; the
  KeyboardShortcutsView + `Shortcut.swift` catalog make the audit cheap)

### A11Y-F8 (P2) — Command palette: selection movement and jump-rows are AX-silent / non-actionable

- **File:** `Sources/ViewerUI/CommandPaletteView.swift:95-117` (rows via
  hover/tap closures, `isSelected:` passed for *visual* styling), `:436-440`
  (line-jump rows are plain `HStack` + `.onTapGesture`, not Buttons), `:57-68`
  (focus pinned to the `TextField`)
- **Evidence:** as cited; no `.accessibilityAddTraits(.isSelected)` / no
  `accessibilityElement` on the row containers; `selectedIndex` changes produce no AX
  event (focus never leaves the field).
- **Impact:** VoiceOver users hear nothing as ↑/↓ move the highlight (the standard
  combobox/aria-activedescendant behavior is missing), and the jump-list rows are not
  AX-actionable at all (tap-gesture-only). Keyboard behavior itself is complete
  (arrows/Return/Escape all bound — `:583-606,68`).
- **Suggested fix:** Make jump rows `Button`s (`.plain` style keeps the look); add
  `.isSelected` traits driven by `selectedIndex`; announce the selected row's title on
  change (shares the A11Y-F3 announcer).
- **Fix size:** S · **Fix risk:** safe

### A11Y-F9 (P2) — Reduce Motion gate exists but ~80% of animation sites bypass it

- **File:** gate at `Sources/ViewerUI/RowHoverButtonStyle.swift:237-247`
  (`MotionGate.animation`, tested in `G12AccessibilityHelpersTests`); bypass examples:
  `Sources/ViewerUI/SidebarView.swift:1487-1489` (chevron rotation animates
  unconditionally), plus the bulk of the 35 raw `withAnimation`/`.animation(` sites
  vs only 7 `MotionGate` references in ViewerUI.
- **Evidence:** counts above; `@Environment(\.accessibilityReduceMotion)` is read in
  only 3 files (FloatingTooltip, RowHoverButtonStyle, CommandPaletteView).
- **Impact:** Users with Reduce Motion on still get expand/collapse spins, layout
  slides, and assorted transitions. Not a blocker (macOS suppresses some system-level
  motion), but the app has a named gate whose coverage stalled — the A11Y-06 intent
  isn't enforced.
- **Suggested fix:** Sweep raw `.animation(`/`withAnimation` in ViewerUI through
  `MotionGate`; add a grep-guard test permitting only allow-listed raw sites (the same
  teeth pattern used elsewhere in this repo).
- **Fix size:** M · **Fix risk:** safe

### A11Y-F10 (P2) — No adaptation to Increase Contrast or Differentiate Without Color

- **File:** app-wide. `rg -n "shouldIncreaseContrast|differentiateWithoutColor|ReduceTransparency" Sources` → zero hits.
- **Evidence:** State pairs distinguished chiefly by hue: tab dirty-dot vs disk-change
  dot (`TabBar.swift:425-440` — both small dots, different colors; AX labels *do*
  differ), sidebar recency stripe tiers (`SidebarView.swift:1619` — color-only, but
  AX-hidden decoration), find highlight current-vs-other
  (`markdown.css:126-133` — 0.30 vs 0.58 alpha of the same blue). Semantic
  `NSColor`s elsewhere (`Palette.swift:30-39`) do adapt automatically — the gap is the
  hand-rolled indicators and the `.thinMaterial` tooltip bubble
  (`FloatingTooltip.swift:218`) under Reduce Transparency.
- **Impact:** Low-vision users relying on the two system toggles get no reinforcement
  from the custom indicators. Labels mostly rescue VoiceOver users; sighted low-vision
  users (the toggles' audience) are the ones affected.
- **Suggested fix:** Read
  `NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor` (+
  `…ShouldIncreaseContrast`) once into the environment; give the dirty/disk dots
  distinct glyph shapes under it and bump the find-highlight alpha delta / add an
  outline for the current match.
- **Fix size:** M · **Fix risk:** safe

### A11Y-F11 (P3) — Tab overflow menu: unlabeled chevron trigger; state encoded as "✓ "/"• " title prefixes

- **File:** `Sources/ViewerUI/TabBar.swift:174-192`
- **Evidence:** `Menu { … } label: { Image(systemName: "chevron.down") … }` with only
  `.help("All tabs (N) — jump to any")` (`:191`) — no `accessibilityLabel`; item titles
  are `"✓ " + "• " + title` (`:179-180`).
- **Impact:** VO reads the trigger as "chevron down, menu"; items read literal
  punctuation ("checkmark bullet README.md") instead of selected/modified state.
- **Suggested fix:** `.helpInfo(title: "All Tabs")` on the trigger; move ✓/• into
  `accessibilityLabel`/menu `state:` (NSMenuItem `.state = .on` equivalent — in SwiftUI
  use a `Toggle`-style checkmark or append ", selected"/", modified" to the AX label).
- **Fix size:** S · **Fix risk:** safe

### A11Y-F12 (P3) — AX identifier namespace drift: `sidebar.*` ids outside the `mdv.*` convention

- **File:** `Sources/ViewerUI/SidebarView.swift:714,725,782,1416`
  (`sidebar.filterField`, `.clear`, `sidebar.filterResults`, `sidebar.filterRow.<name>`)
- **Evidence:** every other identifier in ViewerUI is `mdv.*` (520 total; these 4 lines
  are the only bare-`sidebar.*` family — `rg -o 'accessibilityIdentifier\("[^"]+'` diff).
  The `AXIdentifierCatalog` header itself documents "~300 `mdv.*` identifiers".
- **Impact:** Automation/agent addressing contract inconsistency — a driver filtering
  on the `mdv.` prefix misses the sidebar filter surface; drift-guard only protects
  catalogued ids.
- **Suggested fix:** Rename to `mdv.sidebar.filterField` etc.; update any tests that
  address the old ids; consider adding the filter field to `AXIdentifierCatalog.critical`
  (it's a top-level, stable control).
- **Fix size:** S · **Fix risk:** careful (grep Tests/ + drive plans for the old
  strings before renaming — it's an addressing contract)

### A11Y-F13 (P3) — Decorative elements carry AX identifiers instead of being hidden

- **File:** `Sources/ViewerUI/TabBar.swift:134-137` (`mdv.tab.divider` on a 1-pt
  separator `Rectangle`)
- **Evidence:** the divider is pure decoration yet is an addressable AX element; by
  contrast the sidebar recency stripe correctly pairs its identifier with
  `.accessibilityHidden(true)` (`SidebarView.swift:1515,1619`).
- **Impact:** VO element-navigation noise in the tab strip (one junk stop per tab).
- **Suggested fix:** `.accessibilityHidden(true)` on the divider (keep the identifier
  if a pixel test addresses it — hidden elements remain reachable by identifier in the
  XCUI/AX-dump lanes used here, or drop it if nothing references it).
- **Fix size:** S · **Fix risk:** safe

### A11Y-F14 (P3) — Canvas surface has no ARIA semantics (feature currently parked)

- **File:** `Sources/ViewerUI/Resources/canvas/canvas.js` (only `data-cv-role`
  attributes, e.g. `:469`; no `role=`, `aria-*`, or `tabindex` anywhere)
- **Evidence:** `rg -n "aria-|role=|tabindex" canvas.js` → one `data-cv-role` hit.
- **Impact:** The canvas/slides surface is a div-soup for AT. Low urgency: the Canvas
  epic is parked pending owner review (memory: do not resume without owner) — but the
  a11y work should be a line item in its un-park checklist.
- **Suggested fix:** When Canvas resumes: roles (`role="list"/"listitem"` for slides),
  keyboard focus model (`tabindex`, arrow-key handlers), and labels from slide titles.
- **Fix size:** L (part of the parked epic) · **Fix risk:** safe

### A11Y-F15 (P3) — `.helpInfo` clobbers more-specific existing AX labels when stacked

- **File:** `Sources/ViewerUI/FloatingTooltip.swift:364` (`.accessibilityLabel(Text(info.title))` applied unconditionally inside the modifier)
- **Evidence:** any call site that already sets a *dynamic* label and then adds
  `.helpInfo` outside it gets the static tooltip title as its VO name (outermost label
  wins). Example of the risk pattern (currently mostly avoided by ordering):
  `StatusBar.swift:418-421` deliberately re-sets the label *after* `.helpInfo` to win —
  which shows call sites must know this trap.
- **Impact:** Latent foot-gun: future `.helpInfo` adoptions (A11Y-F5 sweep!) can
  silently replace rich state-bearing labels with generic tooltip titles.
- **Suggested fix:** Document the ordering contract on the modifier (label-last wins),
  or add a `helpInfo(…, preservesLabel: true)` variant that skips the label when the
  content already provides one. Cover in `G12AccessibilityHelpersTests`-style host test.
- **Fix size:** S · **Fix risk:** safe

---

## Positive observations

- **`HelpInfo` / `.helpInfo` unified tooltip system** (`ViewerKit/HelpInfo.swift`,
  `FloatingTooltip.swift`) is genuinely good design: one call site yields native
  tooltip + floating themed bubble + status-bar description + AX label + AX hint, with
  Reduce Motion respected and the bubble itself correctly `accessibilityHidden` +
  `allowsHitTesting(false)` (`FloatingTooltip.swift:224-230`).
- **`AXIdentifierCatalog` + drift guard** (`ViewerCore/Automation/AXIdentifierCatalog.swift`,
  `Tests/ViewerCoreTests/Automation/AXIdentifierCatalogTests.swift`): a curated, tested
  addressing contract for the agent-drivable AX surface — rare discipline.
- **Inactive mounted panes are AX-hidden by policy** — `PaneCompositingPolicy` drives
  `.accessibilityHidden` alongside opacity/hit-testing/z-order (`ContentView.swift:732-748`),
  so the perf-motivated always-mounted ZStack does *not* leak ghost documents into the
  AX tree, and it's pinned by a host test (TSK-839).
- **Rich, state-bearing AX labels on the dense surfaces**: tab rows combine title +
  dirty + disk + selected state (`TabBar.swift:511-531`); sidebar rows speak
  folder-expanded/collapsed, git status, and "currently open"
  (`SidebarView.swift:1669-1682`); session tabs label git badges and close buttons
  per-session (`SessionTabBar.swift:254-300`); CSV cells get "Header: value" labels with
  positional fallback, host-tested (`CSVTableView.cellLabel`,
  `G12AccessibilityHelpersTests.swift`); hex view labels the dump including truncation
  state (`HexView.swift:555,604,1327-1342`).
- **Keyboard breadth**: 60 `keyboardShortcut` sites, Escape consistently dismisses
  overlays, the palette/go-to/find bars are fully arrow-key drivable, a searchable
  Help → Keyboard Shortcuts page renders every *bound* shortcut from one catalog
  (`KeyboardShortcutsView.swift`, TSK-678), and user rebinding exists
  (keybinding.json + `applyShortcut`).
- **Semantic color discipline on the native side**: `Palette.swift` is built on
  `NSColor` semantic colors (label/secondaryLabel/separator/selectedContentBackground),
  so native chrome tracks appearance and (mostly) system contrast for free. Git status
  badges pair letter + color + helpInfo (`SidebarView.swift:1276-1300`); diff lines keep
  their `+`/`-` text prefixes (`DiffView.swift:568,626-631`) — no color-only encoding of
  those states.
- **Markdown → HTML emission is semantically sound** (`rust-core/crates/core/src/markdown.rs`):
  real `<h1..h6>` with stable slug ids (`:409`), `<thead>/<th>` tables (`:338-351`),
  `alt` preserved on images (`:380`), tested (`:661-785`).
- **Terminal tab strip has an in-process AX-tree regression test**
  (`TerminalAccessibilityTests.swift`) — the "semantic complement to the pixel lane"
  pattern is exactly right; it just needs to grow to the grid (A11Y-F1).

## Coverage gaps (not examined / not verifiable statically)

- **Live VoiceOver behavior** — everything here is inferred from the AX API surface;
  no VO session was run. The P1s/P2s should be spot-confirmed with VO on the VM GUI
  lane before/after fixing.
- **WKWebView AX bridging quality** — whether CM6's screen-reader support and the
  rendered-markdown DOM actually read well through WebKit's AX bridge (heading rotor,
  link rotor, table navigation) needs on-VM verification; only
  `mdv.editor.webView` identifier wiring (`CodeMirrorEditorView.swift:302`) was checked
  statically. CodeMirror 6 generally handles roles/aria internally.
- **Focus order / key-view loop across the whole window** (sidebar → tabs → content →
  status bar) under Full Keyboard Access — runtime-only.
- **Contrast measurements** — no computed contrast ratios for the syntax token palettes
  (`markdown.css:142-173`, `codemirror.css` themes) or find-highlight overlays; a
  scripted WCAG-ratio pass over the token colors would close this.
- **Settings, Plugins, Walkthrough, Review, HTTPClient, SQLiteBrowser, Feed, audio/image
  editors** — spot-checked for identifier counts only, not row-by-row label audits.
- **The menu bar's completeness as a keyboard surface** (every verb reachable via a
  menu item) — sampled (View/focus/Help), not exhaustively cross-referenced against
  `ScriptVerbCatalog`.
- **Localization of AX strings** — all labels are English literals; i18n was out of
  scope for this lens.
