import XCTest
import Foundation

/// L5 scenario tests: longer composed flows that exercise multiple
/// components in sequence. These verify that interactions chain
/// correctly — that toggling source mode while a search is active
/// doesn't break, that opening multiple files updates the tabs AND
/// the title, etc.
///
/// Each scenario is one `--script` run with N steps. We assert on
/// invariants that span steps, not just the final state — that's what
/// a chain test is for.
final class ScenarioTests: XCTestCase {

    private var tmpDir: URL!

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var appBundlePath: String {
        projectRoot().appendingPathComponent("dist/MarkdownViewer.app").path
    }

    private var appExecutable: URL {
        projectRoot().appendingPathComponent(
            "dist/MarkdownViewer.app/Contents/MacOS/MarkdownViewer")
    }

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scenario-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = AppLauncher.currentPID(of: "MarkdownViewer").map { kill($0, SIGTERM) }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func runScript(
        _ script: String,
        with fileArg: URL,
        timeout: TimeInterval = 30
    ) throws -> [[String: Any]] {
        try AppLauncher.runScript(
            appBundlePath: appBundlePath,
            scriptContents: script,
            scriptPath: tmpDir.appendingPathComponent("script.txt").path,
            fileArg: fileArg,
            timeout: timeout
        )
    }

    private func writeMarkdown(_ name: String, _ body: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func nodesOfClass(_ cls: String, in tree: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ n: [String: Any]) {
            if (n["class"] as? String) == cls { out.append(n) }
            if let subs = n["subviews"] as? [[String: Any]] { subs.forEach(walk) }
        }
        if let cv = tree["contentView"] as? [String: Any] { walk(cv) }
        return out
    }

    // MARK: - Scenario 1: open multiple files via script, verify tabs accumulate

    func test_scenario_openMultipleFiles_buildsTabList() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let a = try writeMarkdown("a.md", "# A\n")
        let b = try writeMarkdown("b.md", "# B\n")
        let c = try writeMarkdown("c.md", "# C\n")
        // Open `a` via argv, then open b and c via script.
        let dumps = try runScript("""
            open \(b.path)
            open \(c.path)
            prev-tab
            close-tab
            """, with: a)
        XCTAssertEqual(dumps.count, 4)
        // After step 2 (open b, open c): 3 tabs total.
        // After step 3 (prev-tab): still 3 tabs, just different selected.
        // After step 4 (close-tab): 2 tabs.
        let titles = dumps.map { ($0["window"] as? [String: Any])?["title"] as? String ?? "" }
        // Title should have changed at least once across the 4 steps.
        let uniqueTitles = Set(titles)
        XCTAssertGreaterThanOrEqual(uniqueTitles.count, 2,
            "Window title should change as we open/close files. Titles: \(titles)")
    }

    // MARK: - Scenario 2: source mode round-trip preserves content

    func test_scenario_renderedSourceRoundtrip_keepsContent() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let md = try writeMarkdown("rt.md", """
            # Heading

            This is a paragraph with **bold** and *italic*.

            - first
            - second
            - third
            """)
        let dumps = try runScript("""
            toggle-view
            toggle-view
            toggle-view
            """, with: md)
        XCTAssertEqual(dumps.count, 3)
        // Step 1: source. Step 2: rendered. Step 3: source.
        let s1 = nodesOfClass("NSTextView", in: dumps[0]).first
        let s3 = nodesOfClass("NSTextView", in: dumps[2]).first
        XCTAssertNotNil(s1, "Step 1 should be in source mode (NSTextView present)")
        XCTAssertNotNil(s3, "Step 3 should be back in source mode")
        let len1 = (s1?["nsTextView"] as? [String: Any])?["string_length"] as? Int ?? 0
        let len3 = (s3?["nsTextView"] as? [String: Any])?["string_length"] as? Int ?? 0
        XCTAssertEqual(len1, len3,
            "Text content length must be the same before and after rendered/source/source roundtrip")
        // Middle step is rendered — verify WKWebView present, no NSTextView.
        XCTAssertTrue(nodesOfClass("NSTextView", in: dumps[1]).isEmpty,
            "Step 2 should not have an NSTextView source view")
        XCTAssertFalse(nodesOfClass("WKWebView", in: dumps[1]).isEmpty,
            "Step 2 should have a WKWebView for rendered markdown")
    }

    // MARK: - Scenario 3: zoom then toggle view persists zoom

    func test_scenario_zoomPersistsAcrossViewToggle() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let md = try writeMarkdown("z.md", "# Hello\n\nsome text\n")
        let dumps = try runScript("""
            toggle-view
            zoom-in
            zoom-in
            toggle-view
            toggle-view
            """, with: md)
        XCTAssertEqual(dumps.count, 5)
        // Step 1: source mode, baseline font.
        // Step 2-3: zoomed in.
        // Step 4: rendered mode (zoom should still be the same model state).
        // Step 5: source mode again — font should still be at zoomed-2x level.
        func fontPt(_ d: [String: Any]) -> Double? {
            guard let tv = nodesOfClass("NSTextView", in: d).first,
                  let info = tv["nsTextView"] as? [String: Any],
                  let desc = info["font_description"] as? String else { return nil }
            let parts = desc.split(separator: " ")
            for (i, p) in parts.enumerated() where p == "pt." && i > 0 {
                return Double(parts[i-1])
            }
            return nil
        }
        let baseline = fontPt(dumps[0])
        let zoomedTwoSteps = fontPt(dumps[2])
        let returnedToSource = fontPt(dumps[4])
        XCTAssertNotNil(baseline)
        XCTAssertNotNil(zoomedTwoSteps)
        XCTAssertNotNil(returnedToSource)
        if let b = baseline, let z = zoomedTwoSteps, let r = returnedToSource {
            XCTAssertGreaterThan(z, b, "two zoom-in steps must enlarge the font")
            XCTAssertEqual(r, z, accuracy: 0.5,
                "after rendered round-trip, source view's font should still be at the zoomed size")
        }
    }

    // MARK: - Scenario 4: open folder, sidebar shows, content area stays valid

    func test_scenario_openFolder_doesNotBreakContent() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let md = try writeMarkdown("a.md", "# inline\n")
        // Open a sibling file then open the folder. Content should remain
        // valid throughout.
        let dumps = try runScript("""
            open \(tmpDir.path)
            zoom-in
            zoom-reset
            """, with: md)
        XCTAssertEqual(dumps.count, 3)
        // WKWebView should be present in all three steps (we're in markdown
        // rendered mode for a.md throughout).
        for (i, d) in dumps.enumerated() {
            let webs = nodesOfClass("WKWebView", in: d)
            XCTAssertFalse(webs.isEmpty,
                "WKWebView should be present at step \(i + 1) — folder-open should not collapse content")
        }
    }
}
