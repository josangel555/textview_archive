# Adversarial Performance Review — 2026-06-18

Hunt for real per-keystroke / per-frame / per-body recompute, quadratic hot paths, synchronous main-thread I/O, and redundant work in TextView / MarkdownViewer (Swift `Sources/` + Rust `rust-core/`). The codebase is, on the whole, carefully optimized — many hot paths (find highlight, selection highlight, sidebar sort, rendered-HTML, syntax tokenize) already carry caches, throttles, off-main hops, and signposts with documented rationale. The findings below are the places where a cache key is wrong (perpetual miss), heavy work was left on the main thread, a port lost the original's data structure, or a remote endpoint omits the guards its host twin has. They are ordered roughly by impact.

### StatusBar re-encodes + rescans the whole editor buffer on every keystroke (cache always misses)

**Severity:** high

**Location:** `Sources/ViewerUI/StatusBar.swift:506-519` (editor-mode branch of `currentMetrics`) → `Sources/ViewerUI/StatusBar.swift:568-595` (`metrics(for:)`)

**Why:** `StatusBar` observes `tabCoordinator` directly, and its own doc comment (line 28-29) states "every editor keystroke mutates `editorBuffers`" — so the `StatusBar` body re-evaluates on every keystroke while editing. In editor mode `currentMetrics` does, per body eval:
1. `buf.text.data(using: buf.encoding)?.count` (line 508) — allocates a **full encoded copy of the entire buffer** just to count bytes, then throws it away.
2. `Self.metrics(for: bufferFile)` (line 517) which runs `lineCount` (full UTF-8 scan), `f.contents.utf16.count`, `LineEndingDetector.displayString`, and `RustIndentAdapter.detect` (an FFI round-trip that scans the document).

The `metrics(for:)` cache (line 569-575) is keyed on `(url, byteCount)`. Because `byteCount` changes on essentially every keystroke that adds/removes a character, the cache is a **perpetual miss during editing** — and the editor-mode branch builds a fresh `bufferFile` and calls `metrics(for:)` unconditionally, so even a no-length-change keystroke pays the full re-encode + scan. On a multi-hundred-KB file this is a full-document re-encode + multi-pass scan + FFI call **per keystroke on the main thread**, exactly the kind of typing-latency tax the rest of the file works hard to avoid.

**Fix:** Don't re-encode the buffer to `Data` to get a byte count — track the byte count incrementally in `EditorBuffer` (it already owns the text and encoding), or count UTF-8 code units (`buf.text.utf8.count`, no allocation) which equals the on-disk byte count for UTF-8 (the common case). Debounce the editor-mode metrics recompute (e.g. coalesce to ~150ms, like the selection-highlight throttle) so a burst of keystrokes recomputes once. Or cache metrics keyed on a cheap content fingerprint that the editor already bumps, and short-circuit when the line count / indent can't have changed (e.g. only re-detect indent when a newline or leading-whitespace edit occurred).

**CONFIRMED** — `StatusBar` observes `tabCoordinator` directly (line 28-29 doc comment confirms "every editor keystroke mutates `editorBuffers`"); `currentMetrics` (line 508) does `buf.text.data(using:)?.count` (full encode) then unconditionally calls `metrics(for:)` keyed on `(url, byteCount)` (line 569-570) which changes per char ⇒ perpetual miss + full re-scan + `RustIndentAdapter.detect` FFI per keystroke on the main thread.

### `canShowFileHistory` spawns a `git` subprocess on the main thread from context-menu / menu-validation builders

**Severity:** high

**Location:** `Sources/ViewerUI/DocumentModel.swift:2138-2143` (`canShowFileHistory`, `@MainActor`) — `GitClient.isTracked` runs `git ls-files` (`Sources/ViewerCore/Git/GitClient.swift:102-105`). Callers: `Sources/ViewerUI/SidebarView.swift:1134`, `Sources/ViewerUI/TabBar.swift:312`, `Sources/MarkdownViewer/main.swift:2810`.

