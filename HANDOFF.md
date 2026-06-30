<!-- CLAUDE-HANDOFF v1 -->
# Handoff — render-VM lane characterized + drained: 7 validated + TSK-1152 (Lock View As) built + TSK-373 reconciled; hard tail scoped (2026-06-30)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `b202eb6a`+ (TSK-1152 lock badge; verify `git log -1`)

## ⛳ STATE AT THIS CHECKPOINT (tick ~281, post-compaction) — READ FIRST
RENDER-CONFIRM TIERS (the lane, fastest first — full detail in memory `feedback_render_path_review_ceiling`): **(1) HOST ImageRenderer** (`HeadlessUITestCase`, NO VM) for PURE-SwiftUI pixel render-confirm — rasterize + assert a pixel DELTA (`DiffViewLayoutTests` / `DiffViewSelectionRenderTests`). FASTEST; UN-GATED renders only (ImageRenderer has no focus engine → can't render focus-gated tints, and placeholders representables → no occlusion). **(2) VM hosting test** (`NSHostingView` + hierarchy-walk, `WebViewTestCase` #192, `test-in-vm.sh webview`) for SwiftUI bridging to NSViews. **(3) T5 pixel** — ONLY WebView/representable pixels or occlusion (TSK-488). **(4) AX** (off-limits) — ONLY the out-of-process gesture/focus executor. A state-seam (additive `initial*` init param) + tier 1/2 drives most "render at review on the AX exception" items to validated.
VALIDATED THIS STRETCH (7, via the lane): TSK-1141 multi-sheet .xlsx (design eeb39117→model 2dab2413→view 0db225bd→hosting facc5a0d, end-to-end), TSK-1119 walkthrough overlay (existing hosting test VM-passed), TSK-722 task-runner epic + TSK-723 structural-search epic (host engine + validated UI child TSK-1160/1161), TSK-1049 off-main render (host parity), TSK-1321 image-overlay selectable/editable (VM hosting test), TSK-910 commit-diff multi-line select (BUILT a selection seam + host-ImageRenderer render-confirm c22288c6 — corrected its over-cautious AX-cap). Verify-before-validate confirmed TSK-698/1160/1161/1176/958/1163/1306/1312/1314/1316/1323/1325/1032 ALREADY done (no dup).
ALSO SHIPPED since tick ~235: **TSK-1152 Lock View As** built end-to-end → review (2382aee1: the file-nav "Lock View As → <mode>" context submenu + per-url DocumentModel helpers; b202eb6a: the lock badge in the row via FileRowState.isViewModeLocked) — logic comprehensively host-tested (DocumentModelViewModeLockTests + FileRowStateTests); the badge/menu PIXEL render is the T5/owner tail. **TSK-373** New-Session▸Kind menu reconciled → review (verify-before-build caught it BUILT — NewSessionMenuItems + SessionTabBar + host tests — wrongly bounced to ack by a #NNN over-correction). The `CSVRectSelection.contains` dedup (e2a46bee). The rust-core proptest lane is comprehensively done (30 engines). **NEW TIER-1 CAVEAT (TSK-1152, in memory):** host ImageRenderer renders a `Button`-wrapped / `onAppear`-complex full ROW (FileRowView) BLANK → 0-delta false-fail; it works ONLY for plain CONTENT sub-views (DiffView.scrollBody). Don't tier-1 a full interactive row.
HARD RENDER TAIL — precisely scoped (NOT clean quick builds; recorded on the tickets): **TSK-924** CSV rect-select tint is `gridFocused`-gated → host ImageRenderer can't render it (no focus engine); model fully host-tested → honest review ceiling. **TSK-1331** revert (restore-over-current, not-open case) is data-safety-subtle — the data-safest open-then-apply needs a render-coupled pendingRestore + editor-mount-consume hook (precedent: pendingEditorDiagnostics); disk-write has a snapshot-nil-ambiguity recoverability risk. Both = focused render builds, not deep-context. **TSK-1200** CM6 scroll = parked (owner real-vs-harness; neither lane composites/measures CM6).
NEXT: clean host-completable ships (coverage/dedup; rust-core fuzz if a parser gap) + the render-VM lane for any remaining UN-GATED SwiftUI render; reserve TSK-1331 (data-safety) + TSK-1146 (CM6 squiggles) for focused render contexts. TSK-598 "MD open laggy" = a ~334ms CoreAnimation COMMIT STALL (banked; fix = launch pre-warm / owner TSK-838 DOM-patch flip).
OWNER ACTIONS (highest-leverage first): (1) Close the review→validated→done queue (validated→done is owner-only) — incl. the 7 just-validated + the ~410 others. (2) **TSK-838** DOM-patch flip → the TSK-598 re-render half. (3) Decisions: TSK-1139 (CSV paging — recommend skip), TSK-1305/1320/1335-pt2/1200, TSK-1149 (feed-reader surface). (4) **TSK-1334** VM Screen-Recording → only the WebView-pixel/occlusion T5 items (e.g. TSK-1333 mermaid), NOT the pure-SwiftUI pile (agent validates directly).

## ⚠️ CORRECTION (owner 2026-06-29) — STILL IN FORCE
The VM is UP; the ENTIRE UI/render lane is agent-workable — BUILD + VM-validate. ONLY off-limits tier = AX-driven tests. "host-testable-seam vein drained" is a banned framing. The render-confirm directive is satisfied BY VM-validating, not by handing render to the owner. (Note: a few remainder items above ARE genuinely careful/risky/owner-gated — that's a per-item engineering judgment after a thorough spike, NOT the banned blanket "render isn't my work".)

## Mission
Autonomous drain loop (cron). Work INLINE, one item/firing: read-first → implement → host-test → host-gate (`bash scripts/test-headless-gate.sh`) → commit per item; land rebase+ff; keep main gate-green; fold docs into the item's commit. Cron canonical = `docs/TASK_WORKFLOW.md §7`.

## ⚠️ CORRECTION THAT RESET THIS HANDOFF (owner, 2026-06-29) — READ FIRST
A prior version of this handoff declared a "host-testable-seam vein DRAINED" and routed all render/UI work to a "VM/owner venue." **That framing was WRONG and is now banned.** The owner's standing model: **the VM is UP and the ENTIRE UI/render lane is agent-workable — build AND VM-validate it. The ONLY off-limits tier is AX-driven tests.** There is NO "host-testable vs render" split in what to work; render/UI/VM items are first-class drain targets you BUILD and VALIDATE (on the VM), not hand to the owner. The instructions that caused the misread were hardened this session (CLAUDE.md new 2026-06-29 directive + §4 self-validation; TASK_WORKFLOW §4 + §7 cron; the live cron prompt). The render-confirm directive is satisfied BY VM-validating, not by leaving things at review.

## ★★★ LATEST — copy-trimmed shipped + the VALIDATE-DRAIN stretch (2026-06-30, after the image-editor intake) — READ FIRST
After the image-editor intake (below), re-challenged my own "owner-gated" drift (the cron: render is NOT owner's lane, "vein drained" is banned) and found genuine HOST work the big render items had masked:
- **TSK-769 copy-trimmed SHIPPED** (47d63a02) — terminal copy strips the cell-grid trailing-space padding + bottom blank rows (Terminal.app/iTerm parity); TerminalCopyTrim.trim (pure, host-tested) → TerminalNSView.copy(_:). User-facing, CHANGELOG'd. (Rest of TSK-769 — open-in-pwd, favorites, history, palette, tab-rename model — already built; tab-rename UI / colours / shoulder-border are render-VM.)
- **VALIDATE-DRAIN → 5 items to `validated`** (advancing the ~417 owner-close queue with real proof): TSK-1332 (UAT TK2-blank false-negative — DiagnosticDump textLength + 6 consumers + host test), TSK-1240 (PaneRetention LRU mount-probe — stale, fixed by TSK-1274, VM-confirmed 2/2), TSK-1328 (ChromeBodyEvalCount parallel flake — retry-the-measure + ~15 green parallel gate runs), TSK-1210 (VM Swift 6.1.2 RustCore circular-ref — MsgPackPair, VM 6.1.2 compile clean), TSK-1209 (tooltip appear-delay 0.6 — test-gap backfill).
- **THE VALIDATE-DRAIN DISCRIMINATOR (use it):** test-infra / build / logic items with REAL teeth and NO T5/AX tail are agent-validatable end-to-end (host test, VM compile, empirical gate runs) → drive fixed/review → `validated`. Render items (image-editor, mermaid) correctly stay at review behind T5/owner; key-routing/focus bugs behind AX. Many "VM bugs" are STALE test expectations already fixed in code — diagnose host-side first, then VM-confirm + reconcile (TSK-1240).
- **The DELETE-set (TSK-1268 class A: LSPService superseded, EditorPerfBench, CSVRowWindowSource) stays OWNER-gated** — the safety rule (didn't-create-it → surface) applies; don't autonomously delete.

## ★★ SINCE 16 — THE OWNER-CORRECTION RENDER STRETCH (2026-06-30) — READ FIRST
The owner corrected the END-STATE below: **"T5-pixel-blocked" was conflated with "render-blocked."**
T5-screencapture (TSK-1334, still owner-blocked) gates ONLY the pixel-exact / occlusion-COMPOSITE check —
NOT the render BUILD nor its structure/DOM/in-process validation (webview / NSHostingView / T4). I'd
wrongly parked whole render items on that narrow T5 slice. Re-opened + shipped (all host-gate-green +
VM-validated via the webview lane):
- **TSK-1333 rendered Mermaid in the walkthrough overlay** — wired WalkthroughMermaidWebView into the
  overlay (occlusion-safe compositingGroup); render webview-validated (df0d8c11) + mount in-process-
  validated (70b118e3) → review. Occlusion-composite = child **TSK-1336** (T5, blocked on TSK-1334).
- **TSK-1149 FeedReaderView render** in-process-validated (46ef18f7 + ce60dfe8 fixup — the built view
  renders the add-feed field). The MOUNT is **re-parked (owner-decision)**: surfacing model a/b/c
  (tool-window vs tab vs window) — a genuine product call, NOT render/T5.
- **TSK-1321 element-properties inspector** (e0383724 + this commit) — the NON-AX edit-after-placement
  FORM (stroke colour · line width · x/y/w/h frame → host-tested restyle/resizeSelectedShape),
  render-guarded (NSColorWell renders for a selection, none otherwise). The canvas vein's on-canvas DRAG
  is the **AX tier** (off-limits, per TSK-1188), NOT T5 — the inspector is the non-AX path.
- **TSK-1334 re-verified** still denied; fix surfaced: the VM has no stable signing identity (ad-hoc →
  TCC re-prompts each rebuild) → `bash scripts/setup-signing.sh` + a one-time owner grant makes it stick.

**THE IMAGE-EDITOR INTAKE CLUSTER (TSK-1302–1321) — now DRAINED (after the above):**
- **TSK-1310 editable text** (34dc97ff + b6a417b8) → review. "Draw Text" was a one-shot raster op; added a
  RETAINED `.text` VectorShape kind (reuses the TSK-1321 inspector/selection machinery) + the Text tool
  now creates it + the inspector retypes/resizes it. On-canvas text PIXELS = T5 tail.
- **TSK-1321 ROTATION** (cefb4da2) completed the inspector → resize·rotate·move·colour/width all via the
  FORM (VectorShape.rotation + setRotation + a GraphicsContext rotate). On-canvas drag-handles +
  click-select-any = AX tail; rotated pixels = T5 tail.
- **TSK-1302 pane-overlap** (e969e531) → review. ImageEditorView is a full-bleed `.overlay` of
  MediaPreviewView while the MetadataPanel is an HStack SIBLING → editing crowded it. FIX: onEditingChanged
  callback (ImagePreview→MediaPreviewView→ContentView) → model.isEditingImage → ContentView
  .showsPreviewMetadataPanel gates the panel off while editing. Host-tested (4-combo predicate).
- **TSK-1303 edit-state persistence FOUNDATION** (8e1636bb) → triaged. ImageEditState (Codable: ops + 7
  tonal + overlay, NO pixels) + vm.captureEditState/restoreEditState, round-trip host-tested. The
  session-snapshot WIRING is the data-safety tail (careful VM, owner-aware — losing edits is the failure mode).
- **Reconciled/owner:** TSK-1304 (hide-toggle pre-exists = the "Info" toggle) + TSK-1307 (resize sheet
  pre-exists) + TSK-1309 (Box button already removed) → review; TSK-1320 (annotations clarity — editability
  solved by TSK-1321; the 3-overlapping-shape-surfaces CONSOLIDATION is an owner a/b/c UX decision, recorded
  as a comment since the park-ping failed).

**TRACKER TOOLING BUG (this session):** task_park / task_advance's SECOND string param (`context` / `note`)
silently fails to register — re-calls don't help. Workaround: task_comment (single `body` param) to record
the disposition, or split into separate calls. Worth an INT ticket.

**HOST VEIN WORKED THROUGH (2026-06-30) — verified item-by-item, the triaged queue is at its host-ceiling:**
TSK-1146 (validated), TSK-1186 (11 clean FILE-WRITE verbs shipped; the render-panel commands are AppDelegate
NSAlerts needing an NSAlert→model-flag-panel refactor = render, not a host descriptor-add), TSK-1315
(diagnosed: NO central focus coordinator → panes compete for first-responder; fix = a render-VM focus
refactor + the owner's repro), TSK-382 (perf, measure-first), TSK-751/781/1128/1182/1305/1320 (owner-decisions),
TSK-1303-wiring (data-safety). NO clean fresh-buildable-host item remains; the high-value tails are
owner/VM/measure-gated — NOT a "host-vein-drained → render-is-owner's-lane" claim (that framing is banned),
but an honest end of the *clean host-completable* work after a comprehensive render + intake delivery.

**THE DURABLE RULE (also LESSONS):** "T5-blocked" ≠ "render-blocked." Split every render item into
(render build + non-T5 structure/DOM/in-process validation) vs the narrow slice that truly needs T5
(pixel-exact / occlusion-composite) or AX (faithful pointer/key gesture). Build + validate the former;
carve the latter into a child. **THREE owner-actions unblock the most remaining work:** TSK-1334 (T5
re-grant → reopens ALL occlusion/pixel), TSK-1149 (feed surfacing a/b/c), TSK-1305 (tonal-undo UX).
**NEXT buildable (no owner):** a TEXT-element inspector (TSK-1310 — a separate text-overlay type, not a
VectorShape) is the remaining non-AX image-edit render path; then frame-field follow-ons.

## ⭐ SINCE THE LAST REFRESH (11 → 16 validated) + THE END-STATE MAP — READ THIS
**NEW validated:** TSK-1306 (New-Image landing button) · TSK-1325 (image format/quality CONVERT — View ▸ Convert Image, full primitive→off-main-VM→UI) · TSK-1323 + TSK-1324 (audio extract-from-video + format/quality convert — View ▸ Extract Audio / Convert Audio, shared VM+panel). **NEW at review:** TSK-1326 (walkthrough authoring guide + parse-validated sample — `docs/WALKTHROUGH_AUTHORING.md` + `docs/examples/sample-walkthrough.json`; the in-app "New Walkthrough" affordance is the follow-on). **PARKED (owner decision):** TSK-1305 (image full-undo — tonal-undo overturns the DELIBERATE live-slider design; needs the owner's UX call).

**⚠️ THE P0 WEBVIEW BUGS ARE FIXED-AT-HOST + AT-REVIEW + AX-BLOCKED FOR ON-SCREEN — DO NOT re-attempt webview synthesis.** TSK-1188 (plain-click-after-scroll, fix `c0fd1543` + grep-guard), TSK-1271 (rendered-MD find scroll, fix `6e9e4efb` + FindCoordinatorTests), TSK-910 (commit-diff multi-line, host core `f809e271`; render slice = child TSK-1182). Their on-screen confirm needs a FAITHFUL POINTER/KEY GESTURE, which is **NOT tractable in the in-process webview lane** — VERIFIED across 4 VM rounds on TSK-1188 (synthesized MouseEvents don't drive CM6's MouseSelection; caret introspection returns nil even past a faithfulness gate). That's the AX/spawned-app tier. See LESSONS (headless-webview CM6 gesture synthesis + the `evaluateJavaScript` unsupported-type trap → append `; true;`). **The webview lane is for STATE-driven render assertions (cmDispatch → DOM query — diagnostics/autocomplete/folds/pickers), NOT gestures.**

**END-STATE — what's left + why each isn't a quick win** (verified by traversing the whole intake + P0 list this session): (a) **AX-tier on-screen confirms** — the P0 gesture/key bugs above (fixed; await the AX/spawned-app lane or an owner glance); (b) **T5-pixel render** — ⚠️ SUPERSEDED by the SINCE-16 section above: the render was non-T5-validatable all along (TSK-1333 mermaid + TSK-1149 feed + TSK-1321 inspector SHIPPED + validated); ONLY the occlusion-COMPOSITE (TSK-1336) needs T5 (blocked on TSK-1334), and the on-canvas drag is AX, not T5; (c) **data-safety** — TSK-1303 (edit-state persist) + TSK-1311 (session-state) — do NOT build the capture/restore wiring blind; (d) **parked design** — TSK-1305 (tonal-undo), TSK-1318 (menu reorg), TSK-1322 (paste); (e) **large features** — TSK-1319 (dynamic per-tab menu), TSK-1182 (diff single-Text render slice), TSK-1327 (smart-paste wiring — sensitive, overlaps 1322); (f) **P2-host** — TSK-382 (memory, measure-first), TSK-538 (rust-core), TSK-852 (.build cache — owner wants SPEED not storage), TSK-441–445 (CI). **NEXT agent:** prioritize TSK-1334 (the T5 re-grant reopens the whole canvas vein), else a P2-host item, else validate/reconcile toward owner-close. Do NOT re-mine the intake or the P0 webview bugs — they're correctly at-review/blocked.

## What shipped this session (4 render epics validated via the in-process template)
Render is FIRST-CLASS agent work — built + VM-validated, not handed to the owner. The template —
**view-model (host-tested) → SwiftUI panel → DocumentModel wiring → menu trigger → in-process
NSHostingView VM-hosting-test (webview lane) → validated** — drove FOUR owner-wishlist epics from
foundation-only to VALIDATED:
- **★ TSK-698 Script Console — VALIDATED.** View ▸ Script Console: JS query/transform over JSON/log/CSV, off-main, Apply→new-tab.
- **★ TSK-1161 Structural Search — VALIDATED.** View ▸ Structural Search: AST query (DSL) → ranged-match list.
- **★ TSK-1160 Task Runner — VALIDATED.** View ▸ Task Runner: discover package.json/Cargo/Makefile → Run → captured output (bounded, off-main).
- **★ TSK-1176 Terminal Command Palette — VALIDATED.** View ▸ Terminal Command Palette: search history+favorites → insert at prompt.

Plus:
- **TSK-1032** HEX byte-grid "blank" resolved as a T4 UAT false-negative (`numberOfGlyphs` is TK1-only, ~0 for the TK2 fixed-grid view) + a reliable host guard (`dc1caa45`); TSK-1332 filed for the UAT-harness fix.
- **TSK-1155** jump-to-step coordinator primitive landed (`06d51f11`), PARKED — the live-timeline UI needs the action-history INTEGRATION (unify-vs-separate-undo = TSK-703 architecture decision, owner).
- **settle() gate flake KILLED (`8c06b297`)** — it bit 3 gates; now 2-consecutive-empty quiescence ⇒ reliably green.
- Earlier: owner intake TSK-1302–1327, host slices (audio-persistence/overlay-selection/structural grammar).
- **TSK-1119 walkthrough illustrations ON SCREEN (review, `111bcab3`).** WalkthroughDiagramOverlay renders .ascii/.image + caption (occlusion-free, VM-validated); .mermaid shows source as interim. Slice 2 (rendered Mermaid) = TSK-1333.
- **TSK-1333 Mermaid-render foundation built; T5 owner-blocked.** WalkthroughMermaidPage (page builder, host-tested, `9482349e`) + WalkthroughMermaidWebView (WebView component, mount-validated on the VM, `62c400c6`). The occlusion verification needs T5-pixel.
- **NEW `pixel` targeted-T5 mode (`74796e9f`)** — `test-in-vm.sh pixel --filter <PixelSuite>` runs ONE T5 suite in ~50s (no full-`all` kill). BUT discovered the T5 screencapture is **TCC-DENIED** (owner-only re-grant, SIP) → **TSK-1334 filed**; ALL T5-pixel CAPTURE is owner-blocked until re-granted.
- **★ TSK-958/1163 Universal Paste — VALIDATED (`c32ee925`).** Edit ▸ Paste as New Document (⇧⌘V) → dispatch each clipboard kind to the right viewer (image/table/text/file). Was wrongly held at review-as-VM-only; host-testable via an INJECTABLE NSPasteboard (UniversalPasteActionTests 3/0).
- **★ TSK-1146 Spell/LSP squiggles — VALIDATED (`29e4c48b`).** Editor spell underlines + LSP diagnostics; logic host-tested at every layer + the RENDER webview-guarded (EditorDiagnosticsWebViewTests: setDiagnostics → `.cm-lintRange` in the live CM6 DOM, VM 2/0). The webview lane is NOT TCC-blocked (≠ T5 screencapture).
- **★ TSK-1136/463 LSP autocomplete — VALIDATED (`ff7be92d`/`7bf25128`).** Did the rebundle session: exposed `startCompletion` (entry.js + `npm run build`) → EditorCompletionWebViewTests proves the editor INVOKES completion (requestCompletion post) + the popup renders (`.cm-tooltip-autocomplete`). VM 1/0.
- **★ TSK-1312 terminal colours — VALIDATED (`15b6cb49`).** User bug "colors off running claude code": theme-aware TerminalPalette + Settings picker; SettingsTerminalColorSchemeHostingTests (in-process host SettingsView → the colour-scheme NSPopUpButton renders with the AnsiTheme options incl. Classic xterm).
- **★ TSK-1314 side-nav toggle — VALIDATED (`05fcca7c`).** User bug: file-tree showed with its shoulder toggle OFF. SidebarFilesToggleHostingTests (count-delta: the filesPanel subtree drops when .files=.hidden).
- **★ TSK-1316 empty shoulders — VALIDATED (`fb283787`).** User bug: empty shoulder bars always showed. ShoulderRailView gated on `if hasContent || isDraggingPanel`; ShoulderRailEmptyHidingHostingTests (count-delta).
- **★ TSK-1308 audio-survives-switch — VALIDATED (`f06098fe`).** User bug: switching session stopped music. App-level AudioPlaybackController.shared holds the player; AudioPlayerHostIntegrationTests (host → controller registers URL → teardown → SAME player survives).
- **NEW REUSABLE TECHNIQUES this session:** (1) **In-process NSHostingView host-tests** for SwiftUI render — host the view, walk the NSView tree for a concrete control (NSPopUpButton) OR use a **COUNT-DELTA** when SwiftUI `.accessibilityIdentifier` on a Text doesn't surface as a walkable NSView id. `#192`-gated, run via the webview lane (`MDV_WEBVIEW_FILTER=...`). (2) The **codemirror.js rebundle** path (`scripts/codemirror-build`: edit entry.js + `npm run build`) to expose CM6 commands. (3) **Retry-the-measure flake harden** (`e625bf81`): the find-typeahead body-eval flake recurred even with 2-consecutive-empty `settle()` under a heavier gate — durable fix is re-running the measure with a VARYING mutation (the action's effect is deterministic, noise clears).

## ⭐ NEXT ACTION — render is NOT exhausted: the WEBVIEW + host-completable lanes are OPEN; only T5-SCREENCAPTURE is owner-blocked + AX off-limits
**CRITICAL — DO NOT re-make the "render exhausted → host P2" mistake.** A prior version of this NEXT said exactly that; it was the SAME premature error the owner banned, and it was DISPROVEN this session by validating TSK-958 (universal paste, host) + TSK-1146 (spell squiggles, webview) AFTER it was written. The lanes:
- **WEBVIEW lane: OPEN + agent-runnable** — in-process WKWebView + JS DOM introspection (`MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=ViewerUITests.<Suite> bash scripts/test-in-vm.sh webview`). NOT TCC-blocked (≠ the T5 screencapture lane). Validated TSK-1146's diagnostics render via it (EditorDiagnosticsWebViewTests, the FoldGutter pattern: load codemirror.html → cmDispatch → query the CM6 DOM). Next render = un-drained webview-lane (CM6/rendered) items.
- **Host-completable feature logic: OPEN** — injectable-seam actions (universal paste was one). "AppKit/pasteboard = VM-only" is OFTEN FALSE — look for an injectable seam (NSPasteboard arg, etc.).
- **VERIFY-BEFORE-BUILD (recovered MANY items this session):** review-pool items sit wrongly labeled "VM/owner-only" but are host/in-process-validatable (TSK-1163/1146/1312/1314/1316/1308 all were). `task_get` + grep the seam before assuming un-agent-workable.
- **The EASY in-process vein is now largely worked** (separable views with findable controls / clean count-deltas). The REMAINING review-pool intake items are HARDER render-validations: button DELETIONS (TSK-1309 — absence has no clean positive teeth), empty-title buttons in the big ContentView empty-state (TSK-1306), partial host-slice+UI-tail features (TSK-1325 image-convert, TSK-1327 smart-paste — the convert/paste PRIMITIVE is host-done+tested, the UI/live-wiring tail is unbuilt), image-editor CANVAS (TSK-1307 resize, TSK-1321 selectable elements, TSK-1310 text-edit — T5/AX), and layout (TSK-1313 terminal-expand — T5/in-process). Pick the ones whose UI tail is buildable + in-process-assertable; the canvas/T5 ones wait on TSK-1334 or are AX.
- **T5-SCREENCAPTURE (occlusion/pixel): OWNER-BLOCKED (TSK-1334)** — Screen-Recording grant TCC-denied (owner-only, SIP). When re-granted, `test-in-vm.sh pixel --filter <Suite>` (the new targeted-T5 mode) reopens it → land **TSK-1333** (mermaid occlusion, fully scoped + foundation-built) + TSK-955/1149.
- **AX-interaction: OFF-LIMITS** (the one excepted tier): TSK-924/1187, TSK-1139/1141.
- **Focused-session item:** TSK-1136/463 completion render — expose `startCompletion` (entry.js) + `npm run build` rebundle → a webview render guard (scoped on TSK-1136).
- **Host P2 (legit, but NOT as an escape from render):** TSK-382/538/764. Work the open webview/host RENDER lanes first.

## Owner-input-gated (the genuine exceptions — task_park, don't block)
- Parked: TSK-1200 (scroll: real-bug-vs-harness-false — needs owner's real screen), TSK-1322 (paste repro), TSK-1320 (annotations keep/remove). Flips: TSK-838/1215/1202.
- AX-driven tests = the one off-limits tier.

## Gotchas / lessons (also LESSONS.md)
- **SwiftUI render VM-validation pattern (worked for the console):** in-process host the SwiftUI view in an `NSHostingView`+`NSWindow` (a `WebViewTestCase`, `#192`-gated), force `layoutSubtreeIfNeeded`, walk the NSView hierarchy — sidesteps the TSK-1247 spawned-app framebuffer bug. Add the suite to `run_webview_tests`' filter list (+ use `MDV_WEBVIEW_FILTER=ViewerUITests.<Suite>` to run just it), then `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=… bash scripts/test-in-vm.sh webview`. ASSERT ON STRUCTURE not titles: a SwiftUI `Button("X")` bridges to an NSButton whose `.title` is EMPTY (label is a subview) — assert `count`/types (NSButton/NSSegmentedControl/NSTextField), not `.title=="X"`.
- **`test_findTypeahead_doesNotReBodyChromeStrip` (ChromeBodyEvalCountTests) flake — FIXED (`8c06b297`).** It bit 3 gates this session: `settle()` declared quiescence on a SINGLE empty pump, so a slow async residual under the 18-worker load leaked into the measured window. Fixed: `settle()` now requires TWO consecutive empty pumps (sustained-idle) + doubled the bound (12→24). Gates reliably green. (LESSONS: "quiescent" must mean sustained-idle, not a single idle tick.)
- **The VM render lanes work — use the RIGHT one.** Webview (in-process WKWebView) for WebView/CM6 render; T5 window-ID capture for SwiftUI/AppKit pixels. The SPAWNED-APP UAT lane has a framebuffer-compositing bug (TSK-1247 — the app window isn't composited so live-WebView reads return -1/0); that's a SPECIFIC broken lane to fix/route-around, NOT a reason to call render "un-workable." Don't grind the full `all`-mode UAT (it gets killed) — use the targeted lane.
- **Owner-sensitive scroll (TSK-1200):** the editor-scroll "no-op" seen via the spawned-app UAT is harness-false (the framebuffer bug). Disambiguate real-vs-harness on the owner's real screen / T5 window-ID before changing scroll code (parked). Don't blind-fix.
- **Backticks in `git commit -m "..."` trigger shell command-substitution** → mangled message. Use `git commit -F -` with a `<<'EOF'` heredoc.
- **Read-first ALWAYS** — most P0/board items were already fixed→review or stale-reset-but-done (1188 `c0fd1543`, 1271 `6e9e4efb`, 343 delta-storage); don't re-build.
- **The INT-126 lease sweep re-resets long-lived `progress` items to `reported`** — `review` sticks, `progress` doesn't. To permanently drain a host-done/render-tail epic, take it to review (host done) with the render UI tracked as a child to BUILD on the VM.

## Tracker (tasked / claude-mdv)
VALIDATED this session (16): TSK-698 · TSK-1161 · TSK-1160 · TSK-1176 · TSK-958/1163 (universal paste) · TSK-1146 (spell/LSP squiggles) · TSK-463/1136 (LSP autocomplete) · TSK-1312 (terminal colours) · TSK-1314 (side-nav toggle) · TSK-1316 (empty shoulders) · TSK-1308 (audio-survives-switch) · TSK-1306 (New-Image landing) · TSK-1325 (image convert) · TSK-1323 + TSK-1324 (audio extract/convert) · + TSK-1032 (harness-false + guarded). REVIEW: TSK-1326 (walkthrough authoring guide+sample) · TSK-1188 (plain-click fix + grep-guard; AX-tier on-screen) · TSK-1271 (find-scroll fix; AX-tier) · TSK-910 (diff multi-line host core; render slice = TSK-1182) · TSK-1119 (illustrations; mermaid = TSK-1333) · TSK-1309/1313 (intake). PARKED (owner): TSK-1305 (tonal-undo design) · TSK-1155 (architecture) · TSK-1333 (T5 → TSK-1334) · TSK-1182/1200/1320/1322 + flips 838/1215/1202. FILED: **TSK-1334 (VM screencapture TCC re-grant — OWNER ACTION, blocks ALL T5-pixel)** · TSK-1332 (UAT-harness). NEW infra/LESSONS: `pixel` targeted-T5 mode · in-process NSHostingView host-tests (control-walk / count-delta) · codemirror rebundle · retry-the-measure flake harden · **headless-webview can't synthesize CM6 gestures (TSK-1188, 4 rounds) — webview lane = state-driven assertions only** · evaluateJavaScript-function-assignment → append `; true;`. ~85 commits this run.

## How to resume
Read this + `BACKLOG.md` + `git log -1`. Confirm main gate-green (`bash scripts/test-headless-gate.sh` — reliably green now). The clean in-process render template is DONE (4 epics validated). Take the NEXT-ACTION vein: **T5-pixel render** (TSK-1119 overlay = highest value — build occlusion-safe `compositingGroup().zIndex` + T5-validate, NOT in-process [false-green trap]) OR **host P2** (TSK-382/538/764). Render is your lane (build + VM-validate); only AX-interaction tests + owner-gated items are off-limits. Do NOT re-pick the validated epics or blind-build the occlusion/AX items via the in-process test.
