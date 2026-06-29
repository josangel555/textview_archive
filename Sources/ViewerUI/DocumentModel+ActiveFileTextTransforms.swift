import Foundation
import ViewerCore

// Active-file text transforms (TSK-1110 SRP slice; TSK-675/351/1113) — the Edit ▸
// Lines / Transformations commands that rewrite the whole active text file in
// place (encoding + trailing-newline preserved): sort/reverse/dedupe/remove-empty/
// collapse-blank lines, upper/lower/capitalize case, trim-trailing-whitespace,
// ensure-final-newline. All route through the internal `applyTextTransformToActiveFile`
// write-through seam (stays on DocumentModel). Behavior-preserving move.
extension DocumentModel {

    /// True when the whitespace-cleanup / line-op commands can act — active text file.
    public var canCleanUpActiveFile: Bool { activeTextWithEncoding != nil }

    /// Edit ▸ Lines: sort / reverse / dedupe the whole active file in place
    /// (terminator + trailing-newline preserved). Encoding preserved.
    @discardableResult
    public func sortActiveFileLines(ascending: Bool) -> Bool {
        applyTextTransformToActiveFile { LineOps.sort($0, ascending: ascending) }
    }
    @discardableResult
    public func reverseActiveFileLines() -> Bool {
        applyTextTransformToActiveFile(LineOps.reverse)
    }
    @discardableResult
    public func removeDuplicateActiveFileLines() -> Bool {
        applyTextTransformToActiveFile(LineOps.removeDuplicates)
    }
    @discardableResult
    public func removeEmptyActiveFileLines() -> Bool {
        applyTextTransformToActiveFile(LineOps.removeEmptyLines)
    }
    @discardableResult
    public func collapseBlankActiveFileLines() -> Bool {
        applyTextTransformToActiveFile(LineOps.collapseBlankLines)
    }

    /// Edit ▸ Transformations (TSK-1113, surfacing the TSK-351 TextTransform
    /// engine) — TextEdit-parity case transforms over the whole active text
    /// file (encoding preserved). No-op (false) when there's no active text
    /// file or the text is already in the target form.
    @discardableResult
    public func makeActiveFileUpperCase() -> Bool {
        applyTextTransformToActiveFile { TextTransform.apply(.uppercase, to: $0) }
    }
    @discardableResult
    public func makeActiveFileLowerCase() -> Bool {
        applyTextTransformToActiveFile { TextTransform.apply(.lowercase, to: $0) }
    }
    @discardableResult
    public func capitalizeActiveFile() -> Bool {
        applyTextTransformToActiveFile { TextTransform.apply(.capitalize, to: $0) }
    }

    /// TSK-675 — strip trailing spaces/tabs from every line (line endings + all
    /// other content preserved).
    @discardableResult
    public func trimTrailingWhitespaceInActiveFile() -> Bool {
        applyTextTransformToActiveFile(TextCleanup.trimTrailingWhitespace)
    }

    /// TSK-675 — ensure the file ends with exactly one newline, matching its own
    /// dominant line-ending convention (LF for mixed/none).
    @discardableResult
    public func ensureFinalNewlineInActiveFile() -> Bool {
        applyTextTransformToActiveFile { text in
            let detected = LineEndingDetector.detect(in: text)
            let ending: LineEnding = (detected == .crlf || detected == .cr) ? detected : .lf
            return TextCleanup.ensureFinalNewline(text, using: ending)
        }
    }
}
