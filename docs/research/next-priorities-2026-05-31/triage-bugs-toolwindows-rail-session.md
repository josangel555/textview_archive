# Triage — bugs:toolwindows-rail-session

Confirmed. The SessionTabBar `+` button uses the dedicated `requestNewSessionViaGoTo()` (which arms the gate WITHOUT opening a folder — the prompt then asks the user for a path). That means `openFolder(forceNew: true)` arming the gate is redundant *and* harmful: every caller of `openFolder(forceNew: true)` already knows the folder, so the gate-arming branch (SessionsAppCoordinator.swift:111-113) has no legitimate use — the `+` button doesn't even go through it. The fix is to stop arming the gate inside `openFolder(forceNew:)`.

I have all three bugs fully traced with code citations. Writing up the triage.

---

### 1. "Row count" tool window always visible, no dismiss toggle

**Status today**
- The "ROW COUNTS" window is the bundled `RowCounterPlugin`, which registers a sidebar section (`Sources/ViewerCore/Plugins/BundledPlugins/RowCounterPlugin.swift:34-45`, title `"ROW COUNTS"`). It is **not** tabular-file-specific — its provider counts lines of *every open file* (`RowCounterPlugin.swift:51-62`), so it shows for all files, not just CSV/SQLite.
- It renders through `PluginSidebarSections` (`Sources/ViewerUI/PluginSidebarSections.swift:16-30`), which pulls every registered section from `PluginRegistry.shared.sidebarSections.all`.
- `SidebarView` mounts `PluginSidebarSections` **unconditionally** at `Sources/ViewerUI/SidebarView.swift:122-124` — it is rendered directly in `sidebarBody`, outside the `accordionStack`/`SidebarSectionPlanner` plan that gates every other panel.
- The rail *does* have a button for it: `pluginSections` is the 9th entry in `SidebarPanelRegistry.defaultOrder` (`Sources/ViewerCore/SidebarPanelRegistry.swift:20-30`), icon `puzzlepiece.extension`. Clicking it flips the override via `panelLayout.toggle(.pluginSections, …)` (`ShoulderRailView.swift:93`).

**Root cause / gap**
- Two compounding gaps:
  1. `PluginSidebarSections` is rendered raw in `SidebarView.swift:122-124` and never consults `panelLayout.isVisible(.pluginSections, dataPresent:)`. Every other panel resolves through `panelVisibility` (`SidebarView.swift:189-209`) → `SidebarSectionPlanner`. The plugin panel bypasses that entirely, so the rail toggle's `.hidden` override is computed but never read for this panel — the button is a dead toggle.
  2. Data-presence for `.pluginSections` is hard-coded `true` (`Sources/ViewerCore/SidebarDataPresence.swift:57`), so even if it *were* gated, `.auto` would always resolve visible. That's intended ("a plugin section appears regardless of folder"), but it means the *only* way to hide it must be the explicit `.hidden` override — which is exactly the path that isn't wired.

