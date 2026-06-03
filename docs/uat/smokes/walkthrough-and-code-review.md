# UAT smokes — Walkthrough player + Code Review

**Area:** Automation / guided tours · Code review
**App under test:** `dist/TextView.app` (Finder name TextView.app), bundle id `com.markdownviewer.MarkdownViewer`
**Primary surfaces exercised here:**

- **Walkthrough player strip** (`mdv.walkthrough.player`, docked-bottom, 28 px idle / ~120 px narrating): speaker pill (`mdv.walkthrough.speaker`), narration line (`mdv.walkthrough.narration`, ≤ 3 lines + reserved blank), scrub/progress capsule (`mdv.walkthrough.scrub`), transport prev/play-pause/next (`mdv.walkthrough.prev` / `.playpause` / `.next`), speed menu (`mdv.walkthrough.speed`, 1x/1.5x/2x), Steps jump menu (`mdv.walkthrough.steps`), Note button (`mdv.walkthrough.note`), Exit (`mdv.walkthrough.exit`)
- **Walkthrough window-root overlay** (coordinate space `walkthroughOverlay`): persistent highlight stripe over a line range (focus=accent / warn=orange / info=blue / agent=purple), transient flash stripe (fades `durationMs`), popover card (body + Dismiss) with line / surface / container anchoring
- **Walkthrough engine** (`WalkthroughPlayerImpl`, `WalkthroughAutoAdvance`): JSON script `textview.walkthrough/v1` + `/v2`, 13 step verbs (`openFile`, `revealLine`, `highlightRange`, `flash`, `showPopover`, `setView`, `splitFile`, `runDiff`, `awaitUser`, `addBookmark`, `revealInSidebar`, `openGitPanel`, `narrateOnly`), `--walkthrough PATH` CLI flag, `File ▸ Walkthroughs` submenu, file-drop inbox transport (env-gated `TV_WALKTHROUGH_DROP=1`)
- **Code review document surface** (`ReviewTabView`): toolbar (title + state line + toggle-comments + **Mark Complete** + **Export…**), review-aware `DiffView`, 280 pt `CommentSidebar`
- **Comment thread UI** (`CommentCards`): severity dot + label (6 severities — Blocker red / Issue orange / Suggestion blue / Question purple / Info secondary / Praise green), line/range, resolved tag, staleness badge, body, reply rows, action row; inline `CommentEditorView` composer (severity Picker + monospaced TextEditor)
- **Git-panel `.review` index tab** (`ReviewIndexTab`, one of the 6 Git-panel tabs): review summaries (title, `<state> · N comments`, unresolved-count badge); tab badge = total unresolved
- **Review store** (`ReviewStore+ProjectLocal`, project-local `.textview/reviews/`, git-ignored; `_index.json` currently empty) + `ReviewSession` (state machine draft → inReview → complete → sent) + `ReviewExporter` (JSON to clipboard, Cmd+Shift+E)

---

## Conventions / common preconditions

These apply to every smoke unless overridden in the smoke's own preconditions block.

- **Fixtures live under temp, never under protected roots.** Create scratch git repos / files under `FileManager.default.temporaryDirectory` (per-user `/var/folders/...`) — **never** `~/Documents`, `~/Desktop`, `~/Downloads`. Walkthrough scripts go alongside.
- **Walkthrough scripts are JSON, `schema: "textview.walkthrough/v1"` (or `/v2`).** A v1 reader handed a v2-only verb **rejects the whole load** (`UnsupportedSchemaError`) — it never partially plays. Always pin the schema you intend to test.
- **`rootHint` is mandatory for the drop transport** and load is rejected if a step's path resolves outside it via `..`. The `--walkthrough` CLI path fills `rootHint` from the frontmost window's working dir when absent. Use **absolute** step paths under the fixture root to keep the path-escape pass happy.
- **The file-drop inbox transport is OFF by default** — it throws `envGateDisabled` unless launched with `TV_WALKTHROUGH_DROP=1`. For the default smoke set, drive walkthroughs via the `--walkthrough PATH` CLI flag or the `File ▸ Walkthroughs` submenu. Only the explicit drop-transport smoke sets the env var.
- **Known walkthrough gaps that are EXPECTED current behavior (log, do NOT fail unless the spec line says "fail"):**
  - `awaitUser` **pauses the engine but renders NO prompt / placeholder / reply-pills UI** — the walkthrough silently halts on an `awaitUser` step. The payload carries prompt + pills; neither the player strip nor the overlay shows them.
  - The per-step **Note button is visual-only** (bumps `noteNonce` + emits a stderr crumb; the "Code Review hookup" is pending). It does not create a review comment.
  - **`runDiff` discards `p.sha`** — it only surfaces the git log, not the per-SHA diff.
  - **Drop-transport rejections + CLI load failures surface only via the delegate / stderr** — there is **no in-app error UI** for a bad script.
  - Branching reads `guardOn` but the branch-choice **UI is not wired**.
