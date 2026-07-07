import XCTest
@testable import ViewerCore

/// TSK-1530 (M6 v1) — the web-source route gate. Ships OFF (the render swap
/// needs its VM slice green, TSK-1550); env beats defaults; an explicit
/// user default persists.
final class WebSourceViewGateTests: XCTestCase {
    private let suite = "WebSourceViewGateTests-\(UUID().uuidString)"

    func test_shipsOff_envAndDefaultOverride() {
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(WebSourceViewGate.isEnabled(defaults: d, environment: [:]),
                       "M6 ships OFF until the VM render slice validates the swap")
        XCTAssertTrue(WebSourceViewGate.isEnabled(defaults: d, environment: ["MDV_WEB_SOURCE": "1"]))
        XCTAssertFalse(WebSourceViewGate.isEnabled(defaults: d, environment: ["MDV_WEB_SOURCE": "0"]))
        d.set(true, forKey: WebSourceViewGate.defaultsKey)
        XCTAssertTrue(WebSourceViewGate.isEnabled(defaults: d, environment: [:]),
                      "a persisted opt-in enables the route")
        XCTAssertFalse(WebSourceViewGate.isEnabled(defaults: d, environment: ["MDV_WEB_SOURCE": "0"]),
                       "env pin beats the persisted default")
    }
}
