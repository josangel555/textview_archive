# PLUGINS.md — design ideas for an extensibility system

DRAFT. Goal: brainstorm what a plugin system *could* look like before
committing to a shape. No implementation yet. Approve a direction
first, then we'll pick a slice and ship it.

## Why have plugins at all

Today, extending MarkdownViewer means cloning the repo and writing
Swift. That's fine for first-party features. It's not fine for:
- A user who wants a viewer for their proprietary file format
- A team that wants to share custom syntax themes
- Someone who wants to add a sidebar widget for their tool
- Workflow integrations (e.g. "open in Cursor", "send to ChatGPT")

A plugin system trades some risk (sandbox, instability, supply chain)
for a much wider extension surface.

## Extension points we'd want to support

Listed by frequency-of-want, biggest-leverage first:

1. **File-type handlers** — "I have `.foo` files, here's how to render them"
2. **Viewer modes** — "I have a custom mode that turns markdown into outline view"
3. **Sidebar widgets** — A panel in the left sidebar (under bookmarks, etc.)
4. **Status-bar items** — Read-only widget in the bottom status bar
5. **Menu commands** — `Plugins → MyPlugin → Send to X` (Cmd+Shift+X)
6. **Toolbar buttons** — Optional, since we don't have a toolbar today
7. **Command palette entries** — Items in Cmd+K
8. **Highlighters** — Custom syntax highlighter for a language we don't ship
9. **Themes** — Color schemes for source view + markdown CSS
10. **Formatters** — Pretty-print for a custom format
11. **File-watcher hooks** — Receive "file changed" events
12. **Quick actions** — Right-click context menu entries on files
13. **Custom URL schemes** — `markdownviewer://open?path=...` style
14. **Render filters** — Transform AST before HTML render
15. **Find providers** — Custom search engines (e.g. "search in my notes index")

## Plugin packaging options

### Option A: Swift bundle (.bundle) loaded via `Bundle.load()`
**Pros:** Native Swift / AppKit access, full speed, debuggable in Xcode.
**Cons:** Requires recompilation per macOS update; signing/notarization
needed for distribution; security boundary nonexistent (full process
access); hard to sandbox.

### Option B: WKWebView-hosted JS plugins
**Pros:** Sandboxed by default; cross-platform potential; familiar
language for many developers; live-reload friendly.
**Cons:** Native UI is awkward via JS bridge; performance not great
for hot paths (highlighting, file loading).

### Option C: External process + stdin/stdout JSON-RPC (LSP-style)
**Pros:** Strong isolation, language-agnostic (Python, Node, Rust),
already-known pattern.
**Cons:** Process spawning overhead per plugin; complex to wire native
UI; daemons need lifecycle management; not great for synchronous
extension points (highlighter on hot path).

### Option D: WASM via wasmtime/wasmer Swift bindings
**Pros:** Strong sandbox, language-agnostic, fast enough for most things.
**Cons:** Tooling immature on macOS; can't touch AppKit directly;
overkill for v1.

### Option E: AppleScript / OSAKit
**Pros:** Built into macOS; users can write in Script Editor.
**Cons:** Limited (no UI extension, hard to do anything stateful);
declining usage.

### Option F: URL schemes / external apps
**Pros:** Trivial; works today via `NSWorkspace.open(url:)`.
**Cons:** Not really "plugins" — more "integrations." Limited to
roundtripping.

### Recommended hybrid (proposal)
- **Native handlers** for performance-critical extension points
  (highlighters, file-type viewers): ship as Swift bundles loaded at
  startup. Require signature from a known developer ID or
  user-acknowledged trust prompt.
- **Scripted commands** for menu items / status bar widgets / quick
  actions: ship as WKWebView-hosted JS with a small JS-bridge API
  exposing model state + actions. Cheap to write, sandboxed by
  default.
- **External integrations** for "send to" / "open in" workflows: just
  use URL schemes + NSWorkspace. No plugin protocol needed.

## Plugin manifest format (proposal)

