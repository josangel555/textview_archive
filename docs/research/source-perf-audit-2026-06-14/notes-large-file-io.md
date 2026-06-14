# Large-file / I/O notes

Covers file open/load, the large-read-only path, synchronous I/O on the
main/render path, and folder walks.

## Already good (do NOT re-file)

- **File loading is fully off-main.** Every open routes through
  `Task.detached(priority: .userInitiated)` → `DocumentController.open(url:)` /
  `TextFileLoader.load` / `BinaryFileLoader.load`, then hops to `MainActor.run`
  to store the result (`DocumentModel.swift:4280`, `:5022`, `:5272`, `:5314`).
  The `materializeTask` registry (`TabCoordinator.swift:124`) coalesces and
  cancels in-flight reads on tab churn. No sync `Data(contentsOf:)` on the main
  path.
- **Stat-before-read refusal.** `TextFileLoader.load` checks the on-disk size
  against `readableMaxBytes` BEFORE reading, so an over-ceiling file never
  allocates (`TextFileLoader.swift:170-178`). mtime is captured once at load and
  threaded into `TextFile` so derived caches (rendered HTML, highlight runs) key
  off it without re-stat'ing per body re-eval (`:185-191`).
- **Large-read-only path exists.** `isLargeReadOnly` (`> softWarnBytes`) flags
  big files so the UI can skip the O(N) line-index build (the `line == 0`
  sentinel the StatusBar comments reference) and the source view degrades
  gracefully.
- **`FileTreeService.children`** batches `.isDirectoryKey` / `.fileSizeKey` /
  `.contentModificationDateKey` into the single `contentsOfDirectory` resource
  call — no extra `fileExists`/`stat` per child (`FileTreeService.swift:61-86`).
- **`BinaryFileLoader`** reads at most `maxBytes` (it reads a bounded prefix
  rather than the whole file for the hex view).
- **`SelectionHighlightEngine`** takes a cached `haystackByteCount` so it doesn't
  re-walk `text.utf8` per selection change (`SelectionHighlightEngine.swift:72-78`).

## Findings

The I/O path itself is healthy. The large-file perf risk has **migrated to the
FFI seam**: the bytes are read off-main fine, but the *derived outputs* of the
big-file engines (hex render, markdown render) are copied through the FFI
receive-side `Array(UnsafeBufferPointer)` — see **finding #1** in
`notes-rust-core-ffi.md`. A 4 MB file → ~18 MB hex dump → copied whole into a
Swift `[UInt8]` and then `String(decoding:)`'d. That's the large-file cost worth
chasing, and it's the same fix as #1.

### Synchronous I/O sweep — what's on which thread

Greped `Data(contentsOf:)` / `String(contentsOf:)` / `contentsOfDirectory`
across `Sources/`. The ones on potentially-hot paths:

- **`StatusBar` git chip** reads `.git/HEAD` synchronously on the body path
  (`SessionGitInfo.footerLabel`) — covered as finding #12 (small file, OS
  page-cache-served; low priority, but it's the one uncached filesystem read
  left on the status-bar body path).
- **`ClaudeTimelineSection.swift:167`**, **`LSPOutlineSection.swift:95`**,
  **`MermaidBundle.swift:48`**, **`MarkdownRenderedView.swift:872`** — these are
  in `.task`/async or one-shot setup contexts, not per-body. Checked; not hot.
- **`CrossFileSearch.swift:214`** `Data(contentsOf:)` per file — this is the
  single-threaded search body (finding #5); it's already off-main (the caller
  runs it on a worker), the issue is it's *single*-threaded.

No sync file read was found on the SwiftUI `body` / render main path except the
git-chip `.git/HEAD` read (#12). Good.

### Folder walks

- `CrossFileSearch` and `searchFilenames` cap entries at 50k and guard symlink
  loops with a canonical-path `Set` (`CrossFileSearch.swift:152`, `:310`) —
  correct, but note the `url.resolvingSymlinksInPath().standardizedFileURL.path`
  per directory is itself a syscall-ish normalization done for *every* directory
  entry (`:191`, `:336`). On a deep tree that's a lot of path canonicalization.
  Minor; only matters if profiling shows the walk (not the read) dominating.
  Not filed separately — folds into the #5 parallelization work (the canonical
  set stays in the serial walk).

## Summary

The large-file story is: **read path = healthy and off-main; the remaining
large-file cost is the FFI receive-side copy of big derived outputs (#1) and the
single-threaded cross-file search (#5).** Both are already captured as findings;
no separate IO-specific ticket is needed beyond those.
