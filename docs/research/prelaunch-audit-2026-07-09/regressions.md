# Pre-Launch Product Review — Dimension: Regression Risks

**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`
**Date:** 2026-07-10
**Lens:** Risky recent changes; behavior changes without tests; weakened/deleted
assertions; TODO-disabled tests; features that landed as "model + host test" with the
user-facing surface silently deferred.

---

## Executive summary

The recent history is *unusually* disciplined about tests — nearly every source-touching
commit ships a matching host-test suite, and the team has explicit "teeth" conventions
(negative-control switches, tier gates). Assertion-deletion scanning turned up refactors
and Swift→Rust engine-gate migrations, **not** weakenings. So the classic regression
smells (silent assertion removal, TODO-disabled tests hiding failures) are largely absent.

The real regression risk here is a **different shape**, and it is systemic: a large number
of features land as a fully host-tested **model layer plus a deferred "render tail"
ticket**, where the render tail is *the part the user actually touches* — and several of
those tails are **not yet wired**. The board / CHANGELOG can read "feature shipped" while
the code that mounts it into the UI has zero callers. Three concrete, independently
verifiable instances are below (conflict-resolution 3-pane sheet, HTML network-consent
grant UI, dynamic content menu). Combined with a **default-on** rendering optimization
(TSK-838) whose documented safety-net is **not actually wired**, these are the launch
risks worth gating on.

Findings: **1 P1 (default-on render patch with a dead fallback), 1 P1 (data-safety —
conflict UI unreachable), 4 P2, 1 P3.**

---

## Methodology

- Enumerated the last ~3 weeks of history (`git log --since=2026-06-20`), plus a targeted
  read of the 8 most recent + highest-risk commits (P0 launch fix, data-safety fixes,
  security-consent, DOM-patch default flip, merge stack, content menu).
- Scanned every `XCTSkip*` / `XCTSkipIf(true)` in `Tests/` and every `#[ignore]` in
  `rust-core/`; classified each as environment-guard vs. permanently-disabled.
- Diffed removed assertions across `Tests/` for the window
  (`git log -p -- Tests | grep '^-.*XCTAssert'`), inspected the top hits.
- Read the actual product code for the four highest-stakes changes and, for each
  "model-complete, render-tail-deferred" feature, grepped for **real callers** of the new
  view/model/accessor across `Sources/` to confirm whether it is mounted.
- Verified the DOM-patch JS apply path (`BlockPatchJS.swift`) against its Swift caller
  (`MarkdownRenderedView.tryApplyDOMPatch`).

**Not run:** any UI/window-opening test, any VM lane, any full `swift test`. All findings
are from static reading + grep and are verifiable without building.

---

## Findings

### P1 — Default-on rendered-markdown DOM-patch: the documented fallback is not wired, and post-processing is not re-run
- **File:** `Sources/ViewerUI/MarkdownRenderedView.swift:156-169`;
  `Sources/ViewerCore/BlockPatchJS.swift:16-52`
- **Commit:** `e4429513` (flip `domPatchEnabled` to default ON, opt-out `MDV_DOM_PATCH=0`).
- **Evidence:**
  1. `tryApplyDOMPatch` fires the patch with
     `webView.evaluateJavaScript(..., completionHandler: nil)` and then
     **unconditionally `return true`** (line 164-168). The JS function
     `mdvApplyBlockPatch` *does* return `false` when the container is missing or the
     payload won't parse, and `BlockPatchJS.swift:16-19` explicitly documents *"the Swift
     caller treats `false` (and any thrown JS) as fall back to loadHTMLString, so the
     patch path is non-regressing by construction."* **That contract is not implemented** —
     the caller discards the completion handler, so a JS-side `false` or a thrown JS error
     leaves the page showing the **stale DOM** with no full-reload fallback. The
     "safe by construction" claim in the commit message covers only the *diff-size*
     heuristic (line 162), not apply-time failure.
  2. `mdvApplyBlockPatch` replaces a top-level block by parsing raw `template.innerHTML`
     and `replaceChild` (BlockPatchJS lines 42-48). It does **not** re-run the page's
     mermaid / math / (any) post-load processing. A block that becomes a mermaid host
     (`<div class="mdv-mermaid">`, see `MarkdownRenderedView.swift:227`), a math block, or
     any block needing a JS post-pass will be inserted as inert markup. On the previous
     default (full `loadHTMLString`) the load-time passes re-ran; on the new default they
     do not.
