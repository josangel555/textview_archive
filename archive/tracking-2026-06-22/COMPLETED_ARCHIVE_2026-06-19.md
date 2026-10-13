# Completed Archive — 2026-06-19

Reconciliation of the **TextView / MarkdownViewer** curated lists (`WORK_QUEUE.md` +
`docs/NEXT_30_TASKS_2026-06-18.md`) against the live `tasked` board. This file is the
**archive of DONE work**. The go-forward active list is
[`docs/CURATED_TASKS_2026-06-19.md`](./CURATED_TASKS_2026-06-19.md).

**DONE** = board state `fixed` / `review` / `validated` / `done`. (`fixed`/`review` =
agent-complete + host-tested; the owner/VM gate is the only remaining step. `validated`/
`done` = closed.)

SHAs are recorded where the board/queue captured them; many `validated` audit tickets
were closed without a queue-recorded SHA (shown as `—`).

Counts: **~430 DONE** markdown_viewer tasks archived below.
Foreign projects (wx-globe 872–880, forge/tasked-tool-dev 102–106 / 441–445) and
`wontdo`/dismissed tickets are excluded entirely (not work, not go-forward).

---

## ★ Intake 2026-06-14 (user bug/feature wave) — DONE

- TSK-887 — Command palette typing laggy — review @ 5a1af0d (@-mode heading-memo slice; bare-mode rebuild remains → see active list)
- TSK-888 — Global search typing + result-scroll laggy — review @ 7d08399 (result-scroll cap slice; common-case trace remains → active list)
- TSK-893 — CM6 cursor pointer↔I-beam flip — review @ 3665000
- TSK-894 — Current-line highlight stuck after drag-select — fixed (intake wave)
- TSK-896 — Hovered-row highlight offset — fixed (intake wave)
- TSK-897 — Editor missing many languages' highlighting — fixed (intake wave; re-report of 362)
- TSK-898 — Render|Editor|HEX segmented button group — fixed (intake wave)
- TSK-899 — view-mode shortcuts ⌘1/⌘2/⌘3 — review
- TSK-900 — Plain-text file locked in HEX — review @ 2fecf10
- TSK-901 — Auto-detect content type (language half) — validated @ dc6aaab
- TSK-902 — Preview tab title italic not bold — review @ d385799
- TSK-903 — Rendered MD GFM task-item check/strike — review
- TSK-905 — Preview ↑/↓ broken unless tab last — review @ 25c3b89
- TSK-906 — Palette dismiss loses editor focus — review @ 828e534
- TSK-907 — Git log duplicate-tab de-dupe — review @ 45cbd0b
- TSK-908 — Right-click commit slow + only "Review Commit" — review @ 8f35c86 (copy actions; framework-cost half VM-confirm)
- TSK-909 — Right-click commit → Reviews submenu — review
- TSK-910 — Git diff multi-line selection — fixed (intake wave; design-on-board)
- TSK-911 — Commit-diff summary header — review
- TSK-913 — File-nav right-click → Rename — review (already built)
- TSK-914 — "Open in Terminal" opens in-app terminal — review @ f748cbe
- TSK-915 — File tree auto-refresh — review (already built, FolderWatcher)
- TSK-916 — "Reload from disk" — review @ 3c4f950
- TSK-917 — Gutter selectable + cursor-icon — review @ 7cbd5a2
- TSK-918 — Remove max-width cap on panel resize — review
- TSK-919 — File-nav sub-folder self-drag trap — review
- TSK-920 — drag-to-Terminal pastes path — review
- TSK-922 — Open-split slow — review @ 5c9fec7 (close-button half 921 still open → active list)
- TSK-924 — CSV copy row/column — review @ 428310d (rectangle select remains → active list)
- TSK-925 — CSV sort by column header — review
- TSK-926 / 927 — CLI open file/folder · pipe stdin — review @ c06a4c0
- TSK-928 — URL scheme markdownviewer:// → textview:// — review
- TSK-929 — External rename → tab follows — review
- TSK-930 — Named saved sessions — review (already built)
- TSK-931 — Rename a session — review
- TSK-932 — Unsaved blue dot on modified tab — review
- TSK-933 — Footer filename as breadcrumb — review
- TSK-934 — breadcrumb right-click context menu — review @ c61f7d0
- TSK-935 — New Tab → Paste virtual-paste — review
- TSK-937 — Focus shortcuts (Terminal/Nav/Git/File) — fixed (intake wave)
- TSK-938 — Esc → current tab focus — fixed (intake wave)
- TSK-939 — Parity audit — review (docs/PARITY_AUDIT_2026-06-14.md)
- TSK-946 — Find Next/Prev (⌘G/⌥⌘G) — review @ db8de59
- TSK-947 — ⌘F dead in HTML-rendered + editor size-cap — review @ 83d9186 / fe11f2c
- TSK-948 — Source code folding dead-wired — fixed (intake wave)
- TSK-949 — Find&Replace (⌥⌘F) greyed outside editor — review @ db8de59
- TSK-950 — LSP Find-References menu/palette — review @ d200171
- TSK-951 — palette-parity umbrella — review @ 0cd2d81 (tail items remain → active list)

