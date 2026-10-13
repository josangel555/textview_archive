# TextView — a four-page portrait

*2026-08-08 · main @ `f6612f04` · all numbers measured from the repo, not estimated*

---

## Page 1 — What it is

**TextView** (bundle name for the `MarkdownViewer` project) is a native macOS
document workbench for Apple Silicon: one window that opens nearly anything a
developer or writer touches — markdown, source code, CSV/TSV and spreadsheets,
JSON/YAML, HTML, PDFs, images, audio, hex dumps, SQLite databases, archives,
Jupyter notebooks, git repositories — and gives each a first-class, fast,
keyboard-driven surface. It began (2026-05-14) as a markdown viewer; twelve
weeks later it is closer to a lightweight IDE with an opinionated soul:
**viewing is sacred, editing is safe, and nothing is ever lost silently.**

### The lens model

Every file opens through a **lens** — Rendered (markdown/HTML via WKWebView,
with LaTeX math as backend MathML, Mermaid diagrams, footnotes, GitHub alerts,
definition lists, wikilinks), Editor (CodeMirror 6), Source (read-only
NSTextView with tree-sitter highlighting), Split (edit + live preview), Table
(CSV/spreadsheet grid), Diff (a CodeMirror-merge web renderer with per-hunk
navigation), Hex (editable), and media Previews. A unified type chip lets any
file be re-opened *as* anything else, with per-category default-lens pins.

### Data safety as a personality trait

The most distinctive engineering thread is the **no-silent-loss doctrine**:

- Unsaved edits (text *and* hex) survive quit, crash, and session switches via
  hot-exit snapshots; a crash-loop breaker keeps a poisoned restore from
  bricking launch — with a "Restore Now" toast escape.
- Disk conflicts are detected by content (not just mtime — a false-conflict
  class was hunted down and shot), and every destructive branch first banks the
  doomed side into **Local History**, which itself supports per-hunk
  "Merge into Current" recovery.
- Saves are atomic, permission/xattr-preserving, symlink-safe, and
  encoding-faithful (BOM round-trips). The write-time no-clobber guard
  re-stats before every ⌘S.

### Everything else in the box

Multi-**session** workspaces (rounded chips in the title bar, drag a tab onto a
session to move it, named save points), a full **git panel** (status with
stage/commit, log with graph, stash, blame, unified history), **Local History**
versioning, cross-file search, an LSP client (definitions, references,
diagnostics, outline), a command palette, a real PTY **terminal**, an **image
editor** (tone, geometry, paint, vector shapes and text), an audio editor,
walkthrough player, plugins, a Claude-session monitor — and a first-run
experience that teaches it all.

---

## Page 2 — How it's built

### Layered Swift, one direction of dependency

~176k lines of Swift across 846 files, split into four SwiftPM targets:
**ViewerKit** (pure value types: lens math, file-type detection),
**ViewerCore** (engines and services: stores, git client, automation catalogs,
conflict machinery — sans-UI, heavily unit-tested), **ViewerUI** (SwiftUI views
+ coordinators), and the **MarkdownViewer** app target (AppKit shell, menus,
windows). The UI observes a central `DocumentModel` (92 `@Published`
properties; 497 app-wide) through deliberately *narrow* channels — re-render
budgets are enforced by tests that count body evaluations per chrome view.

### The Rust core

Hot paths live in a **Rust** static library (`libmdvcore_ffi.a`, 85 files /
54k lines, 188 crates in the lockfile, every dep pinned with
`default-features = false`): markdown parsing (pulldown-cmark + LaTeX math),
tree-sitter highlighting with real predicate evaluation, diff parsing, CSV
windowing, hex search (memchr), indent detection, fuzzy matching. The FFI
boundary is capability-checked at launch; the core stays **sans-IO and
wasm-buildable** by CI decree, because the long-term goal is engine-remote /
UI-local operation. A `mdv-serve` binary already speaks the same contract over
a socket.

### Web surfaces, fenced

CodeMirror 6 (a 1.1 MB self-built bundle — editor, search, folding, LSP
adapters, vim mode, `@codemirror/merge` for diffs) and the rendered-markdown
page run in WKWebViews behind strict CSP, navigation policy, and JS
default-deny for untrusted HTML. The rendered view keeps a persistent page and
DOM-patches updates (killing a 2–9 s reload storm); the diff page draws
full-line washes, edge bars, and a scrollbar match ruler.

### Automation is a first-class citizen

The app exposes **40 MCP tools** over a local socket, **175 script verbs**
sharing the exact closures the UI buttons call, **138 palette commands**, and
**501 accessibility identifiers** (71 curated into an addressing contract for
out-of-process drivers). This isn't garnish — it is how the app tests itself
(next page).

---

## Page 3 — Evolution, and the machine that builds the machine

### Twelve weeks, 3,781 commits

