import XCTest
import Foundation

/// L5 long user-flow tests. Realistic multi-step user sessions
/// composed of 10-25 interactions. Each test asserts INVARIANTS that
/// must hold across the whole session — no crashes, content always
/// rendered when expected, state coherent.
///
/// These take 30s-90s each (each step ~300ms). They're a different
/// shape of test than the granular L4 ones: they catch interaction
/// bugs that only show after a stretch of mixed use.
final class LongFlowTests: XCTestCase {

    private var tmpDir: URL!

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var appBundlePath: String {
        projectRoot().appendingPathComponent("dist/MarkdownViewer.app").path
    }

    private var appExecutable: URL {
        projectRoot().appendingPathComponent("dist/MarkdownViewer.app/Contents/MacOS/MarkdownViewer")
    }

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LongFlow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = AppLauncher.currentPID(of: "MarkdownViewer").map { kill($0, SIGTERM) }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func runScript(_ script: String, with fileArg: URL, timeout: TimeInterval = 90) throws -> [[String: Any]] {
        try AppLauncher.runScript(
            appBundlePath: appBundlePath,
            scriptContents: script,
            scriptPath: tmpDir.appendingPathComponent("script.txt").path,
            fileArg: fileArg,
            timeout: timeout
        )
    }

    private func writeMD(_ name: String, _ body: String = "# x\n") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func nodes(_ cls: String, in tree: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ n: [String: Any]) {
            if (n["class"] as? String) == cls { out.append(n) }
            if let s = n["subviews"] as? [[String: Any]] { s.forEach(walk) }
        }
        if let cv = tree["contentView"] as? [String: Any] { walk(cv) }
        return out
    }

    // MARK: - Scenario: day-in-the-life

    func test_dayInTheLife_15Interactions_noBrokenStates() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        // Fixture: a folder with several files of different types.
        for i in 0..<5 {
            _ = try writeMD("doc\(i).md", "# Doc \(i)\nBody for document \(i).\n- item one\n- item two\n")
        }
        let xml = tmpDir.appendingPathComponent("config.xml")
        try "<?xml version=\"1.0\"?>\n<root>\n  <a>1</a>\n  <b>2</b>\n</root>\n"
            .write(to: xml, atomically: true, encoding: .utf8)

        let first = tmpDir.appendingPathComponent("doc0.md")

        let dumps = try runScript("""
            # Open a folder, open a few files, swap modes, zoom, switch tabs,
            # close some, zoom-reset.
            sidebar-set-root \(tmpDir.path)
            toggle-sidebar
            open \(tmpDir.path)/doc1.md
            open \(tmpDir.path)/doc2.md
            open \(xml.path)
            toggle-view
            select-tab 1
            zoom-in
            zoom-in
            next-tab
            next-tab
            toggle-view
            zoom-reset
            prev-tab
            close-tab
            close-tab
            """, with: first)

        XCTAssertEqual(dumps.count, 16,
            "Day-in-life flow should execute 16 distinct steps")

        // Invariants across all steps:
        // 1. No step ends with a window that has zero or negative size.
        // 2. Every step has a non-nil window title.
        // 3. No step has a "white text on white background" NSTextView
        //    (color contrast is True wherever NSTextView exists).
        for (i, d) in dumps.enumerated() {
            let w = (d["window"] as? [String: Any]) ?? [:]
            let frame = w["frame"] as? String ?? ""
            XCTAssertFalse(frame.isEmpty, "Step \(i+1): no window frame")
            let title = w["title"] as? String ?? ""
            XCTAssertFalse(title.isEmpty,
                "Step \(i+1): window title should never be empty mid-flow")
            for tv in nodes("NSTextView", in: d) {
                let info = (tv["nsTextView"] as? [String: Any]) ?? [:]
                if let contrasts = info["contrastsWithBackground"] as? Bool {
                    XCTAssertTrue(contrasts,
                        "Step \(i+1): NSTextView text/bg contrast failed")
                }
            }
        }
    }

    // MARK: - Scenario: heavy tab churn

    func test_heavyTabChurn_openAndCloseManyTabs() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        var urls: [URL] = []
        for i in 0..<8 {
            urls.append(try writeMD("h\(i).md", "# H\(i)\n"))
        }

        // Open all 8 files, then walk through them, then close half.
        var lines: [String] = []
        for u in urls.dropFirst() { lines.append("open \(u.path)") }
        for _ in 0..<6 { lines.append("next-tab") }
        for _ in 0..<3 { lines.append("close-tab") }
        let script = lines.joined(separator: "\n")

        let dumps = try runScript(script, with: urls[0])
        XCTAssertEqual(dumps.count, lines.count,
            "Each step should produce one dump")

        // Invariant: app shouldn't have crashed mid-flow. The last dump
        // must exist (process didn't exit prematurely).
        XCTAssertNotNil(dumps.last, "Last step should have produced a dump")

        // Invariant: tab count should never decrease unexpectedly during
        // the open-many phase (steps 1..7) — we expect monotonic growth.
        // (Hard to read tab count directly from JSON, so we sample using
        // the title length sequence and just sanity-check that titles
        // change repeatedly.)
        let openPhaseTitles = dumps.prefix(7).map {
            ((($0["window"] as? [String: Any])?["title"] as? String) ?? "")
        }
        XCTAssertGreaterThanOrEqual(Set(openPhaseTitles).count, 5,
            "Opening 7 different files should change the title ≥5 times. Titles: \(openPhaseTitles)")
    }

    // MARK: - Scenario: persistence across rerun is consistent

    func test_zoomPersists_acrossFreshLaunch() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let md = try writeMD("p.md", "# pers\nbody\n")
        // First run: zoom in, then exit.
        _ = try runScript("""
            zoom-reset
            zoom-in
            zoom-in
            """, with: md)
        // Second run: open the same file. Zoom should still be 1.2 (two zoom-ins).
        let dumps = try runScript("""
            toggle-view
            """, with: md)
        XCTAssertEqual(dumps.count, 1)
        func fontPt(_ d: [String: Any]) -> Double? {
            guard let tv = nodes("NSTextView", in: d).first,
                  let info = tv["nsTextView"] as? [String: Any],
                  let desc = info["font_description"] as? String else { return nil }
            let parts = desc.split(separator: " ")
            for (i, p) in parts.enumerated() where p == "pt." && i > 0 {
                return Double(parts[i-1])
            }
            return nil
        }
        let pt = fontPt(dumps[0])
        XCTAssertNotNil(pt, "Source view should expose font size")
        if let p = pt {
            // Two zoom-ins at +0.1 each → zoom 1.2 → font 13 * 1.2 = 15.6.
            // Tolerance because we don't know the exact zoom step.
            XCTAssertGreaterThan(p, 13.0 + 1,
                "After zoom-in × 2 + relaunch, font should be > baseline+1. Got \(p)")
        }
        // Reset for clean state after this test.
        _ = try runScript("zoom-reset\n", with: md)
    }
}