- **Impact:** Now that this is **default-on**, a same-file re-render whose block-diff is
  small (the common single-block edit / live-preview case) can silently show stale or
  unprocessed rendered output, with the intended reload fallback dead. The commit itself
  flags the agentic UAT as *"re-run as the agentic UAT"* — i.e. the confirming UAT was not
  yet done at flip time.
- **Suggested fix:** Wire the completion handler — on `result as? Bool == false`, thrown
  error, or `nil`, fall back to `loadHTMLString`. Re-run mermaid/math post-processing on
  replaced blocks (or refuse to patch blocks whose new HTML contains a mermaid/math host
  and fall back). Run the agentic UAT before ship.
- **Fix size:** M · **Fix risk:** careful (touches the default render path).

---

### P1 — Data-safety: the 3-way conflict-resolution UI is unreachable; a real external-edit conflict forces a lossy keep-mine/reload-theirs choice
- **Files:** `Sources/ViewerUI/ConflictResolutionView.swift` (defined, **0 callers**);
  `Sources/ViewerUI/DocumentModel.swift:3020` (`beginConflictResolution`, **0 callers**);
  banner mount at `Sources/ViewerUI/ContentView.swift:774-778`.
- **Commits:** `3755420f` (built the 3-pane merge stack + `beginConflictResolution` +
  `ConflictResolutionView`, host-tested) and `498ecdc1` (went **live** with the
  auto-merge path in `reloadCurrentFile`).
- **Evidence:** `rg 'ConflictResolutionView' Sources/` and `rg 'beginConflictResolution'
  Sources/` return **only the defining files** — nothing mounts the 3-pane sheet or calls
  the begin-resolution entry point. Meanwhile the auto-merge *is* wired and live
  (`DocumentModel.applyExternalAutoMerge`, `reloadCurrentFile` at DocumentModel.swift
  ~2774). When the reconciler returns `.conflict` (overlapping edits), control falls
  through to `DiskConflictBanner` (ContentView.swift:775), whose only affordances are the
  binary `resolveDiskConflict(intent)` (keep-mine **or** reload-theirs) — **one side's
  edits are discarded**. The richer per-region resolver that was built and tested this
  same window is not reachable.
- **Impact:** For the exact scenario the merge feature exists to protect (a genuine
  overlapping local+disk conflict), the user is still forced into a data-losing binary
  choice; the built resolver that would preserve both sides is dead code. This is the
  data-safety regression that matters most for launch — the mitigation shipped, its
  fallback UI did not.
- **Suggested fix:** Mount `ConflictResolutionView` from the `DiskConflictBanner` (a
  "Resolve…" intent that calls `beginConflictResolution` and presents the sheet). Tracked
  as TSK-1584 but currently unshipped.
- **Fix size:** M · **Fix risk:** careful.

---

### P2 — External-edit auto-merge mutates the dirty buffer silently; Revert semantics drop the merged disk changes; CM6 redisplay on-screen UNVERIFIED
- **File:** `Sources/ViewerUI/DocumentModel.swift:2977-2990` (`applyExternalAutoMerge`),
  reconciler `Sources/ViewerCore/ExternalEditReconciler.swift`.
- **Commit:** `498ecdc1`.
- **Evidence:** On a clean 3-way merge the buffer takes the merged text and is kept dirty
  with `originalText` (the base) **untouched**, and the disk fingerprint is refreshed via
  `buf.refreshSavedFingerprint(...)`. Consequences: (a) a subsequent **Revert** restores
  `originalText` = the *pre-conflict base*, silently discarding **both** the local edits
  **and** the externally-merged disk changes (the commit frames this as intended, but it
  is surprising for a data-safety path); (b) the fingerprint now claims "saved == disk"
  even though the in-memory buffer differs from disk, so the watcher won't re-fire for
  this change; (c) the commit itself states the CM6 re-display after the merge is
  **"on-screen UNVERIFIED (needs a watcher fire, not scene-drivable)"** — so the visible
  result of a silent auto-merge has not been confirmed. The line-merge itself is safe:
  `ThreeWayMerge.merge(String)` uses `components(separatedBy: "\n")` with empty-string
  guards (ThreeWayMerge.swift:200-204), so trailing newlines and CRLF (the `\r` rides the
  line) round-trip.
