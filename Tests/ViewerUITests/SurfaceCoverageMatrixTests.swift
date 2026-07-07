import XCTest
import ViewerKit

/// TSK-1539 — MANDATE 1 (docs/TEST_PYRAMID.md §MANDATES): every content
/// surface gets ≥1 REAL-RENDER guard (WV / T4 / T5), and an unmapped surface
/// is a RED gate. Two source-of-truth sets are matrixed:
///
/// 1. `ViewMode.allCases` — the lens enum. Adding a case without adding a
///    matrix row fails here (the compiler can't force a dictionary entry,
///    so this test does).
/// 2. The aux surfaces that live OUTSIDE ViewMode (canvas, terminal, …).
///
/// Every row is either `.suite("<real-render suite file>")` — verified to
/// exist on disk so evidence can't rot — or `.exempt(ticket:)` with a LIVE
/// gap ticket. Closing the ticket = replacing the exemption with a suite.
final class SurfaceCoverageMatrixTests: XCTestCase {

    private enum Evidence {
        /// A heavy-tier suite FILE in Tests/ViewerUITests (WV/T4/T5 class).
        case suite(String)
        /// No real-render guard yet — carried openly against a gap ticket.
        case exempt(ticket: String)
    }

    /// ViewMode lens → real-render evidence (2026-07-07).
    private static let lensMatrix: [ViewMode: Evidence] = [
        .rendered:  .suite("RenderedFindBarTests.swift"),
        .source:    .suite("SourceViewVisualRegressionTests.swift"),
        .editor:    .suite("EditorScrollRestoreWebViewTests.swift"),
        .formatted: .exempt(ticket: "TSK-1551"),
        .table:     .exempt(ticket: "TSK-1551"),   // CSV lens; xlsx has SpreadsheetViewHostingTests
        .diff:      .exempt(ticket: "TSK-1551"),   // DiffViewSelectionRenderTests is ImageRenderer (not real-render)
        .preview:   .suite("PreviewTabVisualRegressionTests.swift"),
        .hex:       .exempt(ticket: "TSK-1551"),
    ]

    /// Content surfaces outside the ViewMode enum.
    private static let auxMatrix: [String: Evidence] = [
        "canvas":        .suite("CanvasTabMountWebViewTests.swift"),
        "terminal":      .suite("TerminalTabStripVisualRegressionTests.swift"),
        "walkthrough":   .suite("WalkthroughMermaidRenderWebViewTests.swift"),
        "claudeMonitor": .suite("ClaudeMonitorVisualRegressionTests.swift"),
        "imageEditor":   .suite("ImageEditorVisualRegressionTests.swift"),
        "audioEditor":   .suite("AudioEditorVisualRegressionTests.swift"),
        "spreadsheet":   .suite("SpreadsheetViewHostingTests.swift"),
        "fileTabStrip":  .suite("FileTabStripVisualRegressionTests.swift"),
    ]

    private var suitesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    func test_everyViewModeLens_hasAMatrixRow() {
        for mode in ViewMode.allCases {
            XCTAssertNotNil(Self.lensMatrix[mode],
                "ViewMode.\(mode.rawValue) has NO surface-coverage row. MANDATE 1: "
                + "a new content lens ships with ≥1 real-render guard (or an "
                + "explicit exempt(ticket:) while the suite is built).")
        }
    }

    func test_everyEvidenceSuite_existsOnDisk_andEveryExemptionHasALiveTicketId() throws {
        let all: [(String, Evidence)] =
            Self.lensMatrix.map { ("ViewMode.\($0.key.rawValue)", $0.value) }
            + Self.auxMatrix.map { ($0.key, $0.value) }
        for (surface, evidence) in all {
            switch evidence {
            case .suite(let file):
                let path = suitesDir.appendingPathComponent(file).path
                XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                    "\(surface): evidence suite \(file) is GONE (renamed/deleted?) — "
                    + "the matrix must track the real file or the guard rots.")
            case .exempt(let ticket):
                XCTAssertTrue(ticket.range(of: #"^TSK-\d+$"#, options: .regularExpression) != nil,
                    "\(surface): exemption must reference a board ticket, got '\(ticket)'")
            }
        }
        // The gap set may only SHRINK: 4 exemptions as of 2026-07-07.
        let exemptCount = all.filter {
            if case .exempt = $0.1 { return true }; return false
        }.count
        XCTAssertLessThanOrEqual(exemptCount, 4,
            "surface-coverage exemptions GREW — new surfaces need real-render "
            + "suites, not new exemption rows (TSK-1551 tracks the original four).")
    }
}
