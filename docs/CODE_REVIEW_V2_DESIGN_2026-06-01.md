# Code Review — Design v2 (project-local `.textview/` store)

> **Status:** implementation spec. Written *alongside* `docs/CODE_REVIEW_DESIGN.md`
> (v1) — v1 is **not** superseded or to be edited. v2 records the intended
> *evolution* of two v1 decisions that the user has since reversed:
>
> 1. **Storage location.** v1 committed hard to a **global** store at
>    `~/Library/Application Support/MarkdownViewer/Reviews/`. v2 relocates the
>    store to a **project-local `.textview/` folder living with the repo**, so
>    reviews are shareable and travel to Claude alongside the code.
> 2. **On-disk format question.** The user floated JSONL (append-only event
>    log). v2 makes that call **explicitly** (§2): the on-disk store stays a
>    **JSON snapshot per review**; JSONL is *not* adopted as the source of
>    truth, with an optional audit sidecar as the only concession.
>
> Everything else in v1 (the Review tab UX, the comment-add interaction, the
> state machine, the worked export example) stands. v2 is the persistence +
> wiring refinement, not a UX redesign.
>
> **Hard constraint honored throughout: reuse-not-clobber.** The shipped,
> tested types in `Sources/ViewerCore/Review/` are reused verbatim. Only
> *additive* changes (a new resolver, a new optional field on an existing
> struct, new files) are proposed. Every "change" below is checked against the
> existing T1 tests in `Tests/ViewerCoreTests/Review/`.

---

## 0. What this feature is, in one paragraph

A local, git-aware review surface. You open a diff (a commit, a range, a
branch, or your uncommitted working tree), pin comments to specific lines,
tag each with a severity, and the whole set exports as a **self-contained JSON
work order** that a coding agent (Claude Code) can execute against a known
commit *without re-deriving context* — because each comment carries its own
frozen hunk snippet. The reviews now live in `<repo>/.textview/`, so they're
discoverable, shareable, and handed to the agent next to the code.

The model + store + exporter are already built and tested in `ViewerCore`
(`SwiftUI`/`AppKit`-free). This design adds: a project-local store resolver, an
optional staleness signal, the observable `ReviewSession` runtime, and the
`ViewerUI` views — staged so Stage 1 lands independently green on the headless
gate.

---

## 1. The `.textview/` folder

### 1.1 Layout

```
<repoRoot>/
└── .textview/                         # project-local "TextView sidecar" dir
    ├── reviews/
    │   ├── _index.json                # ReviewSummary[] cache (already implemented)
    │   ├── 01HF7Q…ZX.json             # one Review JSON per review (id == ULID)
    │   ├── 01HF8R…AB.json
    │   └── audit/                      # OPTIONAL, off by default — see §2.4
    │       └── 01HF7Q…ZX.events.jsonl # append-only mutation trail (NOT source of truth)
    ├── session.json                   # active-review-per-repo pointer + draft instructions (§1.4)
    ├── config.json                    # repo-level: tracked-vs-ignored choice, author override
    └── .gitignore                     # written by the app on first use (§1.3)
```

- **`reviews/<id>.json`** — the exact on-disk shape `ReviewStore` already writes
  (`ReviewStore.save` → `JSONFileStore.write`). One file per review, `id` is the
  ULID (`ReviewID.generate`). No format change; **only the directory moves.**
- **`reviews/_index.json`** — the `ReviewSummary[]` cache. Already implemented
  (`ReviewStore.list` / `rebuildIndex`, `ReviewStore.swift:130-164`); it
  self-heals via directory scan when stale, so a fresh `.textview/` needs zero
  migration.
- **`session.json`** — small, review-scoped session state (§1.4). Distinct file,
  not folded into any `Review`.
- **`config.json`** — repo-level settings, chiefly the tracked-vs-ignored toggle
  (§1.3).

### 1.2 Why `.textview/` and why this nesting

- **`.textview/` is the dotfile sidecar, `reviews/` is one tenant.** The user
  frames `.textview/` as the home for "session-level information" generally.
  This design **scopes the work to reviews** but lays the namespace out so the
  Sessions feature (`#184`) *could* later add `.textview/workspaces/` or
  `.textview/sessions/` as a sibling of `reviews/` without disturbing it. We are
  **not** building that here — `reviews/` + the review-scoped `session.json` are
  the only tenants this design creates.
- **`repoRoot` already exists on the model.** `Review.repoRoot`
  (`Review.swift:33`) holds the absolute repo path. The store directory is a
  pure function of it — `<repoRoot>/.textview/reviews/` — so a review is
  *self-locating*; no new field is required to find its store.
