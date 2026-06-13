# Wishlist 2026-06-13 — Triage Report

Disposition of the 184 wishlist intake lines. Each line was deduped against the
`tasked` board (topical match via `task_get`, avoiding the `#NNN` offset trap),
then bucketed (`regression` / `bug` / `minor-feature` / `epic` / `very-large`)
and routed to one of three actions:

- **created** — net-new ticket filed, clear scope, no owner gate.
- **parked** — ticket filed but `task_park`ed behind an owner decision /
  design-review gate (logged in the **Need me** list below).
- **duped** — folded into an existing (or earlier-this-intake) ticket; the
  owner re-raise was recorded as a comment rather than a duplicate ticket.

**Net new tickets filed this intake: 136** (73 created + 63 parked).
**48** wishlist lines deduped onto **28** distinct target tickets — 7 of those
targets were themselves *created earlier in this same intake* (the wishlist
named the same capability from several angles), so the later angles deduped onto
the freshly-filed ticket: `TSK-672`, `TSK-685`, `TSK-714`, `TSK-745`,
`TSK-762`, `TSK-769`, `TSK-777`.

---

## 1. Counts

### By bucket (all 184 lines)

| Bucket          | Count |
|-----------------|------:|
| regression      |     0 |
| bug             |    18 |
| minor-feature   |    88 |
| epic            |    73 |
| very-large      |     5 |
| **Total**       | **184** |

### By action (all 184 lines)

| Action   | Count |
|----------|------:|
| created  |    73 |
| parked   |    63 |
| duped    |    48 |
| **Total** | **184** |

### Created + parked (new tickets) by bucket

| Bucket          | created | parked | new total |
|-----------------|--------:|-------:|----------:|
| regression      |       0 |      0 |         0 |
| bug             |      18 |      0 |        18 |
| minor-feature   |      54 |      4 |        58 |
| epic            |       0 |     54 |        54 |
| very-large      |       1 |      5 |         6 |
| **Total**       |  **73** | **63** |  **136**  |

Every `epic` (and 5 of 5 `very-large`) was parked — epics carry a design-review
/ breakdown gate by definition. The four parked `minor-feature` items are
genuine owner decisions despite the small bucket (`TSK-683` app naming,
`TSK-686` "Signing" ambiguity, `TSK-787` test-framework direction, `TSK-793`
language-survey scope). All 18 `bug` lines were created — concrete, reproducible
defects with no decision gate.

---

## 2. Created tickets, grouped by bucket — the chipping order

Recommended order: **bugs first** (user-facing defects in the running app),
then **minor-features** (bounded wiring of already-built backends), then the
lone **very-large** file-and-forget item last.

### regression (0)
_none_

### bug (18) — chip these first

```
TSK-728  Enter in plain-text editor shifts focus to previous tab / file nav
TSK-729  Switching to View Only doesn't show unsaved edits
TSK-730  Editor missing standard key navigation (Arrow, Cmd/Opt+Arrow, PageUp/Down, Home/End)
TSK-731  "-- emoji" causes extra char in Claude Code tables (editor and terminal)
TSK-732  Font mismatch between View/Edit (and Shoulder); make seamless
TSK-733  Save prompt on session switch despite autosave
TSK-734  Crash switching sessions after save-prompt on unsaved file
TSK-735  Terminal rendering glitches in VIM: footer rendered twice, stale error line
TSK-736  Mouse-over line highlight very laggy on 5000-line log with Find + View Only
TSK-737  Last page(s) of a log file missing line number in shoulder
TSK-738  File status footer missing after relaunch / opening a new project
TSK-739  Dismiss Find bar; Cmd+F again should toggle it closed
TSK-740  Terminal: deleted chars not removed from view; display doesn't match true state
TSK-741  App Not Responding after pasting large JSON in VIM inside Terminal
TSK-742  With View Only disabled, switching files in side nav doesn't change content
TSK-743  Preserve scroll state per file when previewing files
TSK-744  Scroll state of one previewed file carried over to the next
TSK-791  Was CM6 a mistake? Why is the editor so slow? (research/perf)
```

