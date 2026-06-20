# Adversarial review — memory-and-resources (2026-06-18)

Hunt for retain cycles, leaked OS handles (fds / pipes / processes / observers /
timers), unbounded caches and growing collections, and large-buffer lifetimes
across the Swift packages and the Rust FFI boundary. The codebase is unusually
disciplined in this dimension — the file/folder watchers (`FileWatcher`,
`FolderWatcher`), the PTY/LSP subprocess teardown, the per-tab highlight cache,
the rendered-HTML cache, the SidebarModel children cache, and the FFI buffer
handling all show prior hardening with explicit eviction, idempotent `stop()`,
and `deinit` backstops. The findings below are the residual real defects: a
deferred-cleanup retain chain that can leak an `NSPopover`, run-loop-retained
`Timer`s with no `deinit` backstop, a children-cache prune that cannot meet its
cap when the working set is dominated by expanded directories, an unbounded
metric registry that the API permits high-cardinality keys into, an
`NSObject` `Coordinator` that registers as a notification target without a
`deinit` removal, and an unbounded hex-edit undo stack.

### LSP hover: block observers strongly capture `HoverState`; cleanup is deferred to an unstructured Task

**Severity**: high

**Location**: `Sources/ViewerUI/LSP/LSPHoverAttachment.swift:192-209` (observer
registration) and `:56-71` (deferred deinit cleanup)

**Why**: The two `NotificationCenter.default.addObserver(forName:...)` blocks
registered in `bind(...)` capture `state` **strongly** — the closure body is
`{ _ in Task { @MainActor in state.dismiss() } }` with no `[weak state]`.
`NotificationCenter` retains a block-based observer until it is explicitly
removed, and the block in turn retains the `HoverState` (which owns the
`NSPopover`). Removal happens only in `LSPHoverToken.deinit`, which does NOT
remove synchronously — it copies the tokens by value and hops the
`removeObserver` calls into `Task { @MainActor in ... }`. That creates two
problems: (1) between the token's deinit and the deferred Task actually running,
the observers — and therefore `HoverState` + its `NSPopover` — stay alive,
anchored by `NotificationCenter`; (2) an unstructured `Task` is not guaranteed
prompt or even to run before process teardown, and if the main actor is
saturated or the app is shutting down the cleanup may never execute, leaking the
observers, the `NSPopover`, and the captured `HoverState` for the rest of the
process. Because hover tokens are created per-textView-bind (every source view
that wires LSP), churning editors/tabs accumulates these. The strong `state`
capture means the leak is the whole hover machinery, not just a token shell.

**Fix**: Capture `state` weakly in both observer blocks
(`{ [weak state] _ in Task { @MainActor in state?.dismiss() } }`) so a delayed
or dropped cleanup Task can't anchor the popover. Better still, make the cleanup
synchronous: give `LSPHoverToken` an explicit `@MainActor func invalidate()`
that removes the tracking area, the observers, and the monitors, and call it
from the binding owner's `@MainActor` teardown (e.g. `teardownStorage()` /
`dismantleNSView`), reserving the deferred-Task deinit only as a last-resort
backstop. Removing observers off the main thread (current deferred-Task path is
main, but `ChainedMonitor.deinit` is not — see related note) is also unsafe for
AppKit.

**VERDICT: CONFIRMED** — Code is exactly as described: both blocks (`:197`, `:207`) capture `state` strongly; removal is deferred into an unstructured `Task { @MainActor }` in `deinit` (`:61-70`), which is not guaranteed prompt or to run on shutdown. Caveat (does not change verdict): `LSPHoverAttachment.bind` has **no live callers** anywhere in `Sources/`/`Tests/` — it is opt-in PoC code, so the leak is not currently reachable in the shipping app; the defect is real in the code as written but the practical "high" exposure is theoretical until the feature is wired up.

### `StatusBarMemorySampler` Timer has no `deinit` backstop; leaks on a missed `onDisappear`

