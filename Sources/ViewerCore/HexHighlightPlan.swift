import Foundation

/// Pure planning logic for the HEX view's highlight painter (TSK-267).
///
/// `HexView`'s controller paints search/click highlights as per-byte
/// `.backgroundColor` attributes: a 2-char hex cell + a 1-char ASCII cell
/// per byte. Clearing used to be a `removeAttribute` over the ENTIRE
/// storage — an O(document) attribute walk on every search edit, the
/// dominant per-keystroke cost on a multi-MB dump. These functions
/// compute the exact character ranges a painted occurrence covers so
/// the controller can clear only what it painted.
///
/// Kept in `ViewerCore` (no AppKit) so the math is host-unit-testable;
/// the controller's painter and this planner share `HexLayout` for the
/// row/column → character-offset math, so they cannot drift.
public enum HexHighlightPlan {
    /// Character ranges (hex pair + ASCII glyph per byte) occupied by a
    /// pattern occurrence of `patternLength` bytes starting at byte
    /// `offset`. Clamped to `byteCount`; out-of-range or empty input
    /// yields `[]`. Mirrors the painter's loop exactly.
    public static func charRanges(offset: Int,
                                  patternLength: Int,
                                  width: Int,
                                  headerCharCount: Int,
                                  byteCount: Int) -> [NSRange] {
        guard patternLength > 0, byteCount > 0, offset >= 0 else { return [] }
        let last = min(offset + patternLength - 1, byteCount - 1)
        guard offset <= last else { return [] }
        let rowLength = HexLayout.renderedRowLength(width: width)
        var out: [NSRange] = []
        out.reserveCapacity((last - offset + 1) * 2)
        for b in offset...last {
            let row = HexLayout.row(forOffset: b, width: width)
            let col = HexLayout.column(forOffset: b, width: width)
            let rowStart = headerCharCount + row * rowLength
            out.append(NSRange(
                location: rowStart + HexLayout.hexCharOffset(inRowColumn: col),
                length: 2))
            out.append(NSRange(
                location: rowStart + HexLayout.asciiCharOffset(
                    inRowColumn: col, width: width),
                length: 1))
        }
        return out
    }

    /// Flattened clear-set for a whole painted offset list (search matches
    /// or click occurrences).
    public static func clearRanges(offsets: [Int],
                                   patternLength: Int,
                                   width: Int,
                                   headerCharCount: Int,
                                   byteCount: Int) -> [NSRange] {
        guard patternLength > 0 else { return [] }
        return offsets.flatMap {
            charRanges(offset: $0,
                       patternLength: patternLength,
                       width: width,
                       headerCharCount: headerCharCount,
                       byteCount: byteCount)
        }
    }
}

/// Build-strategy decision for the HEX dump (TSK-267 step 3).
///
/// The chunked background build exists for multi-MB dumps; for small
/// files its fixed overhead (placeholder flash, detached-task spawn,
/// per-chunk `main.sync` round-trips) IS the per-open latency the
/// owner feels (#218: 6 KB ≈ 1 s). Below the threshold the dump string
/// builds in single-digit milliseconds, so a one-shot synchronous build
/// on the main thread is strictly faster and skips the machinery.
public enum HexRenderPlan {
    /// Render synchronously at or below this many loaded bytes. 256 KiB
    /// renders in a few ms (1 MB builds well under 100 ms per the
    /// TSK-267 spike) — comfortably under a frame budget while covering
    /// virtually every "small file" open.
    public static let syncBuildByteLimit: Int = 256 * 1024

    public static func useSyncBuild(renderedByteCount: Int) -> Bool {
        renderedByteCount <= syncBuildByteLimit
    }
}