### minor-feature (54) — chip second

```
TSK-671  Text view (plain text viewing)
TSK-672  Git stuff (diff, log, status, blame)
TSK-678  Help page listing all keyboard shortcuts
TSK-681  Export/Import settings + user-friendly settings location (~/.textview)
TSK-684  Export/Import settings + user-friendly ~/.textview settings location
TSK-696  TextView CLI launcher on PATH (like `code`)
TSK-704  Markdown side-by-side editor + live preview
TSK-707  Command palette — double-shift shortcut
TSK-708  Preview definition (IntelliJ's Quick Definition / Cmd+Y)
TSK-709  Unify Cmd+K, Cmd+G
TSK-710  Hover symbol info on variables/symbols (LSP textDocument/hover)
TSK-718  Hot exit
TSK-719  Sticky scroll
TSK-720  Cmd+P like VS Code, Cmd+Shift+P
TSK-724  Recent Locations popup
TSK-726  Project-wide replace (search currently read-only)
TSK-745  New tab shows recent files
TSK-746  Open dialog show recent
TSK-747  New tab: offer other types (Sheet, Image)
TSK-748  File info pane: multi-algo checksums + responsive copy button + metadata
TSK-751  Organize the menu items properly
TSK-752  Decide temp file storage (md render html, git diff): disk vs in-memory FS
TSK-753  Dedicated menu item for the type of file being viewed
TSK-755  Session menu should have a section for Tab operations
TSK-756  Top-right button for opening the command menu
TSK-757  Catalog each keyboard shortcut, compare with Mac apps
TSK-758  Search tool window: header filter buttons (Text | FileName) + regex toggle
TSK-759  Drag to reorder tabs
TSK-760  New Tab needs a [New text file] button
TSK-761  Search tool window: regex search toggle beside Aa (aa | Aa | .*)
TSK-762  Show Wrap/Special-char toggles on details pane; toggle buttons; Terminal header pane
TSK-763  Recents tool window: show folder in grey brackets
TSK-765  Find/Replace: Cmd+F twice hides find, Cmd+F again reopens keeping prev text
TSK-766  Editor: git diff text style match Edit/View
TSK-767  Editor: highlight on-disk changes blue+fade, undo on conflict
TSK-769  Terminal UX bundle (open in pwd, rename, history+favorites+search, colors, copy trimmed)
TSK-770  Find/Replace: add Replace and ReplaceAll to the Find bar
TSK-771  Terminal: right-click tab → Rename; show terminal name
TSK-776  Teeth-demonstrated tests — confirm captured in the SOP, add if missing
TSK-778  How to test MCP/Walkthrough; how persisted/serialized
TSK-783  Lock transitive deps + fail build on drift + owner-approval gate
TSK-784  How to run WebUI/TUI
TSK-785  Disable all optional transitive dependencies
TSK-789  Show supported LSP languages and LSP status in settings
TSK-790  Show supported syntax-highlighting languages in settings (View and Edit)
TSK-792  Are we using modern language/test features? Investigate
TSK-794  Audit: generous multi-threading/async + inlining/specialization/generics?
TSK-795  Test coverage check during build/test
TSK-796  How to do code reviews?
TSK-797  What VS Code toolchains do we get from extensions (Swift/Java/TS)?
TSK-801  How to monitor Claude Code?
TSK-802  How does MCP work?
TSK-803  How to interact with LSP — what can I see/do?
TSK-804  How do Claude timeline, Agent view, Transcript search work?
```

### epic (0 created)
_All epics were parked — see the Need me list._

### very-large (1) — chip last (file-and-forget)

```
TSK-691  Own agent harness
```

---

## 3. Need me — parked items awaiting owner decision (63)

Each is filed and `task_park`ed; the loop moves on. Listed with the open
question that gates work.

### Parked epics (54)