## WISH-list shipped (P0–P8, the "the-30"/ultracode wave) — DONE

- TSK-671 — Plain text view — review
- TSK-676 — Built-in browser (epic) — fixed
- TSK-677 — Unify search types — fixed
- TSK-678 — Help page: all keyboard shortcuts — review
- TSK-679 — VIM modal editing (epic) — review (core; VM keystroke smoke remains → active list)
- TSK-681 — Export/Import settings + ~/.textview — review
- TSK-685 — Spell check / Grammar / LSP checks (epic) — fixed
- TSK-696 — TextView CLI launcher on PATH — review
- TSK-705 — Snippets (epic) — review (Tab-key wiring + mgmt UI remain → active list)
- TSK-707 — Command palette double-Shift — review @ c9e416f
- TSK-708 — Preview definition (Cmd+Y) — fixed
- TSK-710 — Hover symbol info (LSP hover) — review (already built)
- TSK-718 — Hot exit — review @ 542e9c8
- TSK-719 — Sticky scroll — review @ c87c07f
- TSK-720 — ⇧⌘P palette binding — validated @ 1482cae
- TSK-721 — HTTP client (epic) — fixed
- TSK-726 — Project-wide replace — review @ d04cbe6
- TSK-727 — Unified Goto Anything — fixed (core @ d977438; `@`-via-LSP tail → active list)
- TSK-749 — Image edit: add text & shapes (epic) — fixed
- TSK-754 — Plugin API: contribute menu items (epic) — fixed
- TSK-955 — RSS / Atom feed reader (epic) — fixed
- TSK-956 — Audio plugin hosting AU + CoreMIDI (epic) — fixed (VST decision → owner-gated, active list)
- TSK-957 — Editor Macros record/replay (epic) — fixed
- TSK-958 — Universal Paste dispatcher (epic) — fixed

## A. Quick wins / minor-features — DONE

- TSK-355 — "Open in" / Reveal in Finder / external app — review @ 6f47d05
- TSK-374 — Find match list view — review @ e7f8ad6
- TSK-411–414 — Omni-invokable Reload / split+move-tab / git panel+bookmark / file history — done
- TSK-437 — File → Reset menu (recoverable cache/state) — validated
- TSK-505 — File SHA-256 in MetadataPanel + Copy command — validated
- TSK-509 / 510 — Line-ending detector + route StatusBar EOL chip — validated
- TSK-511 — Markdown heading outline (TOC) model — validated
- TSK-512 — Source annotation scanner (TODO/FIXME/…) — validated
- TSK-513 — JSON syntax-error locator — validated
- TSK-514 — DiffStat model — validated
- TSK-637 — Markdown outline sidebar wiring — validated
- TSK-638 — Print + Export as PDF (rendered markdown) — validated
- TSK-639 — Multi-cursor in the editor — validated
- TSK-640 — LSP rename + code actions — validated
- TSK-745 — New tab shows recent files — validated
- TSK-747 — New-tab offer other types — review @ ff1e6b6
- TSK-748 — File info pane: multi-algo checksums + metadata — validated
- TSK-753 — View → Language Mode menu item — review @ cb0c3b1
- TSK-755 — Session menu "Tab operations" section — review @ f8be533
- TSK-756 — Top-right toolbar palette button — review @ 38c0ee0
- TSK-757 — Keyboard shortcut catalog + gap-fill — review @ a0cf167
- TSK-758 — Search tool window header filter buttons — review
- TSK-759 — Drag to reorder tabs — review
- TSK-760 — New Tab [New text file] button — validated
- TSK-762 — Wrap/special-char toggle buttons — review @ 4d14eea
- TSK-763 — Recents tool window folder in grey — review
- TSK-770 — Find/Replace add Replace + ReplaceAll — validated
- TSK-771 — Terminal right-click tab → Rename — review
- TSK-784 — How to run WebUI/TUI (answered) — review
- TSK-789 / 790 — Show supported LSP / syntax-highlight languages in settings — review
- TSK-796 / 801 / 802 / 803 / 804 — How to: code reviews / monitor CC / MCP / LSP / timeline (answered) — review
- TSK-807 — File info pane: type-specific metadata for all formats — review
- TSK-823 — Navigate menu: LSP go-to commands — review
- TSK-824 — Edit menu: LSP Format/Rename/Code-Actions — review
- TSK-825 — Pretty-Print minified CSS — validated