- **Known code-review gaps that are EXPECTED current behavior (log, do NOT fail unless the spec line says "fail"):**
  - There is **NO rendered affordance to CREATE a comment in the diff** — the hover-gutter composer and add-comment flow are **unwired**. You cannot author a new comment through the live UI; comments must be seeded into the store fixture.
  - **Reply / Edit / scroll-to-anchor are inert stubs.** Resolve/Reopen and Delete are wired; Reply and Edit affordances render but do nothing.
  - `exportToFile` (NSSavePanel) is **unreachable** from the UI — only **Export… → clipboard** (Cmd+Shift+E) is reachable.
  - `draftInstructions` has **no editor UI** (defaults to `ReviewExporter.defaultInstructions`).
  - `ReviewTabView` is **not yet a first-class document tab** — it is reached via the Git-panel `.review` tab / interim surface, not the per-file TabBar.
  - The on-disk store is **project-local `.textview/reviews/` and git-ignored by owner decision**; `_index.json` ships **empty** (no review threads recorded). A review only exists after a `ReviewSession` is created + flushed.
- **There is NO walkthrough or review script verb** in `ScriptVerbDispatch` (the dispatcher exposes open/view/zoom/tabs/git-panel/sidebar/etc., not walkthrough playback or review authoring). Headless / T4 companions must drive walkthroughs via the `--walkthrough` launch flag and assert at the engine layer (`WalkthroughPlayerImpl`, `WalkthroughAutoAdvance`), and drive review at the store/session layer (`ReviewStore+ProjectLocal`, `ReviewSession`, `ReviewExporter`) — the live diff overlay has no add-comment entry point to script.
- The walkthrough overlay **only renders highlights/flashes when `h.url == currentURL`** and the target line range is on-screen and post-layout (`lineHeight > 0`); off-screen or pre-layout ranges are silently skipped — not a bug.

---

## WCR-01 — CLI-launched v1 walkthrough: auto-advance through openFile + revealLine + highlightRange + setView, driven by the transport bar

**Combines:** `--walkthrough` CLI launch · engine load + first-runloop-tick activation · player strip appearing only when active · auto-advance scheduler dwell · `openFile` / `revealLine` / `highlightRange` / `setView` verbs translating to `DocumentModel` mutations · persistent highlight stripe in the overlay · transport prev/next/play-pause · speed menu reschedule · Steps jump menu · scrub capsule

**Preconditions**

- A scratch fixture folder `tour/` under temp containing 2–3 small source files (e.g. `main.swift`, `helper.swift`, `README.md`) and a walkthrough script `tour.json` with:
  - `schema: "textview.walkthrough/v1"`, `rootHint` = absolute path to `tour/`, a `title` + `author` (e.g. `claude:opus-4.8`).
  - ~5 steps, each with `narration` and `dwellSec` (~2 s) — mixing verbs: step 1 `openFile main.swift` + `setView source`, step 2 `revealLine` (a mid-file line), step 3 `highlightRange` with `kind: focus` over a few lines, step 4 `openFile helper.swift`, step 5 `narrateOnly`.
