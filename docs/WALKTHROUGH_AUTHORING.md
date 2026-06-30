# Authoring a Walkthrough

A **walkthrough** is a guided, step-by-step tour of a project: each step shows some
narration and can drive the app — open a file, highlight a range of code, drop a
bookmark, or show an illustration. This is the practical "how do I make one" guide.
For the design rationale see [`WALKTHROUGH.md`](WALKTHROUGH.md) and
[`WALKTHROUGH_DESIGN_v2.md`](WALKTHROUGH_DESIGN_v2.md).

## TL;DR

1. Copy [`examples/sample-walkthrough.json`](examples/sample-walkthrough.json) — it's a
   valid, runnable starting point (a host test keeps it valid).
2. Edit the `title`, `rootHint`, and `steps`.
3. Drop the file in your Walkthroughs folder (below) — it shows up in the Walkthroughs
   browser, ready to play.

## File format

A walkthrough is a single JSON file (`schema: "textview.walkthrough/v1"`):

```json
{
  "schema": "textview.walkthrough/v1",
  "id": "getting-started",
  "title": "Getting Started",
  "subtitle": "optional one-liner",
  "author": "optional",
  "rootHint": ".",
  "steps": [ ... ]
}
```

| Field        | Required | Meaning |
|--------------|----------|---------|
| `schema`     | yes      | Must be `textview.walkthrough/v1`. |
| `id`         | yes      | Stable identifier (used for progress/checkpoints). |
| `title`      | yes      | Shown in the browser + player. |
| `subtitle`   | no       | One-line description. |
| `author`     | no       | Free text. |
| `rootHint`   | no*      | The project root that step `path`s resolve against. *Required when the host injects a `trustedRoot` (see Security). |
| `steps`      | yes      | Ordered array of steps (below). |

### Steps

```json
{ "id": "open", "narration": "Open the main file.", "actions": [ { "kind": "openFile", "path": "Sources/App/main.swift" } ] }
```

- `id` — unique within the file (duplicates are rejected at load).
- `narration` — optional text shown for the step.
- `actions` — ordered list; all run when the step is shown.

### Action kinds

| `kind`           | Payload fields | Effect |
|------------------|----------------|--------|
| `narrateOnly`    | —              | Show narration only (no app action). |
| `openFile`       | `path`         | Open the file (relative to `rootHint`). |
| `highlightRange` | `path`, `startLine`, `endLine` | Open the file and highlight the line range. |
| `addBookmark`    | `path`         | Bookmark the file. |
| `diagram`        | `diagramKind` (`ascii` \| `image` \| `mermaid`) + payload | Show an illustration alongside the narration (see below). |

A step may combine actions (e.g. `openFile` then `highlightRange`). For the exact,
authoritative payload shapes — especially `diagram` — see the `Action` enum in
[`Sources/ViewerCore/Walkthrough/WalkthroughScript.swift`](../Sources/ViewerCore/Walkthrough/WalkthroughScript.swift)
(the `diagram` kind encodes its medium under `diagramKind`, not `kind`, and carries
the diagram source/`data` + an optional `caption` — rendered by the illustration
overlay, TSK-1119).

## Where to put it + how to run it

Drop your `.json` into the Walkthroughs folder:

```
~/Library/Application Support/com.markdownviewer.MarkdownViewer/Walkthroughs/
```

It appears in the **Walkthroughs browser** (the catalog scans that folder), where you
can start it. Authoring in place + reloading the browser is the iterate loop.

## Security: paths are fenced

Step `path`s and `rootHint` are **not trusted to roam the filesystem**. When the host
loads a walkthrough with a `trustedRoot` (e.g. one received over the file-drop
transport), the loader rejects:

- a `rootHint` that resolves outside the trusted root (an over-broad `rootHint: "/"`
  is the classic exploit — it's the first thing rejected), and
- any step `path` that escapes the effective root.

So `openFile` can never reach `/etc/passwd` via a malicious `rootHint`. When you author
locally (no `trustedRoot`), paths resolve against your `rootHint` normally.

## Validate your file

The loader is `WalkthroughLoader.load(data:requireRootHint:trustedRoot:)` →
`Result<WalkthroughScript, WalkthroughLoadError>`. The error cases are specific
(`unsupportedSchema`, `duplicateStepID`, `pathEscape`, `rootHintOutsideTrustedRoot`,
`missingRootHint`, `decodingFailed`) — read the failure to see exactly what's wrong.
`docs/examples/sample-walkthrough.json` is kept parse-valid by
`WalkthroughAuthoringSampleTests`.
