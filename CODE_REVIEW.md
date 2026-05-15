# Code Review — synthesis of seven parallel agents

Date: 2026-05-14 (round 2). Seven agents reviewed independently along
orthogonal dimensions: security, concurrency/memory, performance, code
quality, UX/UI/accessibility, behavior/edge cases, and test quality.

Legend: **H** = high (data loss / crash / silent failure / broken core
UX), **M** = medium (wrong behavior, friction), **L** = low (polish /
nits / cosmetic).

(Round 1 findings from the earlier "address all of these" pass remain
fixed in the codebase; this document supersedes that one for the
ongoing backlog.)

---

## High — fixed in Batch 1

1. **Cross-file search race** — security + concurrency + perf + bugs.
   `Sources/ViewerUI/DocumentModel.swift:194-215`. Rapid typing fires
   N searches concurrently; the slower one overwrites the newer
   results. No cancellation. Fix: generation counter.
2. **WKWebView find before page load** — bugs.
   `Sources/ViewerUI/MarkdownRenderedView.swift:50-77`. Setting
   renderedFindQuery before loadHTMLString silently fails the find.
   Fix: track pending query; re-run from `didFinish`.
3. **`formattedTabs` keyed by URL** — bugs.
   `Sources/ViewerUI/DocumentModel.swift:248-283`. Opening the same
   URL in two tabs makes them share format state; closing a tab leaks
   the URL in `formattedTabs`. Fix: key by `Tab.id`, prune on close.
4. **Zoom keyEquivalent `+` is wrong** — HIG / UX.
   `Sources/MarkdownViewer/main.swift:741`. `+` requires shift on US
   layout, so Cmd+= never zooms in. Fix: use `=`.
5. **Sidebar `setRoot` always clears `expanded`** — bugs.
   `Sources/ViewerUI/SidebarModel.swift:39-55`. Opening the same
   folder via Open Recent collapses all expansions. Fix: early
   return on unchanged URL.
6. **`/tmp/mdv-*` symlink hijack** — security.
   `Sources/ViewerUI/DiagnosticDump.swift` + `Sources/MarkdownViewer/main.swift`.
   Pre-pointed symlink lets another user redirect writes. Fix: use
   `FileManager.default.temporaryDirectory` (per-user `/var/folders/`).
7. **No match count / no-matches state in rendered find bar** — UX.
   `Sources/ViewerUI/MarkdownRenderedView.swift:126-131`. Source has
   a TODO. Fix: plumb `WKFindResult.matchFound` back.
8. **Hardcoded `Color.black` borders invisible in dark mode** — UX.
   `Sources/ViewerUI/CrossSearchPanel.swift:67,69`. Fix: use
   `Color.primary` / `Color(nsColor: .separatorColor)`.

## High / medium — Batch 2

9. **FileWatcher event handler fires after stop()** — concurrency.
   `Sources/ViewerCore/FileWatcher.swift:84-93,103-132`. Pending events
   on the queue execute after cancel. Reattach is non-cancellable.
   Fix: `isStopped` guard at top of handler; store DispatchWorkItem.
10. **CrossFileSearch symlink loop / DoS** — security.
    `Sources/ViewerCore/CrossFileSearch.swift:65`. `evil/loop -> .`
    loops indefinitely on a binary-only subtree. Fix: visited-inode
    set + hard walk cap.
11. **UTF-16 without BOM mis-classified as binary** — bugs.
    `Sources/ViewerCore/TextFileLoader.swift:101-107`. Common Windows
    files routed to hex view. Fix: probe `.utf16` encodings when
    `looksBinary` triggers.
12. **Drag-drop silently swallows missing files; multi-file order** — bugs.
    `Sources/ViewerUI/ContentView.swift:72-83`. Fix: collect + ordered
    open via openPath unconditionally.
13. **Cannot bookmark a folder; cannot remove non-open bookmark** — UX.
    `Sources/ViewerUI/DocumentModel.swift:154-160`,
    `Sources/ViewerUI/CommandPaletteView.swift:100-108`. Fix: extend
    bookmark target to include folders; hover-× in palette.

## Medium

14. **App menu missing Settings…/Cmd+,, menus out of HIG order** — UX.
15. **Sidebar visibility not persisted** — UX.
16. **SidebarKeyMonitor Esc unconditional pass-through** — UX.
17. **Palette / cross-search dismiss doesn't restore focus** — UX.
18. **Bookmark visual is just `★ ` text prefix** — UX.
    Use `star.fill` SF Symbol.