- **TSK-670** PDF reader — read-only viewing vs. annotation/forms/extraction scope?
- **TSK-673** Sheet calculation + formula eval + Excel reading — approve new deps (xlsx reader + formula-eval crate) under minimal-deps policy?
- **TSK-674** Excel reading / eval — go/no-go; read-only .xlsx vs full formula eval; which formats? (likely a new dep)
- **TSK-675** Text Edit (plain text editing) — confirm scope + child-task breakdown for this foundational P0 edit-and-save epic.
- **TSK-676** Built-in browser — confirm MVP scope before design.
- **TSK-677** Unify search types (Global/Recents/Command) — approve shared provider/index model + consolidated UI + cross-type ranking?
- **TSK-679** VIM support (modal editing) — `@codemirror/vim` dependency vs. hand-roll?
- **TSK-680** Rich Text Markdown editor → .rtf/.rtfd/.docx/.doc — approve a third-party OOXML/binary-Word library (.docx/.doc)?
- **TSK-682** Multi-format viewer (RTF/DOCX/PDF/XLSX) — fold PDF into this bundle or keep TSK-670 separate?
- **TSK-685** Spell check / Grammar / LSP checks — NSSpellChecker (no-dep native) vs. heavier custom/grammar engine?
- **TSK-687** Deep agent integrations (ClaudeCode/Codex/Antigravity) — product direction / design.
- **TSK-688** Walkthrough as a presentation — design doc (step model, multi-pane layout, navigation) + breakdown.
- **TSK-690** Tmux -CC control-mode attach — design/scope approval before work.
- **TSK-692** Download & explore dependency source (crate→github) — design/approval gate.
- **TSK-693** Agent-collaboration workbench (tasks/worktrees/review/walkthrough) — approve, and reconcile vs. absorbing into TSK-373/TSK-537.
- **TSK-694** Log-file pattern identification — behavior undefined; design-review gate.
- **TSK-695** Credential recognition / obfuscation / secure handling — design-review gate.
- **TSK-697** Agent Services suite — keep as one epic or split? Fold overlaps (refactor→TSK-640, global search→TSK-677, review→TSK-537/693)?
- **TSK-698** Script command window (JQ-style) — engine choice (embed jq/SQL/scripting vs. DSL) + arbitrary-execution security decision.
- **TSK-699** Agent Services ("what helps an agent work on a project") — open-ended product-level direction.
- **TSK-700** Inter-person + agent collaboration — product direction; design + likely dep approval.
- **TSK-701** Expand Sessions into a full SDLC surface — desired first deliverable ambiguous (product-direction call).
- **TSK-702** Mac's own intelligence for editing/typing/completion — adopt macOS system text intelligence vs. keep LSP/CM6 path? Which surfaces?
- **TSK-703** Unified action history + history view — which actions reversible; unified vs. per-doc stack; timeline vs. plain undo; fold in existing pieces?
- **TSK-705** Snippets — tabstop engine + per-language defs + storage/management UI; overlap with LSP (TSK-640).
- **TSK-706** RichText Editor (Docs-style) — which Markdown subset; new surface vs. toggle on existing CM6? (fold vs. keep distinct from TSK-680)
- **TSK-711** CSV Table editor — confirm scope (edit/add/del/undo/save/quoting) + Swift-vs-Rust-core placement.
- **TSK-712** 3-way merge — Git-conflict-resolver vs. generic 3-pane file-merge surface?
- **TSK-713** Diagram formats beyond Mermaid/Dot — which fenced-block diagram languages to invest in (per-format bundle/security tradeoffs)?
- **TSK-714** Tab split (left/right) — approve layout/state design + breakdown.
- **TSK-715** Profiling / Memory diffs / Flame charts — what's being profiled (app vs. opened file/repo vs. imported trace) and which sub-surface first?
- **TSK-716** Better UX for Worktree management — concrete scope, and does it fold into TSK-693?
- **TSK-717** Notebooks (multi-kernel Python + Kotlin, LSP, storage) — design + breakdown + likely new deps.
- **TSK-721** HTTP Client — Postman/Insomnia-class composer vs. light fetch-and-render helper? (security angle vs. egress/CSP work)
- **TSK-722** Task/command runner — ambiguous vs. the existing embedded terminal; epic design gate.
- **TSK-723** Structural search — confirm meaning/UX before any work.
- **TSK-725** Inspections/intentions + run configs + indexing nav + dataflow — scope/ordering of 4 IDE-grade subsystems; likely Rust-core indexing infra.
- **TSK-727** Unified Goto Anything (one box, @/: operators) — consolidate 4 search surfaces vs. just align keybindings?
- **TSK-749** Image edit: add text & shapes — "Raster?/Vector?" architecture decision + consolidation across TSK-285/287/380.
- **TSK-750** Image edit: tool window — raster vs. vector; relation to existing engine / TSK-524 / TSK-287.
- **TSK-754** Plugin API: contribute menu items/submenus — contract design (placement/ordering, lifecycle, action security) before code.
- **TSK-764** Git: non-blocking merge-style reconciliation + vim .swp-like diff persistence — three-way-merge model + persistence/recovery format + non-blocking UX.
- **TSK-768** Editor: disk-update highlight + local/disk conflict undo — split the merge piece and ship the two small ones as minor-features?
- **TSK-772** Plugins like SQLite browser — custom full-pane/file-type-bound plugin tools vs. the sidebar+menu-contribution ceiling?
- **TSK-773** Plugins expose MCP — manifest/permission/sandbox/transport design spike + confirmed direction.
- **TSK-774** Music (unspecified) — player vs. editor vs. notation vs. drop? (fully unspecified product-direction call)
- **TSK-775** High-level solid Rust migration plan — scope/horizon + design-review gate for the roadmap deliverable.
- **TSK-777** Plugin Development Kit + AI Plugin-Development Skill — PDK + AI skill together vs. PDK-first?
- **TSK-779** Which parts decompose into plugins vs. must stay core — defines the plugin/core boundary all plugin epics build on (product/architecture).
- **TSK-780** What to cut from the board? — owner prioritization/scope decision.
- **TSK-781** LSP: own implementation or external server? — own-vs-external architecture; robustness-vs-speed (likely a spike).
- **TSK-782** How far to take plugin extensibility (office: Docs/Wiki/CRUX/CR/CodeBrowser/CodeSearch) — scope + which integrations first.
- **TSK-786** Improve build / iteration / UI-testing speed — name the worst-hurting axis (Swift build perf vs. edit-rebuild-rerun vs. VM UI-test turnaround) + pain threshold.
- **TSK-788** Test suite audit — focus (coverage gaps vs. flaky/false-green hunt vs. lane health vs. teeth audit vs. full sweep) + depth.
- **TSK-798** State of inefficiency (throwaway work, lazy-load) — broad audit vs. targeted hot spot; priority vs. existing perf bugs.
- **TSK-799** How does scripting work? — existing plugin/Omni surface vs. a proposed end-user scripting API?
- **TSK-800** Can we use WASM to reduce WebUI duplication? — architecture/feasibility; scope direction (downstream of envelope TSK-580 / shim TSK-587).
- **TSK-805** How to separate core yet still use Swift/macOS features — the local-only Swift value-add boundary question.