- **Impact:** A silent, banner-less mutation of the user's unsaved buffer whose on-screen
  correctness is unverified, with a Revert that can drop the merged content. Model-tested,
  but the user-visible half is not.
- **Suggested fix:** Verify CM6 redisplay on the VM before treating as shipped; consider a
  non-dismissable "merged — review before saving" affordance rather than a transient toast;
  reconsider whether Revert should reach the merged state rather than pre-conflict base.
- **Fix size:** S-M · **Fix risk:** careful (data path).

---

### P2 — HTML per-page network consent is inert: no UI can grant it
- **File:** `Sources/ViewerUI/DocumentModel+HTMLJavaScript.swift:79` (`allowHTMLNetwork`),
  `revokeHTMLNetwork` — **0 callers** outside the defining file.
- **Commit:** `348ff57c`.
- **Evidence:** `rg 'allowHTMLNetwork|revokeHTMLNetwork' Sources/` returns only the
  definition. The CSP-escalation core (`HTMLDocumentPolicy.cspString(trusted:allowedConnectHosts:)`,
  `connectSource(forHost:)`) and the fail-closed store are built and security-tested, but
  there is no grant/blocked-host UI, so the escalation is unreachable.
- **Impact:** Not a security hole — it is **fail-closed** (empty consent ⇒ `connect-src
  'none'`, byte-identical to before), and the security invariant (untrusted never relaxes)
  is tested. But the feature is inert: a user cannot actually authorize a connection. It
  reads as shipped on the board (TSK-1203 core) while the usable surface (TSK-1580) is not
  wired.
- **Suggested fix:** Ship the grant UI (failure banner + per-host allow), TSK-1580.
- **Fix size:** M · **Fix risk:** safe (additive; fail-closed default preserved).

---

### P2 — Dynamic content menu is computed but never rendered
- **File:** `Sources/ViewerCore/ContentActionMenu.swift`;
  `Sources/ViewerUI/DocumentModel.swift:2153` (`activeContentMenu`) — **0 UI consumers**.
- **Commit:** `5fda425a` (HEAD).
- **Evidence:** `rg 'activeContentMenu' Sources/` returns only the defining computed
  property; nothing builds an `NSMenu` from it. The commit is explicit: *"the live dynamic
  NSMenu is the AppKit tail (TSK-1585)."*
- **Impact:** The FileCategory→actions menu the user would see does not exist yet; the menu
  model is host-tested but has no output surface. Lower stakes than the above (no data
  path), but same "shipped model / unshipped surface" pattern.
- **Suggested fix:** Build the NSMenu from `activeContentMenu` (TSK-1585).
- **Fix size:** M · **Fix risk:** safe.

---

### P2 — Systemic pattern: "render tail" deferral can make the board over-report completion
- **Evidence:** The four findings above are the same shape, and it recurs across the
  window — commits routinely land `Sources/<Model>.swift` + `Tests/<Model>Tests.swift`
  with a trailing *"the live … is the render/AppKit/VM/AX tail (TSK-####)."* Open tails
  observed just in the last ~10 commits: TSK-1580 (network grant UI), TSK-1584 (conflict
  sheet), TSK-1585 (content NSMenu), plus the DOM-patch UAT re-run (TSK-838). CHANGELOG
  entries describe these from the user's seat (e.g. *"consent-gated network for trusted
  HTML"*) though the user-facing half is not wired.
- **Impact:** For a pre-launch readiness call, "done on the board" is not a reliable proxy
  for "user can do it." Anyone gating launch on ticket state will over-count.
