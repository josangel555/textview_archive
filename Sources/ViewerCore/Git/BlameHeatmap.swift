import Foundation

/// Line-age heat colors for the blame gutter (TSK-360): map each line's commit
/// time onto a dark-blue → light-blue gradient so the OLDEST lines read dark and
/// the NEWEST read light. Normalized across the file's OWN [min,max] commit
/// timestamps (not wall-clock) so the gradient always spans the file's history,
/// regardless of how old the file is. Pure + host-testable; the gutter render
/// that applies the colors is the CM6 side.
public enum BlameHeatmap {

    /// Gradient endpoints (oldest → newest), as RGB 0–255.
    static let oldRGB = (r: 10,  g: 42,  b: 107)   // dark blue
    static let newRGB = (r: 188, g: 212, b: 240)   // light blue

    /// line(1-based) → recency in 0...1 (0 = oldest commit in the file, 1 =
    /// newest). All-equal (or single) timestamps collapse to 0.5 (a flat mid
    /// tone — no meaningful spread to show). Empty input → empty. Pure.
    public static func normalizedRecency(from blame: [GitClient.BlameLine]) -> [Int: Double] {
        let times = blame.map(\.timestamp)
        guard let lo = times.min(), let hi = times.max() else { return [:] }
        let span = hi - lo
        var out: [Int: Double] = [:]
        out.reserveCapacity(blame.count)
        for b in blame {
            out[b.line] = span == 0 ? 0.5 : Double(b.timestamp - lo) / Double(span)
        }
        return out
    }

    /// Hex color (`#rrggbb`) for a recency `t` (0 = oldest → dark blue, 1 =
    /// newest → light blue). `t` is clamped to 0...1. Pure.
    public static func hex(recency t: Double) -> String {
        let c = max(0.0, min(1.0, t))
        func lerp(_ a: Int, _ b: Int) -> Int { Int((Double(a) + Double(b - a) * c).rounded()) }
        return String(format: "#%02x%02x%02x",
                      lerp(oldRGB.r, newRGB.r),
                      lerp(oldRGB.g, newRGB.g),
                      lerp(oldRGB.b, newRGB.b))
    }

    /// line(1-based) → hex heat color. Combines `normalizedRecency` + `hex`.
    public static func colors(from blame: [GitClient.BlameLine]) -> [Int: String] {
        normalizedRecency(from: blame).mapValues { hex(recency: $0) }
    }
}