**Severity**: medium

**Location**: `Sources/ViewerUI/StatusBarMemory.swift:50-87` (class), lifecycle
driven only by `:118-119` (`.onAppear`/`.onDisappear`)

**Why**: `start()` creates a repeating `Timer.scheduledTimer(...)` which the run
loop **retains**. The class has no `deinit`; the timer is invalidated only by
`stop()`, which is wired exclusively to the SwiftUI `.onDisappear`. SwiftUI does
not guarantee `onDisappear` fires in every removal path (view replaced without an
animated transition, ancestor torn down abruptly, scene teardown). When
`onDisappear` is skipped, the `@StateObject` sampler can be released while its
timer is still scheduled — the closure is `[weak self]` so the sampler does
dealloc, but the `Timer` object and its run-loop source are never invalidated and
keep firing every 1.5 s into a dead `self?` for the lifetime of the run loop. It
is a small but genuine leak that recurs each time the chip mounts/unmounts
without an `onDisappear`.

**Fix**: Add `deinit { timer?.invalidate() }` as the backstop (it runs whenever
the sampler is released regardless of the SwiftUI path). The `[weak self]`
closure already prevents the deinit from being blocked by the timer's retain, so
the deinit will run and can clean up. Same pattern applies as a defensive measure
even though `stop()` is the primary path.

**VERDICT: CONFIRMED** — Verified: `StatusBarMemorySampler` (`:51-87`) has no `deinit`; the run-loop-retained repeating `Timer` is invalidated only by `stop()` (`:69-72`), wired solely to `StatusBarMemoryChip.onDisappear` (`:119`). The `[weak self]` tick (`:64`) lets the sampler dealloc while the orphaned timer keeps firing on any missed `onDisappear`. This is LIVE code (`StatusBarMemoryChip` is the always-visible status-bar chip). Real, defensive `deinit` backstop is the correct fix.

### `GitPanelModel` 60 s Timer relies solely on `stop()`; no `deinit` backstop

**Severity**: medium

**Location**: `Sources/ViewerUI/Git/GitPanelModel.swift:151-167` (start/stop,
no `deinit`); mounted via `Sources/ViewerUI/Git/GitPanelView.swift:36-37`

**Why**: Identical hazard to `StatusBarMemorySampler`. `start()` schedules a
60 s repeating `Timer.scheduledTimer(...)` and adds it to `RunLoop.main` in
`.common` mode, so the run loop owns it. `GitPanelModel` has no `deinit`; the
only invalidation is `stop()` via the view's `.onDisappear`. If `onDisappear` is
skipped on a panel dismount, the timer survives the model (`[weak self]` lets the
model dealloc), so a stale run-loop `Timer` lingers and fires every 60 s into a
nil `self?`. Worse than the status-bar case in one respect: `GitPanelModel` also
holds `refreshTask`/`loadMoreTask`/`logSearchTask` that are cancelled only in
`stop()`, so a missed `onDisappear` can also leak an in-flight `Task` (git
shell-out) that outlives the model.

**Fix**: Add `deinit { timer?.invalidate(); refreshTask?.cancel();
loadMoreTask?.cancel(); logSearchTask?.cancel() }` (mirroring `stop()`), so
teardown is guaranteed independent of the SwiftUI lifecycle. (`ObservabilityProjection`
shows the safer pattern — it stores the timer in an `AnyCancellable`, which
self-cancels on dealloc — and is the model to follow if these are reworked.)

**VERDICT: CONFIRMED** — Verified: `GitPanelModel` (`:21-528`) has no `deinit`; the 60 s `Timer` is added to `RunLoop.main` in `.common` (`:153-157`) and invalidated only in `stop()` (`:160-167`), wired solely to `GitPanelView.onDisappear` (`:37`). The `[weak self]` tick lets the model dealloc while the timer survives. Confirmed the additional severity: `refreshTask`/`loadMoreTask`/`logSearchTask` are cancelled only in `stop()`, so a missed `onDisappear` can leave an in-flight detached `git` shell-out outliving the model. LIVE code. A `deinit` mirroring `stop()` is the correct fix.