19. **No bookmark indicator on tab / ModeBar** — UX.
20. **No zoom indicator anywhere** — UX.
21. **Tab close × on the right + hidden until hover** — UX.
    macOS convention is left, always visible.
22. **CrossSearchPanel has no keyboard navigation** — UX.
23. **CrossSearchPanel result *line* rows are not clickable** — UX.
24. **Dismiss find bar leaves WKWebView highlights** — bugs.
25. **Cmd+F when find bar open should select query field** — UX.
26. **TOCTOU on file size in Text/BinaryFileLoader** — bugs.
27. **HTMLRenderer raw-HTML pass-through bypasses safeURL** — security.
    Mitigated by `allowsContentJavaScript=false` + nav allowlist.
    Defense-in-depth gap if those ever change.
28. **BookmarksStore size check after Data(contentsOf:)** — security.
    Defeats OOM defense. HistoryStore does it correctly.

## Medium — performance

29. **Markdown re-parsed on every @Published cascade**.
    `Sources/ViewerUI/ContentView.swift:107-115`. Memoize HTML by
    (url, contents) in DocumentModel.
30. **`textView.string != text` O(N) compare on every update**.
    `Sources/ViewerUI/TextDisplayView.swift:86`. Compare lengths first
    or track identity counter.
31. **`FuzzyMatcher.match` allocates per-char `.lowercased()`**.
    Pre-lowercase target & query.
32. **No debounce on cross-search or rendered find keystrokes**.
33. **Sync file load on main thread for large files**.
    `Sources/ViewerCore/TextFileLoader.swift`. Dispatch to background
    for files > 1MB.

## Low — polish / nits

34. **Dead file `Sources/ViewerUI/LineNumberRulerView.swift`**.
35. **`Selector(("openDocument:"))` string literals**.
    Brittle to renames; surface as DocumentModel methods.
36. **`makeModel()` test helper duplicated 11×**.
    Extract to `Tests/ViewerUITests/Support/TestHelpers.swift`.
37. **HistoryStore vs BookmarksStore near-duplicate persistence**.
    Extract `JSONFileStore<T>`.
38. **`MarkdownStylesheet.load()` is an identity wrapper around
    `cached`** — confusing API.
39. **`advanceFromCurrent` parameter unused** — remove.
40. **`viewModeBinding` `[weak self]`** redundant.
41. **`BookmarksStoreTests.test_maxEntries_capped` weak assertion**:
    `LessThanOrEqual` should be `Equal`.
42. **Magic numbers** scattered — collect into a `Metrics` namespace.
43. **PaletteRow text overlay uses `Color.white`** which clashes with
    some accent colors. Use `Color(nsColor: .alternateSelectedControlTextColor)`.
44. **CrossSearchPanel placeholder doesn't show folder name when one
    is open** — UX nit.
45. **`InteractionScriptTests` brittle class-name string matches
    (`"PlatformContainer"` etc) duplicated across files** — centralize.

## Notable strengths (no action)

- `FileWatcher` reattach + onLost + `maxReattachAttempts` is careful.
- `TabsState` is a clean value type with thorough round-trip tests.
- The CRIT-4 boundURL check in `reloadCurrentFile(matching:)` prevents
  stale watcher events from corrupting other tabs.
- `MarkdownRenderedView.Coordinator.decide` link allowlist is a tight,
  unit-testable allowlist (round-1 S4 / CRIT-1).
- Frame restoration defenses against missing displays / too-small
  frames are well-thought-out.
- TCC-protected-root opt-out for auto-restore is a thoughtful
  concession to macOS sandbox prompts.
- Git environment hardening (`core.hooksPath=/dev/null`, clean env,
  `protocol.file.allow=user`) is solid.
- Drag-drop locked to `[.fileURL]`; no custom URL scheme handlers.
- WKWebView navigation allowlist is tight (http/https/mailto only).

---

## Fix order

- **Batch 1** (this commit chain): items 1-8. All H, all small-effort.
- **Batch 2**: items 9-28 — concurrency hardening, edge cases,
  accessibility, UX polish.
- **Batch 3**: items 29-45 — performance + dedup refactors + nits.
