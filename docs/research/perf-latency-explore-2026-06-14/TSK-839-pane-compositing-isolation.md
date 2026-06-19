# TSK-839 — per-nav CA commit stall: pane compositing isolation (slice 1)

Follow-up to `app-latency.md` finding #2 (per-nav 30–366 ms main-thread
CoreAnimation commit stall — measured on the VM, 43 stalls / 3.35 s over a 17 s
nav sweep, while the model call is ≤12 ms).

## What this slice does (host-shippable, low-risk)

The retained-pane content `ZStack` (`ContentView.content`) mounts up to 4 tab
panes (the `MountedPanesLRU`); only the active one is visible, the rest sit at
`opacity(0)` so switch-back is a pure visibility flip (perf Fix#1 — no
`WKWebView` teardown+reload). The cost of that retention: every pane's layer
subtree is a sibling in the same container, so each nav action's CA commit can
re-walk / re-composite all of them — and each pane hosts an opaque,
layer-backed `NSViewRepresentable` (rendered-markdown / CodeMirror WebView),
exactly the surface the LESSONS/CLAUDE.md compositor rule (TSK-488) is about.

This slice gives **each retained pane its own compositing group**
(`.compositingGroup()` per pane in the `ForEach`) so a sibling pane's — or the
surrounding chrome's — re-layout cannot fold every pane's opaque-representable
subtree into one CA commit reconciliation. An isolated inactive pane should
contribute a cheap cached composited bitmap to the commit instead of a fresh
layer walk.

The per-pane render decision (opacity / hit-testing / accessibility / z-order /
the isolation flag) is centralized in a named, host-testable contract,
`PaneCompositingPolicy` — same strategy as `SideDockCompositing`:
- `Sources/ViewerUI/PaneCompositingPolicy.swift`
- `Tests/ViewerUITests/PaneCompositingPolicyTests.swift` (7 host tests)

`ContentView` drives all the per-pane modifiers from it, so a regression that
drops `.compositingGroup()`, makes an inactive pane hit-testable, or collapses
the active/inactive z onto one layer fails the host gate.

## What is STILL VM-profile-gated (the honest part)

The host **cannot** measure CoreAnimation commit time — `ImageRenderer` /
`cacheDisplay` are documented FALSE GREEN for opaque-representable compositing
(CLAUDE.md). So this slice does NOT prove the stall shrank; it pins the
*decision* and applies the standard compositor-isolation remedy. The actual
win must be re-traced on the VM:

```
# before/after the change, compare CA Transaction.Stalls totals over a nav sweep
bash scripts/vm-profile.sh Sources/ViewerUI/DocumentModel.swift 22 nav release
# parse the .trace for com.apple.coreanimation Transaction.Stalls
```

Acceptance: the per-nav stall total (3.35 s / 43 stalls baseline) drops, and the
12 stalls >100 ms shrink in count and/or duration. If isolation alone is
insufficient, the next levers (still open under TSK-839) are, in order:

1. **Capture a Time-Profiler stack UNDER one stall window** (debug config) to
   attribute the heavy subtree — re-mount of a pane that fell out of the 4-slot
   LRU vs the rendered-MD WebView re-compositing. MEASURE before the next fix.
2. **Retune `MountedPanesLRU` capacity** if the re-mount-on-eviction path is the
   stall source (currently 4).
3. **Decouple the chrome toggle from the center pane's relayout** if the
   sidebar/view-mode toggle is forcing the center pane to re-lay-out.
4. The rendered-MD reload storm (finding #1) overlaps this — its persistent-page
   + DOM-patch fix (TSK-624 promotion) will independently cut commit churn.

This slice is the cleanest host-shippable foundation; items 1–4 are the
VM-measure-then-fix continuation.
