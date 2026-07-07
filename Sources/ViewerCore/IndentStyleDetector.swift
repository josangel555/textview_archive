import Foundation

/// TSK-1480 — detect the DOMINANT leading-indent style of a text so the
/// converters/menus/footer can show what the file currently IS before a
/// user converts it blind. Pure, host-testable; a cheap leading-whitespace
/// scan (first N lines).
public enum IndentStyleDetector {

    public enum Style: Equatable, Sendable {
        case tabs
        case spaces(width: Int)
        /// No indented lines seen (empty / all flush-left).
        case none

        /// Footer-facing label: "Tabs" / "Spaces:4" / "—".
        public var label: String {
            switch self {
            case .tabs: return "Tabs"
            case .spaces(let w): return "Spaces:\(w)"
            case .none: return "—"
            }
        }
    }

    /// The dominant style over the first `sampleLines` indented lines.
    /// Tabs vs spaces = whichever indents more lines (ties → tabs, the
    /// unambiguous case). The space WIDTH is the most common positive
    /// leading-space count's GCD-ish pick: we take the minimum indent step
    /// observed (2/4/8 dominate real files), falling back to the modal
    /// count.
    public static func detect(in text: String, sampleLines: Int = 400) -> Style {
        var tabLines = 0
        var spaceCounts: [Int] = []
        var seen = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if seen >= sampleLines { break }
            guard let first = line.unicodeScalars.first else { continue }
            if first == "\t" {
                tabLines += 1
                seen += 1
            } else if first == " " {
                var n = 0
                for u in line.unicodeScalars {
                    if u == " " { n += 1 } else { break }
                }
                // Ignore a lone trailing-space or a 1-space continuation
                // (common in prose / aligned comments) — indent steps are ≥2.
                if n >= 2 { spaceCounts.append(n); seen += 1 }
            }
        }
        if tabLines == 0 && spaceCounts.isEmpty { return .none }
        if tabLines >= spaceCounts.count { return .tabs }
        return .spaces(width: inferWidth(spaceCounts))
    }

    /// Infer the indent step from observed leading-space counts: the
    /// SMALLEST indent is the step (a first-level indent = one step; deeper
    /// lines are multiples). Robust across 2/4/8 without a fragile
    /// divisibility vote.
    static func inferWidth(_ counts: [Int]) -> Int {
        counts.min() ?? 4
    }
}