### `SidebarModel.pruneChildrenCacheIfNeeded` cannot enforce the cap when expanded dirs exceed it

**Severity**: medium

**Location**: `Sources/ViewerUI/SidebarModel.swift:693-712`

**Why**: The prune loop walks `childrenCacheOrder` oldest-first and **skips**
(without evicting) any entry that is the `rootURL` or is currently `expanded`,
advancing past it. The loop terminates when `childrenCache.count <= target` OR
when `idx` reaches the end of the order list. If the live working set is
dominated by expanded directories — a deep monorepo where the user (or a restored
session) has more than `childrenCacheMax` (256) directories expanded at once —
every walked entry is skipped, `idx` runs off the end, and the loop exits with
`childrenCache.count` still above the cap. The cache is then effectively
unbounded for that session: it grows one `[FileNode]` array per newly-touched
directory and never shrinks back below 256, because the only entries it is
allowed to drop are the cold/collapsed ones that aren't the source of the growth.
The doc-comment claims to fix the prior "under-evict when expanded dirs dominate"
bug, but the new logic still cannot evict expanded entries, so the same failure
mode remains for working sets larger than the cap. Each entry is a directory
listing (`[FileNode]`), so on a wide tree this is real retained memory.

**Fix**: Raise/parameterize the cap relative to the count of expanded
directories (e.g. `max(childrenCacheMax, expanded.count + slack)`) so the target
is always achievable, OR allow eviction of expanded-but-offscreen directories
that lazily reload on next access (the children cache rebuilds on demand anyway).
At minimum, when the loop exits still over cap, log a gauge so the unbounded case
is observable rather than silent.

**VERDICT: CONFIRMED** — Verified: the prune loop (`:693-712`) `continue`s past (never evicts) `rootURL` or any `expanded.contains(key)` entry, with `target = 256*2/3 = 170`. `expanded` is a `Set<URL>` populated from restored session snapshots (`:367`/`:400`/`:429` `expanded = snapshot`), so it can hold an unbounded number of dirs. When the cached expanded-dir count exceeds 170, the loop runs `idx` to the end while `childrenCache.count` stays over cap — the cap is genuinely unenforceable for that working set. Edge-case (needs >170 simultaneously-expanded dirs, e.g. a deep restored monorepo session), but the failure mode the doc-comment claims to have fixed does persist. LIVE code. Real.

### `RingBufferSink` metric registry (`counters`/`gauges`) is unbounded by cardinality

**Severity**: medium

**Location**: `Sources/ViewerCore/Observability/RingBufferSink.swift:69-70`,
`:118-130` (counter/gauge) — only cleared by `reset()` `:200-208`

**Why**: The event ring buffer is correctly bounded (fixed-capacity, drop-oldest
— see the class doc), but the metric registry is two plain dictionaries keyed by
`MetricKey(name, tags)`. Every distinct `(name, tags)` tuple ever emitted creates
a permanent entry that lives for the process lifetime (only `reset()` clears it,
and that is a test/UI affordance, not an automatic eviction). The `counter` /
`gauge` API accepts an arbitrary `[String: String]` tag dictionary. The moment
any emit site passes a high-cardinality tag — a file path, a URL, a session id, a
per-request id, a timestamp — the registry grows without bound. Today's only call
sites (`TrackedReposChannel.swift:212,217`) use static low-cardinality names with
no tags, so the leak is **latent**, but the API actively invites it and the
buffer is otherwise advertised as "bounded by construction," which is misleading
for the metrics half. This is the classic metric-cardinality explosion: it would
not be caught by the event-buffer bound and would manifest as slow, unbounded
heap growth proportional to distinct tag combinations.