```json
{
  "id": "com.example.mdv.json-tree",
  "name": "JSON Tree Viewer",
  "version": "0.1.0",
  "author": "Example Co.",
  "minMDVVersion": "0.5",
  "permissions": ["read.currentTab", "read.fileTree"],
  "contributes": {
    "viewerModes": [
      {
        "id": "json-tree",
        "label": "Tree",
        "fileTypes": ["public.json"],
        "swiftBundle": "JSONTreeViewer.bundle"
      }
    ],
    "sidebarWidgets": [
      {
        "id": "json-stats",
        "title": "JSON Stats",
        "swiftBundle": "JSONTreeViewer.bundle"
      }
    ],
    "menuCommands": [
      {
        "id": "tree.expand-all",
        "title": "Expand All",
        "menu": "View",
        "keyEquivalent": "$cmd+shift+E"
      }
    ]
  }
}
```

## Loading mechanism

1. App start: enumerate `~/Library/Application Support/MarkdownViewer/Plugins/`
2. For each plugin dir, read `manifest.json`
3. Validate manifest schema + permissions
4. Show first-launch trust prompt: "Plugin X wants to read your file
   tree. Allow this session? Always? Never?"
5. Load `swiftBundle` via `Bundle.load()` if approved
6. Register the plugin's contributions with the host: viewer modes
   show up in the picker, sidebar widgets in the sidebar, etc.

## Security boundary

This is the hardest part. Honest tradeoffs:

- **Native bundle plugins are essentially privileged.** They can do
  anything the host can do — read user files, network access,
  whatever. The mitigation has to be social: code signing, trusted
  developer list, user trust prompt with explicit permission list.
- **WKWebView JS plugins can be sandboxed** via the bridge — the
  host controls what methods are exposed. Recommended for UI-shaped
  extensions; the JS plugin asks for permission to e.g. read tab
  contents.
- For v1: ONLY load bundles from `~/Library/Application Support/MarkdownViewer/Plugins/`,
  require the user to manually drop them in (no auto-install from
  network), and surface installed plugins in Settings.

## UX for plugin management

- Settings → Plugins → list of installed plugins with toggle
- Each entry: name, version, permissions, "view source" link, disable, uninstall
- "Install plugin..." button opens file picker for `.mdvplugin` bundle
- No marketplace, no auto-update in v1. (Maybe `Sparkle` for plugins
  later.)

## Lifecycle

- `onLoad()` — once at app start. Plugin registers contributions.
- `onUnload()` — graceful cleanup if user disables. Probably never
  called; plugin can leak.
- `onFileOpen(url)` — file-watcher-shaped hook
- `onTabSelect(tab)` — model-shaped hook
- `onRender(html, ast)` — render filter

## What we're deliberately NOT doing

- **Plugin marketplace.** Don't manage discovery; let users share
  manifests directly or via GitHub.
- **Auto-update plugins.** Out of scope; manual install only.
- **Cross-platform plugins.** macOS only. If we ever ship for iOS,
  re-evaluate.
- **Public Swift API stability.** Plugins use a versioned API; we'll
  break it on major bumps. Like VS Code, mostly stable but
  occasionally moves.
- **Sandboxing native bundles.** Won't work for performance-critical
  hooks. We rely on user trust + signed bundles.

## v0 — what to actually build first

Smallest useful slice:
1. **Themes as JSON files** in `~/Library/Application Support/MarkdownViewer/Themes/`.
   Load at app start, list in Settings → Appearance → Theme picker.
   Zero security worry (just colors), zero code execution.
2. **Highlighter languages as drop-in `.scm`** in `~/.../Languages/`.
   Auto-discover + load. Same security profile (text data).

Both of these are real extension points, both are pure data, both
prove the discovery+load mechanism works. After v0 ships, expand to
sidebar widgets + menu commands.

## Open questions for review

1. Is "user-acknowledged trust prompt" enough for native bundles, or
   do we wait until we can ship a proper sandboxed runtime?
2. Should the manifest be JSON or TOML or Swift macros?
3. Do we want a `mdv plugins install <url>` CLI?
4. How do we handle plugin conflicts (two plugins claim
   `public.json`)?
5. Is there a market for a marketplace, or is GitHub fine?