## Editor power-ops / markdown / CSV tools (675-slices + format wave) — DONE

- TSK-348 — Deep metadata: PDF + AV codec fields — validated @ c7d4832
- TSK-350 — Formatting: Align Markdown Tables — review @ 68f8a96
- TSK-352 — NotePad++: encoding-convert slice — review @ 63ce3e2
- TSK-358 — Window sizing / font-size slice — review @ 95f7184/e3544b0 (window-sizing half remains → active list)
- TSK-360 — Source-view line-age blame heatmap — review @ 038d237
- TSK-505/347 — SHA-256 surface — validated
- TSK-814 — git blame in editor gutter — validated
- TSK-861 — EditorWriter BOM-less UTF-16 reopen fix — validated
- TSK-862 — Convert Line Endings (LF/CRLF/CR) — review
- TSK-863 — Whitespace cleanup + Document Statistics — review
- TSK-864 — Convert Indentation (Tabs↔Spaces) — review
- TSK-865 — Insert Table of Contents (Markdown) — review
- TSK-866 — Copy as HTML + Export as HTML — review
- TSK-867 — Check Links (broken local links/images) — review
- TSK-868 — Minify JSON — review
- TSK-869 — Lint Markdown — review
- TSK-870 — CSV → Copy as Markdown Table + JSON — review
- TSK-871 — Self-contained HTML export (inline images) — review
- TSK-881 — Open Rendered in Browser — review
- TSK-882 — Promote / Demote Headings — review
- TSK-883 — Edit ▸ Lines (Sort / Reverse / Dedup) — review
- TSK-884 — Edit ▸ Lines (Remove Empty / Collapse Blank) — review
- TSK-885 — View ▸ CSV Summary — review
- TSK-886 — View ▸ Copy as CSV — review

## Media (image + audio editor) — DONE

- TSK-110 — PoC image editing — fixed
- TSK-342 / 344 — Image basic editing + format/histogram — validated
- TSK-524 — Image-editor UI + Save-As dialog — review
- TSK-525 / 526 / 527 / 531 — Audio core: PCM/waveform, FFT spectrum, trim/fade, gain/normalize — done
- TSK-528 — Audio save-as encoders WAV/AAC/MP3 — validated
- TSK-529 — Audio visualization + transport UI — fixed
- TSK-533 — Audio spectrum panel — review @ 111395c
- TSK-534 — Audio draggable trim + fade — review @ 3bc613b
- TSK-535 — Audio Save-As sheet → AudioExporter — fixed
- TSK-285 / 287 — Paint raster + vector slices — fixed
- TSK-286 — Image layers / own format — fixed

## Code Review feature — DONE

- TSK-522 — Multi-select commits → cumulative diff — validated
- TSK-523 — Click commit → inline diff + comments — validated
- TSK-530 — Code-review export with/without snippets — progress→shipped (review-equiv; see note: state `progress`, treat as in-flight if re-touched)
- TSK-532 — Select multiple comments → combined diff — validated

## 0. Perf — user-felt latency — DONE

