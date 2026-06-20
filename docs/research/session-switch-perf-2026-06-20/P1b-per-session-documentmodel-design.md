# P1b — Per-session `DocumentModel` (the durable session-switch retention fix)

**Date:** 2026-06-20 · **Type:** DESIGN (no production code changed) ·
**Author:** `claude-mdv` · **Board:** TSK-1045 (parent TSK-1040) ·
**Status:** DESIGN ONLY — needs owner sign-off before any implementation.

> This is the durable architectural alternative to the P1 warm-WebView cache
> (TSK-1042, landed). The warm cache restores WebView retention across a switch
> *above* the SwiftUI lifecycle (path-keyed park/re-attach); P1b restores it
> *structurally* (the WebViews never unmount because the model that owns them is
> never drained). They are complementary, not exclusive — see §6.

---

## 1. What's wrong today (recap, grounded)

Phase-1 runs **one shared `DocumentModel`** for the whole app
(`SessionsAppCoordinator.swift:12-23`, "Phase 2 will hold a dictionary keyed by
session UUID"). Every `SessionState` wraps that *same* singleton. A session
switch therefore:

1. `detach()` the outgoing session, snapshot it.
2. `model.closeAllTabsPreservingDirty()` — **drains every tab** of the shared
   model → `MountedPanesLRU.retainOnly({})` drops **every retained pane**
   (`dismantleNSView` fires for each WebView).
3. `state.hydrate(from: snap)` re-appends the incoming session's tabs with
   **fresh `Tab.id`s** (the snapshot persists the file *path*, not the id).
4. The focused tab's WebView is built from scratch → re-pays ~94% of a
   rendered-MD open (TSK-598).

The retention win (TSK-108) is keyed by `Tab.id` and lives on the one model that
gets drained. It **cannot** survive the switch by construction.

## 2. The P1b idea

Give **each session its own `DocumentModel`**. A switch becomes a **view
re-bind** to a different model:

```
Phase 1 (today)                         Phase 2 (P1b)
─────────────────                       ─────────────────
SessionsAppCoordinator                  SessionsAppCoordinator
  └─ model: DocumentModel  (shared)       └─ models: [UUID: DocumentModel]
       ▲     ▲     ▲                            ├─ sessA → DocumentModel A  (tabs+WebViews LIVE)
   sessA  sessB  sessC  (façade swap)           ├─ sessB → DocumentModel B  (tabs+WebViews LIVE)
   drains+rebuilds on every switch              └─ sessC → DocumentModel C
                                          switch = ContentView re-binds to models[id];
                                          the OTHER models are never touched → their
                                          WebViews never unmount → zero rebuild.
```

The incoming session's `DocumentModel` already holds its tabs + mounted panes
(the `MountedPanesLRU` is per-model, so each session keeps its own retained
WebViews). Switching back is a pure `@ObservedObject` swap + a SwiftUI re-body —
the TSK-108 instant-tab-switch win, lifted to the **session** level.

## 3. What changes (blast radius)

The shared `model` is referenced *pervasively*. Every one of these must move
from "the one model" to "the active session's model":

| Surface | Today | P1b |
|---|---|---|
| `SessionsAppCoordinator.model` | `let model: DocumentModel` (one) | `models[UUID]`; `var activeModel` computed |
| `ContentView(model:)` | bound once at launch to the singleton | bound to `coord.active?.model`; re-binds on switch (`@ObservedObject` swap or `.id(session)`) |
| `SessionState.model` | injected shared singleton | the session's own model (created at mount) |
| `switchSessionFaçade` | drain + hydrate the shared model | **delete the drain**; just swap the active model + hydrate a fresh model lazily |
| `armAutosave` | observes the shared model's publishers | observes the active model's publishers; already keyed by session id (good) |
| `MultiWindowRegistry` binding | one model ↔ one window | per-session model ↔ window (already the Phase-2 target) |
| AppDelegate menu actions (Undo/Redo, Find, Save, Print, view-mode, zoom, split, …) | call `coord.model.<x>` | call `coord.activeModel.<x>` |
| `CodeMirrorEditorRegistry` / LSP pool / RepoFocusTracker / git watchers | one set per app | **per-model** instances (or a shared pool keyed by model) — see §4 risk R3 |
| Global prefs (zoom / wrap / theme) | on the shared model, app-wide by design (#184) | must stay **app-wide** — live on the coordinator/prefs, NOT per-model, or every session re-applies its own zoom (regression) |
| Tests | construct one `DocumentModel` | many construct `DocumentModel()` directly; a per-session indirection changes ~all session/coordinator tests |

## 4. Risks

- **R1 — Memory: N live models = N live WebKit WebContent processes.** Each
  rendered-MD/CM6 tab is a WKWebView (~30-80 MB WebContent). Today one session's
  worth is live; P1b keeps *every open session's* focused (and retained) panes
  live simultaneously. With 6 sessions × 4-pane LRU that is a lot of resident
  WebKit. **Mitigation:** cap the number of *fully-live* models (an LRU of
  models, e.g. keep the 2-3 most-recent sessions hot, cold-snapshot the rest →
  rebuild on demand). This re-introduces a rebuild for cold sessions but bounds
  memory. The cap is the crux of the design and the main thing to get right.
- **R2 — Global vs per-session state.** zoom/wrap/theme are owner-LOCKED
  app-wide (#184). They must NOT become per-model or switching sessions yanks
  the zoom. Audit every `@Published` on `DocumentModel` for "is this per-session
  or app-wide?" before splitting.
- **R3 — Shared singletons keyed off the model.** `CodeMirrorEditorRegistry`,
  the LSP pool, `RepoFocusTracker`, FSEvents watchers, the shared `WKProcessPool`
  — some are process-global (fine), some assume one model. Each needs an audit:
  per-model instance vs shared-pool-keyed-by-model.
- **R4 — Window/model/session three-way binding.** `MultiWindowRegistry` already
  models window↔session; P1b adds model↔session. The one-window-per-session
  lease must extend to "one model per session," and a future second window must
  bind the *same* model (not a duplicate) when showing the same session.
- **R5 — Persistence correctness.** Autosave is already session-keyed
  (`autosaveBoundSessionID`, `lastPersistedContent[id]`), which is good — but the
  detach-time "drain the shared model" snapshot logic disappears; the new code
  must still snapshot a cold/evicted model before tearing it down.
- **R6 — Test surface.** A large number of session/coordinator tests construct
  and assert against the single shared model. The indirection is mechanical but
  broad; budget for a test sweep.

## 5. Migration plan (incremental, behind the existing seam)

1. **Slice 0 — introduce `activeModel` indirection.** Add
   `coord.activeModel` returning `active?.model` (today == the singleton).
   Mechanically replace `coord.model.<x>` call sites with `coord.activeModel`.
   No behavior change; shrinks the eventual diff and de-risks the rename.
2. **Slice 1 — `models: [UUID: DocumentModel]` registry** with an LRU cap of
   *live* models (default 1, == today). `mountSession` creates/looks-up the
   session's model; `switchSessionFaçade` swaps the active model instead of
   draining. Cap=1 ⇒ identical behavior to today (cold sessions rebuilt), but
   the plumbing is in place.
3. **Slice 2 — raise the live-model cap to 2-3 + cold-snapshot eviction.** This
   is where the win lands: recent sessions stay hot (zero rebuild on switch-
   back); evicted ones snapshot + rebuild. Measure memory on the VM at each cap.
4. **Slice 3 — re-bind `ContentView` to the active model** (the
   `@ObservedObject` swap / `.id(session)`), so the view follows the model swap.
5. **Slice 4 — split per-session vs app-wide state** (R2) and per-model
   singletons (R3); extend the window/lease binding (R4).

Each slice is independently landable + gate-green; the win is realized at
Slice 2-3.

## 6. Interaction with the landed P1 warm cache (TSK-1042)

They coexist cleanly and are complementary:

- **Warm cache (landed):** path-keyed park/re-attach *above* SwiftUI. Wins for
  switch-back to a session whose focused file was recently shown, **even when
  its model was drained/evicted** — i.e. it also covers the *cold-model* case in
  P1b Slice 2 (an evicted model rebuilds its tabs, but each tab's WebView
  re-attaches from the warm cache → still no reload). So the warm cache is the
  safety net that makes a low live-model cap (R1 mitigation) cheap.
- **P1b (this design):** keeps recent sessions' models fully live so a switch is
  a pure re-bind (no drain, no hydrate, no tab rebuild at all — strictly faster
  than even a warm-cache re-attach, which still re-runs hydrate + SwiftUI make).

Recommended sequencing: **ship the warm cache now (done), measure the switch
latency on the VM, then decide whether P1b's additional win justifies its blast
radius.** If the warm cache already collapses the felt latency, P1b can stay a
documented seam and not be built — which is the frugal outcome.

## 7. Recommendation

**Do NOT build P1b speculatively.** Land + VM-measure the warm cache first
(TSK-1042). If the switch is still felt-slow after the warm cache (e.g. the
hydrate/readdir/updateDerived phases dominate once the WebView rebuild is gone),
revisit P1b starting at Slice 0-1 (the safe indirection) and only raise the
live-model cap (Slice 2) with VM memory numbers in hand. Owner sign-off is
required for Slice 2+ because of the memory trade (R1) and the global-state
split (R2).
