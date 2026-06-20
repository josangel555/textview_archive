# Unified Version-History + Diff Viewer — Spike + Design

**Date:** 2026-06-20
**Tickets:** TSK-301 (View local history), TSK-1103 (wire snapshot-on-save +
version-list/restore UI), plus the git-history tickets (TSK-522 cumulative diff,
File-History view) it unifies with.
**Status:** Phase 1 (spike + design) complete; Phase 2 (implement) in this branch.

---

## 1. The owner's spec (the experience to build)

> "Say I want to see a list of versions and click on a version and see either
> that version, or the diff between [it and] current. Or select a range and see
> what changed in that range." … "we need that same diff UI for git versions as
> well — not saying reuse what's there, but rethink."

So the experience is **one** component:

- a **version list** for the active file, newest-first;
- click a version → see **that version's full content** OR its **diff vs current**
  (a toggle);
- select a **range** of versions → see the **cumulative diff** across the range;
- and the SAME component drives **Local History versions** AND **Git commit
  history** for the file.

The owner explicitly does NOT want the existing git-diff UI reused as-is — a
clean rethink with one well-designed component.

---

## 2. What exists today (audit)

### 2a. Local History store (the data, already built)

`Sources/ViewerCore/LocalHistoryStore.swift` — a `Sendable`, host-tested,
deterministic on-disk file-version store. **Stable public API** (the contract
this design builds on; a sibling agent is reworking the internals to store diffs
instead of full snapshots, but the API is held stable):

```swift
struct Version: Sendable, Equatable, Identifiable { id: String; savedAt: Date; byteSize: Int }
func snapshot(path: String, content: String, at: Date) -> Version?   // dedup + prune + cap
func versions(for path: String) -> [Version]                         // newest-first
func contentString(of: Version, for path: String) -> String?         // restore a version's text
func clear(for path: String)
```

It is **unwired** today: nothing calls `snapshot()`, there is no UI.

### 2b. Git history + diff UI (the rethink target)

| File | Role |
|---|---|
| `Sources/ViewerCore/Git/GitClient.swift` | Runs git. `fileHistory(path:)→[LogEntry]`, `fileDiff(path:atCommit:)`, `diff(from:to:path:)`, `cumulativeDiff(baseRef:tipRef:)`, `blobSha(rev:path:)`. |
| `Sources/ViewerCore/Git/CumulativeDiffSelection.swift` | Pure range math: a set of selected commits → `git diff base..tip` range + contiguity. (TSK-522.) |
| `Sources/ViewerCore/RustDiffAdapter.swift` | `parse(unifiedText) -> [UnifiedDiff.File]` via rust-core FFI. **Parses** diff text; does NOT diff two strings. |
| `Sources/ViewerCore/Git/DiffParser.swift` | The `UnifiedDiff` model (File/Hunk/Line). |
| `Sources/ViewerUI/Git/DiffView.swift` | SwiftUI: renders `[UnifiedDiff.File]` (parsed from unified text) as a colored per-file/per-hunk view, find-in-diff, copy. |
| `Sources/ViewerUI/Git/FileHistoryView.swift` | SwiftUI master-detail: left = commit `List`, right = `DiffView`. Single (this-commit / vs-working-tree toggle) + Cmd-click two-commit range. |
| `Sources/ViewerUI/Git/FileHistoryModel.swift` | `@MainActor ObservableObject` view-model: commit list + selection state machine + off-main last-write-wins diff load. |

**Key observation:** `FileHistoryView`/`FileHistoryModel` are *already* exactly
the shape the owner wants — version list + single/range selection + a diff pane.
The ONLY thing tying them to git is that every data call goes straight to
`GitClient`. Generalize that single seam and the same view-model + view serve
Local History too.

### 2c. Two capability gaps the rethink must fill