- TSK-108 — Tab close/switch/open slow cluster — validated
- TSK-266 — Closing a tab takes a second — validated
- TSK-267 — 1MB HEX view extremely slow — validated
- TSK-270 — Delay in opening files — validated
- TSK-273 — Switching tabs very slow — validated
- TSK-455 — HEX ~1s for tiny file — validated
- TSK-486 — Terminal typing/Enter slow — validated
- TSK-601 — Swift source files slow to open — validated
- TSK-603 — Overall UI nav slow (umbrella) — validated
- TSK-611 — MD render + TS compile sync 927ms hang — validated
- TSK-612 / 613 / 614 / 615 — Sidebar ROW COUNTS recount + re-body churn — validated
- TSK-619 — First source open ts.query-compile ~400ms — validated
- TSK-621 — TSK-611 pane-retention regression — validated
- TSK-624 — Rendered-MD WKWebView load latency root-cause — validated
- TSK-736 — Mouse-over highlight laggy on 5000-line log — validated
- TSK-828 — LineNumberRulerView ObjC char message-send — validated
- TSK-829 — CrossFileSearch parallelize — validated
- TSK-840 — Parallelize launch grammar-warm — validated @ bfcc134
- TSK-841 — Highlight wire positional arrays — validated @ f2622b7
- TSK-842 — Files ≤64MiB read+decode off-main — validated @ acd8588
- TSK-843 — Cache per-call gate decision — validated @ cd234e9
- TSK-844 — CSV open parse into arena — validated @ fbc5675
- TSK-853 — Launch warm heats the actual Rust highlight path — validated

## Bugs (broken behavior) — DONE

- TSK-101 — Dark-mode toggle forgets preference — validated
- TSK-313 / 314 — Session-tab double-click / prefill ~ — validated
- TSK-363 — Always show hidden — validated
- TSK-372 — Two-tabs-on-reopen bug — validated
- TSK-440 — Tool-window resize/fill gaps — validated
- TSK-448 — Enter does nothing in embedded terminal — validated
- TSK-452 — File stats not updating on tab change — validated
- TSK-467 — HEX "View Only" toggle non-functional — validated
- TSK-489 / 490 / 494 — Terminal scroll reset / alt-screen / tab-switch remount — validated
- TSK-493 — Terminal pane renders ~1 line — validated
- TSK-504 — Hex byte-grid under non-HEX picker — validated
- TSK-516 — indent::detect CRLF mis-parse — validated
- TSK-593 / 594 / 595 — Git diff align / select-copy / row highlight — validated
- TSK-599 / 600 — Open-in-new-session / New-Session-+ broken — validated
- TSK-602 — ViewOnly↔Edit highlighting parity — validated
- TSK-604 — SQLite UI doesn't scale with zoom — validated
- TSK-607 — Crash loses session state (periodic flush) — validated
- TSK-608 / 609 / 614 — Tool-window dismiss / shoulder buttons inert — validated
- TSK-728 — Enter in editor shifts focus to prev tab — review
- TSK-729 — View Only doesn't show unsaved edits — validated
- TSK-730 — Editor missing standard key navigation — review
- TSK-731 — "-- emoji" extra char in CC tables — validated
- TSK-732 — Font mismatch View/Edit — review
- TSK-734 — Crash switching sessions after save-prompt — review
- TSK-735 / 740 / 741 — Terminal VIM glitches / deleted chars / ANR on large paste — validated
- TSK-737 / 738 — Log line-number / file-status-footer missing — validated
- TSK-739 — Cmd+F again should toggle Find closed — validated
- TSK-742 / 744 — File-switch no content change / scroll carryover — validated
- TSK-743 — Preserve scroll state per previewed file — review
- TSK-806 — Split-pane source shows on-disk not unsaved — review
- TSK-815 — Theme doesn't darken rendered-MD page — validated
- TSK-821 — Rendered-MD per-file scroll persistence — review

## Features (git / sessions / sidebar / terminal / tools) — DONE

