import Foundation

/// TSK-1505 — the PURE core behind the spelling verbs (next/prev/fix). Given a
/// tab's misspelling ranges (document order) and a nav cursor, compute the next
/// stop and the corrected text for a fix. No AppKit, no editor state → fully
/// host-testable; the EditorCoordinator seam applies the results (select the
/// range / replace the text) via the CM6 bridge (the render tail).
public enum SpellNavigation {

    /// Advance a wrapping nav cursor over `count` issues by `direction`
    /// (+1 = next, −1 = prev), starting from `from` (nil ⇒ "before the first",
    /// so the first `next` lands on 0 and the first `prev` on the last).
    /// `count == 0` ⇒ nil (nothing to land on). Any non-zero direction is
    /// treated by its sign, so callers can't step by more than one.
    public static func step(from: Int?, count: Int, by direction: Int) -> Int? {
        guard count > 0 else { return nil }
        let dir = direction >= 0 ? 1 : -1
        guard let cur = from else { return dir > 0 ? 0 : count - 1 }
        // Modulo that stays non-negative for the −1 wrap.
        return ((cur + dir) % count + count) % count
    }

    /// Replace the UTF-16 range `[from, to)` of `text` with `replacement`,
    /// returning the corrected string. Out-of-range / inverted spans return the
    /// text unchanged (a defensive no-op — a stale issue offset must never crash
    /// or corrupt). Uses UTF-16 offsets to match CM6 / `CMDiagnostic.from|to`.
    public static func correctedText(
        replacingUTF16 from: Int, _ to: Int, with replacement: String, in text: String
    ) -> String {
        let units = Array(text.utf16)
        guard from >= 0, to <= units.count, from <= to else { return text }
        let prefix = String(utf16CodeUnits: Array(units[0..<from]), count: from)
        let suffix = String(
            utf16CodeUnits: Array(units[to..<units.count]), count: units.count - to)
        return prefix + replacement + suffix
    }

    /// The substring at UTF-16 range `[from, to)` — the misspelled word an
    /// issue points at (for learn/ignore). Empty on an out-of-range/inverted span.
    public static func word(atUTF16 from: Int, _ to: Int, in text: String) -> String {
        let units = Array(text.utf16)
        guard from >= 0, to <= units.count, from < to else { return "" }
        return String(utf16CodeUnits: Array(units[from..<to]), count: to - from)
    }
}
