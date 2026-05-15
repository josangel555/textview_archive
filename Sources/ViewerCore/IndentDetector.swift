import Foundation

/// Detects whether a source file uses tabs or spaces for indentation,
/// and the typical indent width. Samples the first N non-blank lines
/// so it's O(window) regardless of file size.
///
/// Output examples:
///   - "Tabs" — tab-indented
///   - "Spaces (2)" — 2-space indent
///   - "Spaces (4)" — 4-space indent
///   - "Mixed" — both used in the sample
///   - "—" — no indented lines in the sample
public enum IndentDetector {
    public static func detect(in text: String, sampleLines: Int = 50) -> String {
        var seenTabs = 0
        var spaceWidths: [Int: Int] = [:]   // width → count
        var checked = 0
        var pos = text.startIndex
        while pos < text.endIndex, checked < sampleLines {
            let lineEnd = text[pos...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[pos..<lineEnd]
            if !line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                // First-char test only — indent is a prefix.
                if line.first == "\t" {
                    seenTabs += 1
                    checked += 1
                } else if line.first == " " {
                    var n = 0
                    for ch in line {
                        if ch == " " { n += 1 } else { break }
                    }
                    spaceWidths[n, default: 0] += 1
                    checked += 1
                }
            }
            if lineEnd == text.endIndex { break }
            pos = text.index(after: lineEnd)
        }

        let totalSpaceLines = spaceWidths.values.reduce(0, +)
        if seenTabs == 0, totalSpaceLines == 0 { return "—" }
        if seenTabs > 0, totalSpaceLines > 0 { return "Mixed" }
        if seenTabs > 0 { return "Tabs" }
        // Find the natural indent unit. For each common width
        // candidate, count how many sample lines are divisible by it;
        // pick the largest candidate that explains the most.
        // Largest-wins on tie because we prefer "4" over "2" when
        // both fit equally — the file likely uses 4-space, with the
        // 2-divisibility being incidental.
        let candidates = [8, 4, 3, 2]   // largest first
        var best = (width: 0, score: 0)
        for c in candidates {
            let score = spaceWidths
                .filter { $0.key > 0 && $0.key % c == 0 }
                .values.reduce(0, +)
            if score > best.score { best = (c, score) }
        }
        return best.width == 0 ? "Spaces" : "Spaces (\(best.width))"
    }
}