1. **String→unified-diff TEXT.** The renderer (`DiffView`) consumes unified-diff
   *text* (then parses it via rust-core). Git produces that text with a
   subprocess (`git diff`). Local History has only two in-memory strings (an old
   version's content and current content) and **no way to produce unified text**.
   rust-core only *parses* diff text — it cannot diff two strings, and we add no
   new dependencies. → We need a small **Swift unified-diff generator** (LCS /
   Myers over lines) that emits exactly the text `RustDiffAdapter.parse`
   consumes, so the SAME renderer works for both back-ends. Round-trip
   (generate→parse) is host-testable.

2. **"View a file at a revision" for git.** `GitClient` only ever produces
   *diffs* — there's no "give me the file's full content at commit X". The
   "view that version" half of the spec needs it. → Add
   `GitClient.fileContent(rev:path:)` (`git show <rev>:<path>`).

---

## 3. The unified architecture

### 3a. `VersionSource` — the back-end protocol (ViewerCore, pure)

The single seam both back-ends conform to. SwiftUI/AppKit-free, so it is fully
host-testable.

```swift
public protocol VersionSource: Sendable {
    /// The file these versions belong to (display name in the header).
    var displayName: String { get }

    /// All versions, newest-first. Blocking (git subprocess / disk); the
    /// view-model calls this on a detached task.
    func listVersions() -> [VersionRef]

    /// Full text content of a version (the "view this version" path), or nil.
    func content(of version: VersionRef) -> String?

    /// Unified-diff TEXT for one version vs the CURRENT file. (single-select,
    /// "diff vs current").
    func diffAgainstCurrent(_ version: VersionRef) -> String

    /// Unified-diff TEXT for a → b (single-select "this version's own change"
    /// uses a=version, b=its predecessor's-successor; range uses the endpoints).
    func diff(from: VersionRef, to: VersionRef?) -> String

    /// Cumulative unified-diff TEXT across an ordered range of versions
    /// (oldest..newest). The "what changed in this range" path.
    func cumulativeDiff(in range: [VersionRef]) -> String
}

/// A back-end-agnostic version handle. `id` is the stable token (LocalHistory
/// snapshot id, or git full SHA); the rest is display metadata.
public struct VersionRef: Sendable, Equatable, Identifiable {
    public let id: String          // snapshot id  OR  git full SHA
    public let shortLabel: String  // "1700000000000"→time  OR  short SHA
    public let timestamp: Date?
    public let author: String?     // git only
    public let subject: String?    // git commit subject; nil for local history
    public let kind: Kind          // .localHistory | .git
}
```

### 3b. Two conformances

- **`LocalHistoryVersionSource`** (ViewerCore) — wraps `LocalHistoryStore` + the
  *current* file content (supplied as a closure so it reflects the live editor
  buffer, not stale disk). `listVersions` maps `store.versions(for:)`;
  `content` maps `store.contentString`; the diff methods use the new Swift
  **`UnifiedDiffGenerator`** to turn two strings into unified text.

- **`GitVersionSource`** (ViewerCore) — wraps `GitClient` + repo root + relative
  path. `listVersions` maps `fileHistory`; `content` uses the new
  `GitClient.fileContent(rev:path:)`; the diff methods delegate to the existing
  `GitClient.fileDiff` / `diff(from:to:path:)` / `cumulativeDiff` (reusing
  `CumulativeDiffSelection` for the range math). **No git diff logic
  reinvented** — git already emits unified text.

### 3c. `UnifiedDiffGenerator` — string→unified text (ViewerCore, pure)

Line-based LCS (Hunt–McIlroy / Myers-equivalent for the line granularity we
need) producing **standard unified-diff text** with `--- a/<path>` / `+++ b/<path>`
headers and `@@ -a,b +c,d @@` hunks and a configurable context radius (default 3).
The output is the exact dialect `RustDiffAdapter.parse` already handles, proven
by a generate→parse→reconstruct round-trip test. No dependency; ~150 LOC of
pure Swift; host-tested with teeth (add/remove/modify/empty/identical/no-newline).

### 3d. `UnifiedHistoryViewModel` — one view-model (ViewerUI)

Generalizes `FileHistoryModel`. Owns a `VersionSource` (injected), the version
list, the selection state machine (none / single / range), the single-select
**mode** (`.viewVersion` | `.diffVsCurrent` | `.thisVersionsChange`), and the
off-main last-write-wins content/diff load. The view binds narrow `@Published`
fields. Pure state transitions are host-tested.

```
selection:   none | single(VersionRef) | range([VersionRef])
singleMode:  viewVersion | diffVsCurrent          // the owner's toggle
detail:      .empty | .content(String) | .diff(String)   // what the right pane shows
```

### 3e. `UnifiedHistoryView` — one viewer (ViewerUI)

Master-detail like `FileHistoryView` (left version `List`, Cmd-click range,
right pane). The right pane shows EITHER:
- the version's **full content** (a read-only source view) when single + `viewVersion`;
- a **`DiffView`** (reused as-is — it is the right renderer) when single +
  `diffVsCurrent`, or range (cumulative).

A segmented toggle in single mode switches View ⇄ Diff-vs-Current. A range shows
the cumulative diff + an "includes N intermediate versions" note (from the
contiguity flag, git side). A **Restore** button on a selected version pushes its
content into the editor via `DocumentModel.updateEditorText(_:forTabID:)` — an
**undoable buffer edit** (marks dirty, user can Cmd-Z, user saves explicitly),
NOT a blind disk write. This coordinates with the save path: restore = edit, then
the normal save flow (and its snapshot-on-save) applies.

### 3f. Hosting

Opened as a view-hosting tab exactly like `FileHistoryView` today, via
`DocumentModel.openHostedView(title:rootView:)`. Local History entry point:
`DocumentModel.openLocalHistory(forTabID:)`. Git entry point can later route
`openFileHistory` through the unified viewer (see §5 deferral).

---

## 4. Reused vs replaced (the rethink ledger)

| Piece | Decision | Why |
|---|---|---|
| `DiffView` (renderer) | **REUSED unchanged** | It already renders `UnifiedDiff.File` from unified text beautifully (colors, find, copy, line numbers). The rethink is about *what feeds it*, not the diff pixels. Reinventing it would be waste, not improvement. |
| `RustDiffAdapter` / `UnifiedDiff` model | **REUSED** | The structured-diff parse path is shared by both back-ends. |
| `CumulativeDiffSelection` | **REUSED** for git range math | Already pure + tested. |
| `GitClient` diff/log methods | **REUSED** behind `GitVersionSource` | Git already emits unified text; no reason to reimplement. |
| `FileHistoryModel` | **REPLACED** by `UnifiedHistoryViewModel` | It hard-binds to `GitClient`. The generalized view-model is the rethink — same proven selection state machine, but over a `VersionSource`. The old model stays only until the git UI is migrated (§5). |
| `FileHistoryView` | **SUPERSEDED** by `UnifiedHistoryView` | Same master-detail shape, but a back-end-agnostic version list + a View/Diff toggle + Restore. Kept in place for git until the migration ticket lands. |
| string→unified-diff | **NEW** (`UnifiedDiffGenerator`) | The missing capability — Local History has no git to make diff text. |
| view file @ revision | **NEW** (`GitClient.fileContent`) | Missing capability — git UI only ever showed diffs. |

**Net:** the *renderer and diff plumbing* are reused (they're good); the
*list + selection + back-end binding* are rethought into one generic component
that no longer assumes git.

---

## 5. Scope this pass vs deferred

**Shipped this pass:**
- `VersionSource` protocol + `VersionRef` (ViewerCore).
- `UnifiedDiffGenerator` (ViewerCore) + `GitClient.fileContent` — the two gaps.
- `LocalHistoryVersionSource` + `GitVersionSource` conformances (ViewerCore).
- `UnifiedHistoryViewModel` (ViewerUI) — generic selection/detail state machine.
- `UnifiedHistoryView` (ViewerUI) — list → view-version / diff-vs-current /
  range-cumulative-diff + Restore.
- **Local History wired end-to-end:** snapshot-on-save hook in the editor save
  path (text-only, in-app edits, owner policy excludes for `.env`/secret-like);
  `DocumentModel.openLocalHistory(forTabID:)`; a View menu / context entry.
- Host tests with teeth: protocol behavior, generator round-trip, view-model
  state machine, cumulative-range logic.

**Deferred to a follow-up ticket (filed: TSK-1191):** migrating the existing
**git** `FileHistoryView`/`GitLogTab` UI onto `UnifiedHistoryView`. The `GitVersionSource`
conformance lands now (so git is *adoptable* by the unified viewer immediately),
but ripping out the established git File-History UI + the GitLogTab multi-select
cumulative path is a larger, separately-validatable change — half-migrating the
git UI would be worse than a clean follow-up. This keeps the change cohesive and
avoids destabilizing a working git surface.

---

## 6. Integration seams (for stitching with the two sibling agents)

- **Restore → save path.** Restore calls `DocumentModel.updateEditorText(_:forTabID:)`
  (an undoable buffer edit), NOT a disk write. The sibling editing
  `DocumentModel.saveEditor` should treat a restored-then-saved buffer like any
  other save (which then snapshots the restored content as a new version — the
  desirable behavior).
- **Snapshot-on-save hook.** A single best-effort call placed in `saveEditor`
  after a successful write, guarded by the owner policy (text-only, not a
  secret-like path). Designed as one localized addition so it doesn't collide
  with the sibling's save-path edits; if both touch `saveEditor`, the hook is a
  single self-contained statement easy to rebase.
- **Conflict "View diff" → this viewer.** A merge/restore conflict surface can
  open `UnifiedHistoryView` (or `DiffView` directly) to show the relevant diff —
  the viewer takes any `VersionSource`, so a synthetic two-version source (base
  vs incoming) slots in without new UI.
- **LocalHistoryStore internals.** This layer uses ONLY the stable public API
  (`versions`/`contentString`/`snapshot`/`clear`). The sibling's switch to
  diff-based storage is invisible here.

---

## 7. Testing plan (teeth)

| Layer | Tier | Test |
|---|---|---|
| `UnifiedDiffGenerator` | host (pure) | generate→`RustDiffAdapter.parse`→reconstruct equals new text; identical inputs → empty; pure-add / pure-delete / modify / no-trailing-newline cases. |
| `VersionSource` (LocalHistory) | host (pure) | list newest-first, content retrieval, diff-vs-current non-empty on change / empty on identical, cumulative across a range. |
| `GitVersionSource` | host | range math via `CumulativeDiffSelection`; `fileContent` parsing (guarded by repo availability — skip if no git). |
| `UnifiedHistoryViewModel` | host | selection state machine: single↔range, view↔diff toggle, last-write-wins token, Restore emits the right text. |
| `UnifiedHistoryView` render + Restore-into-editor | review / VM | pixels + real click are VM-only (owner directive). Model behavior pinned host-side so a logic regression fails the host gate. |