**Why:** `canShowFileHistory` is `@MainActor` and synchronously does `GitClient.discoverRoot(from:)` (a filesystem walk up the directory tree) plus `GitClient(...).isTracked(path:)` (which **spawns a `git ls-files` child process** and waits for it). It is wired into `.disabled(!model.canShowFileHistory(for:))` inside the sidebar row context menu and the tab context menu, and into the app menu validation. Process spawn + `waitUntilExit` is multiple milliseconds even on a warm repo, and is unbounded on a slow/large/network repo (it has a default `statusTimeout` but the default `GitClient(repoRoot:)` initializer here uses the standard timeout, and even a fast-but-slowish spawn stalls the main run loop). Right-clicking a file, or the menu bar re-validating its items, fires a synchronous git process on the UI thread — a visible hitch / beachball risk, and it repeats every time the menu is opened.

**Fix:** Make the menu-enable predicate cheap and synchronous: cache `(repoRoot, tracked-set)` per repo (invalidated on HEAD/index change, like the existing HEAD-keyed stats cache) so the menu reads a `Set.contains` instead of spawning. Or render the menu item unconditionally enabled and resolve tracked-ness asynchronously inside `openFileHistory` (which already no-ops when untracked), so the synchronous git spawn never sits on the menu-build / validation path.

**CONFIRMED** — `canShowFileHistory` (DocumentModel.swift:2138, `@MainActor`) does `GitClient.discoverRoot` (tree walk) + `isTracked` (GitClient.swift:102-104) which calls `run(["ls-files", …])` — a real subprocess spawn + `waitUntilExit`. Wired into `.disabled(!model.canShowFileHistory(...))` in the sidebar (SidebarView.swift:1134) and tab (TabBar.swift:312) context menus, evaluated when the menu opens. `openFileHistory` already re-checks tracked-ness, so unconditional-enable + async resolve is viable.

### Rust `search.files` recompiles the regex once per file and never skips `.git` / `node_modules` / build dirs

**Severity:** high

**Location:** `rust-core/crates/serve/src/search.rs:84-141` (the walk loop) calling `rust-core/crates/core/src/find_engine.rs:85-88` (`RegexBuilder::new(&pat).build()` inside `search`).

**Why:** The cross-file search endpoint walks the served tree and calls `find_engine::search(&text, &req.query, …)` per file (line 115). `find_engine::search` **builds the regex from scratch on every call** (`escape_literal` + `RegexBuilder::new().build()` at `find_engine.rs:79-88`). With `MAX_FILES = 10_000`, a single query recompiles the same pattern up to 10,000 times. Worse, the directory walk (line 84-98) pushes every subdirectory unconditionally — it does **not** skip `.git`, `node_modules`, `target`, `.build`, etc. So a search over a real repo descends into `.git` (thousands of loose objects) and `node_modules` (tens of thousands of files), reads + UTF-8-decodes each up to the 4 MiB cap, then recompiles + runs the regex on each. The Swift twin (`Sources/ViewerCore/CrossFileSearch.swift`) gets both right: it compiles the matcher **once** and shares it across files (line 82-83), and it skips well-known build/VCS dirs (`options.skipDirNames`, line 237). The Rust remote endpoint is the inferior twin.

**Fix:** Compile the regex once in `serve/search.rs::dispatch` and pass the compiled matcher (or a closure) into a per-file matching function, instead of calling `find_engine::search` (which re-compiles) per file. Add a skip-list for `.git`, `node_modules`, `target`, `.build`, `dist`, etc. before `stack.push(path)` at line 96 — mirror `CrossFileSearch.skipDirNames`. This turns the common-case search from O(files × pattern-compile) + walking junk dirs into O(files) + one compile.