- TSK-105 — Jump-to-next-unread shortcut — validated
- TSK-259 / 260 / 261 / 262 / 268 / 304 — Front picker / single-shoulder / +-icon / tab-icons / last-tab-border / tab dropdown — mixed validated/fixed
- TSK-263 — Mouse-over line hover highlight — validated
- TSK-271 — PNG/media info respect zoom — validated
- TSK-272 — Up/Down on file-nav changes tab — fixed
- TSK-274 — Drag-drop tabs to sessions — validated
- TSK-275 — Render FPS jankiness indicator — fixed
- TSK-280 — Dependency graph view — fixed
- TSK-281 / 290 / 291 / 292 / 294 / 295 / 299 — Tabs / Digraph / Tools / SHA / BASE64 / UUID / Date-enter — validated
- TSK-282 — File-nav fuzzy find — fixed
- TSK-283 — Enter to rename — fixed
- TSK-284 — Draggable files — fixed
- TSK-300 — Save copy — fixed
- TSK-305 — Markdown overview window (top-right) — fixed
- TSK-306 — Preview mode on click — validated
- TSK-307 — Bookmarks root-folder scope filter — review @ c722514 (new-view affordance remains → active list)
- TSK-309 — TOCTOU on bookmark symlinks — fixed
- TSK-311 — Compressed files without unzipping — fixed
- TSK-315 — Open/move file in new session (tab right-click) — validated
- TSK-317 — Walkthrough deeplinks — fixed
- TSK-321 / 322 / 323 / 325 / 328 / 331 / 332 — zoom/keybind/tab-shrink/plaintext slices — mixed validated/fixed
- TSK-324 — Tooltips for all elements — fixed
- TSK-329 — File New / right-click folder → new — fixed
- TSK-330 — Undo audit — fixed
- TSK-333 — Remove bookmark via Delete + undo — fixed
- TSK-334 — Right-click folder → Stats treemap — fixed
- TSK-335 — Claude session search — validated
- TSK-337 — Custom LSP integration — validated
- TSK-349 — Worktree support — validated
- TSK-365 — zoom-persists regression guard — validated
- TSK-366 — Status-bar memory usage per tab — review
- TSK-371 — Red dot on filesystem change — validated
- TSK-456 / 457 / 458 / 459 / 460 / 461 — Terminal copy-paste/scrollback/tabs/perf — mixed validated/fixed/done
- TSK-488 / 491 — Terminal tab-strip position / edge-assignable — validated
- TSK-506 — Folder-stats treemap Canvas render — fixed
- TSK-520 — Claude monitor transcript content-search — validated
- TSK-521 / 627 — LSP didSave / formatting end-to-end — validated
- TSK-596 / 597 — Git Log message search / diff search — validated
- TSK-636 — App-wide sensitive-activity audit log — validated
- TSK-641 / 642 — Theme engine + VS Code theme import — validated
- TSK-660 — TreeSitter highlighting → Rust — fixed
- TSK-666 — Sidebar global find-any-file — fixed
- TSK-669 — Surface WireError detail host-side — validated
- TSK-670 — PDF reader (epic) — fixed
- TSK-672 — Git diff/log/status/blame wish — wontdo (covered elsewhere; not active)
- TSK-698 — Script command window (JQ-style) — progress→parked human (treat as in-flight if re-touched)
- TSK-711-equiv CSV pieces — see CSV section

## Rust-core / FFI / remote-core / ports — DONE

- TSK-115 — Rust-core migration plan + seam — done
- TSK-394–398 — dist opt-level, snapshot_frame, no-alloc filter, single-alloc encode_frame — validated
- TSK-401 / 439 / 446 / 449 — VM Swift 6.1.2 build skew / test compile / dist assemble / codesign race — validated
- TSK-496 / 499 — XML/HTML pretty-print port + CSV cell-find port — validated
- TSK-539–582 (audit findings, the bulk of the rust-core audit TSK-538) — validated (memory/ABI/perf/security/efficiency findings)
- TSK-578 / 579 / 580 / 581 / 582 — OpenError match, abi_version, thin-waist envelope, mutex tri-state, misuse matrix — validated
- TSK-630 / 631 / 632 / 633 — Ports: FindEngine, markdown→HTML, transcript parser, FuzzyMatcher — validated
- TSK-634 — ffi_export codegen + Swift stub gen + capability bitmap — validated
- TSK-645 / 646 / 647 / 648 — Adapter flips: find, fuzzy, transcript, markdown — validated
- TSK-649 — Default-ON soak + Swift-twin delete plan — fixed
- TSK-652 / 655 — CoreTransport seam + fs.watch duplex design — validated
- TSK-653 / 654 / 656 / 657 / 658 / 659 — mdv-serve + fs/git/transcript/LSP-spike remote families — validated
- TSK-661 — Mermaid host-div in Rust — validated
- TSK-662 / 663 / 664 / 665 — fs.watch + transcript.follow push subs + RemoteTransport client + app attach — validated
- TSK-808 / 809 — Stage-B: delete IndentDetector + DiffParser Swift twins — validated
- TSK-820 — Remove dead per-method C symbols — validated
- TSK-PORT (TUI/WEB W1 family TSK-197–258, minus a few) — validated (in-file find, gutters, diff, CSV filter, hex search, sort, hidden toggle, goto-line, grep, tree-filter, pretty-print, open-as, status bar, encoding badge, image preview, outline, breadcrumb, word-wrap, recents, session-state, table-width, reload, invisibles, dark-mode, empty-states, kbd-help, multi-tab, git, find-minimap, md-render, source-highlight)

