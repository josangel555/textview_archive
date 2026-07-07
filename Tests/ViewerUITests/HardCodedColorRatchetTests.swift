import XCTest

/// TSK-1501 — dark-mode teeth: hard-coded color literals in chrome views are
/// the class behind "looks fine in light, unreadable in dark" bugs (semantic
/// colors — `Color.primary`, `NSColor.textColor`, theme tokens — adapt;
/// literals don't). This is a RATCHET: the per-file baseline below may only
/// SHRINK. A new literal (in a listed file or a fresh one) is RED; when you
/// remove one, LOWER the baseline in the same commit so the ratchet holds.
///
/// Deliberate literal uses (ANSI terminal palette, image-editor paint
/// swatches, file-type brand colors) live INSIDE the baseline — they are
/// carried, not endorsed; converting them to theme tokens shrinks it.
final class HardCodedColorRatchetTests: XCTestCase {

    /// Hard-coded-color patterns swept (chrome scope: Sources/ViewerUI).
    private static let pattern =
        #"Color\.white|Color\.black|NSColor\.white|NSColor\.black|"#
        + #"Color\(red:|NSColor\(red:|NSColor\(calibrated|NSColor\(srgbRed"#

    /// The 2026-07-07 baseline (28 literal matches, 11 files). SHRINK ONLY.
    private static let baseline: [String: Int] = [
        "Sources/ViewerUI/CommandPaletteView.swift": 3,
        "Sources/ViewerUI/ContentView.swift": 5,
        "Sources/ViewerUI/DiagnosticDump.swift": 1,
        "Sources/ViewerUI/FileIconView.swift": 5,
        "Sources/ViewerUI/FloatingTooltip.swift": 1,
        "Sources/ViewerUI/ImageEditorView.swift": 4,
        "Sources/ViewerUI/ImageElementPropertiesPanel.swift": 1,
        "Sources/ViewerUI/SpreadsheetView.swift": 1,
        "Sources/ViewerUI/Terminal/TerminalPalette.swift": 2,
        "Sources/ViewerUI/Terminal/TerminalView.swift": 1,
        "Sources/ViewerUI/TextDisplayView.swift": 4,
    ]

    func test_chromeColorLiterals_neverGrow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let chrome = root.appendingPathComponent("Sources/ViewerUI")
        let regex = try NSRegularExpression(pattern: Self.pattern)

        var counts: [String: Int] = [:]
        let e = try XCTUnwrap(FileManager.default.enumerator(
            at: chrome, includingPropertiesForKeys: nil))
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = regex.numberOfMatches(
                in: text, range: NSRange(text.startIndex..., in: text))
            if n > 0 {
                let rel = "Sources/ViewerUI" + url.path.replacingOccurrences(
                    of: chrome.path, with: "")
                counts[rel] = n
            }
        }

        for (file, n) in counts.sorted(by: { $0.key < $1.key }) {
            let allowed = Self.baseline[file] ?? 0
            XCTAssertLessThanOrEqual(n, allowed,
                "\(file) has \(n) hard-coded color literal(s), baseline \(allowed). "
                + "Use semantic/theme colors (they adapt to dark mode); if this is a "
                + "genuinely fixed color, raising the baseline is an owner call.")
        }
        // The shrink half of the ratchet: celebrate + lower.
        for (file, allowed) in Self.baseline {
            let n = counts[file] ?? 0
            XCTAssertGreaterThanOrEqual(allowed, n)
            if n < allowed {
                // Not a failure — a nudge visible in verbose runs.
                print("[ColorRatchet] \(file): \(n) < baseline \(allowed) — lower the baseline!")
            }
        }
    }
}
