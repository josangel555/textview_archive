import XCTest
import Combine
import ViewerKit
@testable import ViewerUI

/// Extended hover-state coverage for `HelpSink` beyond the two basic
/// dedupe/clear cases in `HelpSinkTests`.
///
/// `HelpSink` is a plain `ObservableObject` + Combine publisher — no
/// NSApplication, no window — so these are host-safe despite living in
/// the ViewerUI test target (HelpSink imports SwiftUI). Run with the
/// class filter `ViewerUITests.HelpSinkHoverStateTests`.
///
/// The contract under test: `set(_:)` publishes `objectWillChange`
/// exactly when the stored `HelpInfo?` actually changes (REPUB-1
/// discipline — hover enter/leave fires on the render thread on every
/// pointer move, so an equal-value set MUST be a no-op).
@MainActor
final class HelpSinkHoverStateTests: XCTestCase {

    /// Subscribe and count `objectWillChange` emissions for the body of a
    /// closure, returning the count.
    private func countingPublishes(of sink: HelpSink,
                                   _ body: () -> Void) -> Int {
        var n = 0
        let c = sink.objectWillChange.sink { _ in n += 1 }
        defer { c.cancel() }
        body()
        return n
    }

    // MARK: - Distinct-value transitions each publish once

    func test_changingToDifferentValue_publishesEachTransition() {
        let sink = HelpSink()
        let a = HelpInfo(title: "A", description: "1")
        let b = HelpInfo(title: "B", description: "2")
        let n = countingPublishes(of: sink) {
            sink.set(a)   // nil → a  : publish
            sink.set(b)   // a → b    : publish
            sink.set(a)   // b → a    : publish
        }
        XCTAssertEqual(n, 3, "each distinct transition must republish")
        XCTAssertEqual(sink.hovered, a)
    }

    /// Hover element A, move onto B without an intervening exit (no nil in
    /// between) — the common "slide pointer across the toolbar" path. Each
    /// element-to-element move is one publish; the stored value tracks the
    /// latest.
    func test_elementToElement_withoutNilBetween() {
        let sink = HelpSink()
        let a = HelpInfo(title: "Save", description: "Write to disk")
        let b = HelpInfo(title: "Open", description: "Open a file")
        sink.set(a)
        let n = countingPublishes(of: sink) {
            sink.set(b)   // a → b directly (no exit): publish once
        }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(sink.hovered, b)
    }

    // MARK: - Equal-value runs collapse to a single publish

    /// A long run of equal-value sets (pointer wiggling inside one
    /// element) must publish at most once — the entry, then silence.
    func test_repeatedEqualSets_collapseToOnePublish() {
        let sink = HelpSink()
        let info = HelpInfo(title: "T", description: "D")
        let n = countingPublishes(of: sink) {
            for _ in 0..<50 { sink.set(info) }
        }
        XCTAssertEqual(n, 1, "a run of equal-value sets must publish only once")
        XCTAssertEqual(sink.hovered, info)
    }

    /// Equal *by value* but a different instance/struct literal still
    /// dedupes (Equatable, not identity).
    func test_equalByValueDifferentLiteral_dedupes() {
        let sink = HelpSink()
        let n = countingPublishes(of: sink) {
            sink.set(HelpInfo(title: "T", description: "D"))
            sink.set(HelpInfo(title: "T", description: "D"))
        }
        XCTAssertEqual(n, 1)
    }

    // MARK: - Enter → exit → re-enter

    func test_enterExitReenter_sameValue_publishesThreeTimes() {
        let sink = HelpSink()
        let info = HelpInfo(title: "T", description: "D")
        let n = countingPublishes(of: sink) {
            sink.set(info)   // nil → info : publish
            sink.set(nil)    // info → nil : publish
            sink.set(info)   // nil → info : publish
        }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(sink.hovered, info)
    }

    func test_redundantNilExit_afterNil_doesNotPublish() {
        let sink = HelpSink()
        let n = countingPublishes(of: sink) {
            sink.set(nil)   // already nil: no publish
            sink.set(nil)   // still nil: no publish
        }
        XCTAssertEqual(n, 0)
        XCTAssertNil(sink.hovered)
    }

    // MARK: - Stored value reflects the latest set

    func test_hovered_reflectsLatestDistinctSet() {
        let sink = HelpSink()
        XCTAssertNil(sink.hovered)
        sink.set(HelpInfo(title: "A", description: "1"))
        sink.set(HelpInfo(title: "B", description: "2"))
        XCTAssertEqual(sink.hovered, HelpInfo(title: "B", description: "2"))
        sink.set(nil)
        XCTAssertNil(sink.hovered)
    }

    // MARK: - Shared environment default

    /// `HelpSink.shared` seeds the `\.helpSink` environment default so
    /// producers and the StatusBar line up without root wiring. It must be
    /// a single stable instance across reads.
    func test_sharedInstance_isStableSingleton() {
        XCTAssertTrue(HelpSink.shared === HelpSink.shared)
    }

    /// A freshly-constructed sink is independent of `shared` — per-window
    /// isolation (overriding `\.helpSink`) must not bleed into the
    /// process-wide default.
    func test_freshInstance_isIndependentOfShared() {
        let local = HelpSink()
        XCTAssertFalse(local === HelpSink.shared)
        local.set(HelpInfo(title: "local", description: "only"))
        // Mutating the local instance must not touch the shared default.
        XCTAssertNotEqual(HelpSink.shared.hovered,
                          HelpInfo(title: "local", description: "only"))
    }

    /// Fresh sink starts empty (nil hovered) — the StatusBar slot is blank
    /// until the first hover.
    func test_freshInstance_startsWithNilHovered() {
        XCTAssertNil(HelpSink().hovered)
    }
}
