# WALKTHROUGH_DESIGN_v2.md — guided-tour engine, v2 design

Status: design only. No code yet. Companion / successor to
`docs/WALKTHROUGH.md` (v1 thinking, kept for context). This document
is the implementer's blueprint: someone landing in the codebase fresh
should be able to build the v1 surface from this doc alone.

Scope of v2 vs v1:

- v1 was MCP-first, single-window, docked-bottom strip, no multi-pane targeting.
- v2 is **transport-agnostic** at the engine boundary (drop-file watcher first, MCP later), **multi-target** at the UI boundary (a step's effects can land in the main pane, the split pane, the file tree, the git panel, the sidebar — not just the active text view), and **top-of-window** controller strip + **per-target overlays** for callouts/highlights.
- The mockup (`aide-walkthrough.jsx` + `aide-walkthrough-data.js`) sets the verb/step shape we mirror: each step is `narration` + a list of `actions`. We keep that shape; we expand the verb set; we add checkpoints + schema versioning.

---

## 1. Goals + non-goals

**Goals.**

- Claude (or any external agent) hands TextView a JSON document; TextView plays it.
- Steps drive concrete editor surfaces: file tree, main editor, split pane, git panel, sidebar sections, callout balloons, popovers.
- The user has transport control: prev / next / pause / restart / jump.
- A step can be a **checkpoint** that pauses for a user reply, which (when a bidirectional transport is configured) round-trips back to the agent.
- Engine is pure logic in `ViewerCore`. No SwiftUI in the engine. UI is a thin SwiftUI layer in `ViewerUI` driven via the existing **request-nonce** pattern on `DocumentModel`.
- Zero new external dependencies for v1. `Codable` + `FileManager` only.

**Non-goals (v1).**

- No multi-window driving. "Foremost window" is the only target. (Multi-window targeting is a v2.5 addition.)
- No screen recording / mouse macros — declarative verbs only.
- No DSL, no YAML. Plain JSON.
- No live diagram bundle in v1. ASCII callouts only; Mermaid + image come later (mirrors v1 §10 phase-5).
- No plugin verbs. The verb set is closed and shipped.

---

## 2. Data model

All types live in `ViewerCore/Walkthrough/` (pure types — `import Foundation` only). They are `Codable` and `Sendable` so the engine can hand them across actor boundaries cleanly.

### 2.1 Top-level script

```swift
// Sources/ViewerCore/Walkthrough/WalkthroughScript.swift

public struct WalkthroughScript: Codable, Sendable, Equatable {
    /// Schema discriminator. Reject loads where this doesn't match the
    /// known set. Allows additive evolution: v1 readers ignore v2 fields
    /// only if v2 is declared `compatibleWith: ["v1"]`.
    public let schema: SchemaVersion

    /// Stable identifier. Used for resume, completion log, and to target
    /// `walkthrough.append` / `walkthrough.replaceFrom` calls.
    public let id: String

    public let title: String
    public let subtitle: String?

    /// Free-text. Convention: `claude:opus-4.7`, `human:jos`, etc.
    public let author: String?

    public let createdAt: Date?
    public let estimatedDurationSec: Int?

    /// Absolute path that all relative `path` fields on steps resolve
    /// against. If nil, every step path must be absolute. The loader
    /// rejects steps whose resolved path escapes `rootHint` via `..`.
    public let rootHint: String?

    /// Optional default targets for verbs that omit their `target`.
    /// E.g. `defaultTargets.editor = .split` makes every `openFile` open
    /// in the split pane unless the step overrides.
    public let defaultTargets: DefaultTargets?

    public let steps: [Step]

    public enum SchemaVersion: String, Codable, Sendable {
        case v1 = "textview.walkthrough/v1"
    }
}

public struct DefaultTargets: Codable, Sendable, Equatable {
    public var editor: EditorTarget?    // .main | .split
    public var popover: PopoverTarget?  // .anchorToEditor | .anchorToSidebar | .floating
}
```

### 2.2 Step

A step is **narration + actions**. We mirror the mockup: narration is the human-facing text the player shows in its strip; actions are the imperatives the engine applies to the UI. Most steps have exactly one action (most common case in the mockup is `highlight` + `callout`, which we model as **two actions**, not a fused step type).

```swift
// Sources/ViewerCore/Walkthrough/Step.swift

public struct Step: Codable, Sendable, Equatable, Identifiable {
    public let id: String                 // stable within a script
    public let narration: String?         // shown in the player strip
    public let speakerLabel: String?      // default "claude"; overridable per step
    public let dwellSec: Double?          // auto-advance hint; player may ignore
    public let actions: [Action]
    public let guardOn: GuardClause?      // skip if a prior checkpoint answer mismatches
}

/// Skip-if logic that runs without round-tripping to the agent.
/// Useful for one-shot scripts that want a simple branch.
public struct GuardClause: Codable, Sendable, Equatable {
    public let checkpointId: String       // refers to a prior `checkpoint` step's id
    public let answerEquals: String       // matches option.id or trimmed free-form text
}
```

### 2.3 Action (verb variants)

A tagged-union encoded as `{"kind": "openFile", ...}`. Each variant has its own params plus an optional `target` field that says **where** in the UI it lands. Targets are listed in §3.

```swift
// Sources/ViewerCore/Walkthrough/Action.swift

public enum Action: Codable, Sendable, Equatable {
    case openFile(OpenFile)
    case revealLine(RevealLine)
    case highlightRange(HighlightRange)
    case showPopover(ShowPopover)
    case setView(SetView)
    case splitFile(SplitFile)
    case runDiff(RunDiff)
    case awaitUser(AwaitUser)
    case addBookmark(AddBookmark)
    case revealInSidebar(RevealInSidebar)
    case openGitPanel(OpenGitPanel)
    case narrateOnly(NarrateOnly)         // no UI mutation; player strip only

    // Codable: discriminator `kind`. See §2.5.
}

public struct OpenFile: Codable, Sendable, Equatable {
    public let path: String               // absolute or relative to rootHint
    public let target: EditorTarget?      // .main (default) | .split
    public let viewMode: ViewMode?        // .source | .rendered | .hex | ...
    public let scrollTo: ScrollTarget?    // line | symbol | regex
    public let select: TextRange?         // optional selection to apply after open
}

public struct RevealLine: Codable, Sendable, Equatable {
    public let target: EditorTarget?      // .main | .split
    public let line: Int                  // 1-indexed
    public let column: Int?               // 1-indexed; default 1
    public let pulse: Bool?               // brief flash when arriving
}

public struct HighlightRange: Codable, Sendable, Equatable {
    public let target: EditorTarget?
    public let lines: [Int]               // 1-indexed line numbers
    public let style: HighlightStyle?     // .focus | .warn | .info | .agent
    public let fadeMs: Int?               // default 1500; 0 = persistent until next step
    public let label: String?             // optional inline label (rendered in gutter)
}

public struct ShowPopover: Codable, Sendable, Equatable {
    public let text: String               // plain text or limited inline markdown
    public let anchor: PopoverAnchor      // see §3
    public let dismissOn: DismissTrigger? // .nextStep (default) | .timer(ms) | .userClick
    public let actionable: ActionablePill?// optional CTA pill in the popover
    public let style: PopoverStyle?       // .agent | .info | .warn
}

public struct ActionablePill: Codable, Sendable, Equatable {
    public let label: String
    public let actionId: String           // engine reports {pillClicked: actionId} back to caller
}

public struct SetView: Codable, Sendable, Equatable {
    public let target: EditorTarget?
    public let viewMode: ViewMode         // .source | .rendered | .hex | .csv | .pdf | ...
}

public struct SplitFile: Codable, Sendable, Equatable {
    public let path: String
    public let viewMode: ViewMode?
    public let scrollTo: ScrollTarget?
    /// If false, an existing split is left as-is when the script ends.
    /// If true (default), split is closed at walkthrough exit.
    public let closeOnExit: Bool?
}

public struct RunDiff: Codable, Sendable, Equatable {
    /// Either a git ref pair OR an inline two-paths pair.
    public let mode: Mode
    public let target: EditorTarget?      // typically .split
    public enum Mode: Codable, Sendable, Equatable {
        case gitRefs(base: String, head: String, path: String)
        case workingTreeVs(ref: String, path: String)
        case files(left: String, right: String)
    }
}

public struct AwaitUser: Codable, Sendable, Equatable {
    public let prompt: String
    public let options: [Option]?         // pill buttons; nil → free-form only
    public let allowFreeForm: Bool?       // default true
    public let timeoutSec: Double?        // nil → infinite (default)
    public let reportCursorContext: Bool? // default true; includes open files etc.

    public struct Option: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
    }
}

public struct AddBookmark: Codable, Sendable, Equatable {
    public let path: String
    public let line: Int?
    public let label: String?
    /// Marks the bookmark as walkthrough-pinned. Removed on exit unless
    /// the user promotes it (renames, edits). Default true.
    public let ephemeral: Bool?
}

public struct RevealInSidebar: Codable, Sendable, Equatable {
    public let section: SidebarSection    // .fileTree | .bookmarks | .search | .git
    public let select: String?            // path / id within the section
    public let expand: Bool?              // expand to reveal `select`
}

public struct OpenGitPanel: Codable, Sendable, Equatable {
    public let tab: GitPanelTab           // .status | .log | .diff
    public let path: String?              // restrict scope when applicable
    public let ref: String?               // for .log / .diff
}

public struct NarrateOnly: Codable, Sendable, Equatable {
    // Empty — narration on the Step itself carries the payload.
    public init() {}
}
```

### 2.4 Supporting enums + small types

```swift
public enum EditorTarget: String, Codable, Sendable {
    case main, split
}

public enum SidebarSection: String, Codable, Sendable {
    case fileTree, bookmarks, search, git, claudeTimeline
}

public enum GitPanelTab: String, Codable, Sendable {
    case status, log, diff
}

public enum ViewMode: String, Codable, Sendable {
    case source, rendered, hex, csv, pdf, image, sqlite
}

public enum HighlightStyle: String, Codable, Sendable {
    case focus, warn, info, agent
}

public enum PopoverStyle: String, Codable, Sendable {
    case agent, info, warn
}

public enum DismissTrigger: Codable, Sendable, Equatable {
    case nextStep
    case timer(ms: Int)
    case userClick
}

public enum ScrollTarget: Codable, Sendable, Equatable {
    case line(Int)                        // 1-indexed
    case symbol(String)                   // best-effort
    case regex(String)                    // first match
}

public struct TextRange: Codable, Sendable, Equatable {
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
}

/// Where a popover anchors. Anchor enums are exhaustive so the engine
/// emits a typed request and the UI layer routes without parsing.
public enum PopoverAnchor: Codable, Sendable, Equatable {
    case editorLine(target: EditorTarget, line: Int)
    case editorSymbol(target: EditorTarget, symbol: String)
    case sidebarRow(section: SidebarSection, rowId: String)
    case gitPanel(tab: GitPanelTab, rowId: String?)
    case windowChrome(WindowChromeAnchor)  // .topRight, .topLeft, .bottomCenter
    case floating                           // free-floating, centered on window
}

public enum WindowChromeAnchor: String, Codable, Sendable {
    case topRight, topLeft, bottomCenter
}
```

### 2.5 Codable wire format

The verb union encodes with a `kind` discriminator and the variant's fields hoisted onto the same object. JSON example:

```json
{
  "schema": "textview.walkthrough/v1",
  "id": "hex-viewer-tour",
  "title": "How the hex viewer renders binary files",
  "subtitle": "Tree-sitter routing, memoized rows",
  "author": "claude:opus-4.7",
  "createdAt": "2026-05-17T14:00:00Z",
  "estimatedDurationSec": 95,
  "rootHint": "/Users/me/Documents/workspaces/claude/markdown_viewer",
  "defaultTargets": { "editor": "main" },
  "steps": [
    {
      "id": "s1",
      "narration": "The viewer pivots on one switch — Viewer.tsx picks the renderer by file kind. Binary files now route to HexView.",
      "actions": [
        { "kind": "openFile", "path": "src/components/Viewer.tsx", "scrollTo": { "type": "line", "value": 72 } },
        { "kind": "highlightRange", "lines": [72, 73], "style": "focus" },
        { "kind": "showPopover",
          "text": "New `data-grouping` and `data-sticky-addr` props get threaded through here.",
          "anchor": { "type": "editorLine", "target": "main", "line": 73 },
          "style": "agent" }
      ]
    },
    {
      "id": "s4",
      "narration": "Want to dive into the perf path, or jump to themes?",
      "actions": [
        { "kind": "awaitUser",
          "prompt": "Where to next?",
          "options": [
            { "id": "perf",   "label": "Incremental reparse" },
            { "id": "themes", "label": "Themes" }
          ],
          "allowFreeForm": true }
      ]
    }
  ]
}
```

Implementation note on the `kind` decoder:

```swift
extension Action: Codable {
    enum CodingKeys: String, CodingKey { case kind }
    enum Kind: String, Codable {
        case openFile, revealLine, highlightRange, showPopover, setView,
             splitFile, runDiff, awaitUser, addBookmark, revealInSidebar,
             openGitPanel, narrateOnly
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let single = try d.singleValueContainer()
        switch kind {
        case .openFile:        self = .openFile(try single.decode(OpenFile.self))
        case .revealLine:      self = .revealLine(try single.decode(RevealLine.self))
        // ...etc
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        switch self {
        case .openFile(let v):  try c.encode(Kind.openFile, forKey: .kind);
                                try v.encode(to: e)   // hoist fields
        // ...etc
        }
    }
}
```

Each variant struct ignores the `kind` field on decode (extra keys are tolerated by `Codable` by default). Encode hoists. Same trick for `ScrollTarget` / `DismissTrigger` / `PopoverAnchor` / `RunDiff.Mode` — they each get a small `{ "type": ..., ... }` discriminator.

### 2.6 Schema versioning policy

- The `schema` field is the **only** discriminator. Never sniff field presence to detect version.
- Loader matches against `SchemaVersion.self.allCases`. Unknown version → fail with a clear error (`UnsupportedSchemaError(version: String, supported: [String])`). No silent best-effort load.
- Additive evolution: v2 may add **new optional fields** to v1 types without bumping; readers ignore unknown keys.
- Breaking change → bump to `v2`. A `Migrator` step (pure, in `ViewerCore/Walkthrough/Migration/`) translates v1 scripts to v2 at load time. Original on-disk JSON is never rewritten by the loader.

---

## 3. Capability model — verbs × targets

Each verb is a parameterized message. Targets are **where** the verb lands; they decouple the engine from "the main pane" being a privileged surface. This is what makes the system multi-pane-friendly.

| verb              | params                                                                          | targets it can address                              | reuses (existing primitive)                            |
| ----------------- | ------------------------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------ |
| `openFile`        | `path, target?, viewMode?, scrollTo?, select?`                                  | `.main`, `.split`                                   | `DocumentModel.openPath`, split-pane router            |
| `revealLine`      | `target?, line, column?, pulse?`                                                | `.main`, `.split`                                   | `sourceScrollLineTarget` + nonce                       |
| `highlightRange`  | `target?, lines[], style?, fadeMs?, label?`                                     | `.main`, `.split`                                   | new line-overlay layer (see §6)                        |
| `showPopover`     | `text, anchor, dismissOn?, actionable?, style?`                                 | any anchor — editor lines, sidebar rows, git panel rows, window chrome, floating | new SwiftUI popover; anchor math reuses gutter line-height + sidebar row frames |
| `setView`         | `target?, viewMode`                                                             | `.main`, `.split`                                   | `DocumentModel.toggleViewMode` / setter                |
| `splitFile`       | `path, viewMode?, scrollTo?, closeOnExit?`                                      | implicit `.split`                                   | `DocumentModel.splitURL` setter                        |
| `runDiff`         | `mode, target?`                                                                 | typically `.split`; also git panel `.diff` tab      | `ViewerCore/Git/*`, `showGitLog`                       |
| `awaitUser`       | `prompt, options?, allowFreeForm?, timeoutSec?, reportCursorContext?`           | walkthrough player strip (no editor mutation)       | engine state machine; transport callback               |
| `addBookmark`     | `path, line?, label?, ephemeral?`                                               | sidebar bookmarks section + gutter dots             | `BookmarksStore.toggle(url:line:displayName:)`         |
| `revealInSidebar` | `section, select?, expand?`                                                     | sidebar sections                                    | `SidebarModel` selection/expand setters                |
| `openGitPanel`    | `tab, path?, ref?`                                                              | git panel                                           | `gitPanelFocusRequest` nonce + `gitPanelDesiredTab`    |
| `narrateOnly`     | —                                                                               | player strip                                        | none                                                   |

Targeting rules:

- A verb's `target` is **optional** when the verb has a sensible default. `openFile` defaults to `.main` unless the script's `defaultTargets.editor` overrides.
- The player rejects (with a non-fatal narrated warning) any verb whose target isn't applicable — e.g. `revealLine target: .split` when no split is open. It logs the skip to the completion record; it does not abort the walkthrough.
- The set of targets is **closed**. New target kinds require an engine + UI change in tandem, not a JSON-side opt-in.

---

## 4. Transport

The engine boundary is transport-agnostic. The same `WalkthroughEngine.run(script: WalkthroughScript)` entrypoint is reachable from a file watcher, a URL scheme handler, an in-process MCP server, an XPC service, or a unit test.

### 4.1 Phase 1 — file-watcher transport (ships in v1)

The simplest transport that lets Claude drive TextView without IPC: drop a JSON file into a watched directory; TextView picks it up. Same shape as `~/.claude/projects/.../*.jsonl` consumption in `ClaudeTimelineSection`.

Watched locations, in priority order:

1. `~/Library/Application Support/MarkdownViewer/Walkthroughs/inbox/` — global drop-zone.
2. `<frontmost-repo>/.textview/walkthroughs/inbox/` — repo-scoped drop-zone (resolved from the frontmost window's working directory).

Filename convention: `<id>.walkthrough.json`. A `.walkthrough.json.tmp` extension is ignored to let writers do atomic rename. Files with no `.walkthrough.json` suffix are ignored.

Detection mechanism: `DispatchSource.makeFileSystemObjectSource` per watched directory. Throttled coalescer (500 ms) so a burst of writes counts as one event. On a hit:

1. Loader parses + validates.
2. On success, the file is **moved** (not copied) to `<dir>/../accepted/<id>.<timestamp>.json` so the inbox doesn't accumulate.
3. On failure, moved to `<dir>/../rejected/<id>.<timestamp>.json` with a sibling `<id>.<timestamp>.error.txt` describing why.
4. The script is handed to the engine: `engine.run(script: parsed, transport: .fileDrop)`.

Why move-not-delete: lets Claude (or the user) inspect what was actually parsed. Move is atomic on APFS; copy + delete is not.

Bidirectional channel for checkpoints (v1, file-based):

- When a step is an `awaitUser`, the engine writes a `<id>.checkpoint.json` to `<dir>/../checkpoints/` (same parent as `inbox`). Schema: `{ "walkthroughId", "stepId", "prompt", "options", "cursor", "writtenAt" }`.
- The user-facing UI also accepts a reply directly (pill click or free-form text) — that reply is **always** persisted to `<dir>/../checkpoints/<id>.<stepId>.reply.json` regardless of whether anyone is listening, so an agent polling the directory sees it.
- If the agent wants to splice steps in, it writes `<id>.append.json` (a step list, with optional `replaceFromStepId` field) into `<dir>/../inbox/`. The engine treats append/replace as a script mutation.

### 4.2 Phase 2 — MCP server (added later, runtime unchanged)

A local MCP server (in-process thread + Unix-domain socket, as v1 §5 described) exposes the same operations as RPC tools. The engine signature does not change: the MCP tool handlers call `engine.run(...)`, `engine.appendSteps(...)`, etc.

Tools:

- `walkthrough.publish(script) -> { id }`
- `walkthrough.start(id)`
- `walkthrough.status() -> EngineStatus`
- `walkthrough.appendSteps(id, steps, replaceFrom?)`
- `walkthrough.reply(walkthroughId, stepId, answer)` — for free-form replies, complement to the file-drop reply path.
- `walkthrough.list()`

The MCP transport is **additive**. The file-drop transport remains as the headless / test path.

### 4.3 Transport abstraction inside the engine

```swift
// Sources/ViewerCore/Walkthrough/WalkthroughTransport.swift

public enum WalkthroughTransport: String, Codable, Sendable {
    case fileDrop
    case mcp
    case urlScheme
    case test
}

/// Sink the engine writes to when it needs to report a checkpoint, a
/// step skip, an exit, or a free-form reply.
public protocol WalkthroughReporter: AnyObject, Sendable {
    func report(_ event: WalkthroughEvent)
}

public enum WalkthroughEvent: Sendable {
    case started(scriptId: String)
    case stepEntered(scriptId: String, stepIndex: Int, stepId: String)
    case stepSkipped(scriptId: String, stepId: String, reason: SkipReason)
    case checkpointReached(scriptId: String, stepId: String, prompt: String)
    case checkpointAnswered(scriptId: String, stepId: String, answer: CheckpointAnswer)
    case pillClicked(scriptId: String, stepId: String, actionId: String)
    case exited(scriptId: String, reason: ExitReason, stepIndex: Int)
    case error(scriptId: String, stepId: String?, message: String)
}
```

The file-drop transport implements `WalkthroughReporter` by serializing events to disk; the MCP transport implements it by pushing JSON-RPC notifications. Neither knows about the other.

---

## 5. State machine

A handful of states. The engine is the source of truth; SwiftUI observes via `@Published` properties on a published facade.

```
                            ┌──────────┐
                  load OK   │  idle    │
                  ─────────▶│          │◀──── exit / done
                            └────┬─────┘
                                 │ run(script)
                                 ▼
                            ┌──────────┐
                  ┌────────▶│ playing  │──────┐
                  │         └────┬─────┘      │
                pause           next/auto    error / fatal
                  │              ▼             │
                  │         ┌──────────┐       │
                  └─────────┤ paused   │       │
                            └────┬─────┘       │
                                 │ next        │
                                 ▼             │
                            ┌──────────┐       │
              awaitUser ───▶│awaiting- │       │
                            │  user    │       │
                            └────┬─────┘       │
                                 │ reply       │
                                 ▼             │
                            ┌──────────┐       │
                            │  done    │◀──────┘
                            └──────────┘
```

Transitions:

| from           | event                          | to             | side-effects                                              |
| -------------- | ------------------------------ | -------------- | --------------------------------------------------------- |
| `idle`         | `run(script)`                  | `playing`      | reporter `.started`, apply step 0                         |
| `playing`      | `next` (auto or user)          | `playing`      | apply step n+1; `.stepEntered`                            |
| `playing`      | `next` and current is checkpoint | `awaitingUser` | `.checkpointReached`                                     |
| `playing`      | `pause`                        | `paused`       | clear auto-advance timer                                  |
| `paused`       | `play`                         | `playing`      | re-arm timer if current step has `dwellSec`               |
| `awaitingUser` | `reply(answer)`                | `playing`      | `.checkpointAnswered`; advance                            |
| `awaitingUser` | `timeout`                      | `paused`       | `.error("checkpoint timeout")` — no auto-skip; user must resume |
| any            | `appendSteps(replaceFrom?)`    | unchanged      | mutate script in place; re-validate; re-anchor cursor     |
| any            | `prev` / `jumpTo(i)`           | `playing`      | re-apply target step idempotently                         |
| any            | `exit`                         | `done`         | `.exited`; cleanup ephemeral bookmarks etc.               |
| any            | fatal (load/resolve)           | `done`         | `.error`; engine drops state                              |

Invariants:

- Steps are **idempotent in their effect**: re-applying step N from any prior state lands on the same observable state. That's what makes `prev` and `jumpTo` cheap and correct. (Authors must respect this; the verb set is chosen so it's naturally true.)
- The engine never auto-advances past a checkpoint. Auto-advance is a per-step affordance (`dwellSec`) and is disabled outright when `awaitingUser`.
- `appendSteps` is the **only** way the script mutates. The original JSON file is never rewritten.

Engine API surface:

```swift
// Sources/ViewerCore/Walkthrough/WalkthroughEngine.swift

@MainActor
public final class WalkthroughEngine: ObservableObject {

    // observable state
    @Published public private(set) var state: EngineState = .idle
    @Published public private(set) var script: WalkthroughScript? = nil
    @Published public private(set) var stepIndex: Int = 0

    /// Verb application is delegated. The UI module supplies the player.
    public init(player: WalkthroughPlayer, reporter: WalkthroughReporter)

    public func run(script: WalkthroughScript) throws
    public func play()
    public func pause()
    public func next()
    public func prev()
    public func jumpTo(stepIndex: Int)
    public func restart()
    public func exit(reason: ExitReason = .userExit)

    public func reply(stepId: String, answer: CheckpointAnswer)
    public func appendSteps(_ steps: [Step], replaceFromStepId: String?)
}

public enum EngineState: Equatable, Sendable {
    case idle
    case playing
    case paused
    case awaitingUser(stepId: String, prompt: String, options: [AwaitUser.Option])
    case done(ExitReason)
}
```

`WalkthroughPlayer` is a protocol that the UI implements — it's how the engine reaches the editor surface without importing SwiftUI:

```swift
// Sources/ViewerCore/Walkthrough/WalkthroughPlayer.swift

@MainActor
public protocol WalkthroughPlayer: AnyObject {
    func apply(_ action: Action) async throws
    /// Called when the engine wants to clear transient effects (highlights,
    /// floating popovers) before applying the next step's actions.
    func clearTransientEffects()
    /// Called on exit. Walkthrough-pinned bookmarks etc. cleaned here.
    func cleanupEphemera(_ pins: [EphemeralPin])
}
```

The engine calls `player.apply(action)` for each action of the current step in order. `apply` is `async throws` so a missing file or unresolved symbol can be surfaced as a non-fatal `.stepSkipped(reason:)` event.

---

## 6. UI placement

### 6.1 Top-of-window controller strip (always present when active)

A 36-pt strip at the top of the active window, **above** the tab bar (the mockup docks it at the bottom of the right pane; we go top-of-window because targets are not just the right pane). Layout:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● Walkthrough  "How the hex viewer renders binary files" · step 3/12         │
│   [⏮] [◀] [⏸] [▶] [⏭]   ━━━●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━   [TOC ▾] │
│   ─────────────────────────────────────────────────────────────────────────  │
│   claude: "Inside the component the row builder is memoized. tomas caught … │
└──────────────────────────────────────────────────────────────────────────────┘
| [tab bar — unchanged]                                                         |
| [mode bar — unchanged]                                                        |
| sidebar │ main editor │ split editor (when open)                              |
| [status bar — unchanged]                                                      |
```

Strip contents (left → right):

- **Pill** with title, author, current/total step indicator. Click → TOC popover.
- **Transport** — `⏮` first, `◀` prev, `⏸/▶` play/pause, `▶` next, `⏭` last. Keyboard: `⌘[` `⌘]` `Space` `Esc`.
- **Scrubber** — clickable segmented bar, one segment per step. Hover shows tooltip with first 50 chars of narration (mirrors `wt-scrub` in the mockup).
- **TOC ▾** — popover with the full step list, jump-to-step (mirrors `wt-steps` in the mockup).
- **Narration row** — current step's `narration`, prefixed with `speakerLabel` (default "claude").

When state is `awaitingUser`, the narration row swaps in:

```
?  Where to next?
   [ Incremental reparse ]  [ Themes ]
   or type your own: [_____________________________________________]  [Send]
```

When state is `paused` with a `dwellSec`, the play button pulses subtly. When the engine emits a `stepSkipped`, the narration row shows a small grey "skipped step X (couldn't locate symbol Y)" indicator that fades after 3 s.

### 6.2 Per-target overlays

A walkthrough step can target any of the surfaces below; the UI module owns a small overlay sublayer per surface so the engine doesn't need to know SwiftUI z-ordering:

| target surface                | overlay layer                                          | what it can render                                |
| ----------------------------- | ------------------------------------------------------ | ------------------------------------------------- |
| main editor (`NSTextView`)    | `LineOverlayLayer` on top of the text view             | `highlightRange`, line-anchored popovers          |
| split editor                  | same, mirrored on the split pane                       | same                                              |
| sidebar (file tree etc.)      | `SidebarOverlayLayer` per section row                  | row-anchored popovers, row-pulse highlight        |
| git panel                     | `GitPanelOverlayLayer`                                 | tab-anchored or row-anchored popovers             |
| window chrome (corners)       | a SwiftUI `ZStack` at window root                      | `WindowChromeAnchor` popovers                     |
| floating                      | window-root `ZStack`                                   | centered popovers, no anchor                      |

Anchoring math reuses what we already do for the gutter: `sourceScrollState.lineHeight` × line index, plus sidebar row frames already exposed by `SidebarModel` via `GeometryReader`. No new layout primitives.

### 6.3 Highlight + callout visual language

- `style: .focus` — solid 2-pt left border in the accent color, faint accent-tinted background. 1500 ms fade by default.
- `style: .warn` — orange border + tint. No fade by default (persistent until next step).
- `style: .info` — neutral grey border + tint.
- `style: .agent` — Claude-orange tint. **This style is the user-visible signal that the agent is "pointing" at this line**, and it's the only style that surfaces the speaker label inline.

Popovers (`showPopover`) use the same color palette. Popovers in `style: .agent` get the same Claude-orange accent and an `AI` avatar puck — same shape as the mockup's `wt-callout` and `speaker` row.

---

## 7. Integration points — how `DocumentModel` gets the request

`DocumentModel` already uses the **request-nonce** pattern (see `HACKABILITY.md` §"The request-nonce pattern") for scroll, find, palette focus, git panel focus. We extend the same pattern. The engine never calls AppKit / SwiftUI; the UI side observes nonce changes and applies.

### 7.1 New `@Published` surface on `DocumentModel`

```swift
// In Sources/ViewerUI/DocumentModel.swift (additions)

// Walkthrough — the engine drives these. The UI layer observes.
@Published public var walkthroughActionRequest: (nonce: Int, action: Action, target: EditorTarget)? = nil
@Published public var walkthroughPopoverRequest: (nonce: Int, popover: ShowPopover)? = nil
@Published public var walkthroughHighlightRequest: (nonce: Int, hl: HighlightRange)? = nil
@Published public var walkthroughClearTransientRequest: Int = 0   // bump to clear
@Published public var walkthroughSidebarFocusRequest: (nonce: Int, section: SidebarSection, select: String?)? = nil
@Published public var walkthroughExitRequest: Int = 0
```

(In practice we want one nonce-per-channel rather than one bus, so unrelated channels don't re-fire each other's observers. The clusters above are the natural grouping.)

### 7.2 `WalkthroughPlayer` implementation lives in `ViewerUI`

```swift
// Sources/ViewerUI/WalkthroughPlayerImpl.swift

@MainActor
final class WalkthroughPlayerImpl: WalkthroughPlayer {
    let model: DocumentModel

    func apply(_ action: Action) async throws {
        switch action {
        case .openFile(let v):
            try await openFile(v)
        case .revealLine(let v):
            model.sourceScrollLineTarget = v.line
            model.sourceScrollLineNonce &+= 1
        case .highlightRange(let v):
            model.walkthroughHighlightRequest = (
                nonce: (model.walkthroughHighlightRequest?.nonce ?? 0) &+ 1,
                hl: v)
        // ...etc — every verb maps to either an existing nonce or a new one
        }
    }

    func clearTransientEffects() {
        model.walkthroughClearTransientRequest &+= 1
    }
}
```

### 7.3 Engine ↔ UI wiring (one-time, in app startup)

```swift
// Sources/MarkdownViewer/main.swift (sketch)

let player   = WalkthroughPlayerImpl(model: documentModel)
let reporter = FileDropReporter(rootDir: walkthroughDir)
let engine   = WalkthroughEngine(player: player, reporter: reporter)
let watcher  = WalkthroughFileWatcher(rootDir: walkthroughDir) { script in
    try? engine.run(script: script)
}
```

`documentModel.walkthroughEngine = engine` makes the engine accessible from menu actions (`File ▸ Walkthroughs ▸ ...`) and from the controller strip's transport buttons.

### 7.4 ViewerCore / ViewerUI module split

Hard line:

| concern                          | module        |
| -------------------------------- | ------------- |
| `WalkthroughScript`, `Step`, `Action`, enums | `ViewerCore/Walkthrough/` (types only — no AppKit, no SwiftUI) |
| `WalkthroughEngine`, state machine, reporter protocol | `ViewerCore/Walkthrough/` |
| `WalkthroughPlayer` protocol     | `ViewerCore/Walkthrough/` |
| `WalkthroughFileWatcher` + file-drop reporter | `ViewerCore/Walkthrough/Transport/` |
| `WalkthroughPlayerImpl`, controller strip view, overlays | `ViewerUI/Walkthrough/` |
| menu wiring                       | `MarkdownViewer/main.swift` |

Test consequence: 90% of the engine is testable from `ViewerCoreTests` with a fake `WalkthroughPlayer`. The SwiftUI strip is exercised only by manual smoke + visual regression.

---

## 8. Example script (5 steps, all the verb classes)

This script opens a file, highlights lines 10–12, splits the view, opens git log, then awaits the user. It's the minimum end-to-end for v1.

```json
{
  "schema": "textview.walkthrough/v1",
  "id": "engine-tour-mini",
  "title": "How the highlight engine routes a file",
  "author": "claude:opus-4.7",
  "createdAt": "2026-05-17T10:00:00Z",
  "estimatedDurationSec": 75,
  "rootHint": "/Users/me/Documents/workspaces/claude/markdown_viewer",
  "defaultTargets": { "editor": "main" },
  "steps": [
    {
      "id": "s1",
      "narration": "Six files implement syntax highlighting. The dispatch enum lives here — adding a new language is one case.",
      "actions": [
        {
          "kind": "openFile",
          "path": "Sources/ViewerKit/HighlightLanguage.swift",
          "viewMode": "source",
          "scrollTo": { "type": "symbol", "value": "detect(from:)" }
        }
      ]
    },
    {
      "id": "s2",
      "narration": "These three lines are the dispatch — extension → enum case. tomas caught this in review; the comment marker on line 11 is intentional.",
      "actions": [
        {
          "kind": "highlightRange",
          "lines": [10, 11, 12],
          "style": "focus",
          "fadeMs": 0
        },
        {
          "kind": "showPopover",
          "text": "Adding `.lua` is one case + one extension here. Five files total — see HACKABILITY §'Add a new file type'.",
          "anchor": { "type": "editorLine", "target": "main", "line": 11 },
          "style": "agent",
          "dismissOn": { "type": "nextStep" }
        }
      ]
    },
    {
      "id": "s3",
      "narration": "Now the engine side — TreeSitterEngine maps the enum case to a Tree-Sitter language pointer. Opening that in a split so you can see both at once.",
      "actions": [
        {
          "kind": "splitFile",
          "path": "Sources/ViewerCore/Highlight/TreeSitterEngine.swift",
          "viewMode": "source",
          "scrollTo": { "type": "symbol", "value": "tsLanguagePointer(for:)" },
          "closeOnExit": true
        }
      ]
    },
    {
      "id": "s4",
      "narration": "And here's what tomas's review on PR #1284 said about this exact switch. Opening the git log for that file.",
      "actions": [
        {
          "kind": "openGitPanel",
          "tab": "log",
          "path": "Sources/ViewerCore/Highlight/TreeSitterEngine.swift"
        },
        {
          "kind": "showPopover",
          "text": "Look for commit 4e1a8c2 — that's where BYTES_PER_ROW got extracted.",
          "anchor": { "type": "gitPanel", "tab": "log", "rowId": null },
          "style": "info"
        }
      ]
    },
    {
      "id": "s5",
      "narration": "Where to next? I can dive into incremental reparse, themes, or a different language. Or ask me anything.",
      "actions": [
        {
          "kind": "awaitUser",
          "prompt": "Pick a branch — or type a question:",
          "options": [
            { "id": "perf",   "label": "Incremental reparse" },
            { "id": "themes", "label": "Themes" },
            { "id": "lang",   "label": "Add a language" }
          ],
          "allowFreeForm": true,
          "reportCursorContext": true
        }
      ]
    }
  ]
}
```

What the engine does end-to-end:

1. File-watcher picks up `engine-tour-mini.walkthrough.json` from inbox. Loader validates, moves to `accepted/`. Engine state → `playing`.
2. Step 1 applies: `openFile` → `DocumentModel.openPath(...)` then `sourceScrollLineTarget` nonce bumps to scroll to the `detect(from:)` symbol. Strip narration updates.
3. Step 2 applies: `highlightRange` request bumps; UI overlay draws focus borders on lines 10–12 with `fadeMs: 0` (persistent). `showPopover` anchors a balloon to line 11.
4. Step 3 applies: `splitFile` opens the split pane. Strip shows step 3 of 5.
5. Step 4 applies: git panel focus nonce bumps with `tab: .log`, scoped to the path. Popover anchors to the panel.
6. Step 5: engine state → `awaitingUser`. Strip swaps narration row to pills + free-form input. Engine waits for `reply(...)`. On reply, reporter emits `.checkpointAnswered` (file-drop transport writes `<id>.s5.reply.json`).

---

## 9. Test strategy

### 9.1 Pure engine tests (`Tests/ViewerCoreTests/WalkthroughEngineTests.swift`)

The engine state machine is testable without SwiftUI. Use a fake `WalkthroughPlayer` that records `apply(_:)` calls into an array. Use a fake `WalkthroughReporter` that records events. All tests run in <100 ms on CI.

Coverage matrix:

| test name                                       | what it asserts                                                |
| ----------------------------------------------- | -------------------------------------------------------------- |
| `run_appliesStep0ActionsInOrder`                | After `run`, `fakePlayer.calls` equals step 0's actions in order. |
| `next_advancesAndAppliesStep1`                  | `next()` from playing → `fakePlayer.calls` grows with step 1.  |
| `next_atLastStep_transitionsToDone`             | `state == .done(.completed)`.                                  |
| `prev_atStep0_isNoop`                           | Calling `prev()` at step 0 leaves state + index unchanged.     |
| `prev_reappliesStepIdempotently`                | `prev()` then `next()` produces same action list as first run. |
| `jumpTo_reachesArbitraryStep`                   | `jumpTo(3)` applies step 3's actions, clears prior overlays.   |
| `checkpoint_transitionsToAwaitingUser`          | Reaching an `awaitUser` step sets state correctly and emits the event. |
| `reply_optionAdvances`                          | `reply(stepId, .option("themes"))` → state back to `.playing`. |
| `reply_freeFormAdvances`                        | Free-form reply also advances; reporter sees the text payload. |
| `guardOn_skipsWhenAnswerMismatches`             | A later step with `guardOn: { checkpointId, answerEquals }` is skipped silently when answer doesn't match. |
| `appendSteps_insertsAfterCurrent`               | `appendSteps([..], replaceFrom: nil)` grows the script in place. |
| `appendSteps_replaceFromRewritesTail`           | `replaceFrom: "s09"` drops s09 onwards then appends.           |
| `pause_haltsAutoAdvance`                        | With `dwellSec: 0.05` and `pause()`, no further `apply` calls. |
| `exit_emitsExitedAndClearsTransients`           | `exit()` triggers `cleanupEphemera`, then state `.done(.userExit)`. |
| `stepSkipped_whenPlayerThrows`                  | Player throwing `.targetUnavailable` → engine continues, emits `.stepSkipped`. |
| `runDiff_targetsSplitWhenNoSplitOpen`           | Action targeting `.split` when no split → `.stepSkipped(reason: .splitNotOpen)`. |
| `loaderRejectsUnknownSchema`                    | JSON with `schema: "v2"` fails with `UnsupportedSchemaError`.  |
| `loaderRejectsPathOutsideRootHint`              | Step `path: "../etc/passwd"` with `rootHint` → rejection.      |
| `decoder_kindDiscriminatorRoundTrip`            | Encode then decode each verb variant, assert equality.         |

### 9.2 Loader + watcher tests (`Tests/ViewerCoreTests/WalkthroughLoaderTests.swift`)

- Round-trip every verb variant through `JSONEncoder` / `JSONDecoder`.
- Watcher unit tests: create a temp dir, write a `.walkthrough.json`, assert the watcher emits a parse + move-to-accepted within 1 s. Write a malformed JSON, assert move-to-rejected + sibling `.error.txt`. Write a `.walkthrough.json.tmp` then rename, assert exactly one delivery.
- Bidi: write an `<id>.append.json`, assert engine receives `.appendSteps(...)`.

### 9.3 UI smoke (manual, scripted)

`scripts/visual-smoke.sh` gains a `walkthrough` scenario:

1. Launch TextView on the repo.
2. Drop `Tests/Fixtures/walkthroughs/engine-tour-mini.walkthrough.json` into the inbox.
3. Take screenshots after each `next` (via the existing `runScriptStep` infrastructure — `walkthrough-next`, `walkthrough-jumpTo`, `walkthrough-reply` added to the dispatcher).
4. Compare against golden screenshots in `Tests/ViewerUITests/Fixtures/Walkthrough/`.

This is the only place we assert visual correctness. Engine logic is covered by the pure tests above; the UI is a thin adapter.

### 9.4 What we intentionally don't test

- Per-pixel popover positioning. The anchoring math is exercised by the smoke scenario; we don't unit-test the geometry.
- MCP transport in v1 (it isn't built yet).
- The author tools (schema linter etc.) — those land in phase 5 with their own tests.

---

## 10. Risks + mitigations (delta from v1)

Most risks are unchanged from `WALKTHROUGH.md` §11. v2-specific additions:

1. **Multi-target verbs that race the user.** Step 3's `splitFile` could land while the user is mid-drag on the sidebar. Mitigation: every `apply(_:)` runs on `@MainActor` and queues serially per step. The engine awaits each `apply` before issuing the next; an `apply` that triggers async work (open file load) awaits the load via the existing `DocumentModel.loadState` publisher.
2. **Top-of-window strip steals chrome real-estate.** Mitigation: strip is auto-hidden when no walkthrough is active. When active, it pushes the tab bar down 36 pt — same delta as the existing find bar.
3. **File-watcher inbox accumulates if app is offline.** Mitigation: on app start, scan inbox for files older than 24 h and move them to `expired/`. Surface a small one-liner in the status bar: "3 walkthroughs expired in inbox — see `expired/`".
4. **Popover anchors to a row that scrolled out of view.** Mitigation: popover sticks to its anchor via the same `GeometryReader` we use for gutter dots; off-screen anchors collapse the popover to a chrome-corner indicator until the anchor returns to view.

---

## 11. Build order — what an implementer does, in order

1. **Types + Codable** (`ViewerCore/Walkthrough/`): `WalkthroughScript`, `Step`, `Action` + variants, enums, custom encoders. Unit-test the encode/decode round-trip exhaustively. ~1 day.
2. **Engine state machine** (`ViewerCore/Walkthrough/WalkthroughEngine.swift`): protocol-only player, fake player for tests, all the transitions listed in §5. Tests in `Tests/ViewerCoreTests/`. ~1 day.
3. **File-drop transport** (`ViewerCore/Walkthrough/Transport/`): watcher + reporter + accepted/rejected/expired dirs. Tests with `FileManager` temp dirs. ~0.5 day.
4. **`WalkthroughPlayerImpl`** (`ViewerUI/Walkthrough/`): one switch over `Action`, each case bumping a request-nonce on `DocumentModel`. Add the new published properties to `DocumentModel`. ~0.5 day.
5. **Overlays** (`ViewerUI/Walkthrough/Overlays/`): line-overlay layer for highlights, popover layer for callouts. Reuse gutter line-height math. ~1–2 days.
6. **Controller strip** (`ViewerUI/Walkthrough/ControllerStripView.swift`): transport buttons, scrubber, TOC popover, awaitingUser swap-in. ~1 day.
7. **App wiring** (`MarkdownViewer/main.swift`): `File ▸ Walkthroughs` menu, engine init at startup, watcher init at startup, custom URL scheme `markdownviewer://walkthrough?id=...`. ~0.5 day.
8. **Smoke scenario** in `scripts/visual-smoke.sh` + a fixture script under `Tests/Fixtures/walkthroughs/`. ~0.5 day.

Total: ~6 working days for v1 end-to-end. MCP transport (phase 2) adds ~2 days on top, with no engine changes.

---

## 12. Open decisions

Five small calls for the implementer (defaults indicated):

1. **Default `dismissOn` for popovers.** Default `.nextStep`. Confirmed in this doc.
2. **Auto-advance default.** Off. Auto-advance is opt-in per step (`dwellSec`). Confirmed.
3. **`appendSteps` semantics when state is `awaitingUser`.** Default: hold the append until the user replies. Alternative: replace the awaitingUser step. Recommend hold (preserves intent).
4. **`awaitUser.timeoutSec` behavior.** Default: on timeout → `paused` with an error banner ("checkpoint timed out"). User must explicitly `play` to resume to the same awaitingUser state.
5. **Ephemeral bookmark cleanup on crash.** A crash mid-walkthrough leaves ephemerals in the bookmarks store. Default: on next launch, scan bookmarks store for entries tagged `walkthroughId == <id>` whose script is no longer in `accepted/` and prune. Confirmed.

---

## Appendix A — JSON schema sketch (for `walkthrough.schema.json`)

Ship a JSON Schema file under `Resources/walkthrough.schema.json` so external editors can lint. Sketch:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://textview.app/schemas/walkthrough/v1.json",
  "title": "WalkthroughScript",
  "type": "object",
  "required": ["schema", "id", "title", "steps"],
  "properties": {
    "schema":  { "const": "textview.walkthrough/v1" },
    "id":      { "type": "string", "pattern": "^[a-zA-Z0-9_-]{1,64}$" },
    "title":   { "type": "string", "maxLength": 200 },
    "subtitle":{ "type": "string", "maxLength": 400 },
    "author":  { "type": "string", "maxLength": 100 },
    "createdAt": { "type": "string", "format": "date-time" },
    "estimatedDurationSec": { "type": "integer", "minimum": 0, "maximum": 7200 },
    "rootHint": { "type": "string" },
    "defaultTargets": {
      "type": "object",
      "properties": {
        "editor":  { "enum": ["main", "split"] },
        "popover": { "enum": ["anchorToEditor", "anchorToSidebar", "floating"] }
      }
    },
    "steps": {
      "type": "array",
      "minItems": 1,
      "maxItems": 50,
      "items": { "$ref": "#/definitions/Step" }
    }
  },
  "definitions": {
    "Step": {
      "type": "object",
      "required": ["id", "actions"],
      "properties": {
        "id":            { "type": "string", "pattern": "^[a-zA-Z0-9_-]{1,32}$" },
        "narration":     { "type": "string", "maxLength": 2000 },
        "speakerLabel":  { "type": "string", "maxLength": 64 },
        "dwellSec":      { "type": "number", "minimum": 0, "maximum": 600 },
        "actions":       { "type": "array", "items": { "$ref": "#/definitions/Action" } },
        "guardOn": {
          "type": "object",
          "required": ["checkpointId", "answerEquals"],
          "properties": {
            "checkpointId": { "type": "string" },
            "answerEquals": { "type": "string" }
          }
        }
      }
    },
    "Action": {
      "oneOf": [
        { "$ref": "#/definitions/OpenFile" },
        { "$ref": "#/definitions/RevealLine" },
        { "$ref": "#/definitions/HighlightRange" },
        { "$ref": "#/definitions/ShowPopover" },
        { "$ref": "#/definitions/SetView" },
        { "$ref": "#/definitions/SplitFile" },
        { "$ref": "#/definitions/RunDiff" },
        { "$ref": "#/definitions/AwaitUser" },
        { "$ref": "#/definitions/AddBookmark" },
        { "$ref": "#/definitions/RevealInSidebar" },
        { "$ref": "#/definitions/OpenGitPanel" },
        { "$ref": "#/definitions/NarrateOnly" }
      ]
    }
    /* ...one definition per variant, each with `kind` as a const... */
  }
}
```

The schema doubles as the wire contract Claude generates against. We don't ship a Swift→JSON-schema generator; we keep the schema hand-maintained alongside the Swift types and add a CI check (`scripts/check-walkthrough-schema.sh`) that round-trips a corpus of fixture scripts through both the Swift decoder and an off-the-shelf JSON Schema validator (CLI, not a Swift dependency).

---

## Appendix B — Why this differs from `WALKTHROUGH.md` v1

Quick diff for anyone who's read the v1 doc:

- **Transport priority inverted.** v1: MCP first, URL scheme + watcher as fallbacks. v2: file-drop watcher first (zero IPC, zero new dependencies, easy to script and test), MCP later as an additive layer. The engine signature is unchanged so phase-2 MCP is a drop-in.
- **Player position moved.** v1: bottom strip docked on the right pane. v2: top-of-window strip spanning the full window. Reason: the verb set now reaches surfaces outside the editor (sidebar, git panel, file tree), so the controller can't live inside one pane.
- **Verb shapes match the mockup.** v1 invented its own verb taxonomy; v2 mirrors the mockup's "step has narration + actions[]" shape, with `actions` as a Codable union. Lets the same JSON drive both a future web mockup and the native player.
- **Multi-target explicit.** v1 implicitly assumed one editor surface. v2's `target` field on every editor-touching verb makes the surface a first-class parameter.
- **Schema versioning formalized.** v1 mentioned `schema: textview.walkthrough/v1`; v2 specifies the migration policy + the unknown-version failure mode.
- **Test strategy split.** v1 deferred tests to phase 5. v2 puts pure-engine tests in phase 2 (before any UI exists), so the engine ships with the state machine fully covered.

End of design.
