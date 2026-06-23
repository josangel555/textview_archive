# Curated Tasks — 2026-06-19 (reorganized: done → bottom)

**Goal: drive every task → `done`.** The `tasked` board is the system of record; this doc is the human-scannable selector, **actionable at top, done/landed at the bottom**.

## How many left (board lanes, 2026-06-19)

| Lane | ~Count | Meaning |
|---|---|---|
| `reported` | ~60 | not yet started (backlog) |
| `ack` | ~35 | acknowledged big `[WISH]` epics / very-large |
| `triaged` | ~6 | scoped (incl. 5 parked design-Qs) |
| `progress` | ~20 | claimed, mostly stale-lease (abandoned mid-work) |
| **= work-remaining** | **~121** | needs actual implementation |
| `fixed` | ~75 | agent-done, awaiting validation/close |
| `review` | ~72 | agent-done, awaiting validation/close |
| `validated` | ~68 | proof-backed, awaiting owner `→done` |
| **= awaiting close** | **~215** | mostly just need the owner's `→done` (or a VM render-validation pass to auto-validate the render-path items) |

**Left to `done` ≈ 336** (215 agent-done-awaiting-close + 121 work-remaining). Two levers shrink this fast: (1) a **VM render-validation pass** drives the render-path `fixed`/`review` pile → `validated`; (2) draining `reported`/`ack`/`triaged`/`progress`.

---

## 🚧 IN FLIGHT NOW — first 50-item drain wave (`wfykpwfqh`, 2026-06-19)
Perf (measure-first): 890, 891, 892, 592, 839 · Features: 326, 364, 367, 530, 353, 923, 940, 904, 752 · Question-homework docs: 776, 778, 792, 793, 794, 795, 797, 798, 799, 800, 805, 780, 782, 786 · `[PARTIAL]`/epic foundation slices: 316, 336, 338, 341, 345, 346, 351, 356, 378, 381, 373, 375, 376, 377, 537, 538, 673, 682, 692, 694, 697, 715. *Each agent: read ticket → one host-completable slice → host-test → commit; I integrate as they land.*

Earlier follow-ups still open: **TSK-1018** tmux live PTY+render (VM-tail), **TSK-1023** tmux controller wiring, **897** grammars (dep).

## 🔓 OPEN — needs owner (decisions / dep-approvals — don't autonomously guess)
- **Design decisions (spiked + parked):** 787 test-framework→HYBRID · 781 LSP→external+fallback · 779 plugins/terminal-Tier-D · 775 migration D1/D2/D3 · 788 T5-coverage prioritization.
- **Dep-approvals:** 897 (TreeSitter grammars + budget) · 399 (memchr SIMD) · 835 (cargo-nextest) · 851 (ccache) · 584/585/587 (fuzz/property/WASM lanes) · 1014 (tree-sitter-swift pin).
- **Decisions:** 854 (delete Swift highlight twin) · 810 (Stage-B hex carve-out) · 589 (session eviction policy) · 470 (zoom split) · 709 (Cmd+K/Cmd+G) · 751 (menu organization) · 791 (CM6 direction) · 936 (View-only shortcut keys) · 956 (VST hosting) · 301 (local history) · 508 (digraph render) · 498/852 (CI policy) · 831 (IDE indexing).
- **Repro-needed:** 343 (image history/revert) · 733 (save-prompt on session switch).

## 📋 OPEN — backlog not yet pulled (next waves)
- **Perf (need VM/Instruments trace first):** 889 (JSON warm re-open) · 887/888 (palette/search residuals) · 382 (DocumentModel memory).
- **Architectural perf:** 838 (rendered-MD WKWebView persistent page + DOM-patch — biggest lever; spike).
- **Big epics (one-slice-and-iterate):** 711 CSV-editor · 712 3-way merge · 716 worktree-UX · 717 notebooks · 706 richtext · 703 action-history · 722 task-runner · 723 structural-search · 691 agent-harness · 701 SDLC-surface · 697 agent-services · 725 inspections · 764 git-reconciliation · 772/773/777/782 plugin-expansion · 688 walkthrough-presentation · 680/682 docx/rtf · 673/674 Excel · 715 profiling · 320/380/403-406 paint.
- **Very-large / aspirational:** 689 PinBoard · 694 log-clustering · 695 credential-handling · 700 collaboration · 702 Mac-intelligence · 774 Music · 687/693/699 agent-integrations · 250/256/409 web-port tail.

## ✅ DONE / LANDED (bottom — for record)
- **The ultracode wave** (~117 commits, `bd1f8ca`→`main`, gate-green, shipped) — Bugs (894/895/896/910/921/948/1008/1016/1017…), cheap+medium Features (912/302/303/668/811/746/358/264/305/319/677/685/708/670/676/727…), epics' foundations (704/711/712/713/716/717/722/723/706/703/749/754…). All at `fixed`/`review` (your in-app close, or a VM pass).
- **Security review wave (965–1015)** — all landed; **965/966/967/968/976/987 `validated`** (proof-backed); rest `fixed`.
- **Rust-core migration** — ports 630/631/632/633 + contract 634 + highlight 660 + flips 645–648 + remote-core 652/655/661 + envelope 580 — **all `validated`/`fixed`**. (583 `wontdo`.)
- **S2/S3 audit batch (116–159)** — ~44 ReDoS/path-traversal/leak/OOM/UAF/contract fixes — **`validated`**.
- **Perf cluster** (108/266/267/455/440/452…) + this session's tmux re-land (model+controller-core, 122 tests), 845/1022 perf measured, 704/1019/1020/1021 follow-ups.
- Detailed per-item SHAs: `docs/AUTONOMOUS_PROGRESS.md` + `docs/COMPLETED_ARCHIVE_2026-06-19.md`.
