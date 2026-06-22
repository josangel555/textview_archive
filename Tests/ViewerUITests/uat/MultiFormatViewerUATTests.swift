import XCTest
import Foundation

/// UAT — TSK-1036: routed multi-format documents open as their EXTRACTED text,
/// not raw container bytes. T4 live-app: spawns `dist/TextView.app`, opens an
/// `.rtf` fixture on launch, and asserts the live model's `loadedTextPrefix`
/// (TSK-1241) holds the extracted plaintext — NOT the raw `\rtf1` control words.
///
/// This is the on-screen confirmation the host `RtfViewerRoutingTests` can't
/// give: it proves the FULL live path — FileTypeDetector routing → the load
/// flow calling MultiFormatReader extraction → the source view receiving the
/// extracted text — fires in the real assembled app, not just the unit loader.
///
/// RTF is the discriminating fixture: routed → "Hello from RTF routing"; NOT
/// routed (opened as raw .plainText) → the literal `{\rtf1 ...}` control words.
///
/// TIER-JUSTIFY: T4 — observable is the assembled bundle's real open→route→
/// load→source-view path via `--script`, only present in a live process.
/// Self-skips off the VM GUI lane (`isAppBuilt` false on the headless gate).
@MainActor
final class MultiFormatViewerUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "MultiFormatViewerUAT" }

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }

    /// MFV-01 — open an `.rtf`; the loaded source text is the EXTRACTED
    /// plaintext, not the raw RTF control words (proves routing + extraction
    /// fire on the live app).
    func test_MFV_01_rtfOpensAsExtractedText() throws {
        let rtf = try harness.writeFile("note.rtf", "{\\rtf1\\ansi Hello from RTF routing.\\par}")
        let script = """
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "rtf-extracted-text",
                argFile: rtf,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "[mfv01] no dumps", file: file, line: line)
                    let rtfDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("note.rtf") }
                    XCTAssertFalse(rtfDumps.isEmpty,
                        "[mfv01] note.rtf never committed currentURL (open didn't land)", file: file, line: line)
                    guard let last = rtfDumps.last else { return }
                    let text = modelString(last, "loadedTextPrefix")
                    XCTAssertTrue(text.contains("Hello from RTF routing"),
                        "[mfv01] extracted RTF text not loaded; loadedTextPrefix=\(text.prefix(120))",
                        file: file, line: line)
                    XCTAssertFalse(text.contains("\\rtf1"),
                        "[mfv01] raw RTF control words leaked into the view — routing/extraction did NOT fire",
                        file: file, line: line)
                })
        ])
    }
}
