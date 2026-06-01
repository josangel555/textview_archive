import XCTest
import Foundation

/// Per-tier base classes (§3.3.1, §4) — *tier is the type*.
///
/// The testing-pyramid audit found the recurring over-placement root
/// cause (§4.5): tier was never a first-class, machine-checkable
/// property — only target + filename + an ad-hoc env gate — so nothing
/// *stopped* a test from sitting too high. These three base classes make
/// tier explicit in the type hierarchy and bake in the guardrail (§4):
///
/// > A test may sit at tier N+1 only if it asserts on an observable that
/// > tier N cannot faithfully produce. The PR must name that observable.
///
/// The default is HEADLESS; you must *opt up*. A subclass of a heavy base
/// (`LiveAppTestCase` / `PixelTestCase`) is required to carry a one-line
///
///     // TIER-JUSTIFY: <the ④ / cross-process / OS-integration observable
///     //               that forces this tier>
///
/// comment naming the observable that forces it. That comment is the
/// reviewable artifact the guardrail asks for; a heavy test without one
/// is a code-review smell.
///
/// Tier ladder (SwiftUI/AppKit; see TESTING_STRATEGY.md §1.1):
///
///   ┌──────────────────────────────────────────────────────────────┐
///   │ HeadlessUITestCase   T1 / T1m / T2'  host, no window, no perm  │  ← default
///   │ LiveAppTestCase      T4              spawns dist/TextView.app  │  ← opt up
///   │ PixelTestCase        T5              WindowServer pixels (VM)  │  ← opt up
///   └──────────────────────────────────────────────────────────────┘
///
/// CI gating (TODO, not yet wired): the merge gate should run
/// `HeadlessUITestCase` descendants as the host-headless sweep, and run
/// `LiveAppTestCase` / `PixelTestCase` descendants in the separate VM
/// lane (nightly + pre-release). With tier in the type, that selection is
/// a class-membership query rather than a hand-maintained `--filter`
/// list. Wiring options: a custom `XCTestObserver` that asserts the
/// active sweep only instantiated the expected base, or a build-time
/// scan. The base classes + the `// TIER-JUSTIFY:` convention are the
/// deliverable here; the gate plumbing is a follow-up.

// MARK: - T1 / T1m / T2' — the default, headless tier

/// Default base for app/UI-tier tests. Runs entirely in the host test
/// process: no spawned `.app`, no real `NSWindow`, no Screen-Recording
/// permission. Covers the three headless tiers from §1.1:
///
///   - **T1**  pure value / logic (plain XCTest assertions).
///   - **T1m** `@MainActor` model / coordinator — construct a hermetic
///     `DocumentModel` (the DI seam) or drive verbs via `HeadlessHarness`
///     and assert on `model.*` scalars. THE leverage tier (~20% of
///     regressions; catches the republish-storm / leak classes that
///     "drive the app and look at it" is structurally blind to).
///   - **T2'** in-process `NSHostingView` walk — `host.layoutSubtreeI
///     fNeeded()` + `DiagnosticDump`, asserting realized-tree shape /
///     geometry only.
///
/// `@MainActor` because `DocumentModel` / `SessionsAppCoordinator` and
/// any `NSHostingView` work are main-actor-isolated. No `// TIER-JUSTIFY:`
/// required — this is the floor.
@MainActor
class HeadlessUITestCase: XCTestCase {}

// MARK: - T4 — real .app, spawned process

/// Base for tests that genuinely need a REAL process boundary: they spawn
/// `dist/TextView.app` via `--script` and read its dump back. Reserve for
/// the irreducible T4 residue (§3.4): the AppDelegate↔coordinator launch
/// wiring that only exists in a real process, real-`NSWindow` geometry
/// clamping, cross-*process* `PreferencesStore` persistence across a
/// relaunch. VM-coupled (Xcode + GUI session); not part of the
/// host-headless merge gate.
///
/// **A subclass MUST carry a `// TIER-JUSTIFY:` comment** naming the
/// cross-process / OS observable that forces T4 over T1m. If the
/// assertions only read `model.*` scalars, it's a T1m test wearing a T4
/// costume — demote it to `HeadlessUITestCase`.
///
/// Not `@MainActor`: the live suites drive an out-of-process app and
/// manage their own isolation (process spawn, file polling). Forcing
/// main-actor isolation on the base would be invasive for no benefit.
class LiveAppTestCase: XCTestCase {}

// MARK: - T5 — WindowServer pixels (the real screen)

/// Base for the single irreducibly-real-screen tier: tests that read the
/// user's actual composited pixels via `screencapture(1)` against a live
/// window. The only observable here is stage ④ (WindowServer composite,
/// §1.1) — out-of-process, no headless equivalent, requires a real GUI
/// login session (the VM) and TCC Screen-Recording grant.
///
/// Today this guards exactly ONE bug class
/// (`NSRulerView`-in-`tile()`-in-SwiftUI-commit sibling-blank
/// compositing; see `SourceViewVisualRegressionTests`). A T2-px /
/// `cacheDisplay` raster would render the strips correctly while the live
/// window is blank — a FALSE green — which is precisely why this can't be
/// demoted.
///
/// **A subclass MUST carry a `// TIER-JUSTIFY:` comment** naming the
/// ④-compositor observable that forces a real screen. The structural
/// prohibition ("never attach `NSRulerView` / subclass `NSLayoutManager`
/// in the source view", LESSONS.md) is the primary defense; T5 is
/// belt-and-suspenders.
///
/// Not `@MainActor`: same reasoning as `LiveAppTestCase` — it spawns the
/// app and drives `screencapture(1)` out-of-process.
class PixelTestCase: XCTestCase {}
