# Code Review (CR) — Design

**Status:** design, pre-implementation. v1 scope only.
**Owner:** TextView Git surface.
**Target reader:** the engineer who lands v1.

---

## 0. What this is (and isn't)

TextView already renders a unified diff better than any browser. The CR feature
turns that read-only rendering into a **commentable surface**: the user reads
a diff (current working tree, a commit, a range, or two branches), drops
anchored comments with severity + markdown body, and exports the whole session
as a single JSON blob suitable for pasting into a Claude Code prompt — so
Claude Code can act on the review (apply fixes, answer questions, expand
threads).

**v1 is local-first and single-user.** No GitHub/GitLab/Phabricator round-trip,
no live collaborators, no provider adapters. The HTML+JSX mocks under
`/Users/me/Downloads/TextView (3)/` ship a *multi-provider inbox* — that's a
later epic. We borrow their **visual vocabulary** (state pills, inline thread
cards under diff rows, file list + diff layout, severity dots) but the data
model and storage are local.

### Out of scope for v1

- Provider sync (GitHub PRs, generic CR, GitLab MRs, Phabricator).
- Multi-author threads / replies from other humans. (Replies *to* Claude
  Code's response land via re-import in a later milestone.)
- CI status, approvals, suggested-change `apply locally` flow.
- Drafts that survive force-pushes / commit-mapping. We anchor by commit SHA
  + path + line; if the SHA goes away, the thread is flagged stale.

### In scope for v1

1. New **Review** tab inside the Git panel — lists active reviews, creates new ones.
2. A dedicated **Review document tab** (opens as a regular top-level tab, so it can
   be moved into a split pane next to the source file).
3. Comment-on-line in the existing `DiffView` with an inline thread card.
4. JSON export → clipboard / file / (later) Claude Code MCP.
5. JSON files under `~/Library/Application Support/MarkdownViewer/Reviews/` via
   `JSONFileStore`.

---

## 1. Where it lives

### Recommendation

Two surfaces, both required:

```
┌───────────── Git panel ─────────────┐      ┌─── Top-level tab ────────────┐
│ Status | Log | Stash | Trees |       │      │ Review: feat/hex-editor  ✕   │
│ Remotes | [Review]                   │      ├──────────────────────────────┤
│   ┌────────────────────────────┐     │      │ files | comments | export    │
│   │ Active reviews         (3) │     │      │ ┌──────┬───────────────────┐ │
│   │  ● feat/hex-editor         │     │      │ │ A.ts │  @@ -10 +10 @@    │ │
│   │  ● commit b09f773          │     │      │ │ B.md │  - cursor?: …    │ │
│   │  ○ chore/cleanup (sent)    │     │      │ │      │  + cursor?: …    │ │
│   ├────────────────────────────┤     │      │ │      │  ┌── comment ──┐ │ │
│   │ + New review…              │     │      │ │      │  │ tomas: …    │ │ │
│   └────────────────────────────┘     │      │ │      │  └─────────────┘ │ │
└──────────────────────────────────────┘      └──────────────────────────────┘
```

- **Git-panel `Review` tab** is the **index**: a flat list of reviews the user has
  drafted, plus a "New review…" button. Lightweight — no diff rendering happens
  here. Same chrome as the other five tabs (`status / log / stash / trees /
  remotes`). Selecting a review row **opens (or focuses) the review tab**.

- **Review tab** opens as a normal top-level document tab (`Tab.Kind.review`).
  This is the only surface that can render the diff at full width. Because
  it's a regular tab, the user can:
  - Move it to a split pane next to the source file.
  - Keep it open across session switches.
  - Tear it off into a separate window once windowing supports detached tabs.

### Discussion — why not a single top-level surface?

A new top-level rail icon (next to Files / Git / Search) is overkill for v1:

- We don't have a polling background loop (no providers to poll).
- Reviews are conceptually a **child of the Git surface** — same commits, same
  diffs, same branches.
- The user already navigates to Git for diffs; "go to Git, then open the
  review" is one extra click, not a workflow break.

If the multi-provider inbox lands later, *that* gets its own rail icon and the
Review tab gets promoted alongside it. v1 doesn't pre-pay that cost.

### Discussion — why not just put the diff inside the Git-panel `Review` tab?

The Git panel is narrow (it lives in a sidebar accordion today). Diffs need
horizontal real estate. The Status tab already opens diffs as top-level tabs
for this reason — the Review tab follows the same precedent.

---

## 2. Data model

All types live in `ViewerCore/Review/` and are `public`, `Codable`, `Sendable`,
`Equatable`. No SwiftUI / AppKit imports — pure persistence types.

```swift
// ViewerCore/Review/Review.swift

import Foundation

/// One review session — what the user is reviewing, the comments
/// they've left, and where it is in its lifecycle. Persisted as a
/// single JSON file at
/// `~/Library/Application Support/MarkdownViewer/Reviews/<id>.json`.
public struct Review: Codable, Equatable, Sendable, Identifiable {

    /// Schema version. Bump on any breaking change; never silently drift.
    public static let currentSchema: Int = 1

    public let id: String                 // ULID-shaped; see naming below
    public let schemaVersion: Int
    public let createdAt: Date
    public var updatedAt: Date

    /// Free-text title. Defaults to a derived one
    /// ("Review of feat/hex-editor", "Review of b09f773…").
    public var title: String
    public var description: String?       // markdown, optional

    /// What's being reviewed. The scope is immutable for the life of
    /// the review — changing it would invalidate every line anchor.
    public let scope: ReviewScope

    /// Repo root the scope resolves against. Absolute path on disk.
    public let repoRoot: String

    /// Git context captured at review creation time. Used to detect
    /// "the diff has moved under me" on reload.
    public let baseSha: String?           // base side
    public let headSha: String?           // head side (working tree → nil)

    public var state: ReviewState

    /// Comments, ordered by `createdAt`. We don't index by file/line
    /// in the on-disk shape — keep it flat, sort on read.
    public var comments: [ReviewComment]

    /// Author identity. v1: pulled from `git config user.name / user.email`
    /// at creation, then frozen. Single-author for v1.
    public let author: ReviewAuthor

    /// Export log. Append-only. Useful for "did I already send this?" UI.
    public var exports: [ReviewExportRecord]

    public init(
        id: String,
        schemaVersion: Int = Review.currentSchema,
        createdAt: Date, updatedAt: Date,
        title: String, description: String? = nil,
        scope: ReviewScope, repoRoot: String,
        baseSha: String?, headSha: String?,
        state: ReviewState = .draft,
        comments: [ReviewComment] = [],
        author: ReviewAuthor,
        exports: [ReviewExportRecord] = []
    ) { /* … */ }
}

public enum ReviewState: String, Codable, Sendable, CaseIterable {
    case draft          // freshly created, no comments yet OR still authoring
    case inReview       // has ≥1 comment, not yet exported
    case complete       // user marked it done locally
    case sent           // exported to clipboard / file / Claude Code
}

/// What's being reviewed. Tagged union — exactly one case applies.
public enum ReviewScope: Codable, Equatable, Sendable {
    /// `git diff` of working tree against HEAD (or a named ref).
    case workingTree(base: String)        // base = "HEAD" typically

    /// A single commit: `git show <sha>`.
    case commit(sha: String)

    /// A range: `git diff <from>..<to>`.
    case range(from: String, to: String)

    /// A branch against its merge-base with another branch.
    case branch(branch: String, base: String)
}

public struct ReviewAuthor: Codable, Equatable, Sendable {
    public let name: String               // git config user.name
    public let email: String              // git config user.email
}
```

### `ReviewComment`

```swift
// ViewerCore/Review/ReviewComment.swift

/// A single comment anchored to a specific line range in a specific file.
/// Threads (replies) are flat: a top-level comment has `parentId == nil`,
/// replies point at the parent.
public struct ReviewComment: Codable, Equatable, Sendable, Identifiable {
    public let id: String                 // ULID-shaped
    public let parentId: String?          // nil for top-level

    /// Path relative to repoRoot, forward-slash, no leading "./".
    /// Matches what `DiffParser` produces.
    public let filePath: String

    /// Anchor — see anchor model below.
    public let anchor: LineAnchor

    public var severity: Severity
    public var body: String               // markdown

    public let createdAt: Date
    public var updatedAt: Date

    public var resolved: Bool

    /// Capture of the diff hunk this comment was placed in. Frozen at
    /// comment-creation; never re-derived. Used by the exporter so
    /// Claude Code has the surrounding context even if the file
    /// changes underneath us.
    public let hunkContext: HunkContext

    public enum Severity: String, Codable, Sendable, CaseIterable {
        case info       // FYI / nit / style preference
        case suggestion // "consider doing X instead"
        case issue      // bug, correctness problem
        case blocker    // must-fix-before-merge
        case praise     // explicit positive callout
        case question   // I don't understand — please explain
    }
}

/// Anchors a comment to one or more lines on the **new** or **old** side
/// of the diff. Comments on context lines anchor to both sides.
public struct LineAnchor: Codable, Equatable, Sendable {

    /// Which side of the diff the user clicked on.
    public enum Side: String, Codable, Sendable {
        case old        // the "-" side — pre-change file content
        case new        // the "+" side — post-change file content
        case context    // a " " line — present on both sides
    }
    public let side: Side

    /// Line number on the anchored side. For multi-line selections,
    /// this is the start line; `endLine` is set.
    /// Line numbers are 1-based; match what DiffParser emits.
    public let startLine: Int
    public let endLine: Int                // == startLine for single-line

    /// SHA of the file's blob on the anchored side, at review creation.
    /// Lets us detect a stale anchor on reload.
    public let blobSha: String?
}

/// 3 lines before + the anchored line(s) + 3 lines after, frozen.
/// Embedded in every comment so the export is self-contained — the
/// receiver (Claude Code) can read context without re-running git.
public struct HunkContext: Codable, Equatable, Sendable {
    public let hunkHeader: String          // "@@ -10,5 +12,7 @@ func foo()"
    public let preLines: [DiffLine]        // 3 lines before
    public let anchoredLines: [DiffLine]   // the actual commented line(s)
    public let postLines: [DiffLine]       // 3 lines after
}

public struct DiffLine: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case context, added, removed
    }
    public let kind: Kind
    public let oldLineNo: Int?
    public let newLineNo: Int?
    public let content: String
}

public struct ReviewExportRecord: Codable, Equatable, Sendable {
    public enum Target: String, Codable, Sendable {
        case clipboard, file, claudeCode
    }
    public let target: Target
    public let at: Date
    public let destination: String?        // file path / "clipboard" / mcp endpoint
    public let commentCount: Int           // sanity: how many comments at export time
}
```

### `ReviewSession` — runtime, not persisted

`Review` is the on-disk type. The runtime container is a separate observable:

```swift
// ViewerUI/Review/ReviewSession.swift

@MainActor
public final class ReviewSession: ObservableObject, Identifiable {
    public let id: String                  // mirrors Review.id

    /// The persisted state. All mutations go through methods on this
    /// class so we can auto-save on change.
    @Published public private(set) var review: Review

    /// Parsed diff cached for the lifetime of the session. Computed
    /// at load time from `git diff <scope>` against the repo, then
    /// frozen. Re-parsing on every keystroke is wasted work.
    @Published public private(set) var diff: [UnifiedDiff.File]

    /// Stale flag — head/base SHA moved since we loaded. UI shows a
    /// banner; user can choose to reload (rebuild anchors best-effort)
    /// or keep editing with the cached diff.
    @Published public var isStale: Bool = false

    public init(review: Review, diff: [UnifiedDiff.File]) { /* … */ }

    public func addComment(/* … */) { /* mutates review.comments, bumps updatedAt, saves */ }
    public func updateComment(id: String, /* … */) { /* … */ }
    public func resolveComment(id: String) { /* … */ }
    public func deleteComment(id: String) { /* … */ }
    public func setState(_ s: ReviewState) { /* … */ }
}
```

### ID format

ULID-style, monotonic, base32, 26 chars. Filename-safe. Already used elsewhere
in the codebase? If not, a 16-char base32 of `Date().timeIntervalSince1970 *
1000 | random_64` is fine. The point is: **lexicographically sortable by
creation time**, so `ls Reviews/` shows newest-last.

Filenames: `<id>.json` — no spaces, no human title. Title lives inside.

---

## 3. JSON export schema

The export is **a different shape** from the on-disk persistence. Persistence
is structured for *editing* (flat comment list, internal IDs, exports log).
The export is structured for *consumption by Claude Code* — file-grouped,
self-contained, with all the context inlined.

### Why a separate shape?

A reviewer pasting JSON into a Claude prompt wants:

- One block per file, with the file's comments inlined.
- Each comment shows its line context — Claude shouldn't need to run `git
  show` to know what was being commented on.
- A top-level instructions block, so the user can phrase the ask once
  ("address all blockers and re-export") instead of in every comment.
- No internal IDs / timestamps / blob SHAs — those are noise for the LLM.

### Example

For a review of `feat/hex-editor` against `main`, with three comments:

```json
{
  "schemaVersion": 1,
  "kind": "textview.code-review",
  "exportedAt": "2026-05-17T14:22:08Z",
  "review": {
    "id": "01HXY7M8K2QZ7C5E4N0V9JZRWA",
    "title": "Review of feat/hex-editor",
    "description": "Self-review before opening the PR. Please address blockers and surface anything I missed in the hex parsing.",
    "state": "complete",
    "scope": {
      "kind": "branch",
      "branch": "feat/hex-editor",
      "base": "main"
    },
    "repo": {
      "root": "/Users/me/code/textview",
      "baseSha": "a3f1c20e9b8d7c6a5f4b3a2918275634d5e6f7a8",
      "headSha": "4e1a8c2d1f0e9b8a7c6d5e4f3a2b1c0d9e8f7a6b"
    },
    "author": { "name": "Jos", "email": "jos@example.com" },
    "stats": {
      "fileCount": 5,
      "commentCount": 3,
      "bySeverity": {
        "blocker": 1, "issue": 1, "suggestion": 1,
        "info": 0, "question": 0, "praise": 0
      },
      "unresolved": 3
    }
  },
  "instructions": "Please act on each comment in turn. For severity=blocker and severity=issue, write the fix. For severity=suggestion, evaluate and either apply or push back with reasoning. For severity=question, answer in line. Re-emit the review JSON with each comment marked resolved=true and a `response` field containing your reply.",
  "files": [
    {
      "path": "src/components/HexView.tsx",
      "stats": { "added": 142, "removed": 6 },
      "comments": [
        {
          "severity": "blocker",
          "resolved": false,
          "anchor": {
            "side": "new",
            "startLine": 82,
            "endLine": 82
          },
          "body": "`bytesPerRow` is undefined here — should be `BYTES_PER_ROW` from `hex.ts`. This will throw at runtime.",
          "context": {
            "hunkHeader": "@@ -79,3 +81,10 @@ export function HexView(...)",
            "lines": [
              { "kind": "added",   "old": null, "new": 81, "text": "export function HexHeader({ grouping, sticky }: { grouping: number; sticky: boolean }) {" },
              { "kind": "added",   "old": null, "new": 82, "text": "  const groups = bytesPerRow / grouping;", "anchored": true },
              { "kind": "added",   "old": null, "new": 83, "text": "  return (" },
              { "kind": "added",   "old": null, "new": 84, "text": "    <div className=\"htop\" data-sticky={sticky}>" }
            ]
          }
        },
        {
          "severity": "suggestion",
          "resolved": false,
          "anchor": {
            "side": "new",
            "startLine": 56,
            "endLine": 57
          },
          "body": "Two new optional props in one commit feels noisy — consider splitting `stickyAddr` into its own PR. Not a blocker.",
          "context": {
            "hunkHeader": "@@ -52,5 +52,7 @@ export interface HexViewProps {",
            "lines": [
              { "kind": "context", "old": 53, "new": 53, "text": "  bytes: Uint8Array;" },
              { "kind": "removed", "old": 54, "new": null, "text": "  cursor?: number;" },
              { "kind": "added",   "old": null, "new": 55, "text": "  cursor?: number;" },
              { "kind": "added",   "old": null, "new": 56, "text": "  grouping?: 1 | 2 | 4 | 8 | 16;     // bytes per group", "anchored": true },
              { "kind": "added",   "old": null, "new": 57, "text": "  stickyAddr?: boolean;               // pin .addr column", "anchored": true },
              { "kind": "context", "old": 55, "new": 58, "text": "}" }
            ]
          }
        }
      ]
    },
    {
      "path": "docs/hex-format.md",
      "stats": { "added": 18, "removed": 0 },
      "comments": [
        {
          "severity": "issue",
          "resolved": false,
          "anchor": {
            "side": "new",
            "startLine": 12,
            "endLine": 12
          },
          "body": "\"streams a window of bytes\" — we use \"page\" elsewhere for the chunked-load primitive. Pick one and use it everywhere.",
          "context": {
            "hunkHeader": "@@ -1,3 +1,13 @@",
            "lines": [
              { "kind": "added", "old": null, "new": 11, "text": "## Byte grouping" },
              { "kind": "added", "old": null, "new": 12, "text": "Select the number of bytes per group via the header strip. Allowed factors: 1, 2, 4, 8, 16.", "anchored": true },
              { "kind": "added", "old": null, "new": 13, "text": "" }
            ]
          }
        }
      ]
    }
  ]
}
```

### Schema rules

- `kind: "textview.code-review"` + `schemaVersion: 1` at the top — lets the
  consumer detect the format and refuse the wrong version.
- All timestamps ISO-8601 UTC.
- Line numbers are 1-based, matching `DiffParser`.
- A comment's `context.lines` ALWAYS includes the anchored line(s), with
  `anchored: true` set on each. Pre-context is up to 3 lines before, post-context
  up to 3 lines after — but **clipped to the hunk boundary** (don't fabricate
  lines we didn't see in the diff).
- Files with zero comments are **omitted** from `files[]`. Reviewers don't
  paste "here's a file I had no opinion on" into a Claude prompt.
- `instructions` is optional but defaults to a sensible template (see above).
  The user can edit it before export.
- Threaded replies in v1 are flattened — the export drops `parentId` and lists
  replies inline under the parent's `body` as a "Thread:" suffix. (Reasoning:
  v1 is single-author; there are no replies except future Claude Code
  responses which arrive via re-import, not in the export.)

### Schema in a separate file

```
ViewerCore/Review/Export/
  ExportSchema.swift       // the on-the-wire DTOs
  ReviewExporter.swift     // Review → ExportSchema → JSON Data
```

Keep these DTOs distinct from the persistence types. When the export shape
evolves, the persistence shape doesn't have to.

---

## 4. UI design — comment-add affordance

### The interaction model

Three entry points to "add a comment", in order of priority:

1. **Hover-then-click on the line-number gutter.** When the user hovers any
   line row, a `+` button appears in the gutter on the right of the line
   number column. Click → opens the inline editor as a card *below* the line.
2. **Right-click anywhere on the line → "Add review comment".** Same outcome;
   exists for muscle memory.
3. **Click-and-drag across multiple line gutters** to select a line range,
   then `+` on the last selected row creates a multi-line anchor.

### What it looks like (ASCII)

Resting state (no comments yet):

```
   54  -  cursor?: number;
   55  +  cursor?: number;
   56  +  grouping?: 1 | 2 | 4 | 8 | 16;     // bytes per group
   57  +  stickyAddr?: boolean;               // pin .addr column
   58     }