- App launched with `--walkthrough /abs/path/tour/tour.json` (this fills `rootHint` if absent and arms playback after one runloop tick).

**Steps**

1. Launch the app with `--walkthrough …/tour.json`. Wait one runloop tick.
   → The docked-bottom **player strip** (`mdv.walkthrough.player`) appears (engine left `.idle`). Speaker pill shows the step's `speakerLabel` (falls back to `claude` when `currentStep` is nil). Step 1 runs: `main.swift` opens in **Source** view; narration line (`mdv.walkthrough.narration`) shows step 1 text; scrub capsule (`mdv.walkthrough.scrub`) reads step 1 of N; a11y label "Step 1 of N".
2. Let the auto-advance scheduler dwell `dwellSec` and advance to step 2.
   → After the dwell, the engine advances: `revealLine` scrolls the Source view to the target line; narration updates; scrub progresses to 2/N. Prev (`mdv.walkthrough.prev`) is now enabled (was disabled on step 1).
3. Let it advance to step 3 (`highlightRange kind: focus`).
   → A **persistent accent highlight stripe** appears over the target line range in the window-root overlay. It re-positions live if you scroll the Source view (highlight tracks the line, not a fixed rect). Stripe color reflects `kind` (focus = accent).
4. Press **play-pause** (`mdv.walkthrough.playpause`) to pause.
   → Auto-advance halts; the play-pause icon flips to `play.fill`; the current step + highlight stay put. Pressing it again resumes the dwell timer.
5. Open the **speed** menu (`mdv.walkthrough.speed`), pick **2x**.
   → The pill label updates to `2x`; the dwell scheduler reschedules — subsequent advances happen at half the dwell. (1x / 1.5x / 2x are the offered options.)
