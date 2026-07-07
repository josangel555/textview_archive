import Foundation

/// TSK-1487 — per-line modification-age coloring for the source view: a
/// DarkBlue→LightBlue gradient by how recently each line changed (recent =
/// light, old = dark), and a green stripe for untracked/new files. Pure:
/// the `git blame --line-porcelain` PARSE and the age→bucket→color RAMP are
/// host-tested here; the async blame spawn (cached per file version) + the
/// gutter-stripe render are the tails.
public enum LineAgeColoring {

    /// A gutter stripe color as 0–1 RGB, theme-agnostic (the view applies
    /// theme-appropriate opacity). `nil` = no stripe (non-git / no blame).
    public struct Stripe: Equatable, Sendable {
        public let r, g, b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }

    /// Age buckets, newest→oldest. The ramp interpolates DarkBlue (old) →
    /// LightBlue (recent). A separate GREEN is used for untracked lines.
    public static let bucketThresholds: [TimeInterval] = [
        60 * 60,            // < 1 hour
        60 * 60 * 24,       // < 1 day
        60 * 60 * 24 * 7,   // < 1 week
        60 * 60 * 24 * 30,  // < 1 month
        60 * 60 * 24 * 365, // < 1 year
    ]

    /// The bucket index (0 = newest … thresholds.count = older-than-oldest)
    /// for a line last modified `ageSeconds` ago.
    public static func bucket(ageSeconds: TimeInterval) -> Int {
        for (i, t) in bucketThresholds.enumerated() where ageSeconds < t {
            return i
        }
        return bucketThresholds.count
    }

    /// The stripe for a line last committed at `commitTime`, relative to
    /// `now`. Recent → LightBlue (0.4,0.7,1.0); old → DarkBlue (0.1,0.15,0.4).
    public static func stripe(commitTime: TimeInterval, now: TimeInterval) -> Stripe {
        let age = max(0, now - commitTime)
        let b = bucket(ageSeconds: age)
        // 0 (newest) → t=1 light; last bucket → t=0 dark.
        let steps = Double(bucketThresholds.count)
        let t = steps == 0 ? 1 : (1 - Double(b) / steps)
        return lerp(dark: Stripe(r: 0.10, g: 0.15, b: 0.40),
                    light: Stripe(r: 0.40, g: 0.70, b: 1.00), t: t)
    }

    /// The untracked/new-file stripe (green).
    public static let untrackedStripe = Stripe(r: 0.30, g: 0.80, b: 0.40)

    static func lerp(dark: Stripe, light: Stripe, t: Double) -> Stripe {
        let c = min(1, max(0, t))
        return Stripe(
            r: dark.r + (light.r - dark.r) * c,
            g: dark.g + (light.g - dark.g) * c,
            b: dark.b + (light.b - dark.b) * c)
    }

    /// Parse the `author-time <epoch>` lines from `git blame --line-porcelain`
    /// output into a per-line commit-time array (index 0 = file line 1).
    /// Porcelain emits a header block per line; the block's first line is
    /// `<sha> <origLine> <finalLine> [<count>]`, and `author-time <epoch>`
    /// appears within it. A line with no author-time (uncommitted / malformed)
    /// gets `nil`. Robust to the abbreviated blocks git emits for repeated
    /// commits (only the sha line + a `previous`/tab-content line).
    public static func parseBlameTimes(_ porcelain: String) -> [TimeInterval?] {
        var times: [TimeInterval?] = []
        var pendingTime: TimeInterval?
        var sawContent = false
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") {
                // The actual source line — flush one entry.
                times.append(pendingTime)
                pendingTime = nil
                sawContent = true
                continue
            }
            if let rest = line.dropFirstIfPrefix("author-time ") {
                pendingTime = TimeInterval(rest.trimmingCharacters(in: .whitespaces))
            }
            _ = sawContent
        }
        return times
    }
}

private extension String {
    /// The remainder after `prefix`, or nil if not prefixed.
    func dropFirstIfPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
