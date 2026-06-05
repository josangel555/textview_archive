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

        // Iterate the unicode-scalar view and split on the LF scalar
        // rather than the grapheme view: in Swift `"\r\n"` is a SINGLE
        // grapheme cluster, so a `Character`-view `firstIndex(of: "\n")`
        // never matches the LF inside a CRLF pair and collapses the
        // whole CRLF-authored file into one line. Per line we strip a
        // trailing CR before the first-char / whitespace tests so the
        // result matches the Rust port on Windows line endings.
        let lf: Unicode.Scalar = "\n"
        let cr: Unicode.Scalar = "\r"
        let space: Unicode.Scalar = " "
        let tab: Unicode.Scalar = "\t"

        // Per-line accumulators, reset at each LF boundary.
        var leadingSpaces = 0       // count of leading ' ' scalars
        var firstScalar: Unicode.Scalar? = nil
        var sawNonIndentContent = false   // a non-(space/tab/CR) scalar this line

        func finishLine() {
            // `sawNonIndentContent` already excludes lines that are blank or
            // pure whitespace once a trailing CR is treated as terminator
            // noise (see below) — so an all-whitespace CRLF line is correctly
            // skipped rather than miscounted as indented.
            guard sawNonIndentContent else { return }
            if firstScalar == tab {
                seenTabs += 1
                checked += 1
            } else if firstScalar == space {
                spaceWidths[leadingSpaces, default: 0] += 1
                checked += 1
            }
        }

        var iter = text.unicodeScalars.makeIterator()
        var inLeadingRun = true   // still consuming the leading-space prefix
        while checked < sampleLines, let scalar = iter.next() {
            if scalar == lf {
                finishLine()
                // Reset per-line state.
                leadingSpaces = 0
                firstScalar = nil
                sawNonIndentContent = false
                inLeadingRun = true
                continue
            }
            if firstScalar == nil { firstScalar = scalar }
            if inLeadingRun, scalar == space {
                leadingSpaces += 1
            } else {
                inLeadingRun = false
            }
            // A trailing CR is line-terminator noise, not content: only a
            // non-(space/tab/CR) scalar makes the line "have content".
            if scalar != space, scalar != tab, scalar != cr {
                sawNonIndentContent = true
            }
        }
        // Final line without a trailing LF.
        if checked < sampleLines, firstScalar != nil {
            finishLine()
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
