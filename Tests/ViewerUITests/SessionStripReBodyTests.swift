import SwiftUI
import XCTest
import ViewerCore
@testable import ViewerUI

/// PERF #1 guard for the SESSION strip — the counterpart to
/// `ChromeBodyEvalCountTests`, which hosts `ContentView` and so covers only
/// the file `TabBar`.
///
/// This matters more here than on the file strip: every `SessionTabBarItem`
/// body calls `SessionGitInfo.badge(forRootPath:)`, which touches the
/// filesystem, so a strip that re-bodies on unrelated republishes does real
/// per-pass IO.
///
/// It exists because drag-to-reorder needed `@State` holding an array
/// (`StripReorderState.frames`) plus a class (`StripFrameBox`), and a
/// non-bitwise-comparable stored property costs the owning view SwiftUI's
/// structural-equality skip — it then re-bodies every time its parent does.
/// The state lives in the private `SessionStripContent` leaf for exactly
/// that reason; inlining it back into `SessionTabBar` re-breaks this.
/// See LESSONS.md 2026-07-27.
/// Parent that re-bodies for a reason the session strip does NOT observe.
///
/// This shape is load-bearing: the structural-equality skip only exists when
/// a PARENT re-bodies and re-creates the child. Hosting `SessionTabBar` as
/// the ROOT makes the test a false green — nothing ever re-creates it, so it
/// passes no matter what state the strip carries. (First version of this file
/// did exactly that and stayed green with a deliberately-broken strip.)
///
/// It observes `FindCoordinator`, which the strip does not, so a find
/// keystroke re-bodies the parent while nothing the strip renders changes —
/// the same situation as `ContentView` vs `TabBar` in the live app.
private struct SessionStripReBodyHost: View {
    @ObservedObject var find: FindCoordinator
    let sessionsApp: SessionsAppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Read the query so the parent genuinely depends on it.
            Text(find.sourceQuery).frame(height: 1)
            SessionTabBar(sessionsApp: sessionsApp)
        }
    }
}

@MainActor
final class SessionStripReBodyTests: HeadlessUITestCase {

    private var host: NSHostingView<SessionStripReBodyHost>?

    private func pump() {
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host?.layoutSubtreeIfNeeded()
    }

    /// Drain setup/async residual until the strip stops re-bodying, so no
    /// initial-render body leaks into the measured window (the `settle()`
    /// pattern from `ChromeBodyEvalCountTests`).
    private func settle() {
        BodyProbe.enabled = true
        var consecutiveEmpty = 0
        for _ in 0..<24 {
            BodyProbe.reset()
            pump()
            if BodyProbe.counts.isEmpty {
                consecutiveEmpty += 1
                if consecutiveEmpty >= 2 { break }
            } else {
                consecutiveEmpty = 0
            }
        }
        BodyProbe.reset()
    }

    private func mount(_ harness: HeadlessHarness) {
        host = NSHostingView(rootView: SessionStripReBodyHost(
            find: harness.model.find, sessionsApp: harness.sessions))
        host?.frame = NSRect(x: 0, y: 0, width: 1100, height: 200)
        for _ in 0..<4 { host?.layoutSubtreeIfNeeded() }
        pump()
    }

    /// A parent re-body for a reason the strip does not observe must NOT
    /// re-body the strip.
    func test_parentRepublish_doesNotReBodyTheSessionStrip() throws {
        let harness = HeadlessHarness(label: "SessionStripReBody")
        mount(harness)

        // Retry across distinct keystrokes and keep the LAST attempt — the
        // `evalsExpectingZero` rule from ChromeBodyEvalCountTests: a genuine
        // per-republish re-body shows on EVERY attempt, while a transient
        // async body clears on a clean one. (Accumulating the worst attempt
        // instead makes one stray body fail the test forever.)
        var observed = Int.max
        for i in 0..<4 {
            settle()
            BodyProbe.enabled = true
            harness.model.find.sourceQuery = "needle\(i)"
            pump()
            BodyProbe.enabled = false
            observed = BodyProbe.count("SessionTabBar")
            if observed == 0 { break }
        }
        XCTAssertEqual(observed, 0,
            "SessionTabBar re-bodied when only its PARENT did — each pill body "
            + "does filesystem IO (SessionGitInfo). The reorder @State must "
            + "stay in the SessionStripContent leaf (LESSONS 2026-07-27).")
        BodyProbe.enabled = false
    }

    /// Negative control: the assert above is only meaningful if the parent
    /// actually re-bodies and the probe can count a strip body. A zoom change
    /// rescales the whole strip, so it MUST re-body.
    func test_zoomChange_doesReBodyTheSessionStrip() throws {
        let harness = HeadlessHarness(label: "SessionStripReBodyZoom")
        mount(harness)
        settle()

        BodyProbe.enabled = true
        harness.model.zoom = harness.model.zoom + 0.25
        pump()
        BodyProbe.enabled = false
        XCTAssertGreaterThan(BodyProbe.count("SessionTabBar"), 0,
            "the probe must be able to observe a strip body — otherwise the "
            + "zero-assert above proves nothing")
    }
}