```

Hover row 56 — `+` affordance appears in the gutter:

```
   54  -  cursor?: number;
   55  +  cursor?: number;
 [+]56  +  grouping?: 1 | 2 | 4 | 8 | 16;     // bytes per group
   57  +  stickyAddr?: boolean;               // pin .addr column
   58     }
```

After click — inline editor opens *below* the line:

```
   54  -  cursor?: number;
   55  +  cursor?: number;
   56  +  grouping?: 1 | 2 | 4 | 8 | 16;     // bytes per group
       ┌─────────────────────────────────────────────────────┐
       │ Severity:  ⚪ info  🔵 suggestion  🟡 issue  🔴 blocker│
       │            ⚪ question  🟢 praise                      │
       │ ┌─────────────────────────────────────────────────┐ │
       │ │ Markdown body…                                  │ │
       │ │                                                 │ │
       │ └─────────────────────────────────────────────────┘ │
       │                            [Cancel]   [Save (⌘↩)]   │
       └─────────────────────────────────────────────────────┘
   57  +  stickyAddr?: boolean;               // pin .addr column
   58     }
```

Saved comment renders as a thread card under the line, until resolved:

```
   54  -  cursor?: number;
   55  +  cursor?: number;
   56  +  grouping?: 1 | 2 | 4 | 8 | 16;     // bytes per group
       ┌──● blocker ──────────────────────────── Jos · 14:22 ┐
       │ `bytesPerRow` is undefined here — should be          │
       │ `BYTES_PER_ROW` from `hex.ts`. Runtime crash.        │
       │                                                      │
       │ [Edit]  [Resolve]  [Delete]                          │
       └──────────────────────────────────────────────────────┘
   57  +  stickyAddr?: boolean;               // pin .addr column
   58     }
