# Usability-queue Validation Protocol (e2e / UAT — DEFERRED lane)

**Owner directive 2026-07-02:** subagents implement the `[USABILITY]` queue with host tests;
the e2e/VM/UAT validation runs LATER as its own pass. This file is the standing guidance every
ticket's "VALIDATE" section defers to — so any later session (or subagent) can run the
validation sweep with zero extra context.

## The three validation rungs (run in order, per ticket)

1. **Host behavior (done at implement time — the subagent's bar):**
   targeted `swift test --filter <suite>` for the new model/logic + TEETH (mutate → RED →
   restore) + `bash scripts/test-headless-gate.sh` green on the committed commit.
2. **Command-path (host, implement- or validation-time):** drive the feature through its REAL
   action path — `ScriptVerb.apply(verb:…)` (the palette/menu dispatch) or the
   `model.runX()` command function — with `HeadlessHarness` + on-disk fixtures; assert the
   observable model/file outcome. Pattern files: `Tests/ViewerUITests/
   MarkdownTocVerbIntegrationTests.swift`, `CheckLinksCommandIntegrationTests.swift`,
   `ToolResultsPanelIntegrationTests.swift`.
3. **VM UI-drive (the DEFERRED e2e/UAT rung — this pass):**
   - Sync + rebuild dist fresh: `rsync -az --delete --exclude='.build/' --exclude='.swiftpm/'
     --exclude='dist/' --exclude='.git/objects/pack/' ./ macOS15:markdown_viewer/` then
     `ssh macOS15 'cd markdown_viewer && MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>
     MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all'` (`all` rebuilds dist — the
     stale-dist trap is real; verify exec mtime vs `git log -1`).
   - Write/extend a **T4 `LiveAppTestCase`** (or webview-lane suite for CM6/WKWebView
     behavior) that drives the feature via verbs/AutomationHost on the REAL app and asserts
     model-state dumps (`DiagnosticDump`/modelStateDump) + geometry/DOM.
   - **Pixels/AX:** gated until TSK-1334 (Screen-Recording grant) — visual checks report
     "behavior-confirmed, pixels-pending-grant". AX-driven tests are the one off-limits lane.
4. **Release smoke (per install):** after `bash scripts/build-app.sh release --install`,
   the owner (or a T4 journey on the VM) opens a markdown file, a CSV, and one hosted view.

## Board protocol for the deferred pass

- Implement-time ceiling: tickets land at **`fixed`** with rungs 1(–2) evidence. Do NOT
  self-validate on host evidence alone for UI-facing tickets.
- Validation pass: run rung 3 for the ticket's family, then `task_validate` with a `checks`
  artifact naming the VM suite + results. The T6 render-confirm directive (CLAUDE.md) governs:
  on-screen behavior claims need the VM run, not code-read.
- Per-family VM entry points already exist: UAT suites under `Tests/ViewerUITests/uat/`
  (SQLiteBrowser/FolderTreemap/HTTPClient/FeedReader…), `MarkdownOutlinePanelTests`,
  webview suites (`MDV_RUN_WEBVIEW_TESTS=1`). Extend the nearest one rather than inventing
  a new harness (question-the-vehicle rule).

## Batch queue for the one-subagent-at-a-time drain (owner 2026-07-02)

Each batch ≈ 5 tickets, one subagent, inline in the repo, commit-per-ticket, board to `fixed`.

| Batch | Tickets | Theme |
|---|---|---|
| 1 (running) | 1483 · 1435 · 1436 · 1479 · 1437 | systemic focus bug + cross-cutting components |
| 2 | 1461 · 1462 · 1463 · 1464 · 1465 | editor + file-nav |
| 3 | 1439 · 1472 · 1486 · 1469 · 1467 | data loops |
| 4 | 1441 · 1473 · 1474 · 1442 · 1485 | media + editor history |
| 5 | 1443 · 1444 · 1475 · 1476 · 1446 | devtools + feeds |
| 6 | 1481 · 1482 · 1448 · 1489 · 1498 | chrome + menus |
| 7 | 1447 · 1478 · 1493 · 1477 · 1470 | web/automation/devtools tail |
| 8 | 1484 · 1488 · 1490 · 1494 · 1495 | theme/perf/instrumentation |
| 9+ | 1438 · 1440 · 1445 · 1449 · 1487 · 1496 · older wishes (1318/1319/1340/1331/1269/1311/…) | remainder |

Owner-gated (not in batches): 1334 · 838-flip · 1414 · 1418 · 1423 · 1426 · 1468 · 1471 ·
1491 · 1492 · 1497 · Canvas review.