**Fix / build sketch**
- Gate the mount on the resolved visibility, mirroring the accordion. In `SidebarView.sidebarBody`:
  ```swift
  if panelLayout.isVisible(.pluginSections,
                           dataPresent: SidebarDataPresence.isPresent(.pluginSections, presenceInputs)) {
      PluginSidebarSections(model: model)
          .environment(\.sidebarSectionBodyHeight, …)
  }
  ```
  where `presenceInputs` is the same `SidebarDataPresence.Inputs` already built in `panelVisibility` (lift it into a computed property so the rail-fill, accordion, and this gate read one source — the file's own header comment at `SidebarView.swift:36-49`/`SidebarDataPresence.swift` insists on that single-heuristic discipline).
- No change needed in `PanelVisibilityResolver`/override types — `.hidden` already resolves to `false` (`PanelVisibilityResolver.swift:42`). Once the mount honors `isVisible`, the existing rail button starts working.

**Size:** S. One conditional in `SidebarView`, reusing existing `panelLayout.isVisible` + `SidebarDataPresence`. The presence-inputs are already computed in the same file.

**Dependencies:** None — all machinery (`PanelLayoutStore`, override persistence, rail button) exists. This is purely closing the gating gap.

**Risk / one-way-door:** Low. Watch one interaction: `leftContainerVisible` (`ContentView.swift:250-256`) only considers `railPanels(on: .left)` — `pluginSections` *is* in that list, so a folder-less window where the user has hidden everything except plugins still keeps the accordion container alive; gating the plugin panel makes the container math honest rather than breaking it. No persistence migration (overrides already persist via `PanelVisibilityOverrides`).

---

### 2. Shoulder buttons 4, 5, 6 do nothing

**Status today**
- Rail buttons are 1:1 with `SidebarPanelRegistry.defaultOrder` rendered by `ShoulderRailView.body` → `ForEach(panels)` (`Sources/ViewerUI/ShoulderRailView.swift:52-59`). With the default left-only layout the order is: 1 `files`, 2 `bookmarks`, 3 `searchAnywhere`, **4 `git`**, **5 `claudeTimeline`**, **6 `lspOutline`**, 7 `lspNavigation`, 8 `lspProblems`, 9 `pluginSections` (`SidebarPanelRegistry.swift:20-30`).
- Each button *does* fire: `action: { panelLayout.toggle(kind, dataPresent: present) }` (`ShoulderRailView.swift:93`), and `toggle` correctly flips the override and persists (`PanelLayoutStore.swift:82-86`, `PanelVisibilityOverrides.swift:51-53`).
- The accordion reads that override: `panelVisibility` → `panelLayout.isVisible(kind, dataPresent:)` (`SidebarView.swift:206-208`), and `panelView(for:)` returns the real section view (`SidebarView.swift:238-249`).

**Root cause / gap**
- The toggle works; the **section views self-gate on their own internal data and discard the `.shown` override**:
  - `GitPanelSection` returns `EmptyView()` when `panel.repoRoot == nil` (`Sources/ViewerUI/Git/GitPanelSection.swift:24-36`).
  - `ClaudeTimelineSection` returns `EmptyView()` when `transcriptCount == 0` (`Sources/ViewerUI/ClaudeTimelineSection.swift:24-37`).
  - `LSPOutlineWrapper` renders nothing unless `outline.isSupported` (`Sources/ViewerUI/SidebarView.swift:988-1003`).
- So for buttons 4/5/6 in the common case (no git repo / no Claude transcripts / current tab isn't an LSP language), the flow is: click → override becomes `.shown` → `isVisible` resolves `true` → `panelView(for: .git)` is mounted → **the section's own `if … else { EmptyView() }` swallows it**. Net visual result: nothing. The toggle is real but invisible, which reads as "the button does nothing."
- Secondary contributor: when `dataPresent` is already `false` and the override is `.auto`, the very first click sets `.shown` (`toggle` line 52) — correct intent — but the self-gate defeats it. (If data *is* present, the first click hides the section, which *does* visibly work — consistent with "does nothing only when empty.")
- Note the user's framing ("git log / changes") is a mental-model mismatch: these buttons toggle *panel visibility*, they are not separate log/changes commands. The git log/changes views live as tabs *inside* `GitPanelSection` (`gitPanelDesiredTab`, `GitPanelSection.swift:47-56`), reachable only once the panel is shown.

**Fix / build sketch**
Two viable directions; pick per product intent:
- **(A) Honor the forced-`.shown` override in the section views.** Thread the resolved visibility (or just an `isForcedShown` bool) into `GitPanelSection`/`ClaudeTimelineSection`/`LSPOutlineWrapper` and render a placeholder ("Not a git repository", "No Claude transcripts", "No language server for this file") instead of `EmptyView()` when forced on. This matches the *documented* intent of `.shown` in `PanelVisibilityOverrides.swift:13-16` ("user forced the panel on even when it has no data … A two-state boolean can't express this — it would be a dead button"). The infrastructure was built for exactly this; the section views just never consumed it.
- **(B) Make the rail buttons reflect the self-gate.** If a panel can't show anything, disable/hide its rail button. This is the smaller change but contradicts the deliberate `.shown` design and removes the "open Git panel in a non-repo to see the placeholder" affordance the override type was created for.

Recommend **(A)**. Build: each section already has the data signal (`panel.repoRoot`, `transcriptCount`, `outline.isSupported`); replace the bare `EmptyView()` branch with a placeholder gated on `override == .shown`. Pass the override down from `SidebarView.panelView(for:)` (it already has `panelLayout`).

**Size:** M. Three section views touched, plus threading the override (or a `forcedShown` bool) through `panelView(for:)`. Each placeholder is a few lines. No new types. (Option B would be S but is the wrong design.)

**Dependencies:** None hard. `PanelOverride`/`PanelVisibilityResolver` already exist. Cleanest if done after item 1 (both touch `SidebarView`'s presence-inputs plumbing — share the lifted `SidebarDataPresence.Inputs` computed property).

**Risk / one-way-door:** Low–medium. The placeholders are new always-on-when-forced UI; verify they don't fight the `SidebarSectionPlanner` divider logic (a forced-shown-but-empty panel must count as "visible" for divider placement — it will, since `isVisible` returns `true`). Pinned by `PanelLayoutRepublishInvariantTests` / `PanelLayoutResolutionTests`; re-run those plus the section suites. No persistence change.

---

### 3. "Open in New Session" pops the Open dialog instead of using the right-clicked folder

**Status today**
- Menu item: `FileRowContextMenu` for folders — `Button("Open in New Session") { openInNewSession(node.url) }` (`Sources/ViewerUI/SidebarView.swift:591-595`), where `openInNewSession = model.openFolderInNewSession`. The known folder URL (`node.url`) **is** passed in correctly.
- `model.openFolderInNewSession` is wired in `main.swift:202-204` to `{ url in self.sessions.openFolder(url, forceNew: true) }`.
- `SessionsAppCoordinator.openFolder(_:forceNew:)` (`Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:109-115`) does **two** things on `forceNew: true`:
  1. Arms the first-paint GoTo gate and bumps `firstPaintGoToToken = UUID()` (lines 110-113).
  2. Calls `core.openFolder(url, forceNew: true)` (line 114) — which **does** create the session with `sidebarRootPath: resolvedPath` from the passed URL (`Sources/ViewerCore/Sessions/SessionsCoordinator.swift:179-213`).
- The token bump is observed by `FirstPaintGoToBridge.onChange(of: sessionsApp.firstPaintGoToToken)` → `model.showGoToPath()` (`Sources/ViewerUI/ContentView.swift:991-996`), which presents `GoToPathPrompt` (`ContentView.swift:168-175`).

**Root cause / gap**
- The folder is **not** lost — `core.openFolder` opens it correctly. The bug is that `openFolder(forceNew:)` *additionally* arms the first-paint GoTo prompt, which then pops on top of the just-opened session. To the user that reads as "it opened the dialog instead of my folder."
- The gate can't distinguish the two intents because `FirstPaintGoToGate.recordOpenFolder(forceNew:)` arms on *any* `forceNew == true` (`Sources/ViewerCore/Sessions/FirstPaintGoToGate.swift:36-38`):
  - **"+" / empty-session entry** wants the prompt — but it does **not** go through `openFolder`; it uses the dedicated `requestNewSessionViaGoTo()` (`SessionTabBar.swift:89` → `SessionsAppCoordinator.swift:130-133`), which arms the gate *without* opening a folder.
  - **"Open in New Session" (and `GoToPathPrompt`'s own system-dialog path, `GoToPathPrompt.swift:231-232`)** already know the folder and must **not** re-prompt.
- So the gate-arming branch inside `openFolder(forceNew:)` (`SessionsAppCoordinator.swift:111-113`) has **no legitimate caller** — every real `forceNew: true` caller already supplies the folder. It's a stray arm that only ever produces the spurious prompt. The `+` button's prompt path is entirely separate.
- Note: the headless `commitGoToPath(_:newSession:)` (`DocumentModel.swift:578-594`) and `OpenInNewSessionTests` (`Tests/ViewerUITests/OpenInNewSessionTests.swift`) exercise `openFolderInNewSession` *as a closure* but stub it (`model.openFolderInNewSession = { newSessionCalls.append($0) }`, line 44) — so they never run the real `SessionsAppCoordinator.openFolder`, which is why this gate-arm slipped through the unit tests. It's a live-app-only defect (the `OpenInNewSessionUITests.swift` VM suite is where it'd surface).

**Fix / build sketch**
- Remove the gate-arming from `openFolder(_:forceNew:)`. In `SessionsAppCoordinator.swift:109-115`, drop lines 110-113:
  ```diff
   public func openFolder(_ url: URL, forceNew: Bool = false) {
  -    firstPaintGate.recordOpenFolder(forceNew: forceNew)
  -    if forceNew, firstPaintGate.isArmed {
  -        firstPaintGoToToken = UUID()
  -    }
       core.openFolder(url, forceNew: forceNew)
   }
  ```
  The empty-session prompt keeps working via `requestNewSessionViaGoTo()` (unchanged). All `openFolder(forceNew: true)` call sites already pass a concrete folder, so none needs the prompt.
- Lower-risk alternative if you want to preserve the gate type's API: split intent at the gate — add a `recordNewSessionWithKnownFolder()` no-op path, or have `openFolder` take an explicit `armGoToPrompt: Bool = false` and only the (currently nonexistent) prompt-driven caller passes `true`. But since no caller needs it, plain removal is cleanest.

**Size:** S. A 4-line deletion in one method. The dead `FirstPaintGoToGate.recordOpenFolder` path can stay (still unit-tested) or be pruned separately.

**Dependencies:** None. `requestNewSessionViaGoTo()` already covers the only intent that wants the prompt.

**Risk / one-way-door:** Low, but add a regression test at the *coordinator* level (the existing unit tests stub the closure and miss this). Assert that `SessionsAppCoordinator.openFolder(url, forceNew: true)` creates a session with the right `sidebarRootPath` and does **not** bump `firstPaintGoToToken`; and that `requestNewSessionViaGoTo()` still bumps it. This is a behavior-only change (no persistence/format), and it's reversible — not a one-way door.

Files of record: `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:109-115`, `Sources/ViewerCore/Sessions/FirstPaintGoToGate.swift:36-38`, `Sources/ViewerUI/ContentView.swift:991-996`, `Sources/MarkdownViewer/main.swift:202-204` & `451-460`, `Sources/ViewerUI/SidebarView.swift:591-595`.