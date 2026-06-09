import XCTest
@testable import ViewerUI

/// Pins the TSK-476 conversion of `NSSelectorFromString("openDocument:")`-style
/// string selectors to compile-checked `#selector(AppMenuActions.x(_:))`.
///
/// Two things are guarded here:
///  1. The `#selector(AppMenuActions.…)` references in the body only COMPILE if
///     the `AppMenuActions` protocol declares each method — i.e. the build is
///     the first line of defence (the whole point of the conversion).
///  2. Each compile-checked selector resolves to the EXACT Objective-C selector
///     string the responder chain + the `AppDelegate`'s `@objc` methods expect,
///     so the conversion is behaviour-preserving (the same selector is
///     dispatched via `NSApp.sendAction`). If a protocol method's ObjC
///     signature ever drifts (e.g. an extra parameter → `openDocument:extra:`),
///     this fails — catching the silent mismatch the old string selectors hid.
///
/// Tier: window-free pure assertions — host-safe.
@MainActor
final class AppMenuActionsTests: XCTestCase {

    func test_appMenuActionSelectors_matchResponderChainStrings() {
        XCTAssertEqual(#selector(AppMenuActions.openDocument(_:)),
                       NSSelectorFromString("openDocument:"),
                       "openDocument selector must match the responder-chain string")
        XCTAssertEqual(#selector(AppMenuActions.openFolder(_:)),
                       NSSelectorFromString("openFolder:"),
                       "openFolder selector must match the responder-chain string")
        XCTAssertEqual(#selector(AppMenuActions.showSettings(_:)),
                       NSSelectorFromString("showSettings:"),
                       "showSettings selector must match the responder-chain string")
    }

    /// A local conformer proves the protocol's selectors are dispatchable —
    /// `responds(to:)` is what `NSApp.sendAction(_:to:nil:)` uses to find a
    /// responder, so this exercises the exact lookup the call sites rely on.
    func test_conformerRespondsToEachActionSelector() {
        @MainActor final class Conformer: NSObject, AppMenuActions {
            func openDocument(_ sender: Any?) {}
            func openFolder(_ sender: Any?) {}
            func showSettings(_ sender: Any?) {}
        }
        let c = Conformer()
        XCTAssertTrue(c.responds(to: #selector(AppMenuActions.openDocument(_:))))
        XCTAssertTrue(c.responds(to: #selector(AppMenuActions.openFolder(_:))))
        XCTAssertTrue(c.responds(to: #selector(AppMenuActions.showSettings(_:))))
    }
}
