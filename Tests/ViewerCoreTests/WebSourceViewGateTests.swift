import XCTest
@testable import ViewerCore

/// TSK-1530 (M6) — the web-source route gate. Ships ON since 2026-07-17
/// (owner directive: retire NSTextView from the source lens); env beats
/// defaults; an explicit user default persists; documents over the
/// large-file threshold fall back to the NSTextView stack (CM6 has no
/// large-file guard).
final class WebSourceViewGateTests: XCTestCase {
    private let suite = "WebSourceViewGateTests-\(UUID().uuidString)"

    func test_shipsOn_envAndDefaultOverride() {
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(WebSourceViewGate.isEnabled(defaults: d, environment: [:]),
                      "M6 ships ON — CM6 read-only is the source lens (owner 2026-07-17)")
        XCTAssertTrue(WebSourceViewGate.isEnabled(defaults: d, environment: ["MDV_WEB_SOURCE": "1"]))
        XCTAssertFalse(WebSourceViewGate.isEnabled(defaults: d, environment: ["MDV_WEB_SOURCE": "0"]),
                       "env kill-switch disables the route")
        d.set(false, forKey: WebSourceViewGate.defaultsKey)
        XCTAssertFalse(WebSourceViewGate.isEnabled(defaults: d, environment: [:]),
                       "a persisted opt-out disables the route")
        XCTAssertTrue(WebSourceViewGate.isEnabled(defaults: d, environment: ["MDV_WEB_SOURCE": "1"]),
                      "env pin beats the persisted default")
    }

    func test_sizeGate_largeFilesFallBackToNSTextView() {
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WebSourceViewGate.maxBytes(defaults: d),
                       WebSourceViewGate.defaultMaxBytes,
                       "default threshold is 16 MiB")
        XCTAssertTrue(WebSourceViewGate.shouldUseWebSource(byteLength: 4096, defaults: d, environment: [:]))
        XCTAssertTrue(WebSourceViewGate.shouldUseWebSource(
            byteLength: WebSourceViewGate.defaultMaxBytes, defaults: d, environment: [:]),
            "threshold itself is inclusive")
        XCTAssertFalse(WebSourceViewGate.shouldUseWebSource(
            byteLength: WebSourceViewGate.defaultMaxBytes + 1, defaults: d, environment: [:]),
            "over-threshold documents stay on the NSTextView large-file path")
    }

    func test_sizeGate_thresholdTunableViaDefaults() {
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(1024, forKey: WebSourceViewGate.maxBytesDefaultsKey)
        XCTAssertEqual(WebSourceViewGate.maxBytes(defaults: d), 1024)
        XCTAssertTrue(WebSourceViewGate.shouldUseWebSource(byteLength: 1024, defaults: d, environment: [:]))
        XCTAssertFalse(WebSourceViewGate.shouldUseWebSource(byteLength: 1025, defaults: d, environment: [:]))
        // A nonsense (non-positive) override falls back to the shipped default.
        d.set(-5, forKey: WebSourceViewGate.maxBytesDefaultsKey)
        XCTAssertEqual(WebSourceViewGate.maxBytes(defaults: d), WebSourceViewGate.defaultMaxBytes)
    }

    func test_sizeGate_respectsDisabledGate() {
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(WebSourceViewGate.shouldUseWebSource(
            byteLength: 10, defaults: d, environment: ["MDV_WEB_SOURCE": "0"]),
            "size gate never overrides a disabled gate")
        d.set(false, forKey: WebSourceViewGate.defaultsKey)
        XCTAssertFalse(WebSourceViewGate.shouldUseWebSource(byteLength: 10, defaults: d, environment: [:]))
    }
}
