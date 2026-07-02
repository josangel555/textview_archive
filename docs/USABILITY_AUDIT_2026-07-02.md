# App-wide feature audit — completion, usability, cohesion (2026-07-02)

> **Owner brief:** "We've built many incoherent features, but almost all are unusable.
> Editor, vim, tabs, file-nav work; the rest is unfinished, unpolished, or unusable." This
> audits the feature surface: what was attempted, its completion + usability state, grouped
> into a hierarchy, with the systemic themes, gaps (→ tickets), and a production-grade path.

**Scope of evidence:** the `Sources/ViewerUI` (454 files) + `ViewerCore` (455) trees, the
CHANGELOG build-activity signal, the BACKLOG P1 catalog (which itself repeatedly flags
"model done / view pending"), the board, and direct session knowledge. Confidence is noted
where an assessment needs on-screen re-verification (the owner's own bar: model-green ≠ usable).

---

## ⚠️ CODE-VERIFICATION CORRECTION (owner: code is source of truth, not tickets/docs)

**The first-pass thesis below was drawn from the BACKLOG/tickets and is WRONG where I've
checked it against code. This is itself the #1 finding.** Spot-checking the three flagship
"model-only, UI-abandoned" claims against actual source:
- **Image editor** — ticket TSK-1048 says "~4 real capabilities wired." CODE: the tool picker
  wires **10** (brush, airbrush, eraser, colorPicker, floodFill, drawLine/Rect/RoundedRect,
  selectRect, selectLasso). **Ticket stale.**
- **CSV multi-cell select/copy** — TSK-924 says model-only. CODE: `CSVRectSelection` +
  `isInSelectionRect` + NSPasteboard copy are **in `CSVTableView.swift`**. **Ticket stale.**
- **LSP completion** — TSK-463/1136 say "not wired." CODE: `autocompletion` is imported and
  invoked in `codemirror.html` (TSK-1136 factory). **Ticket stale.**

3-for-3 refuted. So the dominant pattern is NOT "model built, UI missing" — it is **the board
and docs badly under-report what the code actually does** (~417 items sit at review/fixed;
many are likely done or done-differently). The real usability problem, therefore, is much more
likely **quality / polish / bugs / UX / cohesion in features that ARE wired** than wholesale
missing UI. Every per-feature state below marked from tickets is SUSPECT until code-verified;
subsequent passes replace each with a code-read verdict. **Methodology for the rest of this
audit: read the view + its wiring, exercise the path mentally/on-screen, THEN judge — never
trust the ticket's self-description.**

## THE OVERARCHING THEMES (first-pass — Theme 1 corrected above)

### Theme 1 (CORRECTED) — Board/doc ≠ code: pervasive stale tracking
The tracker is not a reliable map of the product. Tickets say "model-only" for features that
are fully wired; ~417 items await "owner close" that may already be shipped. This is the
owner's stated concern made concrete, and it means **any audit or planning that trusts the
board is built on sand.** Fix: a code-first reconciliation — for each feature, the code
verdict is authoritative; the board gets corrected to match (or the divergence filed).
The likely real defects are polish/quality/UX/cohesion, not missing implementations —
which changes the whole remediation plan (finish-the-polish, not build-the-UI).

### Theme 2 — Scattered / non-cohesive entry points
Features accreted their own entry mechanisms — some menu-only, some command-palette-only,
some env-var-only (`MDV_START_AUDIO_EDIT=1`, `MDV_UI_SCENE`), some reachable only after a
specific file type opens. There is no single coherent "here's everything the app does"
surface, so built features are undiscoverable. Command-palette parity is itself an open
item (TSK-951/1186: "remaining menu-only commands"). Menu reorganization is open
(TSK-751/1318). **Owner-felt:** "I didn't know that existed / I can't find it."

### Theme 3 — Purposefulness drift (breadth over depth)
The app spread across ~30 feature areas (editor, hex, CSV, PDF, SQLite, image editor, audio
editor, video, terminal, LSP, git, code review, walkthrough, canvas, RSS reader, HTTP client,
folder treemap, feed reader, monitor…). Many are single-developer-session spikes that never
reached daily-driver quality. **The question each feature must answer:** is this core to
"a fast, agent-friendly document/code workspace," or a spike that should be finished-or-cut?
Several (HTTP client, RSS reader, folder treemap, SQLite browser) read as exploratory.

### Theme 4 — The render-validation gap institutionalized deferral
Because UI/pixel validation was hard (host can't test SwiftUI-over-WebView; the VM T5 lane
needs an owner TCC grant — TSK-1334), "leave it at review for the owner" became the default
exit for anything visual. That converted "unfinished UI" into a permanent state. The VM lane
is now largely usable (owner 2026-06-29); the deferral habit outlived its cause.

---

## FEATURE HIERARCHY + completion/usability state

Legend: **✅ usable** (works on screen, owner-confirmed or high-confidence) · **🟡 partial**
(works but unpolished / rough edges / gaps) · **🟠 model-only** (engine built, UI unfinished/
unreachable) · **🔴 broken/absent** (doesn't work or missing) · **🅿️ parked**.

### A. Core text editing — ✅ the working spine
- CodeMirror 6 editor (`CodeMirrorEditorView`) — ✅ works
- Vim mode — ✅ works
- Syntax highlight (tree-sitter, `Highlight/`) — ✅ works
- Source gutter / line numbers (`SourceGutterView`) — ✅ works
- Find in editor (`MarkdownFindBar`/`FindCoordinator`) — 🟡 works; edge bugs open (TSK-1188 click-after-scroll, TSK-891 page-up jank, TSK-1271 rendered-find scroll)
- Scroll restore (tab/session) — 🟡 rendered confirmed; editor scroll-to-line automation contested (TSK-1200, owner-parked)
> **Verdict: the spine is solid.** Polish the find/scroll edge bugs; otherwise production-grade.

### B. Navigation & workspace — 🟡 mostly works, rough edges
- Tabs (`TabBar`) — ✅ works
- File nav / sidebar (`SidebarView`, `Sidebar/`) — 🟡 "mostly works" (owner); TSK-1314 side-nav shows when toggled off; TSK-283 enter-to-rename missing
- Sessions (`Sessions/`) — 🟡 large system; TSK-1303 edit-state reset on switch, TSK-1308 music stops on switch, TSK-1311 persistence umbrella
- Command palette (`CommandPaletteView`) — 🟡 works; parity gaps (TSK-951/1186)
- Bookmarks / history / recent (`BookmarksSection`, `RecentChangesSection`) — 🟡 present; polish unknown
- Cross-file search (`CrossSearchPanel`) — 🟡 present; usability unverified
- Go-to-path / go-to-line (`GoToPathPrompt`) — 🟡 present
> **Verdict: functional workspace, needs a polish + cohesion pass** (esp. sessions + sidebar edges).

### C. Document viewers — 🟡/🟠 mixed
- Markdown rendered (`MarkdownRenderedView`) — ✅ works (find, print/PDF)
- HTML rendered (`HTMLRenderedView`) — 🟡 works
- Hex viewer (`HexView`) — 🟡 works; TSK-1032 video-in-hex blank
- CSV table (`CSVTableView`) — 🟠 renders; **multi-cell select/copy + viewport paging are model-only** (TSK-924/1139)
- PDF (`MediaPreviewView` + `PDFSearcher`) — 🟡 view + find work; TSK-1140 tail
- SQLite browser (`SQLiteBrowserView`) — 🟡 present; depth/usability unverified — **purposefulness Q**
- DOCX/XLSX (TSK-1145/1141) — 🟠 xlsx model-only; docx viewer open
> **Verdict: viewers mostly render; the DATA-interaction layer (select/copy/page/edit) is the model-only tail.**

### D. Media editing — 🟠 the biggest model-done/UI-abandoned cluster
- Image editor (`ImageEditorView(Model)`, `ImageEditing/`, epic TSK-1048) — 🟠 **~4 of ~15 built
  capabilities wired**; large tested model (selection, crop, resize, layers, transforms) NOT
  reachable; sync/clunky perf (TSK-1052 dirty-rect model done, render tail open); no image
  creation flow wired (TSK-1054); undo gaps. **THE flagship example of the theme.**
- Audio editor (`AudioEditorView(Model)`, TSK-529/533) — 🟠 waveform/transport built; spectrum +
  trim/fade handles + save-as are the render/live tail (at review, live-validation-blocked)
- Video — 🔴 playback only; editing absent
> **Verdict: media editing is a large investment stuck at model-complete. Either finish image-
> editor to MS-Paint parity (the epic exists) or cut scope to a polished subset. Pick.**

### E. Dev / code tooling — 🟡/🟠 mixed, several model-only
- LSP (`LSP/`) — 🟡 diagnostics/hover work; **completion not wired into CM6** (TSK-463/1136);
  binary-picker UI gated on a security decision (TSK-1128/1129)
- Git (diff gutter, file history, reconcile) — 🟡 gutter+history present; TSK-910 diff single-line
  select; reconcile/disk-conflict is model-done + data-safety tail (TSK-764/1165/1166)
- Code review (`Review/`, epic TSK-537) — 🟠 epic; commit-diff/comments/export incomplete
- Terminal (`Terminal/`) — 🟡 works; TSK-1312 colors, TSK-1313 size caps, TSK-1317 drag,
  TSK-769 UX bundle, TSK-1176 palette (model-only)
- HTTP client (`HTTPClientView`) — 🟡/🟠 present — **purposefulness Q** (is this in-scope?)
- Structural search / script window / task-runner (TSK-698/703/722/723) — 🟠 host engines built, render tail
> **Verdict: dev tooling is half-wired. LSP completion + git-diff selection are the highest-value finishes.**

### F. Authoring / generative — 🅿️/🟡
- Canvas (WYSIWYG, M0→M6) — 🅿️ **complete + validated + hardened; parked pending owner review**
- Walkthrough (`Walkthrough/`) — 🟡 engine exists; authoring path + samples open (TSK-1326); dogfood pending
- Mermaid / diagrams — 🟡 rendering works (vendored)
> **Verdict: Canvas is the one feature FINISHED end-to-end this session. Walkthrough needs an authoring UX.**

### G. Agentic / observability — 🟡
- Claude monitor (`ClaudeMonitor/`, `Observability/`) — 🟡 present; usability/polish unverified
- Automation / MCP (`Automation/`) — ✅ the agent tool surface works (Canvas proved it end-to-end)
- AX-driven testing — 🔴 blocked (TCC, the one off-limits lane)
> **Verdict: the agent-facing surface is solid; the human-facing monitor UI needs a usability pass.**

### H. Content / feeds / misc — 🟠 exploratory, likely finish-or-cut
- RSS/feed reader (`FeedReaderView`, TSK-955/1149) — 🟠 model+view built, mount-tail occlusion — **purposefulness Q**
- Folder treemap / stats (`FolderTreemapView`, TSK-506) — 🟠 layout core done, render at review — **purposefulness Q**
- Metadata panel (`MetadataPanel`) — 🟡 present
> **Verdict: these read as spikes. Decide: finish to daily-driver quality or cut to reduce surface.**

### I. Platform / chrome — 🟡
- Settings (`SettingsView`, `PluginsSettingsView`) — 🟡 works; menu reorg open (TSK-751/1318)
- Plugins (Tier-D contract, TSK-1138) — 🟡 contract delivered, ratify pending
- Tool windows / docking / split panes (`DockedToolWindow`, `SplitPaneView`, `PanelLayoutStore`) —
  🟡 works; TSK-1313 size-restriction removal, TSK-1123 placement UI, TSK-1104/1111 multi-window
- Theming — 🟡 works
- Key-event routing — 🔴 **TSK-1315: keystrokes leak to wrong recipient** (a cohesion/quality bug affecting many features)
> **Verdict: chrome works; the key-event routing bug + panel size caps are cross-cutting quality issues.**

---

## PRODUCTION-GRADE PATH (how to fix the class, not the instances)

1. **Redefine "done."** A feature ships when it is *reachable* (a discoverable entry point),
   *usable* (the core task completes on screen without a workaround), *polished* (no obvious
   rough edge), and *confirmed on screen* (T6 partial). Model-green is a checkpoint, not done.
2. **Close the model-only tails, feature by feature, to on-screen-validated.** The BACKLOG P1
   list IS the queue; each item's "build the view" tail is the work. Prioritize by daily-driver
   value: LSP completion → CSV data-interaction → git-diff selection → image-editor wiring →
   terminal UX → sessions polish.
3. **One cohesion pass on entry points.** Command-palette parity (every action reachable there)
   + a menu reorganization + kill env-var-only entries. Make the app self-describing.
4. **Finish-or-cut the exploratory spikes.** HTTP client, RSS reader, folder treemap, SQLite
   browser: each gets an owner decision — invest to daily-driver quality, or remove to shrink
   the surface and raise coherence.
5. **Fix the cross-cutting quality bugs first** (they tax every feature): key-event routing
   (TSK-1315), pane size caps (TSK-1313), the render-validation habit (use the now-open VM lane).
6. **Per-feature production-grade rubric** (apply in each finish ticket): correctness · reachable
   entry · empty/error/loading states · keyboard access · perf/latency on the hot path ·
   visual polish · a T6 on-screen confirmation. File each as the feature's "→ production-grade" ticket.

---

## GAPS FILED (this audit → board)
See the `[AUDIT]`-tagged tickets filed 2026-07-02 (systemic + per-family finish tickets),
parented where a milestone/epic exists. The systemic tickets (redefine-done, cohesion pass,
finish-or-cut decisions, key-event routing) are the highest leverage.

## NEXT (this is a multi-pass audit)
This is the foundation pass (hierarchy + themes + state + path). Subsequent passes: (a) deep
per-feature production-grade specs for the top finish targets; (b) on-screen re-verification of
the 🟡/🟠 assessments (owner's bar: confirm usability on the real UI, not from code); (c) the
finish-or-cut owner decisions for the exploratory spikes.

---

## CODE-VERIFICATION LOG (append per pass — code verdicts replace ticket-derived states)

### Pass 2 (2026-07-02) — document viewers + command surface

**Verdict: the CORE is substantially more built, cohesive, and tested than pass-1 (ticket-
derived) implied.** Code-reading three central areas found them near-production-grade, three
tickets stale, one real gap (fixed), one real gap (confirmed, deferred):

| Area | Code verdict | Ticket said | Delta |
|---|---|---|---|
| CSV viewer (`CSVTableView`, 974 ln) | keyboard cell-cursor, find-in-table, filter, sort, multi-cell rect-select + NSPasteboard copy, formula gate — all WIRED | TSK-924 "multi-cell model-only" | **ticket STALE** |
| CSV viewport paging (`CSVViewportPager`) | **0 refs in the view — genuinely not wired** (large-file perf gap) | TSK-1139 "done, not wired" | **ticket ACCURATE** — real gap, render-VM slice |
| CSV empty-state | was a blank void on empty/filtered-nothing → **FIXED** (TSK-1415, `CSVEmptyState`) | (unticketed — found by code-read) | **new gap, closed** |
| Hex viewer (`HexView`, 1517 ln) | hex/ASCII search, "0 matches"/"N/M+", truncation handling, chunked streaming + placeholder, match-cap, edit mode | — | **production-grade already** |
| Command surface (`CommandRegistry+BuiltIn`, 116 cmds/11 cats + 490-ln test) | comprehensive; unique-ids/namespacing/palette-parity all tested; 13 `scriptVerb:nil` are CORRECTLY nil (interactive dialogs/window ops) | Theme-2 feared scatter | **cohesive; palette parity largely done (TSK-951)** |
| Image editor tool picker | 10 tools wired (brush/airbrush/eraser/colorPicker/floodFill/drawLine/Rect/RoundedRect/selectRect/selectLasso) | TSK-1048 "~4 capabilities" | **ticket STALE** |
| LSP completion | `autocompletion` wired + invoked in `codemirror.html` | TSK-463/1136 "not wired" | **ticket STALE** |

**Implication for the plan (revised):** the remediation is NOT "build missing UI." It is, in
priority order: (1) **reconcile the stale board to code** (TSK-1412 — 4 stale tickets found in
one pass; extrapolates to many of the ~417) so planning rests on truth; (2) fix the genuinely-
thin spots + real gaps (CSVViewportPager perf, and whatever code-reads surface next); (3)
cohesion/discoverability of LESS-central features + cross-cutting bugs (key-event routing
TSK-1315); (4) finish-or-cut the exploratory spikes (TSK-1414). The well-built core mostly needs
targeted polish (empty-states, edge bugs), not rebuilding. **Owner's "almost all unusable" reads,
at the code level, as: a few thin spikes + discoverability + a badly stale tracker — the core is
sound.** (Caveat: on-screen re-verification of the 🟡 features is still owed per the render bar;
this pass verified code-wiring, which for these native-SwiftUI/CM6 features is high-signal.)

### Pass 2 addendum (self-correction) — distinguish BACKLOG.md-file lag from BOARD state

Deeper check corrects pass-2's own "board badly under-reports code" claim — it was **too
strong**. Reconciling one flagged ticket against the live board (not the BACKLOG.md file):
- **TSK-924** (CSV multi-cell) board state = `review`, with a careful reconciliation: model
  host-tested (CSVRectSelection 5/5, CSVCopy, CSVClipboard, EditableCSVModel.paste), view
  wired (rect→⌘C→NSPasteboard, Copy Row/Col context menu), and an HONEST ceiling note — the
  focus-gated selection tint + the shift-select gesture (AX) genuinely can't be host-confirmed
  (ImageRenderer has no focus engine; AX is the one off-limits lane). So the ticket is **not
  stale** — it's accurately at review with a real render/AX tail.

**Refined finding:** the staleness is layered — (a) the **BACKLOG.md FILE lags** (it says
"model-only" for features the board already reconciled; the file's own header admits it lags);
(b) the **board tickets are largely honest**, sitting at `review`/`fixed` with real render/AX-
confirmation tails; (c) my pass-2 conflated the two. The genuine systemic pattern is therefore:
**features are model-complete + view-wired, stuck at an honest on-screen/AX confirmation tail**
that is the SAME owner-gated bar the whole app hit (TSK-1334 pixel grant + the AX lane) — NOT
incompleteness, and NOT a dishonest board. So TSK-1412 shrinks from "reconcile a dishonest
board" to "refresh the lagging BACKLOG.md file + close the review-lane items whose only gap is
the owner-gated render/AX confirmation." The real agent-actionable polish is the genuine gaps
code-reads surface (e.g. the CSV empty-state, TSK-1415) + the thin spikes + cross-cutting bugs.