```

Multi-line anchor (lines 56-57 selected):

```
   54  -  cursor?: number;
   55  +  cursor?: number;
   56  +  grouping?: 1 | 2 | 4 | 8 | 16;     ◀─┐
   57  +  stickyAddr?: boolean;               ◀─┴ anchor range
       ┌──○ suggestion ────────────────────── Jos · 14:24 ┐
       │ Two new optional props in one commit feels       │
       │ noisy — split stickyAddr into its own PR.        │
       └──────────────────────────────────────────────────┘
   58     }
```

### Sidebar list — comments index

To the **right** of the diff view (when the Review tab has horizontal room),
or as a collapsible drawer otherwise:

```
┌── Comments ───────────────────────────── 3 ─┐
│ 🔴 blocker  HexView.tsx:82                  │
│    `bytesPerRow` is undefined here — should… │
├─────────────────────────────────────────────┤
│ 🔵 suggestion  HexView.tsx:56-57            │
│    Two new optional props in one commit…    │
├─────────────────────────────────────────────┤
│ 🟡 issue  docs/hex-format.md:12             │
│    "streams a window of bytes" — we use…    │
├─────────────────────────────────────────────┤
│ [Show resolved]  [Filter: severity ▾]       │
└─────────────────────────────────────────────┘
```

Clicking a row scrolls the diff to that line and flashes the thread card.

### Mode switch — read-only vs. authoring

The same `DiffView` is used for non-review diffs (Status row, commit show,
stash show). Those should stay **completely unchanged** — no `+` button on
hover, no right-click menu addition. The review mode is opt-in by a property:

```swift
DiffView(text: …, doc: …, reviewSession: session)  // authoring
DiffView(text: …, doc: …)                          // read-only (today)
```

When `reviewSession == nil`, the view renders exactly as today. When set, the
extra affordances activate. See §6 for the integration plan.

---

## 5. Storage

### Layout

```
~/Library/Application Support/MarkdownViewer/
  Reviews/
    01HXY7M8K2QZ7C5E4N0V9JZRWA.json   # one file per review
    01HXY3PNRDM5XT0WAE4F2GBQKZ.json
    _index.json                        # OPTIONAL: cached list-view metadata
