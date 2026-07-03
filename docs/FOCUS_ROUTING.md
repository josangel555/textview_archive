# Key-event & focus routing — the audit + the ownership rule (TSK-1483)

Owner symptom set (OwnerWishlist, twice): *Enter while typing in the editor opens the
file selected in file-nav; snippets insert into whichever view has stale focus; ⌘F with
file-nav focused opens the wrong find.* This document maps every key-routing surface,
records the verified state of each symptom against the code, and states the ONE rule
each surface must follow.

## The focus-ownership rule

> **The typing surface owns keys.** Any component that observes keys OUTSIDE the normal
> responder chain (an `NSEvent` local monitor, a menu accelerator handler, a one-shot
> imperative request channel) must prove the key/request is NOT owned by a typing or
> document surface before acting — via a **pure, host-tested predicate**, never an
> inline heuristic. One-shot requests must additionally name the **tab they target**;
> "whatever pane happens to see the value" is never an acceptable addressee.

## Surface map — who observes keys / requests, and their guard predicate

| Surface | File | Guard (pure, host-tested) | Behavior |
|---|---|---|---|
| Sidebar nav keys (↑↓←→ ⏎ ⎋ F2) | `Sources/ViewerUI/SidebarKeyMonitor.swift` | `shouldYield(modifiers:firstResponder:editorViews:)` | Yields on ⌘/⌥/⌃, on `NSText`, on `SidebarKeyMonitorExempt` (terminal), on ANY live CM6 editor webview or descendant (`CodeMirrorEditorRegistry.liveWebViews` — ALL mounted panes, TSK-1280) |
| Esc → refocus document | `Sources/ViewerUI/EscFocusMonitor.swift` | `firstResponderIsDocument(_:editorViews:contentRoot:)` | Consumes Esc only when the model bumps a focus nonce; passes through for palette/find-bar dismiss |
| Double-Shift → palette | `Sources/ViewerUI/DoubleShiftMonitor.swift` | `detectorEvent(...)` + `DoubleTapModifierDetector` | Observation-only — never consumes |
| ⌘F router | `Sources/MarkdownViewer/main.swift` `findInPage` | `shouldDeferFindToFocusedField` (TSK-1248) + `FindBarRouting.target` | Defers to a control's field editor; routes rendered/editor/pdf/source by surface |
| LSP hover dismiss | `Sources/ViewerUI/LSP/LSPHoverAttachment.swift` | scroll/keys dismiss the popover | Observation-only |
| One-shot editor requests (goto / insert / select / focus / find nonces) | `Sources/ViewerUI/CMOneShotRouting.swift` + `CodeMirrorEditorView.Coordinator` | `CMOneShotRouting.paneMayApply` + `CMOneShotLedger` (exactly-once) + `baselineNonceChannels` | See below — the TSK-1483 fix |

## Verified symptom status (code-verified 2026-07-02)

1. **Enter in editor leaks to file-nav — FIXED earlier (TSK-1280).**
   `SidebarKeyMonitor.shouldYield` yields when the first responder is (a descendant of)
   ANY registered CM6 editor webview, not just `current()`. Pinned by
   `Tests/ViewerUITests/SidebarKeyMonitorYieldTests.swift` (incl. the multi-pane case).
2. **⌘F with file-nav focused misroutes — FIXED earlier (TSK-1248 / TSK-946 / TSK-1140).**
   `findInPage` defers to the focused field editor unless a find bar is already open
   (`DocumentModel.shouldDeferFindToFocusedField`), then routes via the pure
   `FindBarRouting.target`. Pinned by `FindBarRoutingTests` + `DocumentModelTests`.
3. **Snippets insert at wrong focus — WAS LIVE; fixed by this ticket.** Root cause was
   not focus at all but one-shot request routing (below). This is the same bug class as
   TSK-1280, one layer up: per-pane `lastApplied*` mirrors instead of one addressed,
   consumed request.

## The one-shot request routing fix (the live bug)

**Mechanism (diagnosed, not inferred):** `EditorCoordinator` publishes app-global
one-shot requests (`editorGotoLine`, `editorInsertRequest`, `editorSelectRequest`,
`editorFocusRequest`, find/replace nonces). `ContentView` feeds them into **every
mounted `CodeMirrorEditorView`** (`MountedPanesLRU`, up to 4 retained panes at
`opacity(0)`). Each pane's Coordinator applied a request whenever it differed from its
*own private* `lastApplied*` mirror, and the published request is **never cleared**. So:

- **Fan-out:** an insert/goto fired for the active pane was also applied by every other
  mounted, ready pane — snippet text landed in invisible documents.
- **Stale replay:** a pane mounted (or warm-cache re-attached; `adoptState` drops the
  nonce mirrors by design) AFTER a request fired saw it as new and replayed it —
  "snippets insert into whichever view has stale focus".

**Fix (routing layer, class-wide):**

- **Targeted one-shots** (`CMGotoLineRequest` / `CMInsertRequest` / `CMSelectRequest`
  gained a `target: UUID?` tab stamp, applied at the model layer — the only layer that
  knows the addressee): a pane applies a request iff `CMOneShotRouting.paneMayApply`
  (target == its tab; untargeted legacy requests → active pane only) **and**
  `CMOneShotLedger.shared.consume(id)` — exactly once app-wide, killing both fan-out
  and replay. No mount-time baseline for these: open-at-line
  (`DocumentModel.openPath(_:atLine:)`) publishes the goto BEFORE its target pane
  mounts and relies on apply-at-mount; the tab stamp + ledger make that safe.
- **Int-nonce channels** (`editorFocusRequest`, find/replace next/prev/all): baselined
  at mount (`baselineNonceChannels`, both fresh-build and warm re-attach paths) so a
  stale app-global nonce is never treated as a new request; the focus nonce
  additionally dispatches only on the **active** pane (an inactive sibling records it
  but must never steal first responder).

**Tests:** `Tests/ViewerUITests/OneShotRoutingTests.swift` — the `paneMayApply` matrix,
ledger exactly-once + capacity eviction, and model-level stamping (snippet insert,
tab-stop selects, goto forwarder, date-time insert). Rendered-view nonce channels
(`markdownWebView`) already gate by `isActive ? nonce : 0` at the call site.

## Rules for new code

1. A new `NSEvent` local monitor MUST route its fire/yield decision through a pure
   static predicate (same shape as `shouldYield`) with host tests, and must check the
   first responder against ALL mounted editor surfaces (`liveWebViews`), never
   `current()` alone.
2. A new one-shot imperative channel into a representable MUST either (a) carry a
   target (tab id) stamped at the model layer and consume through `CMOneShotLedger`,
   or (b) be an Int nonce that the coordinator baselines at mount and applies only on
   the active pane. Never rely on a per-coordinator `lastApplied` mirror alone — that
   is the fan-out/replay bug by construction.
3. Interactive surfaces that consume raw Return/arrows outside `NSText` must adopt
   `SidebarKeyMonitorExempt`.
