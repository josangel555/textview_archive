# Curated Active Tasks — 2026-06-19

> ## ✅ 2026-06-19 PM — most of this list MERGED TO MAIN
> The ultracode backlog-drain wave (~80 of these items) landed on `main` (ff `bd1f8ca`→`d4a8612c`,
> **116 commits**, headless gate green 7329/0, `/Applications` rebuilt). The merged items are at
> `fixed` on the board (owner closes `validated→done`); per-item SHAs are in the lane `.output`s +
> `docs/AUTONOMOUS_PROGRESS.md` (2026-06-19 PM). **Still OPEN / re-land:** tmux 964 (TSK-1018 controller
> + a model-reconcile — incompatible parallel `PaneNode` designs), CSV inline-editor wiring (TSK-1019),
> 897 TreeSitter grammars (need the owner-approved dep + a non-sandbox build), 704 Markdown side-by-side
> (re-retrying), and the owner-gated / deprioritized sections below. Next: drain those + the remaining
> board pools.

**The go-forward list** for TextView / MarkdownViewer. Reconciled on 2026-06-19 from the
live `tasked` board (source of truth for state), folding in + superseding the old
`WORK_QUEUE.md` and `docs/NEXT_30_TASKS_2026-06-18.md`. The completed archive is
[`docs/COMPLETED_ARCHIVE_2026-06-19.md`](./COMPLETED_ARCHIVE_2026-06-19.md).

**Scope:** every board task in state `reported` / `ack` / `triaged` / `progress`, plus the
remaining slice of any `[~]` partial whose body shipped to `review`. Foreign projects
(wx-globe, forge, tasked-tool-dev) and `wontdo` tickets are excluded.

