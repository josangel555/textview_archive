# TextView — Exhaustive Feature Inventory & Usability State

**Created 2026-07-02** (owner directive: "scan the overarching themes/features/epics we attempted,
audit completion + usability, group into hierarchies, document, file tickets for gaps, explain the
path to production-grade for each").

**THE CALIBRATION (owner, 2026-07-02):** *"We have been building many features, but almost all of
them are unusable. Editor works, vim mode works, File nav mostly works. The rest are unfinished,
unpolished or unusable."* — This inventory therefore distinguishes **Built** (code exists),
**Logic-verified** (host tests pass), and **Usable** (an end user can discover it, drive it, and
get value without friction). The 2026-07-02 usability run verified the first two extensively; the
owner's verdict is that the third is where nearly everything falls short. **Usability column
defaults to ✖ unverified/owner-reported-unusable unless the owner has confirmed it.**

Legend — **Built:** ✅ full · 🟡 partial · 📐 design-only. **Logic:** ✅ host-tested · ➖ thin/none.
**Usable (owner bar):** ✅ owner-confirmed · 🟡 partially · ✖ unfinished/unpolished/unusable/unverified.

Sources scanned for this inventory: `buildMenu()` (15 top-level menus), `CommandRegistry+BuiltIn`
(125 palette commands, 12 categories), `ScriptVerbCatalog` (160 verbs), ~70 feature views in
`Sources/ViewerUI/`, `ViewMode` lenses, `docs/*.md` design docs, the tasked board. Prior partial
inventories: `CAPABILITIES.md` (automation surfaces only), `USABILITY_AUDIT_2026-07-02.md`
(code-verification log). **This file is the single hierarchy; keep it current when features land.**

---

## 1. Editor  — ✅ THE anchor feature (owner: "works")

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| CM6 editor (edit/save/undo) | ✅ | ✅ | ✅ owner |
| Vim mode | ✅ | ✅ | ✅ owner |
| Syntax highlight (Rust tree-sitter, 22 langs, predicates) | ✅ | ✅ | ✅ |
| Folding, indent guides, invisibles, language mode | ✅ | ✅ | 🟡 |
| Snippets (insert/manage) | ✅ | ✅ | ✖ |
| Find in editor / structural search | ✅ | ✅ | 🟡 |
| Local history / File history | ✅ | ✅ | ✖ |
| Read-only / focus mode / zoom | ✅ | ✅ | 🟡 |

**Path to production-grade:** this family is the bar the rest must meet. Remaining polish:
P0 CM6 render bugs (TSK-1200/1188/1271/891/910/1032 — pixel-gated on TSK-1334), snippet manager
UX (discoverability, preview), local-history surfacing (currently buried; needs a timeline UI).

## 2. File navigation & workspace  — 🟡 (owner: "mostly works")

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| Sidebar file tree (files panel) | ✅ | ✅ | ✅ owner (mostly) |
| Tabs (open/close/reorder/pin?) + tab operations | ✅ | ✅ | 🟡 |
| Splits (toggle/swap) | ✅ | ✅ | ✖ |
| Sessions (new/rename/jump/restore) + workspaces | ✅ | ✅ | 🟡 |
| Bookmarks / Recents / History | ✅ | ✅ | ✖ |
| Fuzzy finder (double-shift), goto-line | ✅ | ✅ | 🟡 |
| Cross-file search (+ replace) | ✅ | ✅ | ✖ |
| Breadcrumb, outline panel, minimap/overview | ✅ | ✅ | ✖ |

**Path to production-grade:** fix the "mostly" — file-tree edge cases (rename/move/delete flows,
watcher refresh), session-switch state restore polish (scroll/edit-state — model fixed, on-screen
verify pending), make cross-file search a first-class UI (progress, cancel, result grouping),
bookmarks/recents need visible entry points + empty states.

## 3. Viewing & rendering (the "viewer" core)  — 🟡

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| Markdown rendered view (Rust renderer + chunks) | ✅ | ✅ | 🟡 |
| View lenses: rendered/source/formatted/diff/hex/csv/transcript | ✅ | ✅ | 🟡 |
| Mermaid / diagrams | ✅ | ✅ | ✖ |
| HTML file rendering (policy-gated) | ✅ | ✅ | ✖ |
| Frontmatter hidden (fixed 8e0ec3c8), task lists, footnotes? | 🟡 | ✅ | 🟡 |
| Themes (light/dark/custom), zoom, wrap | ✅ | ✅ | 🟡 |
| Find in rendered view (all-matches highlight) | ✅ | ✅ | 🟡 |
| Perf: DOM-patch pipeline (TSK-838) **built + validated, gated OFF** | ✅ | ✅ | ✖ (latency felt) |

**Path to production-grade:** FLIP TSK-838 (biggest felt-latency win, owner call);
render-path pixel confirmation once TSK-1334 grants; mermaid error UX (bad diagram → readable
error, not blank); consistent lens switching (some formats auto-pick, some don't — cohesion).

## 4. Markdown power tools  — 🟡 (logic now solid; UX thin)

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| Outline/TOC panel + Insert TOC (slug-correct since 2d646798) | ✅ | ✅ | ✖ |
| Check Links (code-span-safe since e8baf4ad) | ✅ | ✅ | ✖ |
| Lint Markdown | ✅ | ✅ | ✖ |
| Document statistics | ✅ | ✅ | ✖ |
| Align tables / promote-demote headings (code-safe since 428e8160/62e7892f) | ✅ | ✅ | ✖ |
| Copy/Export as HTML, Open in Browser | ✅ | ✅ | ✖ |
| Copy as Markdown-table/JSON/CSV (from CSV/JSON) | ✅ | ✅ | ✖ |

**Path to production-grade:** these were the 2026-07-02 run's fix focus — the *logic* is now
correct + teeth-tested, but the *experience* is raw: results land in modal alerts (Check
Links/Lint/Stats should be a results PANEL with click-to-line), no progress states, menu items
scattered until this run (now Tools/Format menus), no keyboard shortcuts, no empty-state
guidance. One results-panel component would productionize four features at once.

## 5. Data formats  — 🟡 (strong engines, uneven surfaces)

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| CSV table view (Rust: sort/filter/stream) + editing | ✅ | ✅ | 🟡 |
| CSV summary/convert (→MD/JSON) | ✅ | ✅ | ✖ |
| JSON formatted lens + minify | ✅ | ✅ | 🟡 |
| Spreadsheet (XLSX/ODS) + formula engine (Rust, gated OFF) | 🟡 | ✅ | ✖ |
| SQLite browser | ✅ | ✅ | ✖ |
| Hex view + search (Rust memmem) (+ hex EDIT = TSK-1423 owner call) | ✅ | ✅ | 🟡 |
| Archive browser (zip), Package explorer, Dependency graph | ✅ | ✅ | ✖ |
| Notebook (.ipynb) cell list | 🟡 | ✅ | ✖ |
| Log patterns view | 🟡 | ➖ | ✖ |
| DOCX/RTF/ODS import (tables since 2d2bf9b3) | ✅ | ✅ | 🟡 |

**Path to production-grade:** each viewer needs its core loop closed: SQLite browser (query box +
export results), spreadsheet (flip formula gate after soak — owner call TSK-788/1215), notebook
(render outputs, not just cells), archive/package (preview-on-select), and EVERY data view needs:
big-file progress, empty/error states, copy/export affordances, type-appropriate toolbar.

## 6. Media  — 🟡

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| Image viewer (+ metadata panel) | ✅ | ✅ | 🟡 |
| Image editor (paint/shapes/text/crop/tone; unified undo this run) | ✅ | ✅ | ✖ |
| Convert image (format/size) | ✅ | ✅ | ✖ |
| Audio player + audio editor (waveform) | 🟡 | ✅ | ✖ |
| Audio convert / extract-from-video (ffmpeg, host-tool) | ✅ | ✅ | ✖ |
| Video preview | 🟡 | ➖ | ✖ |

**Path to production-grade:** image editor got 7 logic fixes this run but its UX needs an
on-screen pass (tool feedback, cursor states, zoom/pan, save-vs-copy clarity, paint-raster
persistence TSK-1426 owner call); audio editor needs core-loop completion (trim/export
round-trip verified on screen); ffmpeg-absent messaging ("install ffmpeg" guidance).

## 7. Dev tools  — 🟡 (deep backends, thin/undiscoverable fronts)

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| Terminal (PTY) + favorites + task runner + terminal palette | ✅ | ✅ | 🟡 |
| Git panel (status/stage/commit?) + repo/file history + chips | ✅ | ✅ | ✖ |
| Diff viewer (Rust diff) | ✅ | ✅ | 🟡 |
| Code review (comments, anchors, approve/reject) | ✅ | ✅ | ✖ |
| LSP (hover/defs/completions/diagnostics; jdtls etc.) | ✅ | ✅ | ✖ |
| Claude monitor (sessions/transcripts) | ✅ | ✅ | 🟡 |
| Script console | ✅ | ✅ | ✖ |
| Walkthroughs | ✅ | ✅ | ✖ |
| Structural search (tree-sitter) | ✅ | ✅ | ✖ |

**Path to production-grade:** these are the "unfinished epic" cluster — each has a real backend
and a v0 surface. Pick per-feature: LSP needs status affordance (server up? which?) + graceful
degradation; code review needs an end-to-end on-screen journey test (open→comment→resolve);
git panel needs the standard loop (stage/unstage/commit/push visible + safe); walkthroughs need
an entry-point + first-run sample. Cull candidates if unwanted: script console vs terminal
palette overlap (cohesion — TSK-1413).

## 8. Automation & extensibility  — ✅ backend / ✖ discoverability

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| Script verbs (160) + --script runner | ✅ | ✅ | 🟡 (agent-usable) |
| MCP stdio server (tools/list, tools/call) | ✅ | ✅ | 🟡 (agent-usable) |
| Plugins v1/v2 (+ settings view, sidebar sections) | 🟡 | ✅ | ✖ |
| URL scheme, `textview` CLI, action history | ✅ | ✅ | 🟡 |
| Command palette (125 commands; format/export parity this run) | ✅ | ✅ | 🟡 |

**Path to production-grade:** the automation surface is the app's differentiator and is genuinely
strong for AGENTS; for HUMANS it needs: palette-first UX audit (every command reachable +
searchable + shortcut-labeled), plugins need a lifecycle story (install/enable/trust UI),
CAPABILITIES.md → in-app help.

## 9. Import / paste / convert  — ✅ logic (this run) / ✖ feedback

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| Universal paste (file/image/CSV→table/rich-text) | ✅ | ✅ | ✖ |
| Rich paste → markdown (code/table/nested-list fixed this run) | ✅ | ✅ | 🟡 |
| Encoding / line-endings / indentation converters | ✅ | ✅ | 🟡 |
| RichText editor (Docs-style, flag-gated WIP) + RTF/DOCX export | 🟡 | ✅ | ✖ (gated) |

**Path to production-grade:** paste is invisible magic — needs a transient "Pasted as X (undo)"
affordance; converters need current-state display (what encoding/EOL IS this file); RichText
editor is a finish-or-cut owner decision (TSK-1418).

## 10. Feeds & web  — 🟡

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| RSS feed reader (wired this run, TSK-1417) | ✅ | ✅ | ✖ |
| HTTP client | ✅ | ✅ | ✖ |
| Built-in browser (TSK-676 epic) | 🟡 | ➖ | ✖ |

**Path to production-grade:** feed reader needs the reading loop (unread counts, mark-read,
open-in-tab polish); HTTP client needs the request-builder ergonomics (headers table, auth,
history); browser epic is an owner finish-or-cut.

## 11. Canvas  — ✅ built M0–M6, **PARKED for owner review** (do not build)

## 12. App chrome & system  — 🟡

| Sub-feature | Built | Logic | Usable |
|---|---|---|---|
| Settings window | ✅ | ✅ | 🟡 |
| Keyboard shortcuts viewer + audit doc | ✅ | ✅ | ✖ |
| Help / walkthrough entry / sample docs | 🟡 | ➖ | ✖ |
| Session restore, crash-safe state, File→Reset | ✅ | ✅ | 🟡 |
| Egress guard, HTML policy, sanitizer (security) | ✅ | ✅ | ✅ (invisible) |
| Obs/diagnostics (DiagnosticDump, perf signposts) | ✅ | ✅ | n/a (internal) |

**Path to production-grade:** first-run experience (what IS this app? sample tour), shortcuts
discoverability (menu items show keys; palette shows keys), Settings information architecture
(currently a grab-bag).

---

## The cross-cutting usability gaps (why "built" ≠ "usable")

These EIGHT themes recur in every ✖ above — fixing them per-feature is the production-grade path:

1. **Results-in-alerts** — Check Links/Lint/Stats/CSV summary dump into modal alerts. Needs one
   reusable results panel (list + click-to-navigate + copy/export).
2. **No empty states** — hosted views (feeds, HTTP, SQLite, treemap…) open blank with no "what
   do I do here" guidance.
3. **No progress/error surfacing** — long ops (cross-search, big CSV, convert) give no feedback;
   failures are silent or console-only.
4. **Discoverability** — features exist only as verbs/palette entries (or neither); menu
   placement landed only this run; shortcuts unlabeled; no in-app capability help.
5. **Cohesion** (TSK-1413) — overlapping surfaces (script console vs terminal palette; three
   search UIs; two history views) with no shared pattern.
6. **Felt latency** — TSK-838 DOM-patch gated OFF; markdown open lag is THE felt-perf item.
7. **Unfinished core loops** — many features do 70% (SQLite browse but no query→export; audio
   edit but no verified round-trip; review comments but no resolve flow).
8. **On-screen verification debt** — pixel/AX validation gated (TSK-1334), so polish bugs
   (spacing, color, focus, cursor) are invisible to the current test lanes.

## Owner decision queue (blocking the biggest jumps)

| Decision | Impact |
|---|---|
| Grant TSK-1334 (screen recording) | unlocks pixel/AX validation → polish lane opens |
| Flip TSK-838 (DOM patch) | biggest felt-latency fix |
| Finish-or-cut: RichText (1418), browser (676), notebook, log-patterns | focus |
| Formula-engine gate flip (788/1215) | spreadsheet becomes real |
| Hex edit (1423), paint persistence (1426) | data-editing completeness |
| Canvas review (M0–M6 parked) | ship or shelve |

## Gap-ticket hierarchy (filed 2026-07-02; every ticket is a self-contained subagent brief)

Root: **TSK-1411** (usability umbrella). Every child ticket carries CONTEXT / FILES / BUILD /
VALIDATE / DONE-WHEN so a fresh subagent can execute it with minimal context.

**Cross-cutting themes (directly under TSK-1411):**
- TSK-1434 results panel (de-alerts Check Links/Lint/Stats/CSV summary) · TSK-1435 empty states
- TSK-1436 progress+error surfacing · TSK-1437 keyboard shortcuts · TSK-1449 cohesion/consolidation

**Family epics → children:**
| Epic | Children |
|---|---|
| TSK-1450 editor polish | 1461 snippets UX · 1462 local-history timeline |
| TSK-1451 file-nav | 1463 file-tree ops · 1464 bookmarks/recents · 1465 cross-file search UX |
| TSK-1452 viewing | 1466 mermaid error UX · 1467 lens auto-pick cohesion (+ owner: flip TSK-838) |
| TSK-1453 markdown tools | 1438 outline/TOC panel (+ 1434/1437 apply here) |
| TSK-1454 data formats | 1439 SQLite loop · 1440 notebook outputs · 1468 spreadsheet gate-prep · 1469 archive/package preview · 1470 dep-graph interactive · 1471 log-patterns finish-or-cut · 1472 CSV editing |
| TSK-1455 media | 1441 image-editor UX · 1442 audio round-trip · 1473 convert-image · 1474 video preview |
| TSK-1456 devtools | 1443 git loop · 1444 LSP status · 1445 review journey · 1475 terminal/task-runner · 1476 structural-search UX · 1477 monitor polish |
| TSK-1457 automation | 1478 plugins lifecycle UI |
| TSK-1458 paste/convert | 1479 paste feedback toast · 1480 converters show current state (+ owner: RichText 1418) |
| TSK-1459 feeds & web | 1446 feed reading loop · 1447 HTTP ergonomics (+ owner: browser 676) |
| TSK-1460 chrome | 1448 first-run · 1481 Settings IA · 1482 menu-bar audit |

Owner-decision items stay in § Owner decision queue above (1334, 838, 1418, 1423, 1426, 676,
788/1215, Canvas review) — referenced by the epics, never duplicated.

This document is the hierarchy + the production-grade path; the board tracks execution state.