### Parked very-large (5)

- **TSK-689** Integrate with PinBoard — target system and integration scope both undefined.
- **TSK-691** _(created, not parked — see very-large above)_
- **TSK-700** Inter-person + agent collaboration — _(listed under epics above)_
- **TSK-701** Expand Sessions into a full SDLC surface — _(listed under epics above)_

> Note: of the 5 `very-large` lines, 4 were parked (`TSK-689`, `TSK-700`,
> `TSK-701`, `TSK-774`) and 1 created (`TSK-691`). `TSK-700`/`TSK-701`/`TSK-774`
> are grouped above where their bucket/note sits; `TSK-689` is the only
> very-large unique to this sub-list.

### Parked minor-feature (4)

- **TSK-683** Proper name for the app — owner branding decision; product has a split identity (bundle/exec `MarkdownViewer` vs. display `TextView`) with no agreed canonical name (bundle id stays for TCC).
- **TSK-686** Signing — verbatim one-word title is ambiguous: best guess Developer ID + notarization + stapling for public release, but could mean document/PDF signing, e-signature, or git commit signing.
- **TSK-787** Test framework: Swift Testing vs. XCTest — adopt swift-testing for logic tests + migrate, vs. stay XCTest? Keep XCTest for VM-only UI/live tiers (T4/T5/WebView)?
- **TSK-793** Look at Swift and Rust recent additions — survey-only vs. adoption shortlist with refactor tickets vs. ecosystem crates? (no stated version range/deliverable)

