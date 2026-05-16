# WALKTHROUGH.md — guided-tour system for TextView

Status: design draft. No code yet. Targets the existing
`DocumentModel` control surface in `Sources/ViewerUI/DocumentModel.swift`
and the menu/script dispatcher in `Sources/MarkdownViewer/main.swift`.

---

## 1. What is a walkthrough? (concrete)

A **walkthrough** is a saved, replayable sequence of TextView actions
plus narration that Claude (or a human author) drives the editor
through, with the user holding a transport (play / pause / step /
back / skip). It is the visual analog of `git log -p` for a piece of
code or a doc: instead of reading a diff, you watch the editor unfold
a tour through the codebase, with annotations.

A concrete example, end-to-end:

> User opens TextView on this repo and tells Claude (via MCP):
> "Walk me through how syntax highlighting works." Claude generates
> a 14-step walkthrough script and hands it to TextView. The player
> appears as a docked strip at the bottom of the window. Step 1
> opens `HACKABILITY.md` and highlights the "Add a new file type
> to highlight" section. Step 2 opens
> `Sources/ViewerKit/HighlightLanguage.swift` and pins a callout
> to `detect(from:)`. Steps 3–9 walk through the engine. Step 10
> is a **checkpoint** — "Want me to dive into incremental reparse,
> or move on to themes?" The user's answer plus the cursor position
> is sent back over MCP; Claude returns either an inline next-step
> injection or a new walkthrough fragment to splice in. Steps 11–14
> finish whichever branch was taken.

What it is **not**: not a recorded macro of mouse clicks, not a
screencast, not a slideshow. It's a structured script of *editor
verbs* + *narration* + *checkpoints*, replayable, scrubbable,
diffable, machine-authorable.

