# Pre-launch Product Review — macOS UI Best Practices (HIG conformance) — v2

> Note: a prior same-dimension report exists at `ui-best-practices.md`. This `.v2.md`
> is an independent pass written to avoid clobbering that file (safe-write policy).

**Dimension:** macOS Human Interface Guidelines conformance — control sizes/spacing,
sheet vs panel use, toolbar/menu conventions, dark-mode correctness, vibrancy, SF
Symbols usage.

**Reviewer lens:** Native-macOS-app quality bar. Does the app read, behave, and
respond like a well-behaved AppKit/SwiftUI document app, or does it carry web-isms /
custom reimplementations that diverge from platform conventions?

**Date:** 2026-07-09 · **Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`

---

## Executive summary

The app is, on the whole, a **conscientiously-built native macOS app** with good
platform hygiene in the areas that most often go wrong: it uses a disciplined dynamic
system-color palette (`Palette`) rather than hardcoded RGB, never forces an appearance
or overrides the system accent (dark mode "just works"), respects
`accessibilityReduceMotion`, uses SF Symbols (not emoji) for iconography, and wires a
mostly-complete standard menu bar (About / Settings… ⌘, / Hide / Hide Others / Show
All / Quit, plus Help, Window, File, Edit, View menus with correct key equivalents).

The findings are **quality/polish deviations, not ship-blockers** — no P0/P1. The
recurring theme is that the app **reimplements standard AppKit chrome by hand** (custom
in-content toolbar instead of `NSToolbar`, hand-rolled segmented control instead of
`Picker(.segmented)`, manually-managed Window menu) and carries a few **web-isms** (the
link/pointing-hand cursor on every custom button; fixed pixel font sizes that ignore
the system text-size accessibility setting). The most user-visible items are the
pointing-hand cursor on all buttons (F1), the Settings window violating preference-window
conventions (F2), sub-11pt unreadable text in the tab strip and badges (F3), and the
lack of Dynamic-Type / accessibility-text-size support (F4).

Counts, all lens-relevant, in `Sources/ViewerUI/` (288 Swift files):

| Signal | Count | Note |
|---|---|---|
| `Color(red:` / `Color(.sRGB` hardcoded literals | 3 | all in image-editing color pickers (legit) |
| `foregroundStyle(.white)` hardcoded | 5 | on colored chips (mostly OK) |
| Dynamic system-color palette entries | ~25 | `Palette.swift` — good |
| `Image(systemName:)` (SF Symbols) | 256 | good |
| Emoji used in `Text()` instead of a symbol | 0 | (arrow glyphs ↑↓⎋↵ only) |
| `.font(.system(size:` total | 596 | 241 literal, 170 zoom-scaled |
| Semantic `.font(.body/.headline/…)` | ~112 | mixed with the above |
| `NSVisualEffectView` / explicit vibrancy | 0 | uses SwiftUI `Material` (14 sites) |
| Forced `.preferredColorScheme` / appearance override | 0 | good |
| `.accentColor(`/`.tint(` overrides | 0 | respects system accent — good |

---

## Methodology

Static analysis (`rg`/`grep`/`find` + `Read`) over the presentation strata, primarily
`Sources/ViewerUI/` (288 files, ~71K LOC) and the app shell
`Sources/MarkdownViewer/main.swift` (4,435 LOC). No UI/window-opening tests were run
(per constraints). Specifically examined:

- **Toolbar & window chrome** — `ContentToolbar.swift`, `main.swift` window/`styleMask`
  construction, `NSWindow.allowsAutomaticWindowTabbing`.
- **Menu bar** — the full `NSMenu` build-out in `main.swift` (app menu, File, Edit,
  View, Window, Help, Services registration).
- **Settings** — `SettingsView.swift` + `SettingsWindowController`.
- **Colors / dark mode / vibrancy** — `Palette.swift`, `ChromeTheme.swift`, grep for
  hardcoded RGB, forced appearance, `Material`/`NSVisualEffectView`.
- **Control sizing & typography** — `.font(.system(size:))` census, `.controlSize`
  census, the shared button styles `RowHoverButtonStyle.swift` (hover/cursor/hit-target).
- **SF Symbols** — `Image(systemName:)`/`Label(…, systemImage:)` usage; emoji-in-text.
- **Sheets vs popovers vs windows** — `.sheet`/`.popover` census; auxiliary
  `NSWindow`s; `TabBar.swift` (tab close affordances).

Not exercised: runtime pixel/appearance validation, VoiceOver rotor/keyboard-nav
behavior, right-to-left/localization layout, or the WebView-rendered surfaces
(CodeMirror/Mermaid/Canvas HTML chrome) — see Coverage gaps.

---

## Findings

### F1 — Link/pointing-hand cursor on every custom button (web-ism) · P2

- **Where:** `Sources/ViewerUI/RowHoverButtonStyle.swift:83` and `:194`
  (`NSCursor.pointingHand.push()`), also documented at `:17` and `:125`. These two
  shared styles (`RowHoverButtonStyle`, `IconHoverButtonStyle`) are each used at ~10
  call sites and back the breadcrumb segments, view-mode control, command-palette
  button, sidebar rows, and most icon buttons app-wide.
- **Evidence:** the hover modifier unconditionally pushes `NSCursor.pointingHand` for
  any control adopting the style.
- **Impact:** On macOS the pointing-hand (link) cursor is reserved for **web
  hyperlinks**. Native controls (buttons, toolbar items, segmented controls, table
  rows) keep the **arrow** cursor. Showing the link cursor on ordinary buttons is a
  classic web-app tell that makes the app feel non-native, and it miscommunicates
  "this is a link" on things that aren't.
- **Suggested fix:** Drop the `pointingHand` push from these styles (native buttons
  don't change the cursor). If a hover cursor is desired at all, it should not be the
  link cursor. This is a one-line removal in each style.
- **Fix size:** S · **Risk:** safe

### F2 — Settings window violates preference-window conventions · P2

- **Where:** `Sources/ViewerUI/SettingsView.swift:700-701`
  (`win.title = "\(appName) Settings"`, `styleMask = [.titled, .closable,
  .miniaturizable, .resizable]`).
- **Evidence:** The Settings window is created **resizable and miniaturizable**, titled
  "TextView Settings".
- **Impact:** macOS preference/Settings windows are utility-style: **non-resizable,
  non-minimizable**, and since macOS 13 titled simply **"Settings"** (not
  "AppName Settings"). Offering a minimize button and free resize on a settings sheet
  is off-pattern and lets the content reflow in ways the layout wasn't designed for.
- **Suggested fix:** Use `styleMask = [.titled, .closable]` (no `.resizable`,
  no `.miniaturizable`); set `win.title = "Settings"`. If the multi-section content
  needs height, size the content to fit rather than allowing free resize.
- **Fix size:** S · **Risk:** safe

### F3 — Sub-11pt text in tab strip, badges, and walkthrough (below legible minimum) · P2

- **Where:** `Sources/ViewerUI/TabBar.swift:444` (`size: 8 * scale`), `:478`
  (`size: 8 * scale`); `Sources/ViewerUI/ContentView.swift:1684` (`size: 7`), `:1764`
  (`size: 8`), `:1767` (`size: 7`); `Sources/ViewerUI/Walkthrough/WalkthroughPlayerView.swift:232`
  (`size: 8`).
- **Evidence:** Fixed 7–8pt font sizes on tab badges/indicators and overlay badges.
- **Impact:** The macOS system font floors around **11pt** (`.mini` control text ≈ 9pt
  is already the smallest system control text). 7–8pt is below the legible minimum, is
  effectively unreadable for many users, and does not scale with any accessibility
  setting. On the tab strip (a primary navigation surface) this is user-facing.
- **Suggested fix:** Raise to ≥11pt (or use `.caption2`/`.footnote` semantic styles);
  if the badge is a count/dot, prefer an SF Symbol or a fixed-diameter badge over
  micro-text.
- **Fix size:** S · **Risk:** safe

### F4 — App chrome ignores the system text-size accessibility setting (no Dynamic Type) · P2

- **Where:** app-wide. `Sources/ViewerUI/DocumentModel.swift:307`
  (`func uiSize(_ base: CGFloat) -> CGFloat { base * CGFloat(zoom) }`); 241 literal
  `.font(.system(size: <n>))` sites and 170 `.font(.system(size: model.uiSize(<n>)))`
  sites.
- **Evidence:** Chrome typography is either a hardcoded point size or a size multiplied
  by the **document zoom** factor. Neither channel reads
  `@Environment(\.dynamicTypeSize)` / `@ScaledMetric` / the semantic text styles that
  track System Settings → Accessibility → Display → Text size.
- **Impact:** A user who enlarges text system-wide for readability gets **no response**
  from the app's chrome (breadcrumb, toolbar, sidebar, status bar, tab strip). The
  `uiSize`-zoom channel scales chrome with ⌘+/⌘−, but that is a different, manual signal
  — it is not the accessibility preference and is coupled to document zoom (see F5).
- **Suggested fix:** Route chrome typography through semantic styles
  (`.font(.body)`/`.callout`/`.caption`) or `@ScaledMetric`, so it honors the system
  text-size preference. This is a broad, mechanical change — best done behind a small
  font-token helper.
- **Fix size:** L · **Risk:** careful (touches many views; verify layouts don't clip at
  larger sizes)

### F5 — App chrome resizes with document zoom (⌘+/⌘− scales the toolbar, not just content) · P3

- **Where:** `Sources/ViewerUI/DocumentModel.swift:307` (`uiSize = base * zoom`),
  consumed by `ContentToolbar.swift` (height `uiSize(22)`, all fonts/padding),
  `TabBar.swift` (tab size `uiSize(24/28)`), and ~170 other chrome sites.
- **Evidence:** `zoom` (driven by Zoom In/Out, `DocumentModel+Zoom.swift`) multiplies
  every `uiSize()` chrome dimension.
- **Impact:** On macOS, ⌘+/⌘− conventionally zooms **document content**, leaving app
  chrome (toolbar, tab bar, sidebar) at native size. Here the whole UI grows/shrinks,
  which is non-standard and can push chrome into awkward proportions at zoom extremes.
  It may be a deliberate "whole-app zoom" product decision — flagging it as a
  convention divergence to confirm intent, not a defect.
- **Suggested fix:** If content-only zoom is intended, decouple `uiSize` from `zoom`
  and scale only the content surface; if whole-app zoom is a deliberate feature, keep
  it but document the divergence.
- **Fix size:** M · **Risk:** careful (product decision + layout re-verification)

### F6 — Custom in-content toolbar instead of `NSToolbar` / SwiftUI `.toolbar` · P3

- **Where:** `Sources/ViewerUI/ContentToolbar.swift` (a plain `HStack` at
  `.frame(height: model.uiSize(22))`, lines 36–45). No `NSToolbar` and zero SwiftUI
  `.toolbar { }` modifiers exist anywhere in `Sources/`.
- **Evidence:** The primary command bar (breadcrumb + view-mode control + command
  palette) is a hand-built content view living below the title bar, not a window
  toolbar.
- **Impact:** Foregoes native toolbar affordances: the **unified title-bar/toolbar**
  look, user **toolbar customization** (right-click → Customize Toolbar), automatic
  **overflow** into a chevron menu on narrow windows, and correct behavior in full
  screen. The breadcrumb does hand-roll its own overflow menu (`ContentToolbar.swift:74`),
  duplicating what `NSToolbar` provides for free. Native toolbar items also get standard
  keyboard/VoiceOver semantics automatically.
- **Suggested fix:** Longer-term, migrate the top bar to a real `NSToolbar` (or SwiftUI
  `.toolbar` with `ToolbarItem` placements) so it participates in the window chrome.
  Large change; acceptable to defer, but worth capturing as debt before launch.
- **Fix size:** L · **Risk:** careful

### F7 — Hand-rolled segmented control instead of native `Picker(.segmented)` · P3

- **Where:** `Sources/ViewerUI/ContentToolbar.swift:239-304`
  (`segmentedPrimaries`/`segment` — a manual rounded container with hairline dividers,
  `.buttonStyle(.plain)` segments).
- **Evidence:** The Render | Editor | HEX mode switch is built from `Button`s and
  `Rectangle` dividers rather than a `Picker(selection:) { }.pickerStyle(.segmented)`.
- **Impact:** Reimplements a standard AppKit control, so it doesn't inherit native
  segmented-control **appearance, keyboard traversal, focus ring, and VoiceOver
  grouping** for free. To their credit the code adds `accessibilityAddTraits(.isSelected)`
  and an accessibility label/container (`:302-303`, `:184-186`), partially compensating.
  Visual/behavioral drift from the platform segmented control remains.
- **Suggested fix:** Replace with `Picker(...).pickerStyle(.segmented)` where the
  dynamic segment set allows; if the custom look is required, keep it but ensure
  keyboard focusability (`.buttonStyle(.plain)` can drop the focus ring).
- **Fix size:** M · **Risk:** careful

### F8 — Settings is a single 13-section scroll page (no category tabs) · P3

- **Where:** `Sources/ViewerUI/SettingsView.swift:7-14` (comment: "Single page, no
  tabs, every knob flat") and `:29-60` (13 stacked sections: appearance, editor,
  languages, terminal, viewer, file associations, audio, privacy, plugins, extensions,
  LSP, advanced, separated by `Divider()`).
- **Evidence:** All settings live in one long `ScrollView`.
- **Impact:** macOS convention for a settings window with many categories is a
  **toolbar-tab or sidebar** layout (System Settings-style), giving stable category
  landmarks and shorter scroll distance. A 13-section wall is harder to navigate and
  doesn't match user expectations for a Settings window. The code explicitly
  acknowledges this is a deliberate interim choice.
- **Suggested fix:** Adopt `TabView { … }.tabViewStyle(...)` (or a sidebar
  `NavigationSplitView`) with per-category panes.
- **Fix size:** M · **Risk:** safe

### F9 — Window menu not registered with AppKit (`NSApp.windowsMenu` unset) · P3

- **Where:** `Sources/MarkdownViewer/main.swift:2509-2516` — a `NSMenu(title: "Window")`
  is built and populated manually (`rebuildWindowMenu()` via `menuNeedsUpdate`), but
  `NSApp.windowsMenu = windowMenu` is **never** assigned (grep for `windowsMenu`
  returns only the local var).
- **Evidence:** No `NSApp.windowsMenu` assignment anywhere in `main.swift`.
- **Impact:** AppKit won't auto-manage the Window menu — the standard **open-window
  list**, the **checkmark on the active window**, and **"Bring All to Front"** are not
  system-provided. For a primarily single-window app with in-app tabs this is minor,
  but it's a standard-menu wiring gap.
- **Suggested fix:** Set `NSApp.windowsMenu = windowMenu` (and let AppKit add the
  managed items), or confirm the manual management is intentional and complete.
- **Fix size:** S · **Risk:** careful (interacts with the existing manual rebuild)

### F10 — No Services submenu in the app menu · P3

- **Where:** `Sources/MarkdownViewer/main.swift` app-menu build (About …1647,
  Settings …1656, Hide/Hide Others/Show All …1673-1687, Quit …1691). The app registers
  as a services **provider** (`registerAsServicesProvider()`, `:238`, `:4088`) but never
  adds a **Services submenu** to the app menu nor sets `NSApp.servicesMenu`.
- **Evidence:** No `servicesMenu` / "Services" item in the app-menu construction.
- **Impact:** Users can't invoke system Services on a text selection from within the
  app, and the HIG-standard app-menu slot (About / Settings / **Services** / Hide … /
  Quit) is incomplete.
- **Suggested fix:** Add a "Services" `NSMenuItem` with an empty submenu after Settings
  and assign `NSApp.servicesMenu = thatSubmenu`.
- **Fix size:** S · **Risk:** safe

### F11 — Native window tabbing disabled · P3 (likely intentional — confirm)

- **Where:** `Sources/MarkdownViewer/main.swift:229`
  (`NSWindow.allowsAutomaticWindowTabbing = false`).
- **Evidence:** System window tabbing ("Merge All Windows", the View → Show Tab Bar
  affordances) is turned off.
- **Impact:** Deliberate given the app ships its own in-window tab strip (`TabBar.swift`)
  — enabling both would double up tab UIs. Flagging only so the choice is a conscious
  one; it does remove the standard macOS window-tabbing behavior users may expect.
- **Suggested fix:** None required if intentional; document the rationale.
- **Fix size:** S · **Risk:** safe

---

## Positive observations

- **Disciplined dynamic-color palette.** `Sources/ViewerUI/Palette.swift` wraps AppKit
  **dynamic** system colors (`.windowBackgroundColor`, `.separatorColor`, `.labelColor`,
  etc.) that re-resolve on appearance change, with a documented allocation rationale.
  Very few hardcoded RGB literals exist (3, all in image-editing color pickers where
  literal color is the point).
- **Dark mode is correct by construction.** Zero forced `.preferredColorScheme`, zero
  `NSApp.appearance` overrides — the app follows the system appearance. No hardcoded
  black/white backgrounds fighting dark mode.
- **Respects the system accent.** Zero `.tint(`/`.accentColor(` overrides;
  `Color.accentColor` used for selection states (e.g. `ContentToolbar.swift:289`,
  `RowHoverButtonStyle` fills).
- **Respects Reduce Motion.** `RowHoverButtonStyle.swift:170` reads
  `accessibilityReduceMotion` and pins scale/animation off when set (`:212`, via
  `MotionGate`).
- **SF Symbols, not emoji.** 256 `Image(systemName:)`/`Label(systemImage:)` sites; no
  emoji misused as iconography (the only non-ASCII glyphs in `Text` are keyboard hints
  ↑↓⎋↵).
- **Mostly-complete standard menu bar.** App menu has About / Settings… (⌘,) /
  Hide (⌘H) / Hide Others (⌥⌘H) / Show All / Quit (⌘Q); Help, Window, File, Edit, View
  menus present. Correct key-equivalent detail: Zoom In deliberately uses ⌘= not
  shifted ⌘+ (`main.swift:2270` comment). A disabled-but-present Settings… stub was
  kept specifically to honor ⌘, muscle memory.
- **Proper tab affordances.** `TabBar.swift` has per-tab close buttons and a full
  context menu (Close Tab / Close Other Tabs / Close Tabs to the Right, `:298-301`).
- **Reasonable window minimums.** Main window `contentMinSize = 600×360`
  (`main.swift:328`); auxiliary windows sized explicitly.
- **Vibrancy via SwiftUI `Material`** (14 sites) rather than raw `NSVisualEffectView`,
  which is the modern approach.
- **Accessibility identifiers + traits** are applied liberally (`mdv.*` ids), and the
  custom segmented control adds `.isSelected` traits and container labels — partial
  compensation for the hand-rolled controls (F7).

---

## Coverage gaps (not examined)

- **Runtime appearance/pixel validation.** No UI/window-opening tests were run (per
  constraints). Dark-mode contrast of the custom `ChromeTheme` themes, actual hit-target
  sizes, and focus-ring visibility on `.buttonStyle(.plain)` controls were assessed
  statically only.
- **WebView-rendered chrome.** The CodeMirror/Mermaid/Canvas surfaces render their own
  HTML/CSS UI (`Resources/codemirror`, `mermaid`, `canvas`) — their control sizing,
  dark-mode theming, and cursor behavior are outside this static Swift pass.
- **VoiceOver / keyboard-only navigation** behavior (rotor order, focus traversal
  through the hand-rolled segmented control and custom buttons) was not exercised.
- **Localization / RTL layout** — fixed-width fields and truncation behavior under long
  localized strings were not evaluated.
- **`ChromeTheme` custom themes** (`ChromeTheme.swift`) — whether user/preset themes can
  produce insufficient-contrast or non-HIG color combinations was not deeply audited.
- **Full menu-item audit** — I confirmed the standard menu skeleton and key equivalents
  for the app/Window/Help menus but did not verify every File/Edit/View item's shortcut
  against HIG-reserved combinations.
- **Sheet/dialog content** — the 12 `.sheet` and 5 `.popover` sites were enumerated and
  spot-checked (usage looked appropriate: modal tasks in sheets, transient info in
  popovers) but not individually reviewed for button ordering (Cancel/Default placement)
  or escape-to-dismiss.