**CONFIRMED** — `search.rs:115` calls `find_engine::search` per file inside the walk loop; `find_engine::search` rebuilds the regex via `RegexBuilder::new(&pat).build()` on every call (find_engine.rs:85-88, `escape_literal`/`pat` set at 78-84). Walk loop pushes every dir unconditionally (`stack.push(path)`, search.rs:96) with no skip-list. Swift twin compiles `Matcher` once (CrossFileSearch.swift:76-89) and skips dirs (`options.skipDirNames.contains`, line 237). Rust is the inferior twin.

### O(N²) heading-slug dedup in the Rust markdown engine (Swift original used a hash map)

**Severity:** medium

**Location:** `rust-core/crates/core/src/markdown.rs:447-473` (`unique_slug`), backing field `used_slugs: Vec<(String, u32)>` at line 129.

**Why:** `unique_slug` is called once per heading. For each heading it does `self.used_slugs.iter_mut().find(|(s, _)| *s == slug)` (line 467) — a **linear scan over all previously-seen slugs**, each comparison being a full `String` equality. For a document with N headings this is O(N²) string comparisons. Auto-generated docs, API references, changelogs, and large tables-of-contents routinely have hundreds-to-thousands of headings, where this becomes the dominant cost of the markdown render. This is also a **regression versus the Swift original it claims to port exactly**: `Sources/ViewerCore/HTMLRenderer.swift:172` uses `var usedSlugs: [String: Int]` — an O(1) hash lookup. The port swapped the data structure for a Vec and lost the asymptotics.

**Fix:** Change `used_slugs` to a `HashMap<String, u32>` (or `BTreeMap` if deterministic iteration is needed elsewhere — it isn't here) and replace the linear `find` with a single map lookup/insert, matching the Swift original. (Note: there is also a latent correctness gap — the suffixed `"{slug}-{n}"` is never inserted, so a base slug colliding with another heading's suffixed form can still produce duplicate ids — worth fixing in the same pass, but out of scope for this perf dimension.)

**CONFIRMED** — `used_slugs: Vec<(String, u32)>` (markdown.rs:129; comment literally says "Vec keeps it Hash-free") with `iter_mut().find(|(s, _)| *s == slug)` per heading (line 467) ⇒ O(N²) on heading count. Swift original uses `var usedSlugs: [String: Int]` (HTMLRenderer.swift:172), an O(1) hash. The port lost the asymptotics. The latent suffix-not-inserted correctness gap also holds.

### Claude monitor `filteredSessions` re-filters + re-sorts (with per-session `lowercased()` allocations) on every body eval and keystroke

**Severity:** medium

**Location:** `Sources/ViewerUI/ClaudeMonitor/ClaudeMonitorView.swift:110-126` (`filteredSessions` computed property), consumed at line 418 (`ForEach(model.filteredSessions)`) and the keyboard-nav helpers.

**Why:** `filteredSessions` is a plain computed property: each access lowercases the search needle, then for a non-empty needle calls `s.title?.lowercased()`, `s.cwd?.lowercased()`, and `s.projectDirName.lowercased()` for **every** session (line 117-121, three fresh String allocations per session), then `.sorted` the whole list (line 123-125). It is read inside the `ForEach` and the nav helpers, so it recomputes on every body re-evaluation and on every keystroke into the search field. For a heavy Claude user with thousands of sessions on disk, each character typed re-lowercases and re-filters all of them and re-sorts — O(N log N) plus 3N string allocations per keystroke on the main thread. The sort in particular is redundant work even on the empty-needle path: the full list is re-sorted on every body eval.

**Fix:** Sort `sessions` once when it's assigned (it's set from the off-main scan in `loadSessions`, line 144) and keep it sorted, so `filteredSessions` only filters. Precompute lowercased title/cwd/projectDir per `ClaudeSessionSummary` once at index time (store the folded strings alongside the originals) so per-keystroke filtering is `contains` against pre-folded strings with zero allocation. Optionally debounce `searchText` so a fast typist filters once per pause rather than per character.

