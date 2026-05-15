import XCTest
import Foundation

/// L4 deep interaction tests — exercise tab cycling, sidebar nav,
/// palette show/dismiss, find invocation, window resize, zoom across
/// many small interactions. Driven by the `--script` runner so we don't
/// depend on AppleScript focus stealing.
final class InteractionDeepTests: XCTestCase {

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
            .appendingPathComponent("InteractionDeep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = AppLauncher.currentPID(of: "MarkdownViewer").map { kill($0, SIGTERM) }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func runScript(_ script: String, with fileArg: URL, timeout: TimeInterval = 30) throws -> [[String: Any]] {
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

    // MARK: - Tab cycling

    func test_tabCycling_nextPrev_andSelectByIndex() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let a = try writeMD("a.md", "# A\n")
        let b = try writeMD("b.md", "# B\n")
        let c = try writeMD("c.md", "# C\n")
        // Open three tabs, then cycle through them.
        let dumps = try runScript("""
            open \(b.path)
            open \(c.path)
            select-tab 1
            next-tab
            next-tab
            prev-tab
            """, with: a)
        XCTAssertEqual(dumps.count, 6)
        // After each navigation the window title should reflect the
        // selected tab's filename. Confirm we see at least 2 distinct titles
        // in the sequence (we navigate between 3 files).
        let titles = dumps.map { ($0["window"] as? [String: Any])?["title"] as? String ?? "" }
        XCTAssertGreaterThanOrEqual(Set(titles).count, 2,
            "Tab cycling should produce ≥2 distinct window titles. Got: \(titles)")
    }

    func test_closeMiddleTab_keepsOthers() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let a = try writeMD("aa.md")
        let b = try writeMD("bb.md")
        let c = try writeMD("cc.md")
        let dumps = try runScript("""
            open \(b.path)
            open \(c.path)
            select-tab 2
            close-tab
            """, with: a)
        XCTAssertEqual(dumps.count, 4)
        // Final title should be a.md or c.md (not b.md — that was closed).
        let finalTitle = ((dumps.last?["window"] as? [String: Any])?["title"] as? String) ?? ""
        XCTAssertFalse(finalTitle.contains("bb.md"),
            "After closing the middle tab, the title should not reference bb.md. Got: \(finalTitle)")
    }

    // MARK: - Palette show / dismiss

    func test_palette_showAndDismiss_modelStateUpdates() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let md = try writeMD("a.md")
        let dumps = try runScript("""
            show-palette
            dismiss-palette
            show-palette
            """, with: md)
        XCTAssertEqual(dumps.count, 3)
        // The palette overlay produces a NSHostingView for the panel —
        // detecting its presence from JSON is fragile, so we check that
        // the SwiftUI hosting tree grew/shrunk between steps.
        let counts = dumps.map { d -> Int in
            var count = 0
            func walk(_ n: [String: Any]) {
                count += 1
                if let s = n["subviews"] as? [[String: Any]] { s.forEach(walk) }
            }
            if let cv = d["contentView"] as? [String: Any] { walk(cv) }
            return count
        }
        // After show (1) and again show (3): higher. After dismiss (2): lower.
        XCTAssertGreaterThan(counts[0], counts[1],
            "After dismiss-palette the view tree should shrink. Counts: \(counts)")
        XCTAssertGreaterThan(counts[2], counts[1],
            "After re-show-palette the view tree should grow again. Counts: \(counts)")
    }

    // MARK: - Window resize

    func test_resize_changesWindowGeometry() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let md = try writeMD("a.md")
        let dumps = try runScript("""
            resize 800x600
            resize 1400x900
            """, with: md)
        XCTAssertEqual(dumps.count, 2)
        func size(_ d: [String: Any]) -> (Int, Int) {
            guard let w = d["window"] as? [String: Any],
                  let f = w["frame"] as? String else { return (0, 0) }
            let parts = f.replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .split(whereSeparator: { ",x ".contains($0) })
                .compactMap { Double($0) }
            return parts.count == 4 ? (Int(parts[2]), Int(parts[3])) : (0, 0)
        }
        let (w1, h1) = size(dumps[0])
        let (w2, h2) = size(dumps[1])
        // First resize: 800x600 + titlebar height. Window.frame includes the
        // titlebar so height will be ~600+28 = 628.
        XCTAssertEqual(w1, 800, "First resize width should be 800")
        XCTAssertGreaterThan(h1, 600 - 5)
        XCTAssertLessThan(h1, 600 + 40)
        XCTAssertEqual(w2, 1400, "Second resize width should be 1400")
        XCTAssertGreaterThan(h2, 900 - 5)
        XCTAssertLessThan(h2, 900 + 40)
    }

    // MARK: - Zoom persistence

    func test_zoom_persistsAcrossNewTab() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let a = try writeMD("a.md", "# A\nbody\n")
        let b = try writeMD("b.md", "# B\nbody\n")
        // View mode is per-tab; new tabs inherit the current view mode. So
        // toggle-view → source for a.md, zoom in twice, open b.md (inherits
        // source mode), and the NSTextView in b.md should have the SAME
        // font size as the one in a.md.
        let dumps = try runScript("""
            zoom-reset
            toggle-view
            zoom-in
            zoom-in
            open \(b.path)
            """, with: a)
        XCTAssertEqual(dumps.count, 5)
        func fontPt(_ d: [String: Any]) -> Double? {
            let tvs = nodes("NSTextView", in: d)
            guard let tv = tvs.first,
                  let info = tv["nsTextView"] as? [String: Any],
                  let desc = info["font_description"] as? String else { return nil }
            let parts = desc.split(separator: " ")
            for (i, p) in parts.enumerated() where p == "pt." && i > 0 {
                return Double(parts[i-1])
            }
            return nil
        }
        // dumps[3]: source view of a.md after two zoom-ins.
        // dumps[4]: just opened b.md — inherits source mode + zoom.
        let zoomedA = fontPt(dumps[3])
        let zoomedB = fontPt(dumps[4])
        XCTAssertNotNil(zoomedA, "Step 4 (zoom-in #2 on a.md source view) should have NSTextView with font info")
        XCTAssertNotNil(zoomedB, "Step 5 (opened b.md, inheriting source mode) should have NSTextView")
        if let za = zoomedA, let zb = zoomedB {
            XCTAssertEqual(za, zb, accuracy: 0.5,
                "Zoomed font size should be identical across tabs (model.zoom persists). a=\(za) b=\(zb)")
        }
    }

    // MARK: - Sidebar navigation

    func test_sidebar_setRoot_andWalkUp() throws {
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw XCTSkip("Build .app first")
        }
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try writeMD("sub/inner.md", "# inner\n")
        let outer = try writeMD("a.md")
        // Set root to subfolder, then walk up. Walk-up only moves *selection*
        // if there's a selection inside the root — here there's none, so
        // sidebar root stays put. This still exercises the code path.
        let dumps = try runScript("""
            sidebar-set-root \(sub.path)
            sidebar-walk-up
            sidebar-select-next
            sidebar-select-prev
            """, with: outer)
        XCTAssertEqual(dumps.count, 4)
        // Just verify no crash and all 4 dumps were produced.
    }
}