6. Open the **Steps** jump menu (`mdv.walkthrough.steps`), pick step 4.
   → `engine.jumpTo(4)` runs immediately: `helper.swift` opens (the step's `openFile`), narration + scrub jump to 4/N, the step-3 highlight (whose `url != currentURL` now) is no longer rendered.
7. Click **next** (`mdv.walkthrough.next`) to reach the last step.
   → Reaches step 5 (`narrateOnly`): narration shows, **no** content mutation. Next is now **disabled** (last step); prev still enabled.

**Expected end state:** the tour played start-to-finish; every verb landed its `DocumentModel` mutation in order; the highlight stripe tracked the source scroll; transport (prev/next/play-pause), speed, scrub, and Steps-jump all drove the engine; the strip remained docked through completion.

**Variations / edge states**

- **Done state:** after the last step auto-advances (or you jump to it), auto-advance is cancelled but the strip **remains** until you press **Exit** (`mdv.walkthrough.exit`). Confirm Exit tears down the strip + clears any overlay highlight.
- **Empty narration:** a step with empty `narration` reserves a blank line (height does not jump). Confirm the narration row keeps its envelope.
- **First/last disable:** on step 1 prev is disabled; on the last step next is disabled. Verify both at the boundaries.
- **Highlight off-screen:** scroll so the highlighted range is fully off-screen — the stripe hides (it only renders when on-screen + post-layout); scroll back → it re-appears anchored correctly. No stray rect at the top.
- **`flash` verb:** add a step with a `flash` (transient stripe, `durationMs`) — it pulses once and fades; re-triggering (flashNonce bump) re-pulses. It does not persist like `highlightRange`.
- **Speed during pause:** change speed while paused, then resume — the new speed takes effect on the next dwell.

---

## WCR-02 — Multi-target walkthrough: showPopover anchoring + splitFile + revealInSidebar + openGitPanel + addBookmark all driven by the script

**Combines:** `showPopover` card with line/surface/container anchoring + Dismiss + overlay hit-testing · `splitFile` (selects primary pane) · `revealInSidebar` (idempotent) · `openGitPanel` (idempotent) · `addBookmark` (idempotent, tour-namespaced) · multi-pane targeting · overlay coordinate space `walkthroughOverlay`

**Preconditions**

- A scratch **git repo** `proj/` under temp (`git init`, one commit) with `a.swift`, `b.swift`, and a nested folder. App built with the source-load fix (`main 798b7ee` or later — earlier builds cannot load source files).
- A `multi.json` walkthrough (`schema /v1` or `/v2`, `rootHint` = `proj/`) with steps:
  1. `openFile a.swift` + `setView source`
  2. `showPopover` anchored to a line in `a.swift` (body text + `surface`/`container` hint)
  3. `splitFile b.swift` (open `b.swift` alongside; the verb selects the primary pane)
  4. `revealInSidebar a.swift`
  5. `openGitPanel` (status tab)
  6. `addBookmark a.swift:<line>`
- Launched via `File ▸ Walkthroughs ▸ multi.json` (the submenu) **or** `--walkthrough …/multi.json`.

**Steps**

1. Start the walkthrough. Let it reach step 1.
   → `a.swift` opens in Source.
2. Advance to step 2 (`showPopover`).
   → A **popover card** renders in the window-root overlay, anchored to the target line (falls back to container-alignment when the surface frame isn't registered). The card shows the body text + a **Dismiss** button. While the popover is present, the overlay **hit-tests** (it is otherwise pass-through, `allowsHitTesting false`). Click Dismiss → card disappears.
3. Advance to step 3 (`splitFile b.swift`).
   → Split view engages; `b.swift` opens in a second pane alongside `a.swift`; the verb **selects the primary pane** as the active target (so subsequent verbs land where intended).
4. Advance to step 4 (`revealInSidebar a.swift`).
   → The sidebar reveals + selects `a.swift` (expands ancestors, roots if needed). This verb is **idempotent** — re-running it does not toggle/collapse.
5. Advance to step 5 (`openGitPanel`).
   → The GIT accordion section opens to the Status tab (idempotent — already-open is a no-op, no flicker).
6. Advance to step 6 (`addBookmark a.swift:<line>`).
   → A bookmark is added at that line; it is **namespaced `[tour]`** (tour-pinned). A star/gutter-dot appears for it.
7. Press **Exit** (`mdv.walkthrough.exit`).
   → Strip + overlay tear down. **Tour-pinned `[tour]` bookmarks are removed on exit** — confirm the line bookmark added in step 6 is gone from the Bookmarks section (it was tour-scoped, not a user bookmark).

**Expected end state:** popover anchored + dismissable with correct hit-testing; split engaged with the right primary pane; sidebar + git panel revealed idempotently; the tour bookmark added and then cleaned up on exit.

**Variations / edge states**

- **Popover overlay hit-testing:** while NO popover is present, clicking "through" the overlay reaches the content beneath (pass-through). Only when a popover is shown does the overlay capture clicks. Verify both.
- **`splitFile` on too-large file:** point `splitFile` at a > 64 MiB file → the split pane shows `File too large for split view`; the walkthrough does not crash, just shows the placeholder.
- **`revealInSidebar` when sidebar hidden:** if the sidebar is collapsed, confirm the verb's behavior (reveal should still resolve at the model level even if the section is not visible) — log whether it force-shows.
- **`openGitPanel` outside a repo:** run `multi.json` against a **non-repo** fixture folder → the GIT section either stays hidden or force-shows the `Not a git repository.` placeholder. No crash.
- **Bookmark survives mid-tour:** a `[tour]` bookmark is visible while the tour is active and only removed on Exit (not on step advance). Confirm it persists across steps until Exit.
- **Container-anchoring fallback:** author a `showPopover` whose `surface` frame is never registered → the card falls back to container alignment rather than vanishing.

---

## WCR-03 — awaitUser silent-halt + Note-button + runDiff + schema-rejection: the honest-gaps walkthrough

**Combines:** `awaitUser` engine pause with **no UI** (documented gap) · Note button visual-only crumb · `runDiff` surfacing git log only (sha discarded) · v1-reader rejecting a v2-only verb (`UnsupportedSchemaError`) · CLI load-failure surfacing only via stderr (no in-app error UI)

**Preconditions**

- Two walkthrough scripts under a git-repo fixture `proj/`:
  - `await.json` (`schema /v1`, valid `rootHint`): step 1 `openFile`, step 2 `awaitUser` (with a `prompt` + reply `pills` in the payload), step 3 `narrateOnly`.
  - `bad-v2.json` (`schema "textview.walkthrough/v1"` but containing a **v2-only verb** the v1 decoder does not know) — to exercise the strict reject.
  - `rundiff.json` (`schema /v1`): step `runDiff` with a `sha` field set + a `path`.

**Steps**

1. Launch `--walkthrough …/await.json`. Let it auto-advance to the `awaitUser` step (step 2).
   → The engine **pauses** (`pendingAwaitUser` stashed). **NO prompt, placeholder, or reply-pills UI is rendered** — the walkthrough silently halts on this step. The strip stays (play-pause shows the paused icon). This is the **expected current behavior**: log it; the only way forward is manual transport.
2. Press **next** (`mdv.walkthrough.next`) to manually advance past the awaitUser step.
   → Advances to step 3 (`narrateOnly`) — confirming the engine isn't dead, it was just waiting on a reply that has no UI to deliver.
3. Press the **Note** button (`mdv.walkthrough.note`).
   → `noteNonce` bumps + a stderr crumb is emitted. **No review comment is created**, no panel opens, no visible UI change beyond a transient button press. Expected current behavior (Code-Review hookup pending) — log it.
4. Exit, then launch `--walkthrough …/bad-v2.json`.
   → The load is **rejected wholesale** (`UnsupportedSchemaError` for the unknown verb under a `/v1` schema). **No player strip appears** and **no in-app error UI** is shown — the failure surfaces only on **stderr** / via the load delegate. Verify the app does not crash and stays usable. Fail only if the app crashes or partially plays.
5. Exit, then launch `--walkthrough …/rundiff.json` against `proj/`.
   → The `runDiff` step surfaces the **git log** (not the per-SHA diff) — `p.sha` is **discarded** in v1. Confirm a git log tab/view appears and that the specific SHA's diff is *not* shown. Log this as the documented `runDiff` gap.

**Expected end state:** awaitUser halts silently with no reply UI (manually advanceable); Note is a no-op crumb; a v2-verb-in-v1 script is fully rejected with stderr-only signal and no crash; runDiff shows only the log.

**Variations / edge states**

- **Unknown verb in matching schema:** a `/v2` script with a verb that *no* decoder knows → graceful unknown-verb decode error, no partial play.
- **Missing `rootHint` via drop transport:** (see WCR-05) a script without `rootHint` loaded through the drop transport throws (the loader requires it). Via `--walkthrough` the rootHint is backfilled from the window's working dir.
- **awaitUser with empty pills:** confirm even an `awaitUser` carrying zero pills still just halts (no spurious empty pill row, since there is no pill UI at all).
- **Note while paused vs playing:** press Note in both states — same crumb-only behavior, no engine state change either way.
- **Load a nonexistent path:** `--walkthrough /tmp/does-not-exist.json` → no strip, stderr-only failure, app stays alive.

---

## WCR-04 — Code review end-to-end: seeded threads in the Git-panel .review tab → diff overlay with severities/staleness → resolve → Mark Complete → Export to clipboard

**Combines:** Git-panel `.review` index tab + unresolved-count badge · review state machine (draft → inReview → complete → sent) · review-aware `DiffView` with comment threads · 6-severity rendering + resolved tag + staleness badge · Resolve/Reopen (wired) + Delete (wired) · toggle comment sidebar · **Mark Complete** gating · **Export…** to clipboard (Cmd+Shift+E) + `.sent` transition

**Preconditions**

- A scratch **git repo** `proj/` under temp with a tracked file `a.swift` that has at least one committed change to diff against (so `DiffView` has hunks).
- A **seeded `ReviewSession`** persisted into the project-local store `proj/.textview/reviews/` (the live UI has **no create-comment affordance**, so comments must be seeded at the store/session layer): a review whose state is `inReview` with **multiple comments** anchored to lines in `a.swift`, spanning **several severities** (at least one Blocker, one Issue, one Suggestion, one Praise) and including **one comment with a reply** and **one resolved** comment. Seed one comment whose anchored code is unchanged (anchor `current`) and one whose surrounding code changed since (anchor `stale`).
- The Git panel can reach the `.review` tab (force-show the Git section via the shoulder rail if needed).

**Steps**

1. Open `proj/` as the session root, open the **Git panel** (`⌥⌘B`), switch to the **REVIEW** tab (`mdv.gitpanel.tab.review`).
   → The Review index lists the seeded review summary: title, `inReview · N comments`, and an **unresolved-count badge**. The `.review` tab itself carries a badge = total unresolved across reviews.
2. Open the review (click its summary) to reach the `ReviewTabView` surface.
   → Toolbar shows the **title + state line** (`inReview · N comments`), a **toggle-comments** control, **Mark Complete**, and **Export…**. The review-aware `DiffView` renders `a.swift`'s hunks **with comment threads inlined**.
3. Inspect the comment threads (`CommentThreadView` cards).
   → Each card shows: a **severity dot + label** in the right color (Blocker red, Issue orange, Suggestion blue, Question purple, Info secondary, Praise green), the anchored **line/range**, the body, and any **reply rows**. The pre-seeded **resolved** comment shows the **resolved tag** + strikethrough styling. The **stale** comment shows the orange `code changed since review` staleness badge; the `current` one shows no staleness warning.
4. On an unresolved comment, click **Resolve**.
   → The thread flips to resolved (strikethrough + resolved tag); the review's **unresolved count drops by one**, reflected in the Git-panel `.review` tab badge and the index summary. Click **Reopen** → it returns to unresolved and the count climbs back. (Resolve/Reopen are wired.)
5. **Delete** one comment (the action is wired — removes the thread + its replies).
   → The thread disappears from the diff overlay and the `CommentSidebar`; comment count in the state line decrements. Confirm the reply attached to a *different* comment is unaffected.
6. Toggle the **comment sidebar** off and on.
   → The 280 pt `CommentSidebar` (severity dot + `file:line` + snippet rows) hides/shows; the inline diff threads remain regardless.
7. Click **Mark Complete**.
   → If the transition is legal (it has ≥ 1 comment → `inReview` → `complete` is allowed), state → `complete`; the toolbar state line updates. (If not legally transitionable the button is **disabled** — see variations.)
8. Click **Export…** (or press **Cmd+Shift+E**).
   → `ReviewExportCoordinator.exportToClipboard` renders the review as **JSON to the system clipboard** using `draftInstructions` (= `ReviewExporter.defaultInstructions`, no editor UI), records an export record, and transitions state → **`.sent`**. Paste elsewhere to confirm valid JSON containing the comments + severities. The state line now reads `sent`.

**Expected end state:** the seeded review is browsable from the Git-panel `.review` tab, its threads render with correct per-severity colors + staleness + resolved styling, Resolve/Delete mutate counts correctly, Mark Complete advances state when legal, and Export copies valid JSON to the clipboard and lands the review in `.sent`.

**Variations / edge states**

- **No create-comment affordance (documented gap):** confirm there is **no hover-gutter composer / "add comment" button** in the diff — you cannot author a new comment through the live UI. Log it; do not fail.
- **Reply / Edit are inert (documented gap):** click Reply and Edit on a thread — the affordances render but **do nothing** (stubs). scroll-to-anchor is also inert. Log; do not fail.
- **Export disabled with no comments:** a review with **zero** comments → **Export… is disabled** and Mark Complete may be disabled (illegal transition from `draft` with no comments). Confirm the gating.
- **Mark Complete illegal:** from an already-`sent` review, Mark Complete should be **disabled** (no legal transition). Verify the button state, not a silent no-op.
- **Staleness flavors:** seed a comment with `anchorState` missing → renders the `.unknown` (`anchor not verifiable`) badge, distinct from the orange `.stale` (`code changed since review`).
- **Empty diff in ReviewTabView:** if the diff fails to load → `No diff loaded.\nReload the review to populate it.` placeholder; comments may still list in the sidebar.
- **`exportToFile` unreachable:** confirm there is **no NSSavePanel "export to file" path** reachable from the toolbar — only clipboard export. Log it.

---

## WCR-05 — Empty/zero-review states + project-local store + flush-race durability + drop-transport gating

**Combines:** review index empty states (no-repo vs repo-no-reviews) · project-local `.textview/reviews/` store + git-ignore-by-default · `_index.json` ships empty · `ReviewSession.flush` serial-queue durability (no stale clobber under concurrency) · drop-transport env gate (`TV_WALKTHROUGH_DROP=1`) + `rootHint` path-escape rejection · FIFO/dedup/debounce of dropped scripts

**Preconditions**

- A **non-git** scratch folder `plain/` and a **fresh git repo** `freshrepo/` (committed, but with **no `ReviewSession` ever created** — so `.textview/reviews/_index.json` is empty or absent).
- For the drop-transport sub-flow: a valid `drop.json` walkthrough with a correct `rootHint`, and a malicious `escape.json` whose step path resolves **outside** `rootHint` via `..`.

**Steps**

1. Open `plain/` (non-repo), open the Git panel → REVIEW tab.
   → Index shows `Open a file in a git repository to start a review.` (no-repo placeholder). No crash, fixed-height envelope.
2. Open `freshrepo/` (git repo, no reviews), Git panel → REVIEW tab.
   → Index shows `No reviews yet.\nStart one from a diff or a commit.` (repo-but-empty placeholder). The `.review` tab badge is absent/zero (no unresolved comments).
3. Inspect the on-disk store for `freshrepo/`.
   → The store lives at `freshrepo/.textview/reviews/` (project-local). `_index.json` is **empty** (or absent until a session writes). Confirm the `.textview/` directory carries the **git-ignore** entry so reviews are not committed by default (owner decision).
4. Seed + flush a `ReviewSession` (store/session layer) for `freshrepo/`, then re-open the REVIEW tab.
   → The summary now appears; the index transitions from empty to one row. This confirms the empty → populated path (and that a review only exists after a session flush — the catalog's "`_index.json` ships empty" claim).
5. **Flush durability:** drive several concurrent `ReviewSession.flush()` calls (rapid resolve/edit churn) — assert at the session/store layer that the **latest** value lands on disk (the drain+write runs as the serial queue's own last block; an older queued block must not clobber a newer value, v0-beats-v50 was the fixed race). Re-read `_index.json` / the session file and confirm it reflects the final state.
6. **Drop transport — gate OFF (default):** with the app launched normally (no env var), drop `drop.json` into the inbox.
   → The transport throws `envGateDisabled` — **nothing plays**, no strip, no error UI (delegate/stderr only). Confirm no walkthrough starts.
7. **Drop transport — gate ON:** relaunch with `TV_WALKTHROUGH_DROP=1`, drop `drop.json` (valid `rootHint`).
   → It loads + plays (FIFO inbox, deduped, debounced; `.json.tmp` / `.partial` ignored). The player strip appears.
8. With the gate ON, drop `escape.json` (path escapes `rootHint` via `..`).
   → The loader **rejects** it (path-escape pass); it does **not** play. The rejection surfaces only via delegate/stderr (no in-app UI). App stays alive.

**Expected end state:** the two distinct empty-state messages render correctly; the store is project-local + git-ignored with an initially-empty index; a flushed session populates the index; concurrent flushes are durable (newest-wins); the drop transport is OFF unless `TV_WALKTHROUGH_DROP=1`, deduped/debounced when on, and rejects `..`-escaping paths.

**Variations / edge states**

- **`.tmp` / `.partial` ignored:** drop a `drop.json.tmp` and a `drop.json.partial` with the gate ON → neither plays (only finalized `.json` is consumed). Then atomically rename to `drop.json` → it plays.
- **FIFO + dedup:** drop the same `drop.json` twice in quick succession → it plays once (deduped); the delivered set is capped (1024 FIFO) — log that the cap exists, don't exhaust it.
- **Schema-version downgrade on the store:** point the review store at a `session.json` written by a **newer** schema (`schemaVersion` ahead) → the reader **refuses to write** / guards (no silent destructive downgrade). Log the guard.
- **`.textview/reviews/` tracked-by-default vs git-ignored:** confirm the current behavior is **git-ignored** (the directory's `.gitignore` is written); a `git status` in `freshrepo/` should NOT show the review files as untracked-to-commit.
- **Store relocation pending (#203):** note that store location + JSONL-vs-per-review-JSON is an open decision; only assert current project-local JSON behavior, not a future layout.
- **998 MB-equivalent guard does not apply here** — that was the *tab* restore cap; reviews have their own store-file caps. Don't conflate.

---

## WCR-06 — Walkthrough + Code Review intended-integration boundary: Note-during-review-of-a-diff (currently decoupled)

**Combines:** a realistic "review-driven tour" flow that exercises BOTH features in one session · walkthrough `openGitPanel` + `runDiff` landing on a repo under review · the Note button's *intended* (but unwired) Code-Review hookup · confirming the two systems are currently independent

**Preconditions**

- A git-repo fixture `proj/` under temp with a tracked file `a.swift` (committed changes to diff) **and** a seeded `inReview` `ReviewSession` with a couple of comments (as in WCR-04).
- A `review-tour.json` walkthrough (`/v1`, `rootHint` = `proj/`) with steps: `openFile a.swift` → `setView source` → `openGitPanel` → `highlightRange` over a reviewed line → `narrateOnly` ("press Note to log a review thought").

**Steps**

1. Launch `--walkthrough …/review-tour.json` against `proj/`.
   → Tour starts; `a.swift` opens; the Git panel opens; the highlight stripe lands over the reviewed line range.
2. While paused on the highlight step, open the Git panel **REVIEW** tab and confirm the seeded review is present (state line `inReview · N comments`).
   → Both systems coexist in one window: the walkthrough strip is docked at the bottom, the review is browsable in the Git panel. No interference between the overlay and the review diff.
3. Press the walkthrough **Note** button (`mdv.walkthrough.note`) while a reviewed line is highlighted.
   → **Expected current behavior:** Note bumps `noteNonce` + emits a stderr crumb. It **does NOT** create a review comment, does **not** open the composer, does **not** anchor anything to the highlighted line. The intended Note→Code-Review integration is **pending** — log the gap; do not fail.
4. Independently, in the review, **Resolve** a comment, then **Export…** (Cmd+Shift+E).
   → Review mutations work normally regardless of the active walkthrough; export copies JSON to clipboard and lands `.sent`. The walkthrough is unaffected by the review state change.
5. **Exit** the walkthrough.
   → Strip + overlay tear down; tour-pinned bookmarks (if any) are cleared. The review and its `.sent` state persist (review state is independent of the tour lifecycle).

**Expected end state:** walkthrough and code-review run side-by-side in one window without interference; the Note button is confirmed decoupled from review (the documented pending hookup); review mutations + export are unaffected by the active tour; exiting the tour leaves the review state intact.

**Variations / edge states**

- **Highlight over a stale-anchored comment:** highlight a line whose review comment is `stale` → the overlay stripe and the review staleness badge are independent; both render, neither drives the other.
- **runDiff in a review repo:** add a `runDiff` step (with a `sha`) → it surfaces the git **log** (sha discarded), separate from the review diff. Confirm they don't collide.
- **Two windows:** open a second window without the tour → the walkthrough is **one active per window**; the second window has no strip. Review store is project-local so both windows see the same `.textview/reviews/`.
- **Note after the tour exits:** the Note button is gone once the strip tears down — there is no post-tour way to "log a note". Confirm.
- **Future-proofing reminder:** when the Note→Code-Review hookup eventually lands, this smoke becomes the regression anchor for "Note creates an anchored review comment". For now it asserts the **decoupled** behavior.