**CONFIRMED** — `filteredSessions` (ClaudeMonitorView.swift:111-126) is a plain computed property: per-session `s.title?.lowercased()`/`s.cwd?.lowercased()`/`s.projectDirName.lowercased()` (3 allocs/session, line 118-120) on a non-empty needle, then `.sorted` the whole list unconditionally (line 123-125) — the sort runs even on the empty-needle path. Recomputes on every body eval / keystroke; `sessions` is assigned once in `loadSessions` (line 144) and could be pre-sorted/pre-folded.

### Hex search runs a full-buffer scan synchronously on the main thread per keystroke (no debounce)

**Severity:** medium

**Location:** `Sources/ViewerUI/HexView.swift:110-111` (`.onChange(of: searchQuery)/(searchMode) { recomputeMatches() }`) → `Sources/ViewerUI/HexView.swift:208-238` (`recomputeMatches`), `RustHexSearchAdapter.search(... in: file.data)` at line 233.

**Why:** Every change to the hex search field calls `recomputeMatches` synchronously on the main thread, which runs `RustHexSearchAdapter.search` over the **entire** `file.data` buffer (up to the multi-MB hex cap). There is no debounce on `searchQuery`, so a fast typist triggers a full multi-MB scan per character on the UI thread. The retained match list is capped (`HexMatchCap`, good) but the *scan itself* is not deferred or coalesced — it blocks the run loop for the duration of each scan. The find bar in the text view, by contrast, throttles its selection-highlight pass (`scheduleSelectionHighlightRefresh`, ~150ms) precisely to avoid per-keystroke full-document work.

**Fix:** Debounce `searchQuery` changes (coalesce to ~150ms) before invoking `recomputeMatches`, and/or run the scan on a background queue and hop the (capped) results back to the main actor — the scan is over an immutable `Data` snapshot so it's trivially offloadable. This keeps typing responsive on large binaries.

**CONFIRMED** — `.onChange(of: searchQuery) { recomputeMatches() }` (HexView.swift:110) calls it synchronously; `recomputeMatches` runs `RustHexSearchAdapter.search(searchQuery, mode:, in: file.data)` over the full buffer (line 233) with no debounce/coalescing. The match list is capped (`HexMatchCap`) but the scan itself is unguarded — full multi-MB scan per keystroke on the main thread.

### Rust fuzzy matcher reallocates `Vec<char>` for query and target on every candidate

**Severity:** low

**Location:** `rust-core/crates/core/src/fuzzy.rs:55-56` (`let q: Vec<char> = query.chars().collect(); let t: Vec<char> = target.chars().collect();`).

**Why:** `match_query` collects both the query and the target into freshly-allocated `Vec<char>` on every invocation. In the command-palette / file-filter use case it is called once per candidate per keystroke; over a corpus of thousands of candidates, the per-candidate `target.chars().collect()` is unavoidable-ish, but `query.chars().collect()` is recomputed identically for every candidate in the batch even though the query is constant across the batch. The batch adapter (`RustFuzzyAdapter`) drives many candidates against one query, so the query Vec is rebuilt N times per keystroke for no reason. (The scoring loop itself is correctly O(target) single-pass.)

**Fix:** Hoist query parsing out of the per-candidate call — add a batch entry point that collects the query `Vec<char>` (and its lowercase folding, if precomputable) once, then scores each target against the shared query slice. The target `Vec<char>` can also be avoided by iterating `target.char_indices()` directly, since the matcher only needs forward scalar iteration plus the previous char for the boundary bonus.

**CONFIRMED** — `match_query` collects `q`/`t` into fresh `Vec<char>` per call (fuzzy.rs:55-56). The batch entry `rank` (line 106-118) calls `match_query(query, c)` once per candidate (line 113), so the constant query Vec is rebuilt N times per keystroke. Low impact (the filename corpus is bounded), but real redundant work — confirmed as the low-severity finding it's labeled.