```

- **One JSON file per review.** Keeps individual files small and lets us
  delete / move / inspect one review without touching the others.
- Filename = `<id>.json` (ULID). Title is *inside* the file. Two reasons:
  - ULIDs are filesystem-safe; titles have slashes, emoji, whitespace.
  - Lexicographic sort = chronological sort.
- `_index.json` (optional, can defer to a follow-up) caches `(id, title,
  state, updatedAt, commentCount)` for fast list rendering without reading
  every review file at boot. The leading underscore reserves the namespace
  so a future review can't collide. If absent, fall back to scanning the
  directory and reading each file lazily.

### `ReviewStore`

Wraps `JSONFileStore`. Same shape as `WorkspaceStore`:

```swift
// ViewerCore/Review/ReviewStore.swift

public final class ReviewStore: Sendable {
    public let directory: URL

    public static func defaultDirectory() -> URL {
        // Mirror WorkspaceStore: ~/Library/Application Support/MarkdownViewer/Reviews
    }

    public init(directory: URL = ReviewStore.defaultDirectory())

    public func list() -> [ReviewSummary]            // cheap; reads _index or scans
    public func load(id: String) -> Review?
    public func save(_ review: Review)                // atomic via JSONFileStore.write
    public func delete(id: String)
    public func rebuildIndex()                        // scans dir → writes _index.json
}

