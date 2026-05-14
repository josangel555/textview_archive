import XCTest
import AppKit

/// Tier 4 (lite): launches the built `.app` as a real subprocess, then
/// queries the running app's window via the macOS accessibility bridge
/// (AppleScript / System Events). Catches bugs that pure in-process
/// hosting tests can't:
///   - window restored off-screen onto a disconnected monitor
///   - argv handling broken at the launch path
///   - AppDelegate setup ordering bugs
///   - apps that "launch" but never produce a visible window
///
/// Requires:
///   1. `bash scripts/build-app.sh debug` to produce dist/MarkdownViewer.app.
///   2. Accessibility permission for `osascript`/`xctest` (System Settings →
///      Privacy & Security → Accessibility). Without it, the test skips.
@MainActor
final class LiveAppLaunchTests: XCTestCase {

    private var process: Process?
    private var tmpDir: URL!

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // project root
    }

    private var appExecutable: URL {
        projectRoot()
            .appendingPathComponent("dist/MarkdownViewer.app/Contents/MacOS/MarkdownViewer")
    }

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveAppLaunchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let p = process, p.isRunning {
            p.terminate()
            // Give the SIGTERM up to a second to land, then force-kill.
            for _ in 0..<10 {
                if !p.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                p.waitUntilExit()
            }
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func runAppleScript(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func test_launchWithXML_windowAppearsAndHasUIChildren() async throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build the .app first: `bash scripts/build-app.sh debug`")
        }

        // Permission probe — if AppleScript can't even talk to System Events,
        // there's no way to query the running app's window. Skip gracefully.
        if runAppleScript(#"tell application "System Events" to return "ok""#) != "ok" {
            throw XCTSkip("AppleScript / Accessibility access not available to xctest. Grant Accessibility permission to `xctest` in System Settings → Privacy & Security → Accessibility, then re-run.")
        }

        let xml = tmpDir.appendingPathComponent("live.xml")
        try """
        <?xml version="1.0"?>
        <root>
          <a/>
          <b/>
          <c/>
        </root>
        """.write(to: xml, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = appExecutable
        p.arguments = [xml.path]
        try p.run()
        self.process = p

        // Wait for the window to appear.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertTrue(p.isRunning, "Live app exited unexpectedly within 2.5s of launch")

        // Query the window count.
        let countOutput = runAppleScript("""
        tell application "System Events"
            tell process "MarkdownViewer"
                return (count of windows) as text
            end tell
        end tell
        """)
        XCTAssertEqual(countOutput, "1",
            "Expected exactly one MarkdownViewer window after launch with an XML file. Got: \(countOutput ?? "nil")")

        // Query window geometry.
        let geomOutput = runAppleScript("""
        tell application "System Events"
            tell process "MarkdownViewer"
                set w to front window
                set p to position of w
                set s to size of w
                return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
            end tell
        end tell
        """)
        guard let geom = geomOutput else {
            return XCTFail("Could not read window geometry")
        }
        let parts = geom.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 4 else {
            return XCTFail("Window geometry parse failed: '\(geom)'")
        }
        let width = parts[2], height = parts[3]
        XCTAssertGreaterThan(width, 100, "Window too narrow: \(width)pt")
        XCTAssertGreaterThan(height, 100, "Window too short: \(height)pt")

        // Sanity-check the UI hierarchy: the window should have multiple
        // child UI elements, including at least one AXScrollArea (the
        // tab bar, sidebar, or source view).
        let countChildren = runAppleScript("""
        tell application "System Events"
            tell process "MarkdownViewer"
                set w to front window
                return (count of UI elements of w) as text
            end tell
        end tell
        """)
        if let n = countChildren.flatMap(Int.init) {
            XCTAssertGreaterThanOrEqual(n, 5,
                "Window should have ≥5 child UI elements (tabbar, sidebar, source, etc.); got \(n)")
        }

        // SwiftUI wraps everything in a top-level AXGroup so scroll areas
        // are nested two levels under the window. `entire contents` is
        // unreliable for cross-process AX, so we walk explicitly to depth
        // 3 and emit a `|`-delimited "widthxheight" string per scroll area.
        // Parsing happens in Swift — AppleScript's coercion of `size`
        // (a {w, h} list) into integers via `item 1 of …` is finicky.
        let walkOutput = runAppleScript(#"""
        tell application "System Events"
            tell process "MarkdownViewer"
                set w to front window
                set output to ""
                repeat with l1 in (UI elements of w)
                    try
                        if role of l1 is "AXScrollArea" then
                            set sz to size of l1
                            set output to output & ((item 1 of sz) as text) & "x" & ((item 2 of sz) as text) & "|"
                        end if
                    end try
                    try
                        repeat with l2 in (UI elements of l1)
                            try
                                if role of l2 is "AXScrollArea" then
                                    set sz to size of l2
                                    set output to output & ((item 1 of sz) as text) & "x" & ((item 2 of sz) as text) & "|"
                                end if
                            end try
                            try
                                repeat with l3 in (UI elements of l2)
                                    try
                                        if role of l3 is "AXScrollArea" then
                                            set sz to size of l3
                                            set output to output & ((item 1 of sz) as text) & "x" & ((item 2 of sz) as text) & "|"
                                        end if
                                    end try
                                end repeat
                            end try
                        end repeat
                    end try
                end repeat
                return output
            end tell
        end tell
        """#)
        guard let raw = walkOutput else {
            return XCTFail("AppleScript walk returned nil")
        }
        let scrolls: [(width: Int, height: Int)] = raw
            .split(separator: "|")
            .compactMap { part in
                let dims = part.split(separator: "x").compactMap { Int($0) }
                guard dims.count == 2 else { return nil }
                return (dims[0], dims[1])
            }
        XCTAssertGreaterThanOrEqual(scrolls.count, 2,
            "Window should contain ≥2 AXScrollAreas (TabBar + content). Got \(scrolls.count) — raw: '\(raw)'")
        // The regression we keep chasing: source view squished to the
        // line-number gutter width (~40pt). With contentMinSize=(600,360),
        // the widest scroll area should easily exceed 200pt.
        let widest = scrolls.map { $0.width }.max() ?? 0
        XCTAssertGreaterThan(widest, 200,
            "Widest scroll area should be > 200pt (otherwise the source view collapsed to the line-number gutter). Got \(widest)pt — raw: '\(raw)'")
    }
}