The key property: each step is declarative ("open file X, scroll
to line Y, show callout Z"), so the player can render any step in
isolation — no replay of prior steps needed. That makes back/skip
cheap and the script trivially diffable.

---

## 2. Script format

**Recommendation: JSON.**

- YAML — nicer to hand-type, but adds a dependency (Yams or hand-
  rolled parser) and indentation footguns when Claude generates it.
  Reject.
- Custom DSL — means a new parser; project rules forbid adding
  dependencies without discussion. Reject.
- JSON — stdlib `JSONDecoder`, Claude emits it reliably, easy to
  validate and diff, and TextView already syntax-highlights it.
  Accept.

The schema is small and versioned. Top-level:

```json
{
  "schema": "textview.walkthrough/v1",
  "id": "highlight-engine-tour",
  "title": "How syntax highlighting works",
  "subtitle": "Tree-Sitter, capture maps, themes",
  "author": "claude:opus-4.7",
  "createdAt": "2026-05-16T14:00:00Z",
  "estimatedDurationSec": 360,
  "rootHint": "/Users/me/.../markdown_viewer",
  "steps": [ ... ]
}
```

A 10-step example, end-to-end. Note the verb diversity, the use of
existing TextView primitives (line bookmarks, gutter dots, find
bar), and one checkpoint:

```json
{
  "schema": "textview.walkthrough/v1",
  "id": "highlight-engine-tour",
  "title": "How syntax highlighting works",
  "rootHint": "/Users/me/.../markdown_viewer",
  "steps": [
    {
      "id": "s01",
      "verb": "narrate",
      "text": "TextView uses Tree-Sitter for syntax highlighting. Six files, ~20 lines per language. Let's trace one end-to-end."
    },
    {
      "id": "s02",
      "verb": "openFile",
      "path": "HACKABILITY.md",
      "scrollTo": { "line": 22 },
      "callout": "Five files, one .scm — the contract."
    },
    {
      "id": "s03",
      "verb": "openFile",
      "path": "Sources/ViewerKit/HighlightLanguage.swift",
      "viewMode": "source",
      "scrollTo": { "symbol": "detect(from:)" },
      "highlightLines": [12, 13, 14, 15]
    },
    {
      "id": "s04",
      "verb": "callout",
      "text": "Enum + extension map. Adding `.lua` is one case here.",
      "anchor": { "line": 14 }
    },
    {
      "id": "s05",
      "verb": "openFile",
      "path": "Sources/ViewerCore/Highlight/TreeSitterEngine.swift",
      "scrollTo": { "symbol": "tsLanguagePointer(for:)" },
      "pinBookmark": { "line": 88, "label": "lang ptr switch" }
    },
    {
      "id": "s06",
      "verb": "find",
      "query": "queryURL(for:)",
      "caseSensitive": true,
      "narration": "Each language ships a vendored highlights.scm."
    },
    {
      "id": "s07",
      "verb": "openFile",
      "path": "Sources/ViewerCore/Highlight/CaptureMap.swift",
      "scrollTo": { "line": 1 },
      "callout": "Tree-Sitter capture names → SyntaxToken kinds."
    },
    {
      "id": "s08",
      "verb": "checkpoint",
      "prompt": "Want to dive into incremental reparse (perf), or jump to themes?",
      "options": [
        { "id": "perf",   "label": "Incremental reparse" },
        { "id": "themes", "label": "Themes" }
      ]
    },
    {
      "id": "s09",
      "verb": "openFile",
      "path": "Sources/ViewerCore/Highlight/SyntaxTheme.swift",
      "scrollTo": { "symbol": "static let solarized" },
      "guardOn": { "checkpoint": "s08", "answer": "themes" }
    },
    {
      "id": "s10",
      "verb": "narrate",
      "text": "End of tour. Open `HACKABILITY.md` section 'Add a new theme' for the cookbook recipe.",
      "guardOn": { "checkpoint": "s08", "answer": "themes" }
    }
  ]
}
```

Schema notes:

- Stable `id` per step so we can resume / report checkpoint state
  to Claude unambiguously.
- `path` is repo-relative when the script has a `rootHint`,
  absolute otherwise. Player resolves both.
- `scrollTo` accepts `{line}`, `{symbol}`, or `{regex}`. Try-order
  is symbol → regex → line. Failure is non-fatal — player narrates
  "couldn't locate target" and continues.
- `guardOn` lets later steps depend on checkpoint answers; guarded
  steps are skipped when their gate fails.

---

## 3. Player UI — ASCII layout

The player lives as a **docked strip** at the bottom of the active
window (above the status bar, below the source/rendered area). It
collapses to a 28-pt thin bar when idle, expands to ~120 pt when
narrating.

```
+---------------------------------------------------------------------------+
| [tab bar — unchanged]                                                     |
+---------------------------------------------------------------------------+
| [mode bar — unchanged]                                                    |
+----------------+----------------------------------------------------------+
|                |                                                          |
| sidebar        |       source / rendered area (unchanged)                 |
|                |                                                          |
| ...            |       <gutter dot at line 88 marks pinned bookmark>      |
|                |       <callout balloon anchored to line 14>              |
|                |                                                          |
+----------------+----------------------------------------------------------+
| WALKTHROUGH  How syntax highlighting works  ·  step 5 / 10                |
|                                                                           |
| > "Each language ships a vendored highlights.scm.                         |
|   Notice `tsLanguagePointer(for:)` returns tree_sitter_<lang>()."         |
|                                                                           |
|  [<<] [< prev] [ pause ] [next >] [>>]   [skip ▾]   [✕ exit tour]   1:42  |
+---------------------------------------------------------------------------+
| [status bar — unchanged]                                                  |
+---------------------------------------------------------------------------+
```

Transport semantics:

- `<<` jumps to the first step.
- `< prev` walks back one step. Steps are declarative so this just
  re-applies step N−1's state.
- `pause` halts auto-advance (relevant only when a step has a
  `dwellSec` and the player is in auto mode).
- `next >` advances. On a checkpoint step, this is greyed until the
  user chooses an option (or types a free-form answer in the embedded
  reply field that appears in place of the option pills).
- `>>` jumps to the last step.
- `skip ▾` opens a popover with the full step list (a TOC) so the
  user can jump to any step. Doubles as scrubber.
- `exit tour` closes the player, drops the player state, leaves the
  editor wherever the last step left it.

Checkpoint render — the narration area swaps in option pills plus a
text field:

```
| ?  Want to dive into incremental reparse (perf), or jump to themes?      |
|    [ Incremental reparse ]  [ Themes ]                                   |
|    or type your own: [_________________________________________________] |
```

When the user submits a free-form answer (Cmd-Return in the field),
the player serializes `{ stepId, answer, transcript }` and pings the
MCP server. Claude's reply may include patched / appended steps; the
player splices them in and continues.

Callouts in the document area are SwiftUI overlays anchored to
gutter positions, leveraging `sourceScrollState.lineHeight` and
`bookmarkedLines(for:)` math the gutter already does. Same for
`highlightLines` — short-lived line highlights drawn over the
NSTextView, fading after ~1.5 s.

---

## 4. Authoring model

Two first-class authors. The schema is the same for both.

**Claude (primary).** Via MCP. The MCP server (see §5) exposes a
single tool, `walkthrough.publish(script: Walkthrough) -> String`,
that takes a JSON script, validates it, writes it under
`~/Library/Application Support/MarkdownViewer/Walkthroughs/`, and
hands TextView an opaque ID. A second tool,
`walkthrough.start(id: String)`, kicks off playback in the
foremost TextView window. Claude does not need to know window IDs
— "foremost" is good enough for the single-window-at-a-time
workflow. We can add explicit targeting (`windowId`) later if
multi-window scenarios appear.

Claude authoring loop, when the user asks for a walkthrough:

1. Read the relevant files (cheap — already in its toolset).
2. Plan steps (4–20 typical; cap at 50 in the schema validator).
3. Emit JSON, call `walkthrough.publish` then `walkthrough.start`.
4. Hold context until the player reports a checkpoint or exit, then
   continue or splice.

**Humans (secondary).** A walkthrough is just a JSON file. Drop one
into `~/Library/Application Support/MarkdownViewer/Walkthroughs/`
or `<repo>/.textview/walkthroughs/` and TextView picks it up. The
File menu gets a `Walkthroughs ▸` submenu listing every script in
either location, plus `Open Walkthrough File…` for ad-hoc JSON.

For authors who want help, we ship a `walkthrough.schema.json` JSON
Schema in the repo, which any editor (including TextView itself,
once we add LSP-light schema validation for JSON) can lint against.

---

## 5. Transport — how Claude reaches the player

Three options were on the table.

| transport      | latency | bi-di? | new code         | claude-friendly? |
| -------------- | ------- | ------ | ---------------- | ---------------- |
| URL scheme     | low     | no     | tiny (handler)   | yes (one-shot)   |
| Watched dir    | ~250ms  | no     | small (FSEvents) | yes              |
| MCP server     | low     | **yes**| medium (server)  | yes (native)     |

**Recommendation: MCP server, with URL scheme as a fallback / unit
test harness.**

Why MCP wins:

- Bi-directional. Checkpoints have to send `{ stepId, answer }`
  back to Claude mid-tour. URL scheme is one-shot; watched dir is
  async one-way; MCP gives us duplex.
- Native to the user's stated intent ("scripts Claude can send
  using MCP").
- We already have `ClaudeTimelineSection` reading
  `~/.claude/projects/.../*.jsonl`; the MCP server fits the same
  conventions.

Shape of the server:

- A new local process (or thread inside TextView — likely thread,
  to avoid IPC complexity for v1) listens on a Unix domain socket
  at `~/Library/Application Support/MarkdownViewer/mcp.sock`.
- Implements the standard MCP tool-server handshake.
- Tools exposed:
  - `walkthrough.publish(script) -> { id }`
  - `walkthrough.start(id, options?)`
  - `walkthrough.status() -> { activeId, stepIndex, awaitingCheckpoint, checkpointPrompt? }`
  - `walkthrough.reply(stepId, answer)` — for free-form checkpoint
    replies. Returns the next splice or `{done: true}`.
  - `walkthrough.append(id, steps)` — splice steps after the
    current cursor (used by Claude when the user asks an off-script
    question mid-tour).
  - `walkthrough.list()` — discovery for Claude.

For testing, `markdownviewer://walkthrough?id=foo&action=start`
is wired through the existing `handleCustomURLScheme` in
`main.swift` (line 463). This gives us a no-MCP path for headless
tests and for users who want to trigger from a shell:
`open 'markdownviewer://walkthrough?id=highlight-engine-tour'`.

NSServices: a "Send Selection to TextView as Walkthrough" service
is low-value and out of scope for v1. The script-runner CLI flag
already in `main.swift` (line 227, `runScriptStep`) gets one new
verb, `walkthrough-start <id>`, so headless tests can drive the
player without IPC at all.

---

## 6. Step verbs — enumeration

Eight is the floor. Below are the 12 we'd ship in v1. Each lists
required params, optional params, and the existing primitive(s) it
reuses.

| verb            | required               | optional                                | reuses                                         |
| --------------- | ---------------------- | --------------------------------------- | ---------------------------------------------- |
| `narrate`       | `text`                 | `dwellSec`                              | player narration pane only                     |
| `openFile`      | `path`                 | `viewMode`, `scrollTo`, `highlightLines`, `callout`, `pinBookmark` | `model.openPath`, `scrollSource(toLine:)`, gutter |
| `openFolder`    | `path`                 | `select` (relative path)                | `model.openFolder`, sidebar selection          |
| `scroll`        | `to` (`line`/`symbol`/`regex`) | `pulse: bool`                  | `model.scrollSource(toLine:)`                  |
| `find`          | `query`                | `caseSensitive`, `isRegex`, `mode: source\|rendered` | find-bar publishers on `DocumentModel`      |
| `callout`       | `text`                 | `anchor` (`line`/`symbol`), `dismissOn: next\|timer` | new overlay; gutter math from `sourceScrollState` |
| `highlightLines`| `lines: [int]`         | `style: focus\|warn\|info`, `fadeMs`    | new NSTextView overlay                         |
| `pinBookmark`   | `line`                 | `label`, `removeOnExit`                 | `bookmarksStore.toggle(url:displayName:line:)` |
| `setMode`       | `viewMode`             |                                         | `model.toggleViewMode` / new setter            |
| `togglePalette` | `show: bool`           |                                         | `model.showPalette` / `dismissPalette`         |
| `checkpoint`    | `prompt`               | `options`, `allowFreeForm: bool` (default true), `timeoutSec` | new player state + MCP reply       |
| `diagram`       | `kind`, `data`         | `caption`                               | new SwiftUI overlay; see below                 |

Notes:

- `diagram` covers the user's "illustrations" ask. v1 supports
  three kinds: `mermaid` (reuse the rendered-view Mermaid bundle
  in a small overlay WKWebView), `ascii` (monospace text in a
  callout), `image` (PNG/SVG shipped next to the script). No live
  JS beyond Mermaid — keeps supply-chain flat.
- All verbs are idempotent: re-applying to the same starting state
  gives the same result. That's what makes `< prev` cheap.

Out of scope for v1, noted for later: `range` (group steps in the
TOC), `wait` (pause for non-checkpoint user input), `runScript`
(escape hatch into the existing `runScriptStep` dispatcher).

---

## 7. Checkpoints + branching — the state Claude sees

A checkpoint is a step. When the player reaches one, it pauses
auto-advance and waits for the user. The user's reply is either an
`option.id` (if they clicked a pill) or a free-form string.

Both are wrapped into the same payload before being sent back over
MCP:

```json
{
  "schema": "textview.walkthrough.checkpoint/v1",
  "walkthroughId": "highlight-engine-tour",
  "stepId": "s08",
  "answer": {
    "kind": "freeForm",
    "text": "Actually can you show me how themes interact with markdown.css?"
  },
  "cursor": {
    "currentFile": "Sources/ViewerCore/Highlight/SyntaxTheme.swift",
    "currentLine": 47,
    "viewMode": "source",
    "openTabs": [
      "HACKABILITY.md",
      "Sources/ViewerKit/HighlightLanguage.swift",
      "Sources/ViewerCore/Highlight/TreeSitterEngine.swift",
      "Sources/ViewerCore/Highlight/CaptureMap.swift",
      "Sources/ViewerCore/Highlight/SyntaxTheme.swift"
    ],
    "pinnedBookmarks": [
      { "file": "Sources/ViewerCore/Highlight/TreeSitterEngine.swift", "line": 88, "label": "lang ptr switch" }
    ],
    "checkpointTranscript": [
      { "stepId": "s08", "answer": { "kind": "option", "id": "themes" } }
    ]
  }
}
```

Claude's reply is one of three shapes:

1. `{ append: [...] }` — splice after the current cursor and resume.
2. `{ replaceFrom: "s09", steps: [...] }` — replace from `s09` on.
3. `{ done: true, closingNarration: "..." }` — wrap up.

Branching is therefore server-side: scripts never need an `if`
construct. The static `guardOn` field on step is just the inert
form ("skip if answer wasn't X") for single-shot scripts that
want to branch without a roundtrip. Anything richer is a
checkpoint. The cost is one MCP roundtrip per branch point —
fine, since checkpoints are user-paced.

---

## 8. Resumption + persistence

Walkthroughs persist at three tiers, mirroring `STATE.md` §3:

- **Script storage** (durable). JSON files under
  `~/Library/Application Support/MarkdownViewer/Walkthroughs/<id>.json`,
  plus `<repo>/.textview/walkthroughs/<id>.json` for repo-bound
  tours that ship with a project (consider this the analog of
  `.vscode/launch.json`).
- **Active session state** (workspace-tier). The `WorkspaceSnapshot`
  in `STATE.md` gains:
  ```swift
  let activeWalkthrough: ActiveWalkthrough?
  struct ActiveWalkthrough: Codable {
      let id: String
      let stepIndex: Int
      let checkpointAnswers: [String: CheckpointAnswer]  // stepId → answer
      let pinnedBookmarkIDs: [UUID]  // so we can remove on exit
      let startedAt: Date
  }
  ```
  Auto-saved with the rest of the workspace on the 500ms debounce.
  Result: quit mid-walkthrough, relaunch, the player reappears at
  the same step with the same answers.
- **Completion log** (durable but disposable). Append-only JSONL at
  `~/Library/Application Support/MarkdownViewer/walkthrough-log.jsonl`
  with `{ id, startedAt, endedAt, stepsCompleted, exitedAt }`. Lets
  Claude answer "have I shown the user this before?" without
  guessing. Capped at 1000 entries with FIFO trim.

Resume rules:

- If the active workspace had a walkthrough in flight and the
  script file is still present, restore it. If the file is gone
  (deleted, repo moved), drop the active state silently and log a
  one-liner to the workspace's restore-warnings.
- If a pinned bookmark was added by the walkthrough and the user
  has since promoted it (renamed the label, edited), keep it on
  exit instead of removing. Heuristic: any mutation to the
  bookmark after creation upgrades it from "tour-pinned" to "user-
  owned".

---

## 9. Reuse existing primitives

The brief explicitly calls these out. Mapping:

| primitive                                 | walkthrough use                                                     |
| ----------------------------------------- | ------------------------------------------------------------------- |
| `bookmarksStore.toggle(url:line:)`        | `pinBookmark` verb — including the line-bookmark variant            |
| `bookmarkedLines(for:)` + gutter dots     | gutter dots double as walkthrough waypoints; no new gutter code     |
| `model.scrollSource(toLine:)`             | `scroll`, and the `scrollTo.line` field on `openFile`               |
| `sourceScrollState.lineHeight` math       | callout anchoring math — already used by the gutter                 |
| find-bar publishers (`renderedFind*`, `sourceFind*`) | the `find` verb writes to these directly                |
| `model.toggleViewMode` / mode picker      | `setMode` verb                                                      |
| palette show/dismiss                      | `togglePalette` verb                                                |
| `runScriptStep` in `main.swift`           | the `runScript` escape hatch verb — lets a walkthrough piggyback on every script-runner command we already support |
| `ClaudeTimelineSection`                   | mirror its disclosure-row UX for the walkthrough TOC popover        |
| `markdownviewer://` URL scheme            | `walkthrough?id=...&action=start` for headless / CLI triggers       |
| `WorkspaceSnapshot` (STATE.md)            | gains `activeWalkthrough` field for resume                          |

The implementation principle: a walkthrough verb is a thin
adapter over an existing `DocumentModel` method. New code paths
are forbidden where an existing one works. Three new things are
genuinely new: the player UI strip, the callout overlay, and the
MCP server. Everything else is reuse.

---

## 10. Implementation phases

Five phases. Each has a strict "done when" so we don't ship a
half-built feature.

### Phase 1 — Schema + JSON loader + headless runner

Define `Walkthrough` and `Step` Codable types under
`Sources/ViewerCore/Walkthrough/`. Wire a new script-runner verb
`walkthrough-run <path-to-json>` into `runScriptStep` in
`main.swift`. No UI yet; the runner just applies each step in
sequence, sleeps for `dwellSec`, captures a snapshot, and exits.

**Done when:** `swift run mdv --script <file-with-walkthrough-run>`
plays a 5-step walkthrough end-to-end and produces a deterministic
snapshot per step.

### Phase 2 — Player UI + transport (single-window, no MCP)

Build the docked strip and the callout/highlight overlays. Wire
prev/pause/next/skip via SwiftUI `@State`. Discover scripts in
`~/Library/Application Support/MarkdownViewer/Walkthroughs/` and
`<repo>/.textview/walkthroughs/`, expose them in `File ▸ Walkthroughs`.

**Done when:** a hand-written JSON script in either location appears
in the menu, plays interactively with the transport, and exits
cleanly. Checkpoints render but use only the static `options`
branch (free-form is disabled).

### Phase 3 — MCP server + dynamic branching

Add the local MCP server (Unix-domain socket). Implement the five
tools in §5. Wire checkpoint replies to round-trip through MCP,
splice replies into the active script, persist the splice into the
workspace state.

**Done when:** Claude can publish + start a walkthrough, the user
can answer a checkpoint, Claude can splice in new steps, and a
crash mid-splice leaves the workspace re-launchable to the same
cursor.

### Phase 4 — Resume + completion log + bookmark promotion

Wire `WorkspaceSnapshot.activeWalkthrough`. Implement the
completion log JSONL with FIFO trim. Implement the bookmark-
promotion heuristic from §8.

**Done when:** quit-and-relaunch mid-walkthrough lands the user
exactly where they were; the log file accumulates one record per
run; bookmarks pinned by a walkthrough survive (or don't) per the
heuristic.

### Phase 5 — Diagrams + polish + authoring schema

Implement the `diagram` verb (Mermaid via existing renderer,
ASCII, static image). Ship `walkthrough.schema.json` in the repo.
Visual-regression tests under `Tests/ViewerUITests/`.

**Done when:** all three diagram kinds render in a sample
walkthrough; the schema lints a hand-broken file with a useful
error; `scripts/visual-smoke.sh` includes a walkthrough scenario.

---

## 11. Risks

1. **Scripts go stale.** A walkthrough referencing `scrollTo:
   {symbol: "tsLanguagePointer(for:)"}` breaks when someone renames
   the function. Mitigation: every resolution failure is non-fatal,
   the player narrates it ("couldn't find symbol — skipping"), and
   the completion log records resolution-failure counts so authors
   can see decay.
2. **MCP server lifecycle.** A local server inside an editor process
   means port-conflict-on-second-instance unless we use a UDS with
   `SO_REUSEADDR`-equivalent semantics. Mitigation: UDS path includes
   the bundle ID; second instance falls back to URL scheme.
3. **Free-form checkpoint replies leak intent to Claude.** That's
   the whole point, but it's worth documenting. The player UI
   should make it visually obvious when text is round-tripping to
   Claude (e.g. a Claude-orange tint on the checkpoint area).
4. **Walkthroughs as attack surface.** A malicious JSON script could
   try to open files outside the repo. Mitigation: when a script
   has a `rootHint`, the loader resolves every `path` *within* that
   root and rejects anything that escapes via `..`. Scripts without
   a `rootHint` can open anything (intentional; user owns the file).
5. **Auto-pinned bookmark pollution.** Walkthroughs adding 10
   bookmarks each, never cleaning up, would clobber the user's
   bookmark list. Mitigation: walkthrough-pinned bookmarks live in
   a sub-namespace (display name prefixed with `[tour] `) and are
   removed on exit unless promoted.
6. **The user "wins" the race against the player.** If the user
   manually opens another file mid-step, the next-step apply could
   stomp their context. Mitigation: a pause auto-trigger — any user
   action that mutates `currentURL`/`viewMode` while a walkthrough
   is active pauses the player and surfaces a "Resume tour?" pill.
7. **Concurrent walkthroughs.** Two scripts at once would be chaos.
   Mitigation: hard cap at one active walkthrough per window;
   `walkthrough.start` while one is active prompts the user to end
   or queue (default: end the current one).

---

## 12. What I need from you

Five decisions before code starts:

1. **MCP server in-process vs separate process?** In-process (a
   thread + UDS) is simpler and what this doc assumes. Separate
   process is cleaner for crashes but adds an XPC dance. My vote:
   in-process for v1, revisit if we hit GC/UI hitches.
2. **Repo-bound scripts at `<repo>/.textview/walkthroughs/` — yes
   or no?** Pulling these in means TextView starts respecting a
   per-repo config dir, which is a precedent. Worth it for
   onboarding ("clone this repo, get a tour") but is a footprint
   decision.
3. **Default checkpoint behavior — auto-pause or auto-advance with
   a timeout?** I've assumed auto-pause (no timeout). The user
   asked for "ask Claude question in between," which suggests
   pause-by-default, but a `timeoutSec` option lets authors build
   guided demos. Confirm.
4. **Diagrams scope for v1 — Mermaid + ASCII + static image, or
   just ASCII?** Mermaid means reusing the renderer's JS pipeline,
   which is more work but matches "explain diagrams." ASCII alone
   is a 1-day feature.
5. **Workspace state already has migration concerns (STATE.md §11
   open questions). Adding `activeWalkthrough` bumps schema
   version — comfortable doing that now, or hold the walkthrough
   feature until workspace v1 ships first?**

Anything else (player position — bottom strip vs side panel,
keyboard shortcuts, naming) I'll pick a default and move on
unless flagged.