| Month | Commits | The story |
|---|---|---|
| 2026-05 | 529 | Skeleton → viewer: lenses, markdown, source view, sessions v1 |
| 2026-06 | 2,751 | The build-out: git suite, editors, terminal, LSP, image/audio, rust ports, the test pyramid, VM lane |
| 2026-07 | 476 | Usability recalibration ("built ≠ usable"), web diff, math, perf instrumentation, pre-launch audit |
| 2026-08 | 25 | Owner-driven polish rounds: conflict/root-cause fixes, find overhaul, titlebar chrome, image-editor save fix |

The inflection point was the owner's 2026-07-02 recalibration — *"the bar is
end-user usability, not feature existence"* — which reorganized everything
around paired rounds: **every round ships one user-facing improvement and one
quality improvement**, both named, both validated.

### The autonomous operation model

Most of those commits were produced by an AI agent operating under a written
SOP, and the *process* is as engineered as the product:

- **A task board** (`tasked`, TSK-###) is the system of record; a curated
  `BACKLOG.md` orders the work; `HANDOFF.md` (budget-capped, gate-enforced)
  restores context across compactions.
- **A standing CI loop** runs the full headless gate on every committed HEAD
  in a dedicated worktree and reports `CI <sha> rc=<n>`; per-commit validation
  is targeted suites only. Rounds are *reported at commit*; installs to
  `/Applications` happen only after that commit's CI line is green; red lines
  are triaged fix-forward (three real CI reds were root-caused this month —
  one turned out to be a cross-process SHA-collision cache race).
- **Nothing render-touching ships on host-green alone.** A UTM VM runs the
  heavy tiers: live-app tests, WindowServer pixel captures (with debug PNGs an
  agent actually *reads*), in-process WebView suites, and an **AX interaction
  tier** that finds controls by identifier and drives them with real HID
  events — the tier that caught a hidden close button, swallowed strip
  buttons, and a degenerate sidebar frame.
- **Tests must have teeth**: negative-control switches deliberately break
  features to prove guards go red; ratchets police fixed-duration sleeps;
  audits pin coordinate-space rules and pointer affordances so a fixed bug
  *class* stays fixed. LESSONS.md holds the institutional scar tissue (the
  local-space resize oscillator, the tooltip photobombing pixel tests, AX
  materialization rules).

---

## Page 4 — By the numbers, and where this goes

### The numbers (measured 2026-08-08)

| Metric | Value |
|---|---|
| Commits / span | 3,781 over 12 weeks (2026-05-14 → 2026-08-05) |
| Swift app code | 846 files · 175,633 lines |
| Test code | 1,238 files · **185,130 lines — more test than app** |
| Rust core | 85 files · 54,002 lines · 188 locked crates |
| Automated tests | ~11,700 (10,283 XCTest + 364 Swift Testing + 1,117 Rust) |
| Test tiers | host headless → in-process WebView → VM live-app (T4) → VM pixels (T5) → VM AX/HID → journey UAT (T6) |
| Automation surface | 40 MCP tools · 175 script verbs · 138 palette commands · 25 capture scenes |
| Accessibility ids | 501 unique (71 in the curated driver contract) |
| Ship bundle | 77 MB (68 MB exec, 70 MB budget) · arm64 · macOS 15+ |
| Dependencies | 8 SwiftPM packages, every Rust dep pinned + feature-minimized |
| Docs | 90 files under `docs/` · 27 dated CHANGELOG entries |
| Distribution | github.com/josangel555/textview_dist (dated zips + sha256) |

### Goals

**Near-term (the active queue):** finish the owner-intake polish (AutoSave
opt-in, LSP occurrences, strip placement slices, pointer-audit batch 2), the
web-migrate wave (read-only source → CM6, CSV/hex/log grids — killing the last
big-file chokes), and the remaining pre-launch audit P1s (MCP-socket trust
model, packaging/notarization dry run).

**Structural:** shrink the 68 MB executable (grammar-table dedup), migrate the
remaining resize/cursor stack users, and keep chipping the Swift→Rust ports
under the bugfix-only migration policy.

**The horizon:** the **remote-core** thesis — the sans-IO Rust engine running
anywhere (local, server, wasm) with thin native UIs speaking the versioned
binary contract; sessions as portable, syncable state; and a public,
notarized release once the audit themes are retired.

**The meta-goal**, demonstrated more convincingly every week: that a
production-quality, data-safe, deeply-tested native app can be built and
*operated* by an autonomous agent under human product direction — with the
discipline (boards, gates, teeth, handoffs) engineered so the machine that
builds the machine never quietly breaks it.

---

*Sources: git history, CHANGELOG.md, BACKLOG.md, LESSONS.md, docs/TEST_PYRAMID.md,
and live `grep`/`wc` measurements of this working tree.*