**Fix**: Bound the registry — e.g. cap the number of distinct series and
drop/aggregate on overflow with a "metrics dropped" counter, or reject tag sets
above a small key/value cardinality at the emit boundary. At minimum, document
the cardinality contract on `counter`/`gauge` ("tags MUST be low-cardinality;
never pass paths/ids/timestamps") and add a debug assertion on tag count so a
future caller can't silently introduce the leak. The leak is real the day
anyone tags a metric with a path.

**VERDICT: CONFIRMED (latent)** — Verified: `counters`/`gauges` (`:69-70`) are unbounded dictionaries keyed by `MetricKey(name, tags)` with arbitrary `[String:String]` tags accepted at the `counter`/`gauge` boundary (`:118-130`); the only purge is `reset()` (`:200-208`), a test/UI affordance. Confirmed both — and the ONLY two — call sites are static no-tag names (`TrackedReposChannel.swift:212,217`, `counter("trackedRepos.norm.miss")` / `.reset` with default empty tags), so the explosion is not currently reachable. The finding is honest about this ("Currently latent"). The defect is an API-contract/false-"bounded by construction" hazard rather than an active leak; CONFIRMED as a real latent defect with the documented caveat.

### `MediaPreviewView.Coordinator` registers as a notification target with no `deinit removeObserver`

**Severity**: low

**Location**: `Sources/ViewerUI/MediaPreviewView.swift:412-421` (registration);
`Coordinator` class `:346-368` has no `deinit`

**Why**: `makeNSView` registers the `Coordinator` (an `NSObject`) as a
target/selector observer for two notifications (`didEndLiveMagnifyNotification`
and the custom `wheelZoomDidChangeNotification`), filtered on `object: scroll`.
The `Coordinator` has no `deinit` and never calls
`NotificationCenter.removeObserver(self)`. Modern macOS (10.11+) auto-zeroes
target/selector observers when the observer object deallocs, so this is not a
hard dangling-observer crash, but it is fragile: (1) it relies on the OS's
auto-removal rather than explicit cleanup, which is the exact pattern that
silently breaks if the registration is ever changed to capture additional
context, and (2) each `makeNSView` re-creates a coordinator and re-registers, so
during the window before the OS reclaims a replaced coordinator there can be
duplicate live registrations both forwarding `onUserZoom`. It is the only
observer site in the codebase that does not pair registration with explicit
removal (contrast `TextDisplayView.deinit`, `LSPHoverToken`).

**Fix**: Add `deinit { NotificationCenter.default.removeObserver(self) }` to
`Coordinator`. It is the idiomatic, defensive pairing and makes the lifecycle
explicit rather than depending on AppKit auto-removal semantics.

**VERDICT: REFUTED** — The structural facts hold (no `deinit`/`removeObserver` on `Coordinator` `:346-368`), but there is no actual resource defect under this dimension's bar. (1) The finding itself concedes macOS 10.11+ auto-zeroes target/selector observers on observer dealloc, so there is no dangling-observer crash and no observer leak — the OS reclaims them. (2) The "duplicate live registrations" / "duplicate `onUserZoom` forwarding" concern does not hold: BOTH registrations are filtered on `object: scroll` (`:416`, `:421`), and each `makeNSView` creates a fresh `scroll` (`:372`); a replaced coordinator's observers are keyed to the OLD scroll-view object, which no longer posts events, so they can't double-forward for the new view. What remains is a style/defensiveness preference (explicit pairing vs. relying on documented AppKit semantics), not a leaked OS handle / retain cycle / unbounded growth. Refuted as a memory-and-resources defect.

### `HexEditBuffer.undoStack` is unbounded

**Severity**: low

**Location**: `Sources/ViewerCore/HexEditBuffer.swift:53` (`undoStack`),
`:123-133` (every `recordEdit`/`setByte` appends, no cap)

**Why**: Every overwrite (`setByte` / `setNibble` that changes a byte) appends an
`Edit` to `undoStack` with no upper bound; only a successful save / revert
(`:155-169`) clears it. For a long editing session on a hex view — or any
automated/scripted path that drives many edits — the stack grows monotonically.
Each `Edit` is small (two `UInt8` + an `Int`), so this is not a fast leak, but it
is genuinely unbounded retained state tied to user/automation activity, unlike
the other undo stacks in the codebase which are capped (e.g.
`BookmarksStore.removalUndoStack` enforces `maxUndoDepth` at `:104-105`).

**Fix**: Cap `undoStack` with a `maxUndoDepth` and drop-oldest
(`if undoStack.count > maxUndoDepth { undoStack.removeFirst() }`), matching the
`BookmarksStore` pattern. A few thousand entries is plenty of undo headroom while
bounding the worst case.

**VERDICT: CONFIRMED** — Verified: `undoStack` (`:53`) is appended on every value-changing `apply` (`:130`) with no cap, cleared only by `markSaved`/`revert` (`:158-170`). Each `Edit` is `Int + UInt8 + UInt8` (`:42-51`), so growth is slow but genuinely unbounded across a long edit session. Confirmed the comparison: `BookmarksStore.removalUndoStack` IS capped (`maxUndoDepth = 20`, drop-oldest at `:104-105`), so the codebase pattern the fix proposes exists. LIVE code (backs the editable hex view). Real (low severity).

### `ChainedMonitor.deinit` may call `NSEvent.removeMonitor` off the main thread (resource-cleanup correctness)

**Severity**: low

**Location**: `Sources/ViewerUI/LSP/LSPHoverAttachment.swift:421-430`

**Why**: `ChainedMonitor` removes the local event monitors (cmd-click,
mouse-move, right-click) in its `deinit`, which is **not** isolated to the main
actor. The monitors are added on the main actor via
`NSEvent.addLocalMonitorForEvents`, and `NSEvent.removeMonitor` is an AppKit call
expected on the main thread. The `ChainedMonitor` is held only by
`LSPHoverToken.chain`; if the token (and thus the chain) is released from a
non-main context, the monitors are removed off-main — an AppKit-threading
violation that can intermittently fail to unregister the monitor (leaking the
event tap) or crash. This is the resource-leak-adjacent failure mode of the same
deferred/unisolated cleanup as the first finding.

**Fix**: Make the monitor teardown main-actor-isolated — remove the monitors in
the same explicit `@MainActor invalidate()` proposed for `LSPHoverToken`, or have
`ChainedMonitor` capture the monitors and dispatch removal to the main actor
guarded against re-entrancy. Do not rely on `deinit` running on the main thread.

**VERDICT: CONFIRMED (narrow)** — Verified: `ChainedMonitor` (`:422-430`) is a plain `private final class` (not `@MainActor`), so its `deinit` is nonisolated and calls `NSEvent.removeMonitor` (main-thread-expected AppKit) directly. Skeptical mitigation considered: `LSPHoverToken.deinit` (`:60-69`) captures `chainKeepalive = chain` into a `Task { @MainActor }`, so in the COMMON path the ChainedMonitor's last release — and thus its `deinit` — happens when that main-actor Task body completes, i.e. on main. BUT that mitigation fails in exactly the dropped/never-run-Task case flagged in finding #1: if the unstructured `Task` is destroyed without executing (shutdown / saturated main actor), the captured `chainKeepalive` is released wherever the Task object is torn down, which can be off-main, dragging `NSEvent.removeMonitor` off-main. The structural footgun (nonisolated `deinit` invoking a main-thread AppKit API) is real; the keepalive narrows but does not eliminate it. Same dead/PoC caveat as finding #1 (no live caller of `LSPHoverAttachment.bind`). CONFIRMED as a narrow correctness hazard.