- **Suggested fix:** Before launch, sweep all open `TSK-####` "render tail" references and
  confirm each named view/accessor has a real caller (the grep above is the exact check);
  treat an unmounted surface as not-shipped regardless of model-test greenness. This is
  precisely the miss class the project's own CLAUDE.md "headless-rendered ≠ visible" and
  "confirm on the real UI before fixed" directives exist to catch.
- **Fix size:** L (audit + wire the tails) · **Fix risk:** safe.

---

### P3 — Big-CSV windowed assembly sniffs the delimiter from a 64 KB prefix
- **File:** `Sources/ViewerCore/RustCSVAdapter.swift:113-140` (`windowedAssemble`).
- **Commit:** `a5398bd6`.
- **Evidence:** For inputs > 4 MB, the delimiter is sniffed from `text.prefix(64*1024)` via
  a separate `CsvSession`, while the rows are materialized from a full-file session; the
  reported delimiter comes from the prefix sniff (`sniffed.first ?? ","`). For a
  pathological file whose first 64 KB is a single unbroken field / different apparent
  delimiter than the body, the reported delimiter could disagree with how the body parsed.
  The row-parse itself uses the full session's own sniff, so rows are consistent; only the
  reported `delimiter` field is at risk. Guarded by a 6 MB round-trip regression test.
- **Impact:** Low — realistic CSVs sniff identically on a 64 KB prefix; the correctness
  fix (no more empty grid over the FFI cap) is the important part and is solid.
- **Suggested fix:** Report the full-session's delimiter rather than the prefix sniff, or
  assert they agree.
- **Fix size:** S · **Fix risk:** safe.

---

## Positive observations

- **Test discipline is high.** Every source-touching commit inspected shipped a matching
  host suite; the data-safety and security commits shipped 3-12 new tests each including
  explicit invariant tests (`untrusted-never-relaxes`, `absent-on-disk` regression guard,
  isolation teeth for the UserDefaults race).
- **The P0 launch fix (TSK-1566) is well-guarded.** The `--mcp-connect` branch is correctly
  hoisted above `NSApplication.shared` (main.swift:4301 vs 4320), an orphan watchdog was
  added, and `MCPBridgeLaunchOrderTests` (committed, `git ls-files` confirms) parses the
  live `main.swift` to keep the ordering from regressing.
- **No permanently-disabled product tests hiding failures.** Every `XCTSkip` read is an
  environment guard (bundle-not-present, VM-only tier, tool-not-on-PATH) or a documented
  harness limitation (`KeySynthUATTests` KEY_01, `ScrollRestoreUATTests` — CM6 jetsam under
  spawned-app; both cite tickets and have in-process replacements). The two `XCTSkipIf(true)`
  cases are known-intractable webview-lane repros with alternative coverage, not silenced
  product bugs.
- **Line-merge is newline-safe.** `ThreeWayMerge` splits/joins with
  `components(separatedBy:"\n")` + empty guards, so trailing-newline and CRLF survive the
  auto-merge round-trip.
- **The reverted tmux stack** (`127f2aa9` etc.) was cleanly reverted, not left half-landed.

---

## Coverage gaps (what I did NOT examine)

- **Runtime behavior** — no build, no test run, no VM. Every finding is static; the
  DOM-patch fallback gap and mermaid-re-run gap are code-verified but not runtime-observed.
- **The Rust core engines** (markdown/csv/formula/diff/nav/hex/json/find/canvas) beyond the
  CSV adapter seam — did not diff their recent history for logic regressions.
- **Full assertion-deletion archaeology** — I sampled the top removed-assertion hits and
  judged them refactors/gate-migrations; I did not trace every one to confirm no behavioral
  weakening slipped in.
- **The Canvas DSL** (a large, fast-moving subsystem with many M-slice commits) — only
  noted the one "commit-on-red-gate slip" that was already amended (`99464287`); did not
  audit its slices for regressions.
- **LSP / Git / Terminal / Sessions / Image-editing** feature clusters — not individually
  reviewed for this lens beyond commit-message scanning.
- **Perf regressions** — did not measure; the DOM-patch and InteractionProfiler changes
  are gated/fallback-based but unmeasured here.