public struct ReviewSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: ReviewState
    public let updatedAt: Date
    public let commentCount: Int
    public let unresolvedCount: Int
}
```

`JSONFileStore.write` is already atomic + creates parent dirs. No new
mechanism needed.

### Size guard

`JSONFileStore.read` supports a `maxSize` parameter. Pass `10 * 1024 * 1024`
(10 MiB) per review file. A review with thousands of comments + 5K line
contexts could in theory bloat, but 10 MiB is a sane ceiling — anything
bigger is corruption.

### Migration

`schemaVersion` is on every persisted struct. v1 ships with `currentSchema =
1`. On read, if `schemaVersion > currentSchema`, refuse and surface a
"this review was created by a newer version" error. If equal, load. If
lower, run a migration (none for v1; the policy slot is what matters).

---

## 6. Integration with existing `DiffView` / `DiffParser`

### `DiffParser` — no changes required

The parser already emits what we need: `UnifiedDiff.File` → `Hunk` → `Line`
with `oldLineNo` / `newLineNo` / `kind` / `content`. The anchor model maps
directly:

- `LineAnchor.side == .new` → look up the line by `newLineNo`.
- `LineAnchor.side == .old` → look up by `oldLineNo`.
- `LineAnchor.side == .context` → both line numbers populated.

The `HunkContext` capture (3 lines pre + anchored + 3 post) is computed by
slicing `Hunk.lines` around the anchor index. No parser change.

### `DiffView` — minimal additive changes

The current `DiffView` is a value-typed `struct` with no mutable state beyond
the `text` it's given. To add authoring without regressing the read-only
surface:

```swift
struct DiffView: View {
    let text: String
    @ObservedObject var doc: DocumentModel
    /// NEW. When non-nil, the diff is interactive: hover affordances,
    /// click → add comment, threads render under their anchor lines.
    /// When nil (the default), behavior is unchanged.
    var reviewSession: ReviewSession? = nil
    // …
}
```

Three new private methods, all gated on `reviewSession != nil`:

1. **`lineRow` extension.** Wrap the existing row in a hover-detect overlay
   that shows a `+` button. On click, call
   `reviewSession.beginComment(file:line:side:)`.

2. **`hunkBlock` extension.** After rendering each `lineRow`, look up
   `reviewSession.comments(forFile: file.newPath, line: line.newLineNo ?? line.oldLineNo, side: …)`
   and render a `CommentThreadView` directly after the row.

3. **Multi-line drag selection.** Track an `@State var dragSelection: LineRange?`
   in `DiffView`. On gutter drag, update the range; on drag end, open the
   editor with `endLine` set.

The existing rendering path (`lineRow`, `hunkBlock`, `fileBlock`) is
**unchanged** for `reviewSession == nil`. No layout shifts, no extra padding,
no behavior change for the Status / Log / Stash diff viewers.

### New files

```
Sources/ViewerCore/Review/
  Review.swift                 # Review, ReviewState, ReviewScope, ReviewAuthor
  ReviewComment.swift          # ReviewComment, LineAnchor, HunkContext, DiffLine
  ReviewStore.swift            # disk persistence
  Export/
    ExportSchema.swift         # DTOs for the JSON-export shape
    ReviewExporter.swift       # Review → JSON Data

