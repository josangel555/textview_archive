# MCP + Walkthrough: testing, persistence, serialization, and "saving" tours

Status: answer doc for **TSK-778** ("How to test MCP/Walkthrough; how
persisted/serialized; owner wants to save them"). Surveys what exists
today, answers the three questions, and documents the new
`WalkthroughStore` that closes the "save walkthroughs" gap.

This is a homework/answer doc, but it ships with code: the durable
saved-walkthrough library (`WalkthroughStore`) was the one missing piece
behind "owner wants to save them," so it's implemented + host-tested in
the same change.

---

## TL;DR

| Question | Short answer |
| --- | --- |
| How do I test the MCP server? | Host XCTest, pure logic — `Tests/ViewerCoreTests/Automation/MCP*Tests.swift` cover framing, protocol, tool catalog, server. No VM needed; the protocol/tool layer is host-testable end-to-end with a fake `AutomationHost`. |
| How do I test walkthroughs? | Host XCTest — `Tests/ViewerCoreTests/Walkthrough/*` cover loader (security fence), engine state machine, drop transport, and now the store. The *rendered* player UI (overlays, strip) is the only VM-only part. |
| How are walkthroughs persisted / serialized? | Plain JSON, `Codable`, schema-versioned (`textview.walkthrough/v1` / `v2`). Until now the only on-disk presence was a transient *drop inbox* — files were consumed, not retained. |
| How do I save a walkthrough? | NEW: `WalkthroughStore.save(_:)` writes the script to a durable library at `<appSupport>/MarkdownViewer/Walkthroughs/<id>.json`; `list()` / `load(id:)` / `delete(id:)` manage it. |
| Is MCP persisted? | No — the MCP server is a live automation channel (stateless RPC over a socket). Nothing about MCP is "saved." The thing the owner saves is the **walkthrough script**, which an MCP tool could publish into the store. |

---

## 1. What exists today (the survey)

### 1.1 MCP server

`Sources/ViewerCore/Automation/`:

- `MCPFraming.swift` — newline/length-delimited JSON-RPC framing over a
  byte stream (the transport wire format).
- `MCPProtocol.swift` — JSON-RPC request/response/error envelope +
  `MCP.Value` (a small JSON value type) + `MCP.ToolDescriptor`.
- `MCPToolCatalog.swift` — the **10 v1 tools**: `open_path`, `select_tab`,
  `set_view_mode`, `find`, `goto_line`, `visible_text`, `current_state`,
  `toggle_bookmark`, `list_bookmarks`, `snapshot_window`. Each has a
  descriptor (name + input JSON Schema) and a dispatcher that calls an
  `AutomationHost`.
- `MCPServer.swift` — the server loop + tool wiring.

These are **editor-automation** tools — drive tabs, view modes, find,
bookmarks, screenshots. There are **no walkthrough tools** in the MCP
catalog yet (the design's `walkthrough.publish/start/list` were never
built). MCP and Walkthrough are currently two independent subsystems;
the design intends MCP to *become* a walkthrough transport (see §5).

Security boundary: `validatedExistingURL(from:)` in `MCPToolCatalog`
resolves `~`, resolves symlinks, and confines every path to the user's
home or per-user temp dir (rejects `/etc`, `/System`, other users'
homes). This is the audit-S3 prong on the MCP side.

### 1.2 Walkthrough engine

`Sources/ViewerCore/Walkthrough/`:

- `WalkthroughScript.swift` — the data model: `WalkthroughScript` →
  `[Step]` → `[Action]` (a `kind`-tagged union of 13 verbs:
  `openFile`, `revealLine`, `highlightRange`, `showPopover`, `setView`,
  `splitFile`, `runDiff`, `awaitUser`, `addBookmark`, `revealInSidebar`,
  `openGitPanel`, `flash`, `narrateOnly`). All `Codable + Sendable`.
  Schema versions `v1` / `v2`; unknown version → structured
  `UnsupportedSchemaError`.
- `WalkthroughLoader.swift` — decode + **validate** (the security fence):
  unique step ids, path-escape containment against a *caller-injected*
  `trustedRoot` (NOT the script's self-declared `rootHint`, which is
  attacker-controlled).
- `WalkthroughEngine.swift` — pure `@MainActor` state machine
  (`idle/playing/paused/done`) that emits each step's actions to a
  delegate. No SwiftUI in the engine.
- `WalkthroughDropTransport.swift` — FSEvents watcher on a *drop inbox*.
  Env-gated off by default (`TV_WALKTHROUGH_DROP`). On a hit it
  parses+validates and hands the script to a delegate.
- `WalkthroughStore.swift` — **NEW** (this change): durable saved-tour
  library. See §4.

UI side (`Sources/ViewerUI/Walkthrough/`): player strip, overlays,
anchor registration, auto-advance. Render-path — VM-only to validate.

---

## 2. How to TEST them (host vs VM)

The project's hard rule (`CLAUDE.md`): **model/logic = host XCTest;
rendered UI = VM-only**. Both subsystems are mostly model/logic, so
nearly all of their coverage is host-runnable.

### 2.1 MCP — host-testable end to end

The MCP layer has **no UI**, so it is 100% host-testable. Existing
suites:

- `MCPFramingTests` / `…FileHandleReaderTests` — wire framing.
- `MCPProtocolTests` — JSON-RPC envelope + `MCP.Value` round-trips.
- `MCPToolCatalogTests` / `…VisibleTextTruncationTests` — each tool's
  arg parsing, schema, dispatch, and result shape, driven through a fake
  `AutomationHost`.
- `MCPServerTests` / `…DeadTransportTests` / `MCPServerWedgeTests` —
  the server loop, dead-transport handling, wedge/back-pressure.

Run them:

```bash
swift test --filter ViewerCoreTests.MCPToolCatalogTests
# or the whole automation suite:
swift test --filter ViewerCoreTests.MCP
```

To add a tool: add a descriptor + dispatcher to `MCPToolCatalog`, then a
catalog test asserting (a) the tool appears in `tools/list`, (b) good
args dispatch to the right `AutomationHost` call, (c) bad args throw the
right `MCPError`. The fake host records calls — no app, no window.

### 2.2 Walkthrough — host for model, VM for render

Host-testable (the bulk):

- `WalkthroughLoaderTests` — the security fence: path-escape rejection,
  `trustedRoot` precedence, unknown-schema rejection, duplicate-id.
- `WalkthroughEngineTests` — state-machine transitions with a fake
  delegate recording applied actions (idempotent prev/jumpTo, etc.).
- `WalkthroughScriptTests` / `WalkthroughSchemaErrorTests` — Codable
  round-trip of every verb + graceful unknown-version failure.
- `WalkthroughDropTransportTests` — env-gate + `requireRootHint`
  hardening.
- `WalkthroughStoreTests` — **NEW**: save/list/load/delete + id
  sanitization (path-traversal containment). See §4.

VM-only (render path — the player strip + overlays composite SwiftUI
over `NSViewRepresentable`, exactly the `ImageRenderer` false-green trap
`CLAUDE.md` warns about):

- `Tests/ViewerUITests/Walkthrough/*` + `uat/WalkthroughAndCodeReviewUATTests`.
  Run via `bash scripts/test-in-vm.sh all` under the GUI lane.

```bash
swift test --filter ViewerCoreTests.Walkthrough   # host model layer
# VM render validation (see CLAUDE.md VM workflow):
#   MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/test-in-vm.sh all
```

**Why the split:** a headless "the player is in the view tree" check is
NOT proof the strip is visible — the overlay can be occluded by the
WebView/editor surface. Interaction behaviour (next/prev/jumpTo cycling)
is pinned on the host via the engine state machine; pixel visibility is
VM-only.

---

## 3. How they're PERSISTED / SERIALIZED

### 3.1 Walkthrough wire + disk format

- **Format:** plain JSON. `WalkthroughScript: Codable`. The verb union
  encodes with a `"kind"` discriminator and the variant's fields hoisted
  onto the same object (`{ "kind": "openFile", "path": "..." }`).
- **Schema discriminator:** `"schema": "textview.walkthrough/v1"` (or
  `/v2`). The *only* version signal — never sniff field presence. An
  unknown version fails with `UnsupportedSchemaError(version, supported)`
  so an older app handed a newer script says "update the app," never
  crashes or best-effort decodes.
- **Dates:** ISO-8601 (`createdAt`).
- **Saved canonical form** (the store, §4): pretty-printed + sorted keys
  so a repo-checked-in tour diffs cleanly.

### 3.2 Where on disk (before vs after this change)

```
~/Library/Application Support/
├── com.markdownviewer.MarkdownViewer/      (bundle-id-PREFIXED)
│   └── Walkthroughs/drop/                  ← drop INBOX (transient, env-gated)
│                                              FSEvents picks up <id>.json, runs it.
│                                              NOT a saved copy — consumption channel.
└── MarkdownViewer/                         (UN-prefixed — user state)
    ├── Sessions/  bookmarks.json  history.json  recent-paths.json
    └── Walkthroughs/                        ← NEW: saved-tour LIBRARY (durable)
        ├── engine-tour.json
        └── hex-viewer-tour.json
```

Two distinct trees, by `CLAUDE.md`'s documented convention: the
*bundle-id-prefixed* dir holds Plugins/Walkthroughs-drop/jdtls; the
*un-prefixed* `MarkdownViewer/` dir holds user-facing persisted state
(Sessions, bookmarks, history). The **saved library lives with the user
state** (un-prefixed), because a saved tour is user content, not an
inbound automation artifact.

### 3.3 MCP is NOT persisted

The MCP server is a live RPC channel — stateless, socket-based,
nothing serialized to disk. "Saving" never applies to MCP itself. What
the user saves is the **walkthrough script** an agent authored; MCP is
just one possible delivery transport for it (§5).

---

## 4. The "save walkthroughs" answer — `WalkthroughStore` (NEW)

The gap behind the owner's ask: `WALKTHROUGH_DESIGN_v2.md` §"Script
storage (durable)" promised `Walkthroughs/<id>.json` as a durable
library, but only the *transient drop inbox* was ever built. Dropped
scripts ran once and were gone — nothing the user could re-open from a
menu. `WalkthroughStore` is that durable library.

`Sources/ViewerCore/Walkthrough/WalkthroughStore.swift`:

```swift
let store = WalkthroughStore()              // default library dir
try store.save(script)                       // upsert by id → <id>.json
let rows  = store.list()                     // [SavedWalkthrough] metadata, no step bodies
let tour  = try store.load(id: "engine-tour")// decode + validate, or nil if absent
try store.delete(id: "engine-tour")          // idempotent
store.exists(id: "engine-tour")              // Bool
```

Design properties (all host-tested):

- **Upsert by id.** Re-saving an edited tour overwrites in place — no
  duplicate files.
- **Atomic writes.** `Data.write(.atomic)` → temp-then-rename, so a
  crash mid-write never leaves a torn file the loader rejects.
- **Path-traversal-safe filenames.** A script `id` is untrusted
  payload, so it is sanitized to a single safe component
  (`[A-Za-z0-9._-]`, leading dots stripped, length-capped) before
  becoming `<safe>.json`. `id: "../../etc/passwd"` lands *inside* the
  library, never outside; an id that reduces to empty (`"../"`, `"..."`)
  is rejected with `StoreError.invalidID`. This matters because `save`
  is reachable from the untrusted file-drop boundary.
- **Cheap listing.** `list()` decodes only the header (id/title/author/
  createdAt + step count), not full step bodies — a menu over hundreds
  of tours stays fast. Corrupt files are skipped, not fatal; the skipped
  count is surfaced via `listResult()`.
- **Validation on load.** `load(id:)` runs the on-disk file through
  `WalkthroughLoader`, so a tampered file is rejected exactly like a
  freshly-dropped one.
- **Canonical JSON.** Sorted keys + pretty-printed for clean git diffs.

### What's NOT in this slice (follow-ups, see §6)

- UI: a `File ▸ Walkthroughs` menu listing `store.list()`, a "Save this
  tour" command, a delete affordance. (Render path → VM lane.)
- Auto-retain: wiring the drop-transport delegate to `store.save(_:)` so
  every accepted dropped script is durably kept.
- MCP tools: `walkthrough.publish` (= `store.save`), `walkthrough.list`
  (= `store.list`), `walkthrough.start` (= `engine.load` + `next`).

These are deliberately deferred — the foundation (durable, secure,
tested persistence) is the valuable, self-contained slice. The UI/menu
and MCP-tool wiring are thin adapters over this store and want VM render
validation, so they belong in their own tickets.

---

## 5. How MCP + Walkthrough are meant to connect (design intent)

The design (`WALKTHROUGH.md` §5, `WALKTHROUGH_DESIGN_v2.md` §4.2) wants
MCP to be a *walkthrough transport*: an agent calls a `walkthrough.*`
MCP tool to publish a script (→ saved into the store), start playback,
push checkpoints back, and splice steps. Today those tools don't exist;
the engine is reachable only via the env-gated file-drop transport.

The clean composition with this change:

```
agent ──MCP walkthrough.publish──▶ WalkthroughStore.save(script)   [durable]
agent ──MCP walkthrough.start───▶ WalkthroughEngine.load + next    [playback]
user  ──File ▸ Walkthroughs────▶ WalkthroughStore.list / load     [re-open saved]
```

The store is the join point: both "an agent published a tour" and "the
user wants to replay a saved tour" funnel through the same library.

---

## 6. Recommended follow-up tickets

1. **`File ▸ Walkthroughs` menu** listing `store.list()` + "Save current
   tour" + delete. VM render validation. (UI slice.)
2. **Auto-retain dropped scripts:** drop-transport delegate calls
   `store.save(_:)` on accept, so the inbox feeds the library.
3. **MCP walkthrough tools:** `walkthrough.publish/list/start` over the
   store + engine (host-testable via fake host, like the other 10).
4. **Repo-scoped library:** also read `<repo>/.textview/walkthroughs/`
   so a cloned repo ships tours (design §8). Store already takes a
   `libraryDirectory` override — this is a second store instance.
5. **Completion log** (design §8): append-only JSONL of runs so an agent
   can answer "have I shown this before?".