## Flags
- `[in-flight]` — being implemented right now by one of the 4 running workflows.
- `[owner-gated: …]` — needs an owner decision/approval/repro; do NOT autonomously guess.
- `[needs-VM-trace]` — needs an Instruments/`vm-profile.sh` attribution before coding (measure-don't-guess).
- `[needs-VM-render]` — host-build the model + host-test; render/interaction validated on the VM.
- `[host-buildable]` — fully buildable + testable on the host.

Within each group, ordered by **value × tractability** (do-first at top).

---

## 🐞 Bugs (broken user-facing behavior)

1. **TSK-921** — Can't close a split pane (close button wired; event-routing repro) — small, completes the 922 pair — `[needs-VM-render]`
2. **TSK-894** — Current-line highlight stuck after drag-select (CM6) — `fixed`, awaiting VM close — `[needs-VM-render]`
3. **TSK-896** — Hovered-row highlight offset by several lines (CM6) — `fixed`, awaiting VM close — `[needs-VM-render]`
4. **TSK-895** — Horizontal scrollbar flickers while typing (CM6) — interaction-state bug — `[needs-VM-render]`
5. **TSK-910** — Git diff only one line selectable → multi-line — `fixed` (per-hunk AttributedString design) — `[needs-VM-render]`
6. **TSK-728** — Enter in plain-text editor shifts focus to prev tab — `review`, key-routing — `[needs-VM-render]`
7. **TSK-730** — Editor missing standard key navigation (Arrow/Cmd-Arrow/PageUp/Home/End) — `review` — `[needs-VM-render]`
8. **TSK-969** — H4 stale/out-of-order async clobbers git-chip menu (last-writer-wrong) — correctness — `[in-flight]` `[host-buildable]`
9. **TSK-960** — Right-docked terminal no longer composites in right column (regression) — compositor — `[needs-VM-render]`
10. **TSK-602-residual / 962** — Highlighting parity View↔Edit + all langs get same coding features — `[host-buildable]`
11. **TSK-361** — Large jupyter notebook click hangs app — `review`, confirm fix holds — `[needs-VM-render]`
12. **TSK-1017** — ⭐owner-2026-06-19: scroll state LOST on session switch (very annoying) → durable per-file scroll+zoom memory across session switch & after close (sqlite/buffer, size-capped, only-if-scrolled/zoomed); builds on 743/821 (in-session) — `[host-buildable]` (the store + save/restore-decision is host-testable; the restore render = VM)

## ⚡ Perf

### Host-buildable (rust-core / Swift; real wins, confirmed by code-read)
1. **TSK-826** — FFI receive-side double-copies every response frame — decode directly from MdvBuf — `[host-buildable]`
2. **TSK-543** — `cm_apply` ships the FULL doc across FFI both ways per edit batch (~10× tick traffic) — `[host-buildable]`
3. **TSK-827** — `TreeSitterEngine.tokenize` bridges whole file → NSString + per-predicate substring — `[host-buildable]`
4. **TSK-564** — Swift boundary double full-copy of every response frame — `progress` (claimed), finish it — `[host-buildable]`
5. **TSK-971** — H5 StatusBar re-encodes + rescans whole buffer per keystroke (cache always misses) — `[in-flight]` `[host-buildable]`
6. **TSK-972** — H6 `canShowFileHistory` spawns git subprocess on main thread from menu validation — `[in-flight]` `[host-buildable]`
7. **TSK-973** — H7 Rust `search.files` recompiles regex per file + never skips .git/node_modules/build — `[in-flight]` `[host-buildable]`
8. **TSK-984** — M9 O(N²) heading-slug dedup in Rust markdown engine — `[in-flight]` `[host-buildable]`
9. **TSK-985** — M10 Claude monitor filter re-sorts + per-session lowercased() allocs per keystroke — `[in-flight]` `[host-buildable]`
10. **TSK-986** — M11 Hex search full-buffer scan on main thread per keystroke (no debounce) — `[in-flight]` `[host-buildable]`
11. **TSK-996** — L-perf1 Rust fuzzy matcher reallocs Vec<char> per candidate — `[in-flight]` `[host-buildable]`
12. **TSK-830** — Micro-opt bundle (kind.to_string, class lowercasing, dict rebuild) — `review`, close out — `[host-buildable]`
13. **TSK-845** — Micro-bundle 2 (ContentFingerprint ×3, MsgPackReader tree, lazy-tab) — `triaged`, profile-gated — `[needs-VM-trace]`

### Need a VM/Instruments trace first (measure-don't-guess)
14. **TSK-892** — File-tree hover slow (per-hover compute) — host already optimized; needs trace — `[needs-VM-trace]`
15. **TSK-889** — ~699KB JSON warm re-open lag — root-caused, view-preservation designed (see commit b9d2867e) — `[needs-VM-trace]`
16. **TSK-890** — CM6 drag-selection slow — `[needs-VM-trace]`
17. **TSK-891** — Page-Up janky (CM6) — `[needs-VM-trace]`
18. **TSK-839** — Per-nav main-thread CoreAnimation commit stall (30–366 ms) — the REAL felt nav-slow root — `[needs-VM-trace]`
19. **TSK-887-residual** — Palette typing: bare-mode `merged()` rebuild per keystroke (cache on open) + full trace — `[needs-VM-trace]`
20. **TSK-888-residual** — Global search common-case scroll trace if still felt — `[needs-VM-trace]`

### Architectural perf (spike + slices)
21. **TSK-838** — Rendered-MD WKWebView: persistent page + DOM-patch vs full `loadHTMLString` reload (2–9s storm) — biggest perf lever — `[host-buildable]` (spike first)

## ✨ Features

### Cheap / high-value (host glue)
1. **TSK-912** — Surface code-review comment add/list UI (engine built; hidden affordance) — `[host-buildable]`
2. **TSK-302** — CSV arrow-key cell nav + ⌘C copies cell (`CSVCellCursor` exists) — `progress` (claimed) — `[needs-VM-render]`
3. **TSK-303** — Find support in the table view — `fixed`, close out — `[needs-VM-render]`
4. **TSK-668** — Wire CSV table → windowed-snapshot paging (backend exists) — `[needs-VM-render]`
5. **TSK-924-residual** — CSV arbitrary shift-select rectangle (no cursor wiring yet) — `[needs-VM-render]`
6. **TSK-307-residual** — Bookmarks "open in new view/window" affordance (scope filter shipped) — `[host-buildable]`
7. **TSK-811** — "View as" affordance redesign — per-filename lock icon (split from 732) — `[needs-VM-render]`
8. **TSK-466-residual / 463** — Wire LSP completion to the editor — `463 fixed`, verify wired — `[needs-VM-render]`
9. **TSK-705-residual** — Snippets: CM6 Tab-key wiring + management UI (model complete) — `[needs-VM-render]`
10. **TSK-727-residual** — Goto Anything: code-file `@` via LSP documentSymbols (core complete) — `[needs-VM-render]`
11. **TSK-679-residual** — VIM modal editing: VM keystroke smoke (core shipped) — `[needs-VM-render]`
12. **TSK-358-residual** — Window sizing half (font-size slice shipped) — `[host-buildable]`
13. **TSK-898** — Render|Editor|HEX segmented button (pure visual restyle) — `fixed`, VM-confirm — `[needs-VM-render]`
14. **TSK-1016** — ⭐owner-2026-06-19: session tab name = current root folder, auto-updating as the root changes (e.g. Open Folder from File-Nav right-click) — `[host-buildable]` (root-URL→tab-title derivation + re-label-on-root-change wiring; manual rename TSK-931 should override)

### Medium features
14. **TSK-319** — Dependency Package explorer (pairs with shipped 280 graph) — `[host-buildable]`
15. **TSK-318** — Ask-the-agent about a Code Review (CR Q&A) — `[host-buildable]`
16. **TSK-305-equiv / 495** — Unified tool-window placement: any tool window → any shoulder, drag-drop — `[needs-VM-render]`
17. **TSK-368** — Terminal tool window with tabs (umbrella; pieces shipped) — `[needs-VM-render]`
18. **TSK-373** — New → Code review / Agent session / Project view — `progress` (claimed) — `[needs-VM-render]`
19. **TSK-704** — Markdown side-by-side editor + live preview — `[needs-VM-render]`
20. **TSK-722** — Task/command runner (run tests & npm/package scripts) — epic — `[host-buildable]`
21. **TSK-712** — 3-way merge — epic — `[host-buildable]`
22. **TSK-715** — Profiling / memory diffs / flame charts (webpack-analyzer style) — epic — `[host-buildable]`
23. **TSK-723** — Structural search — epic — `[host-buildable]`
24. **TSK-677-equiv** — Unify search types (Global / Recents / Command) — `677 fixed`; integration polish — `[host-buildable]`
25. **TSK-685-equiv** — Spell check / Grammar follow-through (epic fixed; verify surfaces) — `[needs-VM-render]`
26. **TSK-708-equiv** — Preview definition (Cmd+Y) — `fixed`, verify — `[needs-VM-render]`
27. **TSK-708/746** — Open dialog show recents — `reported`, low-value (NSOpenPanel limits) — `[host-buildable]`

### Bigger / epics (file-and-slice)
28. **TSK-675** — Text-edit power ops: line dup/move/delete, column/block select, macro record-replay, insert/overwrite — `triaged`, slices 1-5 shipped — `[host-buildable]`
29. **TSK-264** — Sessions optional (run without the session system) — `[host-buildable]`
30. **TSK-265** — Multi-window session support — `[host-buildable]`
31. **TSK-670-equiv** — PDF reader follow-through (epic fixed; polish) — `[needs-VM-render]`
32. **TSK-711** — CSV table editor (editable cells) — epic — `[needs-VM-render]`
33. **TSK-716** — Better worktree-management UX — epic — `[host-buildable]`
34. **TSK-713** — Diagram formats beyond Mermaid/Dot — epic — `[host-buildable]`
35. **TSK-717** — Notebooks (multi-kernel Python+Kotlin) with LSP + storage — epic — `[host-buildable]`
36. **TSK-706** — RichText editor (Docs-style restricted MD subset) — epic — `[needs-VM-render]`
37. **TSK-703** — Unified action history (all actions reversible) + history view — epic — `[host-buildable]`
38. **TSK-768 / 764** — Editor disk-update highlight + local/disk conflict undo (future merge) — epic — `[host-buildable]`

### In-flight epics (the running workflows)
39. **TSK-963** — Productionalize LSP subsystem: discovery, visibility, integration, organization — `[in-flight]` `[host-buildable]`
40. **TSK-964** — Full tmux -CC control-mode native integration (iTerm2-style) — `[in-flight]` `[host-buildable]`

## 🧱 Tech-debt / test-infra

1. **TSK-818** — VM key-synthesis (T4) lane — unblocks validating the whole CM6/AppKit key-routing bug tail (894/896/921/730/728) — force-multiplier — `[host-buildable]`
2. **TSK-849** — Trim test sleeps + shard subprocess-tail classes (~22s run-floor cut) — `[host-buildable]`
3. **TSK-850-residual** — Shared TestSupport SwiftPM target for ViewerUITests git classes — `review`, owner-judgment on gain — `[host-buildable]`
4. **TSK-836-residual** — Split the slowest swift-test classes (capture half shipped) — `review` — `[host-buildable]`
5. **TSK-586** — rust-core shared golden corpus + differential fuzzing (Swift/TUI/Web parity) — `[host-buildable]`
6. **TSK-588** — Perf-floor ratchet bench + periodic cargo-mutants teeth audit — `[host-buildable]`
7. **TSK-573** — core::theme palette: web hardcodes its own ~30-color palette vs the contract — `triaged` — `[host-buildable]`
8. **TSK-498** — rust-core tui/web test suites are outside the merge gate — `reported`, owner-decision on gate cost — `[owner-gated: CI policy]`
9. **TSK-855** — RemoteTransportLoopbackTests spawns a STALE mdv-serve binary (gate rebuild gap) — `review` — `[host-buildable]`
10. **TSK-382** — Squeeze DocumentModel memory — `triaged`, needs VM memory-profile — `[needs-VM-trace]`
11. **TSK-492** — Deterministic UI-scene control + real-pixel visual eval harness — `triaged` — `[host-buildable]`
12. **TSK-1012 / 1013** — L-test1/2 windowed-CSV snapshot + parseTimestamp non-finite test gaps — `[in-flight]` `[host-buildable]`
13. **TSK-308** — DocumentModel SRP split (architectural) — `reported`, deferred — `[host-buildable]`

## 🔒 Security ([in-flight] — the 2026-06-18 adversarial review wave, TSK-965..1015)

All from `docs/research/adversarial-review-2026-06-18/FINAL.md`; the security-fix workflow
is implementing these now. Ordered by severity. **All `[in-flight]` `[host-buildable]`** unless noted.

### Critical / High
1. **TSK-965** — C1: MessagePack decoder no recursion-depth limit → remote SIGSEGV (uncatchable DoS)
2. **TSK-968** — H2: `sqlite3_bind_text` dangling pointer (use-after-free)
3. **TSK-966** — H1: Stored XSS in exported / browser-opened HTML (no CSP; sanitizer is sole defense)
4. **TSK-967** — H1b: HTMLSanitizer event-handler + javascript-URL regex bypasses
5. **TSK-970** — H3: RepoStatsCache actor blocks its serial executor on synchronous git walks
6. **TSK-974** — H8: Swift grammar deps use caret ranges (violates exact-pin policy)
7. **TSK-975** — H9: Supply-chain audit (cargo-audit/cargo-deny) never gates a PR
8. (H4/H5/H6/H7 are TSK-969/971/972/973 — see Bugs/Perf groups above)

### Medium
9. **TSK-976** — M1: RemoteTransport subscription handler can fire after unsubscribe (use-after-teardown)
10. **TSK-977** — M2: MCPServer.runOnMainActor parks reader thread on a no-deadline semaphore
11. **TSK-978** — M3: NSRange from unchecked remote highlight offset: Int(UInt64) traps
12. **TSK-979** — M4: PTY child does non-async-signal-safe work between forkpty() and execve()
13. **TSK-980** — M5: LSP lsp.json override — untrusted repo args/env reach the trusted server
14. **TSK-981** — M6: snapshotWindow discards rich WireError out-buffer
15. **TSK-982** — M7: Skewed envelope method-id reports Internal, indistinguishable from a fault
16. **TSK-983** — M8: Hand-rolled JSON number parser accepts malformed numbers (A/B parity gap)
17. **TSK-987** — M12: Remote-core unbounded orphan-event dict keyed by attacker sub id (OOM)
18. **TSK-988** — M13: RemoteTransport read/write treat EINTR as fatal
19. **TSK-989** — M14: StatusBarMemorySampler Timer no deinit backstop
20. **TSK-990** — M15: GitPanelModel 60s Timer + in-flight Tasks no deinit backstop
21. **TSK-991** — M16: SidebarModel.pruneChildrenCacheIfNeeded can't enforce cap when expanded dirs exceed it

### Low (L-* cluster)
22. **TSK-992 … TSK-1011** — concurrency (992/993), remote-transport (994/995/1010), perf (996),
    security (997/998/999/1000/1001/1003), terminal/hex/mem bugs (1002/1004/1005/1006/1007),
    error-handling sinks (1008/1009), data-integrity cluster (1011 — hot-exit clobber, no-fsync, >1MiB drop)
23. **TSK-1014** — L-api1: tree-sitter-swift pinned to bare git revision (no tag) — `[owner-gated: dep pin]`
24. **TSK-1015** — L-api2: dead-but-exported FFI surface (per-method symbols + CSV-session family) — cleanup

## 🦀 Rust-core (non-security, host-buildable)

1. **TSK-543** — cm_apply full-doc FFI traffic (also in Perf) — `[host-buildable]`
2. **TSK-826** — FFI receive-side whole-frame copy (also in Perf) — `[host-buildable]`
3. **TSK-399** — memchr SIMD substring for filter + hex_search — `reported` — `[owner-gated: dep-approval]`
4. **TSK-400 / 651** — mdvcore-rpcd remote server spike + epic (most of the wire work shipped) — `[host-buildable]`
5. **TSK-256 / 250 / 409** — [PORT][WEB] markdown render / multi-tab / command palette tail — last-resort per SOP — `[host-buildable]`
6. **TSK-379** — Rust Core migration umbrella — `reported`, tracking shell — `[host-buildable]`

## 🔓 Owner-gated (surface, don't autonomously guess)

- **TSK-854** — Delete the Swift highlight twin → reclaims ~16 MB double-carried grammars — `[owner-gated: no Rust fold path yet]`
- **TSK-835** — `cargo-nextest` for the rust gate (~30–60% off test phase) — `[owner-gated: dep-approval]`
- **TSK-851** — ccache/sccache for TreeSitter C grammars (~165 MB regen/clean build) — `[owner-gated: dep-approval]`
- **TSK-831** — Disable IDE background indexing (−1.7 GB build) — `[owner-gated: affects jump-to-def]`
- **TSK-852** — CI: cache `.build` keyed on resolved deps + source hash — `[owner-gated: CI policy]`
- **TSK-584 / 585 / 587** — rust fuzzing / property-test / WASM lanes — `[owner-gated: dep-approval]`
- **TSK-589** — Session eviction policy for the multi-document runtime — `[owner-gated: decision]`
- **TSK-810** — Stage-B carve-out (hexSearch/hex can't fully delete) — fallback model? — `[owner-gated: decision]`
- **TSK-897-grammars** — Which TreeSitter grammars + bundle-size budget (897 lang-map fixed) — `[owner-gated: dep-approval]`
- **TSK-956-VST** — Add VST hosting? (AU + CoreMIDI shipped) — `[owner-gated: decision]`
- **TSK-936** — Shortcut to toggle View-only mode (collides ⇧⌘R) — `[owner-gated: pick keys]`
- **TSK-470** — Zoom split: UI-chrome zoom vs document zoom — `[owner-gated: decision]`
- **TSK-709** — Unify Cmd+K / Cmd+G — `[owner-gated: ⌘G is standard Find-Next]`
- **TSK-751** — Organize the menu items "properly" — `[owner-gated: undefined]`
- **TSK-791** — "Was CM6 a mistake? Why is the editor slow?" — `[owner-gated: direction]` (informed by 890/891 traces)
- **TSK-343** — Image History / Revert — `[owner-gated: needs repro]`
- **TSK-733** — Save-prompt on session switch despite autosave — `[owner-gated: needs repro]`
- **TSK-301** — View local history — `progress`/owner-decision — `[owner-gated: decision]`
- **TSK-775 / 779 / 780 / 781 / 786 / 787 / 788** — Rust migration plan / plugin-decomposition / what-to-cut / LSP-own-vs-external / build-speed / test-framework / test-audit — `[owner-gated: question/direction]`
- **TSK-792–805** — Research questions (modern features, scripting, WASM, monitoring, …) — `[owner-gated: question]` (several already answered → review)

## ⏸ Deprioritized / aspirational (kept for record, not actively pulled)

- **Paint/Photo-editor epic:** TSK-320 / 380 / 403–406 (canvas/brush/picker/fill/selection) — big.
- **Agent integration suite:** TSK-940–945 (review/approve agent diffs, line-ref-to-agent, LSP/diag share, browser MCP, security-audit) + TSK-687 / 693 / 697 / 699.
- **Very-large / aspirational:** TSK-689 (PinBoard), 691 (own agent harness), 694 (log clustering), 695 (credential handling), 700 (collaboration), 701 (SDLC surface), 702 (Mac intelligence), 774 (Music), 682 / 680 / 706 (docx/rtf/richtext), 673 / 674 (Excel eval), 725 (inspections/intentions), 772 / 773 / 777 / 782 (plugin expansion / PDK), 688 (walkthrough-as-presentation), 692 (dep-source explorer), 698 (script command window — `progress`/parked).
- **Misc reported shells:** TSK-316 (walkthrough versioning), 336 (Claude hook integration), 338/341/345/346/351/353/356/367/375/376/377/378/381 (partial wish shells), 369/370 (Linux/Windows port future-proof), 508 (Digraph phase 2 render), 530 (CR export modes — `progress`), 537/538/651 (epic tracking shells), 671/683/686 (text-view/app-name/signing shells), 752 (temp-file storage decision), 776/778/794/795/797 (test/coverage questions), 962 (highlighting parity — also in Bugs), 924/958 (paste umbrellas).

---

## Top 10 next (value × tractability)

1. **TSK-965** — C1 MessagePack recursion DoS `[in-flight, sec]`
2. **TSK-968** — H2 sqlite use-after-free `[in-flight, sec]`
3. **TSK-826** — FFI receive-side double-copy `[host perf]`
4. **TSK-912** — Code-review comment add/list UI `[host, cheap feature]`
5. **TSK-543** — cm_apply full-doc FFI traffic `[host perf]`
6. **TSK-973** — H7 search.files regex-per-file + no dir-skip `[in-flight, sec/perf]`
7. **TSK-818** — VM key-synthesis lane (unblocks the key-routing bug tail) `[host, force-multiplier]`
8. **TSK-827** — TreeSitter tokenize NSString bridge `[host perf]`
9. **TSK-921** — Close a split pane `[VM-render bug]`
10. **TSK-963** — Productionalize LSP subsystem `[in-flight epic]`