## Security / privacy — DONE

- TSK-116 / 117 / 118 / 119 — mdv-web Host/Origin/method + path confinement + URLScheme sibling bypass — validated
- TSK-124 / 125 — ReDoS wall-clock cap dead code + FindEngine deadline — validated
- TSK-126 / 480 — Nested-blockquote SIGSEGV (cmark-gfm parse guard) — validated
- TSK-135 / 136 / 137 — MCP path validator sibling bypass / symlink / WalkthroughLoader rootHint — validated
- TSK-156 — HTMLSanitizer quote-unaware attr scan — validated
- TSK-175 / 176 — Editor nav-policy unconditional .other + test gap — validated
- TSK-178 — Sidebar timeline redaction bypass — done
- TSK-427 / 431 — jsEscape + safeURL allowlist tests — done
- TSK-484 — WalkthroughLoader rootHint containment — validated
- TSK-540 / 541 / 542 — hex_render width alloc / handle race / web root fail-open — validated
- TSK-549 — git-status core.fsmonitor command exec — validated
- TSK-554 / 628 — cargo-deny/audit/Miri wiring + SwiftPM advisory watch — validated
- TSK-556 / 557 / 558 — slow-loris deadline / CSV memory amplification / unbounded dir listing — validated
- TSK-635 — Rendered-MD auto-fetch remote subresources (default-deny) — validated
- TSK-643 — Unexplained outbound connection investigation — validated
- TSK-812 — DNS-prefetch reading-activity leak — validated
- (Leak/race S2–S4 cluster: TSK-120/127/128/132/133/134/138–155/157–196/410 — validated/done; full numeric set in the board)

## Test infra / CI / build — DONE

- TSK-435 / 436 / 625 — killall footgun fixes (3 sites + visual-smoke.sh) — validated
- TSK-447 / 503 / 507 / 517 / 518 / 519 — stale-test / base64 divergence / plugin flake / band-geometry / sess-probe / ModeBar — validated
- TSK-492-foundation / 620 — UI-scene control + ui-click interaction layer — triaged/validated
- TSK-500 / 501 / 502 — VM fd-exhaustion / launchctl asuser / Screen-Recording TCC — validated
- TSK-616 / 617 / 618 — VM toolchain poisoning / AppLauncher crash / image-editor T5 — validated
- TSK-622 / 623 — Guard tests for unpinned fixed findings + WebView-lane contract — validated
- TSK-626 — SwiftPM ignores CMdvCore header changes — validated
- TSK-783 / 785 — Lock transitive deps + disable optional transitives — validated
- TSK-813 / 816 / 819 / 822 — VM build-app toolchain / host abort regression / .build chown / VR-gate — validated
- TSK-832 / 833 / 834 / 846 / 848 — index-store disable / CARGO_TARGET_DIR unify / reap artifacts / gate scratch-path / rust no-op mtime — validated
- TSK-952 / 953 / 954 / 959 — flaky perf benches / GUI-lane root-xctest temp / MCP fixture HOME / scroll-roundtrip flake — validated
- TSK-Process meta (TSK-112/113/402/450/453/536 + test-backfills 415–434/471–479/482/485) — done/validated

## rust-core audit epic (TSK-538) findings — DONE

The S2–S4 audit findings filed as TSK-539 through TSK-582 are nearly all **validated**
(memory, ABI, perf, security, efficiency-of-means). Remaining live ones (TSK-543 perf,
TSK-573 theme, TSK-583 dismissed) appear in the active list. The epic umbrella tickets
themselves (TSK-538 / 537 / 651) stay `reported` as tracking shells.

---

> **Note on `fixed`/`review`:** these are agent-complete and host-tested but not yet
> owner/VM-closed to `validated`/`done`. They are archived here as DONE per the
> reconciliation spec (the agent's work is done); the owner's `validated→done` close
> and any VM-render gate are the only outstanding steps and are tracked on the board,
> not re-listed as active work. Items with a genuine **remaining slice** (887/888/922/
> 924/951/679/705/727/307/358/956) are cross-referenced into the active list for that
> slice only.