Sources/ViewerUI/Review/
  ReviewSession.swift          # ObservableObject runtime
  ReviewIndexTab.swift         # the "Review" tab inside Git panel (list + New)
  ReviewTabView.swift          # the top-level review tab (diff + comments + export)
  CommentEditorView.swift      # the inline-card editor
  CommentThreadView.swift      # the resolved/unresolved thread card
  CommentSidebar.swift         # right-rail comments index
```

### `GitPanelModel` change

```diff
 public enum Tab: String, CaseIterable, Identifiable, Sendable {
-    case status, log, stash, trees, remotes
+    case status, log, stash, trees, remotes, review
     public var id: String { rawValue }
     public var title: String {
         switch self {
         case .status:  return "Status"
         case .log:     return "Log"
         case .stash:   return "Stash"
         case .trees:   return "Trees"
         case .remotes: return "Remotes"
+        case .review:  return "Review"
         }
     }
     public var keyChord: KeyEquivalent? {
         switch self {
         case .status:  return "s"
         case .log:     return "l"
         case .stash:   return "h"
         case .trees:   return "t"
         case .remotes: return "r"
+        case .review:  return "v"   // "v" for review; ⌘⌥V to open
         }
     }
 }
```

And `GitPanelView.body(for:)` gains a `case .review: ReviewIndexTab(...)` arm.

### `Tab.Kind` change

`Tab.swift` in `ViewerCore` already enumerates tab kinds for the top-level
document tabs. Add:

```swift
case review(reviewId: String)
```

This is what the index tab pushes when the user opens a review; the host
window resolves it to `ReviewTabView(reviewId:)`.

---

## 7. Export workflow

### Menu

A `Review` menu in the app menu bar (sibling to `View`, `Find`, etc.):

```
Review
  New Review from Diff…           ⌘⇧N
  Open Active Reviews             ⌘⇧V          (focuses Git panel → Review tab)
  ──
  Export Current Review
    To Clipboard                  ⌘⇧E
    To File…                      ⌘⌥E
    Send to Claude Code           ⌘⇧⌘E        (disabled if MCP not set up)
  Copy Comment as Quote                       (focused-comment-only contextual)
  ──
  Mark as Complete                ⌘⌥↩
  Mark as Sent
  Delete Review…
```

The `Review` menu items are only enabled when a review tab is the focused
tab. Otherwise they're greyed out.

### Export targets

**Clipboard** — formats the export JSON, writes it to `NSPasteboard.general`
with both `public.json` and `public.utf8-plain-text` representations.

**File** — opens a save panel with default filename
`review-<short-id>-<safe-title>.json` in `~/Downloads/`.

**Send to Claude Code** — gated on a future Claude Code MCP server being
configured. v1 ships this menu item *disabled with a tooltip*: "Configure
Claude Code MCP in Settings (coming in v2)." Don't ship it as visibly
broken; ship it as visibly-pending.

### Export flow state

```
                  ┌── user clicks "Export" ──┐
                  ▼                          │
            ┌──────────────┐                 │
            │ Build DTO    │                 │
            │ from Review  │                 │
            └──────┬───────┘                 │
                   ▼                         │
            ┌──────────────┐                 │
            │ Encode JSON  │                 │
            │ via          │                 │
            │ JSONFileStore│                 │
            │ .encoder     │                 │
            └──────┬───────┘                 │
                   ▼                         │
       ┌───────────┴───────────┐             │
       ▼                       ▼             │
  ┌─────────┐            ┌───────────┐       │
  │ to clip │            │ save file │       │
  └────┬────┘            └─────┬─────┘       │
       │                       │             │
       └──────────┬────────────┘             │
                  ▼                          │
       ┌──────────────────────┐              │
       │ Append               │              │
       │ ReviewExportRecord   │              │
       │ to review.exports    │              │
       └──────────┬───────────┘              │
                  ▼                          │
       ┌──────────────────────┐              │
       │ Transition state →   │              │
       │ .sent                │              │
       └──────────────────────┘              │
```

The on-disk Review is saved after each step. If encoding fails, no export
record is written; the state doesn't transition.

---

## 8. State machine

```
                ┌─────────┐
                │  draft  │ ← created from "New Review…" with no comments
                └────┬────┘
                     │  first comment added
                     ▼
                ┌──────────┐
                │ inReview │ ← actively authoring; has ≥1 comment
                └────┬─────┘
                     │  user clicks "Mark as Complete"
                     ▼
                ┌──────────┐
                │ complete │ ← author considers it done; not yet exported
                └────┬─────┘
                     │  user exports (clipboard / file / mcp)
                     ▼
                ┌──────────┐
                │   sent   │ ← export recorded; review locked from edits
                └──────────┘
                     │
                     │  (escape hatch: user clicks "Reopen for edits")
                     ▼
                ┌──────────┐
                │ inReview │
                └──────────┘
