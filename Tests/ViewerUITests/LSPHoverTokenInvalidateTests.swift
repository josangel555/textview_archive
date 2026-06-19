import XCTest
import AppKit
@testable import ViewerUI

/// Host-safe model-seam tests for `LSPHoverToken.invalidate()` (TSK-963
/// PART 1). The leak this fixes — two NotificationCenter block observers
/// captured `state` STRONGLY and were only removed via a deferred `Task`
/// in `deinit` that may never run — is closed by an explicit, synchronous,
/// idempotent `invalidate()`. The NSPopover *visual* behavior is VM-only;
/// here we pin the cleanup bookkeeping + real observer removal that a logic
/// regression would trip.
///
/// These use real (headless-safe) AppKit objects: `NSTextView` +
/// `NSTrackingArea` need no window/screen to construct or to
/// `removeTrackingArea`, and `NotificationCenter` is a plain Foundation
/// type. No window opens, so this stays in the default HeadlessUITestCase
/// tier. Run with `ViewerUITests.LSPHoverTokenInvalidateTests`.
@MainActor
final class LSPHoverTokenInvalidateTests: XCTestCase {

    /// Build a token over a real NSTextView/tracking area plus N
    /// NotificationCenter observers that bump `counter` when their
    /// notification fires. Returns the token and the observer names so the
    /// caller can post + assert removal.
    private func makeToken(
        observerCount: Int,
        counter: NSMutableArray
    ) -> (LSPHoverToken, [Notification.Name]) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let area = NSTrackingArea(
            rect: tv.bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: tv, userInfo: nil)
        tv.addTrackingArea(area)

        var tokens: [NSObjectProtocol] = []
        var names: [Notification.Name] = []
        let center = NotificationCenter.default
        for i in 0..<observerCount {
            let name = Notification.Name("LSPHoverTokenTest_\(UUID().uuidString)_\(i)")
            names.append(name)
            let tok = center.addObserver(
                forName: name, object: nil, queue: nil
            ) { _ in
                counter.add(1)
            }
            tokens.append(tok)
        }
        let token = LSPHoverToken._makeForTesting(
            textView: tv, trackingArea: area, notifTokens: tokens)
        return (token, names)
    }

    func test_invalidate_clearsBookkeeping() {
        let counter = NSMutableArray()
        let (token, _) = makeToken(observerCount: 2, counter: counter)

        XCTAssertFalse(token._isInvalidatedForTesting)
        XCTAssertEqual(token._notifTokenCountForTesting, 2)
        XCTAssertTrue(token._hasTextViewForTesting)

        token.invalidate()

        XCTAssertTrue(token._isInvalidatedForTesting,
            "invalidate() must latch isInvalidated")
        XCTAssertEqual(token._notifTokenCountForTesting, 0,
            "invalidate() must drop all NotificationCenter observer tokens")
        XCTAssertFalse(token._hasTextViewForTesting,
            "invalidate() must release the textView reference")
    }

    func test_invalidate_removesObserversForReal() {
        // The leak's teeth: prove the observer is actually deregistered, not
        // just dropped from the array. Post BEFORE invalidate → fires; post
        // AFTER → must NOT fire.
        let counter = NSMutableArray()
        let (token, names) = makeToken(observerCount: 2, counter: counter)
        let center = NotificationCenter.default

        for name in names { center.post(name: name, object: nil) }
        XCTAssertEqual(counter.count, 2, "observers should fire while registered")

        token.invalidate()

        for name in names { center.post(name: name, object: nil) }
        XCTAssertEqual(counter.count, 2,
            "after invalidate() the observers must be removed (no further fires)")
    }

    func test_invalidate_isIdempotent() {
        let counter = NSMutableArray()
        let (token, names) = makeToken(observerCount: 1, counter: counter)

        token.invalidate()
        // Second + third calls must be safe no-ops (no crash, no double
        // removeObserver, state stays cleared).
        token.invalidate()
        token.invalidate()

        XCTAssertTrue(token._isInvalidatedForTesting)
        XCTAssertEqual(token._notifTokenCountForTesting, 0)

        let center = NotificationCenter.default
        for name in names { center.post(name: name, object: nil) }
        XCTAssertEqual(counter.count, 0,
            "observer stays removed across repeated invalidate() calls")
    }

    func test_invalidate_withNoObservers_isSafe() {
        // A token bound to a textView with no scroll view / window registers
        // zero observers — invalidate() must still be a clean no-op-ish call.
        let counter = NSMutableArray()
        let (token, _) = makeToken(observerCount: 0, counter: counter)
        token.invalidate()
        XCTAssertTrue(token._isInvalidatedForTesting)
        XCTAssertEqual(token._notifTokenCountForTesting, 0)
        XCTAssertFalse(token._hasTextViewForTesting)
    }
}
