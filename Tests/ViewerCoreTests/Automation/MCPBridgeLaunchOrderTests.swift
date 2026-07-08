import XCTest
@testable import ViewerCore

/// P0 launch-wedge guard (2026-07-07 incident): a `--mcp-connect` bridge
/// process that touches AppKit registers with LaunchServices as an instance
/// of TextView.app — Finder then tries to ACTIVATE the windowless bridge
/// instead of launching the app, and `open` fails with -600 ("can't open").
/// The bridge branch in main.swift must therefore run BEFORE
/// `NSApplication.shared`. This parses the LIVE source (the SettingsCatalog
/// drift-guard pattern) so a reorder goes RED.
final class MCPBridgeLaunchOrderTests: XCTestCase {

    private func mainSwift() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Automation
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/MarkdownViewer/main.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_bridgeBranch_runsBeforeAppKitSpinUp() throws {
        let source = try mainSwift()
        let bridge = source.range(of: "let mcpConnectMode = CommandLine.arguments")
        let appKit = source.range(of: "let app = NSApplication.shared")
        let serveCall = source.range(of: "MCPSocketBridge.serve(")
        XCTAssertNotNil(bridge, "the --mcp-connect branch exists in main.swift")
        XCTAssertNotNil(appKit, "the NSApplication spin-up exists in main.swift")
        XCTAssertNotNil(serveCall, "the bridge serve call exists in main.swift")
        guard let b = bridge, let a = appKit, let s = serveCall else { return }
        XCTAssertTrue(b.lowerBound < a.lowerBound,
                      "the --mcp-connect check must PRECEDE NSApplication.shared — "
                      + "an AppKit-touching bridge wedges LaunchServices (-600, "
                      + "the owner cannot open the app)")
        XCTAssertTrue(s.lowerBound < a.lowerBound,
                      "the bridge's serve+exit must complete before any AppKit spin-up")
    }

    func test_bridgeBranch_armsTheOrphanWatchdog() throws {
        // The zombie half of the incident: a bridge outliving its dead client
        // (orphan-held pipe ends) sat for a DAY and wedged LaunchServices.
        // The branch must arm exitWhenOrphaned before serving.
        let source = try mainSwift()
        guard let branchStart = source.range(of: "if mcpConnectMode,"),
              let serveCall = source.range(of: "MCPSocketBridge.serve(") else {
            return XCTFail("bridge branch not found")
        }
        let branchBody = source[branchStart.lowerBound..<serveCall.lowerBound]
        XCTAssertTrue(branchBody.contains("exitWhenOrphaned"),
                      "the bridge must self-reap when its client parent dies")
    }
}