- **Repo-root discovery** uses `GitClient.discoverRoot(from:)`
  (`GitClient.swift:78`) on the open file's URL.

> **Sync caveat (from the IDE/web survey, input C).** iCloud Drive and Dropbox
> *silently skip* path components beginning with `.`, so a `.textview/` dir
> inside a cloud-synced repo will **not** sync. This is **acceptable and even
> desirable** here: the sharing channel for reviews is **git** (the dir is
> committed, §1.3), not file-sync. If a future user needs sync-without-git, the
> `MDV_TEXTVIEW_DIR` override (§1.5) lets them relocate to a non-dotted path.
> Flag it in `config.json`'s comment, don't engineer around it now.

### 1.3 Committed vs git-ignored — **decision: git-ignored by default, per-repo opt-in** (owner, 2026-06-01)

The user's stated motivation ("reviews shareable + handed to Claude alongside
the code") could point at tracking `.textview/reviews/` in git — but the owner's
decision (2026-06-01) is to **git-ignore by default and opt in per-repo**, so a
review never enters history (and never leaks the verbatim code snippets frozen in
its hunk context) unless the user explicitly turns tracking on for that repo.

- **Ignore by default.** A fresh repo's reviews stay local/private; nothing is
  committed until the user flips `config.json` `"tracked": true`. Sharing /
  handing-to-Claude is then an explicit opt-in per repo, not an accident.
- **Opt in to track.** When turned on, committing makes review feedback travel
  with the branch, survive clone, and be present for the agent on checkout — the
  original "reviews live with the repo" benefit, now consent-gated.
- **The JSON-snapshot format is *not* naturally merge-friendly** (§2.3). That's a
  real cost of "track it" — two branches editing the same review's `<id>.json`
  collide on a whole-file conflict. v2's mitigation: **one file per review, id is
  a ULID**, so independent reviews never collide; only *the same review edited on
  two branches* conflicts, which for a single-author tool is rare.
- **Per-repo opt-in** via `config.json` (`"tracked": true|false`, default
  `false`). By default (ignored), the app writes a `.textview/.gitignore` of:

  ```gitignore
  # Ignore everything in this sidecar…
  *
  # …except the ignore rule itself (so the choice is visible in git).
  !.gitignore
  ```

  When the user opts in (`"tracked": true`), the app writes a narrower
  `.gitignore` that **always** excludes the derived/transient bits regardless of
  the tracked choice:

  ```gitignore
  reviews/audit/      # optional event sidecar — derived, regenerable
  session.json        # local cursor/active-review state — machine-specific
  ```

- **`.gitattributes` (when tracked):** ship a normalization hint so the JSON
  doesn't churn on line-ending flips across machines:

  ```gitattributes
  reviews/*.json text eol=lf
  ```

### 1.4 `session.json` — review-scoped session state (in scope, minimal)

```jsonc
{
  "schemaVersion": 1,
  "activeReviewId": "01HF7Q…ZX",   // which review the Review tab reopens to
  "draftInstructions": "…",         // edited export instructions, survives relaunch
  "lastExport": {                   // mirror of the newest ReviewExportRecord, for UI
    "reviewId": "01HF7Q…ZX",
    "at": "2026-06-01T09:40:00Z",
    "target": "clipboard"
  }
}
```

- `session.json` is **git-ignored even when reviews are tracked** (it's a local
  cursor — committing it would create per-machine churn and merge noise).
- It is **not** part of `Review` and **not** part of `ReviewStore`. It's a tiny
  separate Codable + a one-file read/write through `JSONFileStore`. Keeps the
  tested `Review`/`ReviewStore` shapes untouched.
- Cursor/scroll position is explicitly **out of scope** for v2.

### 1.5 Overrides & test hygiene

- **`MDV_TEXTVIEW_DIR`** env override → relocate the whole sidecar. Resolution
  order: `MDV_TEXTVIEW_DIR` → `<repoRoot>/.textview` → (legacy fallback) global
  `ReviewStore.defaultDirectory()`.
- **Tests** point `repoRoot` (and therefore the store dir) at
  `FileManager.default.temporaryDirectory` — never `~/Documents`, per `CLAUDE.md`.

---

## 2. On-disk schema — **decision: JSON snapshot per review, NOT JSONL**

### 2.1 The call, stated plainly

**Keep one JSON document per review (the status quo), relocated into
`.textview/reviews/<id>.json`. Do not adopt a JSONL event log as the source of
truth.** Optionally write an *additional* append-only `events.jsonl` audit
sidecar (§2.4), off by default.

