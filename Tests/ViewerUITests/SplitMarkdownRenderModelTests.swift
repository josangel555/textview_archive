import XCTest
import ViewerCore
@testable import ViewerUI

/// Audit THEME 6: the split pane rendered the FULL markdown document
/// synchronously inside `body` on every keystroke (no cap). The render now
/// rides `SplitMarkdownRenderModel` — debounced, off-main, coalesced.
@MainActor
final class SplitMarkdownRenderModelTests: XCTestCase {

    // MARK: policy (pure)

    func test_firstRenderIsImmediate() {
        XCTAssertEqual(
            SplitMarkdownRenderModel.debounceMilliseconds(byteCount: 10, isFirstRender: true), 0,
            "opening the split must show content promptly")
        XCTAssertEqual(
            SplitMarkdownRenderModel.debounceMilliseconds(
                byteCount: 50_000_000, isFirstRender: true), 0,
            "even a huge file renders immediately on open — just off-main")
    }

    func test_smallFilesUseTheShortDebounce_largeWaitForATypingPause() {
        let small = SplitMarkdownRenderModel.debounceMilliseconds(
            byteCount: 100_000, isFirstRender: false)
        let large = SplitMarkdownRenderModel.debounceMilliseconds(
            byteCount: SplitMarkdownRenderModel.largeThresholdBytes + 1, isFirstRender: false)
        XCTAssertEqual(small, 150)
        XCTAssertEqual(large, 1_000)
        XCTAssertEqual(SplitMarkdownRenderModel.largeThresholdBytes, 1 * 1024 * 1024,
                       "the 1 MiB line is the owner's small/large threshold (2026-07-29)")
    }

    // MARK: behaviour

    func test_renderLands_andContainsTheDocument() async {
        let model = SplitMarkdownRenderModel()
        model.schedule(text: "# Title\n\nhello **world**\n", isMermaid: false, extraCSS: "")
        await waitUntil { model.html != nil }
        let html = model.html ?? ""
        XCTAssertTrue(html.contains("Title"), "the rendered page carries the content")
        XCTAssertTrue(html.contains("<strong>"), "markdown actually rendered, not echoed")
    }

    func test_mermaidTextIsFenced() async {
        let model = SplitMarkdownRenderModel()
        model.schedule(text: "graph TD; A-->B", isMermaid: true, extraCSS: "")
        await waitUntil { model.html != nil }
        XCTAssertTrue((model.html ?? "").contains("mdv-mermaid"),
                      "a .mmd file renders through the mermaid host element path")
    }

    /// A re-body with an UNCHANGED buffer must not re-render (the pane
    /// re-bodies for plenty of non-text reasons).
    func test_identicalTextIsANoOp() async {
        let model = SplitMarkdownRenderModel()
        model.schedule(text: "# One", isMermaid: false, extraCSS: "")
        await waitUntil { model.html != nil }
        let first = model.html
        model.schedule(text: "# One", isMermaid: false, extraCSS: "")
        // Nothing to await — the schedule must not have started a task that
        // replaces html. Give it a beat and confirm identity.
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(model.html == first, "unchanged text must not re-render")
    }

    /// Rapid keystrokes coalesce: only the LAST text lands.
    func test_burstCoalesces_lastTextWins() async {
        let model = SplitMarkdownRenderModel()
        model.schedule(text: "# seed", isMermaid: false, extraCSS: "")  // immediate first render
        await waitUntil { model.html != nil }
        for i in 0..<10 {
            model.schedule(text: "# draft \(i)", isMermaid: false, extraCSS: "")
        }
        model.schedule(text: "# FINAL", isMermaid: false, extraCSS: "")
        await waitUntil { model.html?.contains("FINAL") == true }
        XCTAssertFalse(model.html?.contains("draft 5") == true,
                       "intermediate keystrokes must be coalesced away")
    }

    /// The split black-text-in-dark-mode bug (owner 2026-08-08): the themed
    /// extra stylesheet (theme pageCSS/tokCSS) must land in the split page —
    /// the split preview used to render default black prose on the themed-dark
    /// pane background because only the mermaid shim was passed.
    func test_themedExtraCSSLandsInThePage() async {
        let model = SplitMarkdownRenderModel()
        let marker = "/* mdv-split-theme-marker */ body { color: #e6e6e6; }"
        model.schedule(text: "# Themed", isMermaid: false, extraCSS: marker)
        await waitUntil { model.html != nil }
        XCTAssertTrue((model.html ?? "").contains("mdv-split-theme-marker"),
                      "the caller's themed CSS must be embedded in the split page")
    }

    /// Theme switch while the split is open: SAME text + NEW css must
    /// re-render (the dedup key includes the stylesheet).
    func test_cssChangeWithSameTextReRenders() async {
        let model = SplitMarkdownRenderModel()
        model.schedule(text: "# Same", isMermaid: false, extraCSS: "/* light */")
        await waitUntil { model.html != nil }
        model.schedule(text: "# Same", isMermaid: false, extraCSS: "/* dark-marker */")
        await waitUntil { model.html?.contains("dark-marker") == true }
        XCTAssertTrue((model.html ?? "").contains("dark-marker"),
                      "a theme change must re-render the split preview")
    }

    /// The split pane must actually route through the model — an inline
    /// renderPage in body is the regression this exists to prevent.
    func test_splitPane_rendersThroughTheModel_notInline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/SplitPaneView.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("SplitMarkdownPane"),
                      "the markdown branch must use the debounced pane")
        XCTAssertFalse(src.contains("HTMLRenderer().renderPage"),
                       "no synchronous in-body markdown render in the split pane")
    }

    private func waitUntil(
        deadline: TimeInterval = 5, _ cond: @MainActor () -> Bool
    ) async {
        let until = Date().addingTimeInterval(deadline)
        while Date() < until {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
