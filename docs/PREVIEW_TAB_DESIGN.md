# Preview-tab / scrub — design breakdown (TSK-306 + TSK-272)

**Status:** breakdown / spike (no code yet). One owner decision gates implementation — see
**§4**. Authored by the autonomous loop 2026-06-07; grounds the recurring "preview" requests
into one executable plan.

## 1. The feature (what the owner asked for)

Two board tasks describe **one** feature — the VSCode/Xcode "preview tab" (a.k.a. *ephemeral*
or *italic* tab):

- **TSK-306** — "by selecting or clicking on a file it should preview, but only persists on
  Enter/double-click." → *single-click in the sidebar opens the file in an ephemeral preview
  slot; Enter or double-click promotes it to a permanent tab.*
- **TSK-272** — "Up/Down on the file nav should change current tab content." → *the keyboard
  equivalent: arrowing the sidebar selection swaps the preview slot's content.*

So the unified model: **at most one preview tab per session.** Navigating files (click or
arrow) reuses that single slot instead of spawning a tab per file. The preview is "promoted"
to a normal tab on an explicit commit gesture.

### Promotion (preview → permanent) triggers — VSCode parity
- Double-click the sidebar row, or press **Enter** on the selection.
- **Editing** the file (the preview becomes dirty → must persist).
- Dragging the tab, or any "pin" affordance.
- Opening a *second* file while the first preview is dirty (can't silently discard edits).

## 2. Current behavior (baseline, file:line)

- Sidebar rows open **immediately + permanently** on a single click:
  `Sources/ViewerUI/SidebarView.swift:257` and `:1174` → `model.open(url:)`. Arrow keys move
  the highlight only (no content change) — TSK-272's gap.
- Tab open/reuse funnels through `TabCoordinator.openOrReveal(url:state:viewMode:)`
  (`Sources/ViewerUI/Coordinators/TabCoordinator.swift:219`) → `tabs.openOrReveal(...)`
  which **reveals an already-open tab or appends a new one.** There is no "reuse this one
  slot regardless of URL" path — that's the new primitive.
- `Tab` (`Sources/ViewerCore/Tab.swift`) is `Codable` + custom `Equatable` (identity-based:
  id/url/viewMode/isDirty/diskState/categoryOverride). Sessions persist the full tab list
  (`SessionStore`).

## 3. Proposed architecture (host-testable core first)

Mirror the fold/indent-guides pattern: land a **pure, unit-tested model core**, stage the
SwiftUI triggers + visual affordance (live/VM-validated) behind it.

### Phase 1 — model core (host-testable, no UI) ⟵ the bulk of the value, de-risks the rest
- `Tab.isPreview: Bool` (default `false`). **Not persisted for free**: `Tab` is *not* `Codable`
  — sessions serialize a separate `TabSnapshot` DTO (`Sources/ViewerCore/Tab.swift:4` is
  `Sendable, Identifiable` only). `TabSnapshot` simply won't carry `isPreview`, so a relaunch
  rehydrates every tab as permanent — Option A (§4) with zero codec surgery. Added to `Tab`'s
  custom `Equatable` so the (future) italic-title affordance re-renders on promote.
- `TabCoordinator.openPreview(url:state:viewMode:) -> Int`:
  - If a preview tab exists → **replace its content in place** (same tab id, new url/state),
    keep it flagged preview, select it.
  - Else → append a new tab flagged `isPreview = true`, select it.
  - If the URL is already open in a **permanent** tab → just reveal it (don't preview).
- `TabCoordinator.promoteTab(id:)` → clears `isPreview` (the "pin"). Idempotent.
- Auto-promote hooks: `updateEditorText` / `setEditorBuffer` on a preview tab → `promoteTab`.
- Invariant test: **never two preview tabs**; opening-permanent never sets the flag.

### Phase 2 — triggers (SwiftUI; live-validated)
- Sidebar single-click → `model.openPreview(url:)`; double-click / Enter → `model.open(url:)`
  (promote-or-open). Arrow Up/Down on a focused sidebar → `openPreview` of the newly-highlighted
  row (TSK-272). Needs a single-vs-double-click discriminator (`TapGesture(count:2)` +
  fallback) — the fiddly AppKit/SwiftUI part.

### Phase 3 — visual affordance (VM-visual only)
- Italic tab title for the preview tab (VSCode convention). Tiny `TabBar` change.

## 4. DECISION NEEDED (owner) — the one real gate

**Preview-tab persistence across an app relaunch / session save.** Three options:

| Option | Behavior | Pro | Con |
|---|---|---|---|
| **A. Promote on save (recommended)** | Preview tabs persist as *normal* tabs across relaunch | No data/tab loss; trivial (just don't encode `isPreview`) | Slightly less "ephemeral" than VSCode |
| B. Drop on save | Preview tabs vanish on relaunch (pure VSCode) | Matches VSCode exactly | This app's whole value-prop is session persistence — surprising here |
| C. Persist as preview | Relaunch restores the italic preview tab | Most faithful | Codec + multi-window/session edge cases; most work |

**Recommendation: A.** It's the safe default, needs zero codec surgery (omit the flag), and
respects the app's persistence-first identity. The owner can upgrade to C later additively.

Until the owner rules, Phase 1 will assume **A** (it's the zero-risk default and doesn't
foreclose B/C).

## 5. Risks / notes
- Single-vs-double-click on a SwiftUI `List` row is historically finicky on macOS; budget
  Phase 2 for gesture tuning + a `MANUAL_TESTING.md` entry.
- `openOrReveal`'s "reveal if already open" must take precedence over preview (don't preview
  a file that already has a permanent tab).
- Split-view + sessions(tabs-within-tabs) interaction: a preview tab is per-session; confirm
  it doesn't leak across session switches (the existing per-session tab list already isolates
  this, but add a test).