---

## 4. Duped — wishlist line → existing/earlier ticket

48 lines folded onto 28 distinct targets. `(N×)` = number of wishlist lines
that collapsed onto that target.

| Target  | Folded-in wishlist lines |
|---------|--------------------------|
| **TSK-289** | AWS Plugin [Dynamo, S3, CloudWatch] |
| **TSK-301** (4×) | AutoSave/Versions/LocalHistory/Timeline · AutoSave+History · Local History · Parity gap: Local history |
| **TSK-319** | Repo sourceview: trace repo paths crate → github |
| **TSK-329** (2×) | File nav: keep all tree roots in view · right-click folder → New → New file |
| **TSK-342** | Image edit: crop |
| **TSK-346** | Allow other Git integrations (GitHub/GitLab/proprietary) incl. code review |
| **TSK-353** | Do we have a CLI to interact with the app itself? |
| **TSK-362** | Source view + syntax highlighting (JS/TS/JSX/Java/JSON/.../CSV/SH) |
| **TSK-376** (3×) | Fully Hackable, Fully Automatable · Fully scriptable, fully hackable · Make the app absolutely hackable |
| **TSK-380** (2×) | Image editing (raster/vector/text) · Image edit: undo 1000+ steps |
| **TSK-463** (2×) | Autocomplete (LSP/word-grammar/Mac-native) · Parity gap: Autocomplete |
| **TSK-464** | Goto / Definition / Usage |
| **TSK-505** (2×) | File info pane: checksum (SHA-256/…/MD5/CRC) · metadata for all file formats |
| **TSK-537** | Code review |
| **TSK-584** | Rust fuzzing/property/Miri lanes blocked on dep approvals |
| **TSK-637** | Parity gap: Markdown outline panel |
| **TSK-638** (3×) | Print and Print as PDF · Print, PDF Export · Parity gap: Print / export-rendered-PDF |
| **TSK-639** (2×) | Multi-cursor · Parity gap: Multi-cursor (⌘D select-next) |
| **TSK-640** (2×) | Rename / signature change · Parity gap: LSP rename + code actions |
| **TSK-641** (2×) | User themable (VSCode/Sublime themes) · Dark Mode |
| **TSK-651** | Remote dev |
| **TSK-672** (2×) | Editor git gutter / blame · Parity gap: Editor git gutter + inline blame |
| **TSK-685** | Parity gap: Prose spellcheck in markdown editing |
| **TSK-714** | Tab: right-click → split right |
| **TSK-745** | New Tab shows Recents, New PlainText/Image/RichText/Source, recent folders, file browser |
| **TSK-762** (2×) | Make Wrap/Special-Chars/View-Only toggle buttons · Terminal header pane "Terminal - Name" |
| **TSK-769** (5×) | Terminal: command history · favorite/named commands + search · support colors · left tab shoulder border · copy trimmed |
| **TSK-777** | How to write plugins? Creative plugin ideas? |

Targets `TSK-672`, `TSK-685`, `TSK-714`, `TSK-745`, `TSK-762`, `TSK-769`,
`TSK-777` were **created/parked earlier in this same intake** — the wishlist
named those capabilities from multiple angles, so the secondary angles deduped
onto the freshly-filed ticket rather than spawning duplicates.