```

### Allowed transitions

```
draft     → inReview                       (auto, on first comment)
draft     → complete                       (manual, only if comments==0 makes sense — rare)
inReview  → complete                       (manual)
inReview  → sent                           (export skipping "complete" is fine)
complete  → sent                           (export)
complete  → inReview                       (reopen)
sent      → inReview                       (reopen for edits; next export creates new record)
ANY       → (deleted)                      (delete review file from disk)
```

### UI surfacing

Each state gets a pill (vocabulary from the JSX mocks, adapted):

```
DRAFT       grey pill                          (no comments yet)
IN REVIEW   blue pill (var(--accent))          (active)
COMPLETE    green pill (var(--git-add))        (ready to send)
SENT        purple pill (var(--syn-kw))        (exported, locked)
```

The state pill appears:

- In the Git-panel `Review` tab list, on each row.
- In the top-level Review tab header (matches the JSX mock's `cr-tab-head`
  state pill in the top right).

`SENT` reviews render comments read-only (no Edit/Delete buttons, no `+`
gutter affordance on the diff). A "Reopen for edits" button in the header
is the escape hatch.

---

## 9. Test strategy

Three layers: model, store, exporter. Each lives next to its source in
`Tests/ViewerCoreTests/Review/`.

### Layer 1 — `Review` model

`ReviewTests.swift`:

- `init` defaults: `state == .draft`, `comments == []`, `exports == []`,
  `schemaVersion == currentSchema`.
- Equatable / Codable round-trip for every nested type (`Review`,
  `ReviewComment`, `LineAnchor`, `HunkContext`, `DiffLine`,
  `ReviewExportRecord`, `ReviewScope` — all four cases).
- `ReviewScope` tagged-union round-trip: encode each case, decode, assert
  equality. Catches accidental discriminator drift.
- ULID-style IDs are filename-safe (regex assertion: `^[0-9A-Z]+$`).

`ReviewCommentTests.swift`:

- `LineAnchor.endLine >= startLine` invariant.
- `HunkContext.preLines.count <= 3`, same for `postLines`.
- Severity enum exhaustive: `allCases.count` matches the spec list.

### Layer 2 — `ReviewStore` round-trip

`ReviewStoreTests.swift`:

- Write to a temp directory (set up in `setUp`, torn down in `tearDown`),
  read back, assert equality.
- `list()` returns entries sorted by `updatedAt` desc.
- `delete(id:)` removes the file from disk and removes it from `list()`.
- Atomic-write contract: corrupt the file mid-write (simulate by writing
  garbage to `Reviews/<id>.json` and then calling `save` again); reading
  after returns the new value, not partial garbage.
- Schema-version refusal: write a file with `schemaVersion: 999` directly,
  call `load`, assert it returns `nil` (or surfaces a typed error if we
  upgrade `JSONFileStore.read` to throw).
- `maxSize` guard: write a 15 MiB blob into a review file (synthetic), call
  `load`, assert it returns `nil`.

### Layer 3 — Exporter

`ReviewExporterTests.swift`:

- **Snapshot tests.** Build a `Review` with one comment of each severity,
  one multi-line anchor, one resolved comment, one with markdown body
  containing backticks + code fences. Export. Compare to a golden JSON
  file in `Tests/Fixtures/review-export-golden.json`.
- **Files with zero comments are omitted.** Build a `Review` with 5 files
  scoped, comments on only 2. Assert the export has 2 entries in `files[]`.
- **Severity stats.** Build a review with `{2 blocker, 1 issue, 3 info}`.
  Assert `stats.bySeverity` exactly matches.
- **Context clipping.** Comment anchored at the first line of a hunk:
  `preLines.count == 0`. Comment at last line of hunk: `postLines.count
  == 0`. Comment in the middle: both `== 3`.
- **Anchored flag.** Every line in `context.lines` matches the anchor's
  `[startLine, endLine]` range gets `anchored: true`; others false.
- **Round-trip via Claude Code consumption shape.** Encode → decode (using
  the export DTO) → assert no data loss. (We don't expect to *import*
  exports in v1, but a round-trip test catches schema regressions.)

### Layer 4 — `DiffView` integration (smoke)

`DiffViewReviewTests.swift` in `ViewerUITests`:

- Render `DiffView(text: sampleDiff, doc: doc, reviewSession: nil)` — no `+`
  button on hover (snapshot or accessibility-element assertion).
- Render `DiffView(..., reviewSession: session)` — `+` button is reachable.
- Clicking the `+` calls `session.beginComment` with the right `(file,
  line, side)` triple. Verify via a spy session.

### Layer 5 — Anchor stability under diff drift

`AnchorStabilityTests.swift`:

- Given a diff parsed at time T0, a comment anchored at `(file: "a.ts",
  side: .new, startLine: 56)`. The file is then edited; re-parse the
  diff at T1. Assert the comment's anchor is detected as **stale** if
  the line at `newLineNo: 56` has a different content than the stored
  `hunkContext.anchoredLines[0].content`.
- This drives the v1 stale-banner behavior. v1 does *not* try to re-map
  anchors — it just flags them. v2 may map them with diff-against-diff.

### What we explicitly don't test in v1

- Provider integration (no providers).
- Multi-author thread replies (single author).
- MCP send to Claude Code (gated behind v2).

---

## 10. Open questions for the implementer

Resolve before landing v1. None are blockers; each has a reasonable default
called out.

1. **ULID dep.** Do we pull a 200-line ULID lib or roll our own? **Default:
   roll our own — 30 lines, no dep.** A future migration to a real ULID
   library is trivial because the IDs are opaque strings.

2. **Where does `git diff <scope>` run from?** `GitClient` already shells
   out for status/log/stash. Add a `diff(scope: ReviewScope) -> String`
   method. **Default: yes, add it; mirror `show(sha:)`'s shape.**

3. **`baseSha` / `headSha` for `workingTree`.** Working-tree has no head
   SHA — it's uncommitted. Store `nil` for `headSha`. The exporter labels
   this scope clearly so Claude Code knows the comments are on uncommitted
   work.

4. **Author identity privacy.** `git config user.email` is what we store.
   If the user runs `git config user.email '<hidden>'` we still capture it.
   The export reveals it. **Default: accept this; reviewers' email leaks
   on every commit anyway. Settings UI to override is a v2.**

5. **Comment ordering in the export.** Sort by file path → line number?
   By creation time? **Default: file path → anchor.startLine. Stable,
   matches reading order, lines that go together stay together.**

6. **Resolved comments in the export.** Include or skip? **Default: include
   with `resolved: true`. Claude Code might still want to know the user
   considered something and let it pass. Add a `--unresolved-only` toggle
   in the export menu as a polish item.**

7. **What happens when the user opens a Status diff in a review session?**
   Status diffs (working tree) are uncommitted. v1: allow them, scope is
   `workingTree(base: "HEAD")`, no `headSha`. Export labels them clearly.

8. **Right-rail vs. drawer for the comments index.** **Default: right-rail
   when window width >= 1200pt, drawer otherwise.** Matches the existing
   responsive breakpoint conventions in the app.

---

## 11. Implementation phasing

A practical ordering for landing v1, each phase mergeable on its own:

1. **Phase 1 — Data model + storage.**
   `Review.swift`, `ReviewComment.swift`, `ReviewStore.swift`. Unit tests
   from §9 layers 1-2. No UI; verify with a CLI-style test that writes a
   handful of reviews and reads them back.

2. **Phase 2 — Exporter.**
   `ExportSchema.swift`, `ReviewExporter.swift`. Unit tests from §9 layer 3.
   No UI; produce JSON from synthetic Reviews and golden-compare.

3. **Phase 3 — Review-aware `DiffView`.**
   Additive props on `DiffView`, hover affordance, click → editor card,
   thread-under-line rendering. `ReviewSession` runtime. Smoke tests
   from §9 layer 4. **Verify the non-review path is byte-identical** —
   the existing Status / Log / Stash diff viewers must look and behave
   exactly as before.

4. **Phase 4 — Git-panel `Review` tab + top-level review tab.**
   `ReviewIndexTab`, `ReviewTabView`, `Tab.Kind.review`. Wire to
   `GitPanelModel.Tab.review`. End-to-end: create a review from the
   Status tab, switch to Review tab, see it listed, open it.

5. **Phase 5 — Export menu + state machine.**
   `Review` menu, clipboard + file targets, state pill, lock-on-sent.
   Anchor stability tests from §9 layer 5.

6. **Phase 6 — Polish.**
   Right-rail comments index, severity filter, markdown rendering of the
   comment body in the thread card, keyboard shortcuts (`N` next
   unresolved, `R` reply, `⌥R` resolve — vocabulary from the JSX mock).

`Send to Claude Code` target stays disabled with a tooltip until the MCP
work lands in a separate epic.

---

## 12. File-by-file summary (for the implementer)

| File                                                | Action  | Why                                       |
|-----------------------------------------------------|---------|-------------------------------------------|
| `ViewerCore/Review/Review.swift`                    | NEW     | `Review`, `ReviewState`, `ReviewScope`    |
| `ViewerCore/Review/ReviewComment.swift`             | NEW     | `ReviewComment`, `LineAnchor`, etc.       |
| `ViewerCore/Review/ReviewStore.swift`               | NEW     | disk I/O via `JSONFileStore`              |
| `ViewerCore/Review/Export/ExportSchema.swift`       | NEW     | wire-format DTOs                          |
| `ViewerCore/Review/Export/ReviewExporter.swift`     | NEW     | Review → JSON                             |
| `ViewerCore/Git/DiffParser.swift`                   | no-op   | already produces what we need             |
| `ViewerCore/Tab.swift`                              | EDIT    | add `Tab.Kind.review(reviewId:)`          |
| `ViewerCore/GitService.swift`                       | EDIT    | add `diff(scope: ReviewScope)`            |
| `ViewerUI/Review/ReviewSession.swift`               | NEW     | `@MainActor` runtime container            |
| `ViewerUI/Review/ReviewIndexTab.swift`              | NEW     | the Git-panel "Review" sub-tab            |
| `ViewerUI/Review/ReviewTabView.swift`               | NEW     | the top-level review tab                  |
| `ViewerUI/Review/CommentEditorView.swift`           | NEW     | inline editor card                        |
| `ViewerUI/Review/CommentThreadView.swift`           | NEW     | rendered thread card                      |
| `ViewerUI/Review/CommentSidebar.swift`              | NEW     | right-rail / drawer comments index        |
| `ViewerUI/Git/DiffView.swift`                       | EDIT    | optional `reviewSession`; gated affordance |
| `ViewerUI/Git/GitPanelModel.swift`                  | EDIT    | add `Tab.review` case                     |
| `ViewerUI/Git/GitPanelView.swift`                   | EDIT    | route `case .review` → `ReviewIndexTab`   |
| `Tests/ViewerCoreTests/Review/*`                    | NEW     | model + store + exporter tests            |
| `Tests/ViewerUITests/Review/*`                      | NEW     | DiffView smoke tests                      |

---

## 13. Vocabulary borrowed from the mocks (and what we drop)

From `/Users/me/Downloads/TextView (3)/codereview*.{js,jsx}` and
`details/code-review.html` we keep:

- **State pill** in the top right of the review header.
- **Inline thread card** under the anchor line, with a colored border.
- **Severity dots** in the comments index.
- **Files-changed column** on the left of the review tab.
- **`+N −M`** stats on each file row.

We drop (because v1 is local-only):

- Provider source badges (`GH` / `CR` / `GL` / `PH`).
- Reviewer avatars and per-reviewer state dots.
- CI section, Checks tab, Timeline tab, Commits tab.
- The Conversation tab (no PR body to render; the review's own
  `description` field is its body).
- The Approve / Request changes header buttons (no provider to approve at).
- Reply input (no other authors to reply to in v1).

The Review tab body in v1 is **just**: Files | Comments | Export.

---

End of design. Ready for v1 implementation.