### 2.2 Why JSON-snapshot wins *here* (vs. inputs A & B, which favored JSONL)

| Force | JSONL would want… | But this codebase has… | Verdict |
|---|---|---|---|
| **Writers** | lock-free concurrent appenders | single-user, single-window, **debounced** writes (`SessionStore`'s serial write-queue + coalescing) | No concurrency to protect → JSONL's headline win doesn't apply |
| **Crash-safety** | atomic `O_APPEND` per event | `JSONFileStore.write` is already **atomic** (write-temp + rename) and **never-throws** | Snapshot is already crash-safe → JSONL's second win is matched |
| **Read path** | fold events → state on every load | `ReviewStore.load` is a single read + schema-gate; `_index.json` caches the list | JSONL forces a reducer + tail-replay the codebase doesn't have; pure cost |
| **Tests** | rewrite round-trip assumptions | ~600 lines of T1 tests pin the snapshot round-trip, `_index` caching, 10 MiB guard, schema-too-new refusal | JSONL would **clobber** the tested contract — violates the hard constraint |
| **Audit history** | native in the log | recoverable via git history of the committed `<id>.json` | When tracked, **git itself is the audit log** |

The decisive point against JSONL is the **reuse-not-clobber constraint**:
adopting an event log means throwing away `JSONFileStore`'s atomic-write +
lenient-array machinery and the entire `ReviewStore` CRUD + index contract that
~600 lines of green T1 tests pin. JSONL's wins are recoverable other ways in
this context; its costs are all new surface.

### 2.3 The honest cost we're accepting

A committed snapshot JSON conflicts on a whole-file merge if the *same* review
is edited on two branches. v2 accepts this because: (a) one-file-per-ULID means
*different* reviews never collide; (b) single-author use makes concurrent
same-review edits rare; (c) the alternative (JSONL `merge=union`) costs the
entire tested-contract rewrite. If multi-author review-merging ever becomes a
real requirement, **that** is the trigger to revisit JSONL — not now.

### 2.4 Optional audit sidecar (the one JSONL concession)

When `config.json` sets `"auditTrail": true`, every `ReviewSession` mutation also
appends one line to `.textview/reviews/audit/<id>.events.jsonl`. Append-only,
never read back as truth, off by default, git-ignored, GC'd when its review is
deleted.

### 2.5 Reused record shapes (no changes)

The on-disk schema **is** the existing types: `Review`, `ReviewState`,
`ReviewScope`, `ReviewComment`, `LineAnchor`, `HunkContext`, `DiffLine`,
`ReviewAuthor`, `ReviewExportRecord`, `ReviewID`, `ReviewSummary`. v2 finally
*populates* `LineAnchor.blobSha` at capture time (§3) — a behavior addition in
the capture code, not a type change. The only persistence-layer code change is
an *additive* resolver on `ReviewStore` (§5.1).

---

## 3. Line anchoring & staleness

### 3.1 Capture at comment-creation time (the new code)

On comment creation, `ReviewSession` captures and **freezes**:

1. **`LineAnchor`** — `side`, `startLine`/`endLine` (1-based), and **`blobSha`**:
   - committed side → `git rev-parse <rev>:<path>` (`GitClient.blobSha(rev:path:)`).
   - working-tree side → `git hash-object -- <path>` (`GitClient.blobShaForWorktree(path:)`).
   - `blobSha` stays optional; helper failure → `nil` → staleness degrades to "unknown".
2. **`HunkContext`** — slice from `UnifiedDiff.Hunk.lines`: up to 3 `preLines`,
   the `anchoredLines`, up to 3 `postLines`, plus the `hunkHeader`. **Clipped to
   hunk boundaries** — never fabricate lines past the hunk edge.
3. **`hunkHeader`** verbatim from `UnifiedDiff.Hunk`.

### 3.2 Staleness detection on reload — **flag, don't re-map**

```
on review load, per comment, against the live target:
  liveBlob = GitClient.blobSha(<anchor side's current blob for filePath>)
  if anchor.blobSha == nil          -> state = .unknown   (couldn't capture)
  else if liveBlob == nil           -> state = .unknown   (file gone / untracked / binary)
  else if liveBlob == anchor.blobSha-> state = .current   (byte-identical)
  else                              -> state = .stale     (file moved under us)
```

- **`.current`** — render inline on its anchored line; safe.
- **`.stale`** — render against frozen `HunkContext` with a "code changed" badge.
- **`.unknown`** — render against frozen context with a neutral note.

`AnchorState` is a **UI-layer derived enum** — recomputed on every load,
**not stored** — keeping `ViewerCore` SwiftUI-free. *(Stage 1 places the pure
`AnchorState` + evaluator in ViewerCore as data-only logic; the per-load
recompute lives in `ReviewSession`.)*

### 3.3 The mapping landmine

`UnifiedDiff.Line.Kind` has **4** cases (`.context/.added/.removed/.noNewline`);
`DiffLine.Kind` has **3** (no `.noNewline`). The capture mapper that turns
`UnifiedDiff.Line` → `DiffLine` **must drop `.noNewline` lines** — they carry no
line numbers and aren't reviewable code. Pinned by `HunkContextCaptureTests`.

### 3.4 What v2 deliberately does *not* build

No fuzzy re-anchoring ladder (diff-match-patch). It needs a dependency requiring
explicit approval, and v1's stance — *flag, don't re-map* — holds: a visible
`.stale` badge + frozen snippet is safer than a confident-wrong fuzzy re-anchor.
Documented future enhancement, gated on a dependency conversation.

---

## 4. Scope handling — commit **and** working tree (reuse `ReviewScope`)

A single scope→diff resolver on `GitClient` composing the existing primitives:

| `ReviewScope` case | `baseSha` / `headSha` frozen | Diff command |
|---|---|---|
| `.workingTree(base)` | `baseSha = rev-parse <base>`, **`headSha = nil`** | `git diff <base> -- <path>` |
| `.commit(sha)` | `baseSha = <sha>~`, `headSha = <sha>` | `commitDiff(sha:)` |
| `.range(from,to)` | `baseSha = from`, `headSha = to` | `diff(from:to:path:)` |
| `.branch(branch,base)` | `merge-base(base, branch)` frozen as `baseSha`; `headSha = rev-parse <branch>` | `diff(from: mergeBase, to: branch, path:)` |

- **Scope is immutable for the review's life** (`Review.scope` is `let`).
- **Working tree** is the only mode with `headSha == nil` — which is *why* the
  per-comment `blobSha` + frozen `HunkContext` are mandatory there.
- The **branch merge-base is resolved once and frozen** so the review doesn't
  silently re-scope when the base branch advances.

`GitClient.diff(scope:)` is a pure addition.

---

## 5. The Claude handoff — **existing `ReviewExporter` JSON is the payload**

### 5.1 Decision

**`ReviewExporter` is the handoff, unchanged.** It already produces the
self-contained, re-derivation-free payload all four inputs converged on.

### 5.2 What each exported comment already carries

`severity`, `anchor` side + line range, `context` = the frozen hunk
(`hunkHeader` + every pre/anchored/post line with `old`/`new` numbers, verbatim
`text`, and `anchored: true` on lines inside the range), `body` (markdown, with
replies flattened into a `Thread:` suffix), the top-level `review` block
(`id`, `title`, `scope`, `repo` with `headSha: null` = uncommitted worktree,
`author`, `stats`), and `instructions`. Kind is `"textview.code-review"`.

### 5.3 Optional, additive-only enrichments (deferred)

`anchorState` on `ExportComment` and `blobSha` echoed under `anchor` — both
deferred polish behind their own tests + golden-fixture update.

### 5.4 Round-trip (re-import) — deferred

The model already supports it (`parentId` for replies, `resolved` flip). The
re-import parser is a follow-on.

---

## 6. UI plan (`ViewerUI`)

All UI lives in `ViewerUI` — **`ViewerCore` stays SwiftUI/AppKit-free**.

### 6.1 `ReviewSession` — the observable keystone (new)

`@MainActor final class ReviewSession: ObservableObject`:

- **Wraps** a `Review` (`@Published private(set) var review: Review`).
- **Caches** the parsed `[UnifiedDiff.File]` for the scope's diff (parse once).
- **Mutations** — `addComment`, `updateComment`, `resolve`/`reopen`, `addReply`,
  `delete`, `setState` — each bumps `review.updatedAt`, enforces
  `ReviewState.canTransition`, and **debounce-saves** through the project-local
  `ReviewStore` using `SessionStore`'s serial-write-queue + coalescing pattern.
- **Capture** — owns the §3.1 capture pipeline.
- **Staleness** — computes the §3.2 `AnchorState` map on load (derived, non-stored).

### 6.2 Review-aware `DiffView` — **extend, don't fork**

Add **one optional property** so the existing call sites stay byte-identical:

```swift
var reviewSession: ReviewSession? = nil   // default keeps read-only behavior
```

Gate all review affordances on `reviewSession != nil`. A T1m test asserts the
**`nil` path renders identically** to today.

### 6.3 Comment cards (new)

`CommentEditorView` (inline composer: severity picker + markdown body), 
`CommentThreadView` (severity dot, author·time, body, `.stale`/`.unknown` badge,
Edit/Resolve/Reply/Delete), `CommentSidebar` (right-rail index). Reuse the
in-tree markdown renderer — **no markdown lib** (bundle cap + dependency rule).

### 6.4 Index + tab plumbing

`ReviewIndexTab` (flat review list + "New review…"), `GitPanelModel.Tab` adds
`.review` (additive arms in the exhaustive switches), `ReviewTabView` top-level
document tab, and a fileless review-tab host arm in `ContentView`.

### 6.5 Export menu

Export ⌘⇧E, Mark Complete, Reopen → `ReviewExporter.export(...)` → pasteboard or
save panel; append a `ReviewExportRecord`; transition `state → .sent` (guarded);
mirror into `session.json.lastExport`.

---

## 7. Staged, headless-testable implementation plan

**Build prerequisite for every stage:** `bash scripts/build-rust-core.sh` before
any `swift build`/`swift test`. Gate = `bash scripts/test-headless-gate.sh`; the
only acceptable pre-existing red is
`MarkdownLinkPolicyTests.test_decide_sameDocFragment_isAllowed`.

### Stage 1 — Core persistence (T1, lands independently green)

**Add:** `ReviewStore+ProjectLocal.swift`, `ReviewSidecar.swift` (session.json),
`HunkContextCapture.swift`, `AnchorStaleness.swift`. **Change (additive):**
`GitClient` gains `diff(scope:)`, `blobSha(rev:path:)`, `blobShaForWorktree(path:)`.
**Tests:** `ReviewStoreProjectLocalTests`, `HunkContextCaptureTests`,
`AnchorStalenessTests`, `ScopeDiffTests`, `SidecarSessionTests`.

### Stage 2 — `ReviewSession` observable + wiring (T1m)

**Add:** `Sources/ViewerUI/Review/ReviewSession.swift`. **Tests:**
`ReviewSessionTests` (mutations + autosave + republish-guard, window-free).

### Stage 3 — Views (structural T1m; interaction VM-owed)

**Add:** comment cards, index tab, review tab, export menu. **Change (additive):**
`DiffView` optional `reviewSession`. **Tests:** `DiffViewReviewTests` (nil path
identical), `CommentCardStructureTests`. VM-only: hover-`+`, drag-select,
composer commit, export-to-clipboard round-trip.

---

## 8. Reuse-vs-change ledger

| Area | Disposition |
|---|---|
| `Review`/`ReviewState`/`ReviewScope`/`ReviewAuthor`/`ReviewExportRecord`/`ReviewID` | **Reuse unchanged** |
| `ReviewComment`/`LineAnchor`/`HunkContext`/`DiffLine` | **Reuse unchanged** (populate `blobSha`, produce `HunkContext`) |
| `ReviewStore` CRUD/index/guard | **Reuse unchanged**; add `projectLocal(repoRoot:)` |
| `ReviewExporter` + wire DTOs | **Reuse unchanged** = the handoff |
| `JSONFileStore`, `GitClient` (existing), `DiffParser`/`UnifiedDiff` | **Reuse unchanged** |
| On-disk format | **JSON snapshot** (JSONL rejected); optional audit sidecar only |
| `GitClient` | **Add** `diff(scope:)`, blob-sha helpers |
| `GitPanelModel.Tab`, `Tab`/`ContentView` | **Additive** `.review` case + fileless host |
| `DiffView` | **Extend** with optional `reviewSession`; nil path unchanged |
| `ReviewSession` + all views | **New** in `ViewerUI` |

**Migration stance:** new reviews go project-local; existing global reviews stay
put; an opt-in "Import legacy reviews…" is a follow-on. No automatic sweep.

---

## 9. Sharp edges carried forward

- `blobSha` was a dead field until v2 — land capture before claiming staleness.
- `DiffLine.Kind` (3) vs `UnifiedDiff.Line.Kind` (4) — drop `.noNewline`.
- `HunkContext` clipping — pre/post are *up to* 3, clipped; an off-by-one bakes
  wrong context **permanently** (frozen).
- Anchor side vs line-number lookup — the export's `anchored` flag uses
  `.context → newLineNo ?? oldLineNo`; re-resolution must match.
- **Untrusted-repo surface widens** — a project-local `.textview/reviews/` is
  now attacker-influenced content. Existing mitigations carry over: 10 MiB guard
  + schema-too-new refusal + `JSONFileStore` never-throws.
- Snapshots embed verbatim source lines — note for secrets-in-code shops.
- Bare `swift test` runs T1m — `DiffViewReviewTests` must be window-free.
