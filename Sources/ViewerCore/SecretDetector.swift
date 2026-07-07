import Foundation

/// TSK-1496 — credential recognition (wishlist P7), the DETECTOR core.
///
/// Pure, line-incremental scanning: high-precision literal patterns for
/// well-known credential shapes plus one entropy-guarded generic rule for
/// `password|secret|token|api_key = <literal>` assignments. The view layer
/// consumes findings as warn-badges / mask decorations (render slice);
/// nothing here modifies file content, ever.
///
/// ## What this does NOT protect (the false-confidence wall)
/// - It cannot prove the ABSENCE of secrets: novel token formats, split
///   strings, encrypted blobs and encodings pass undetected. A clean scan
///   is "nothing recognized", never "nothing sensitive".
/// - It does not stop exfiltration (copy, screen, plugins) — it is a
///   VIEWING aid against accidental exposure, not a DLP boundary.
/// - Values matched stay in memory as part of the document; masking is a
///   pixel treatment, not secure handling of the bytes.
public enum SecretDetector {

    public enum Kind: String, CaseIterable, Sendable {
        case awsAccessKeyID = "AWS access key ID"
        case privateKeyPEM = "private key (PEM)"
        case githubToken = "GitHub token"
        case slackToken = "Slack token"
        case gcpAPIKey = "Google API key"
        case jwt = "JSON Web Token"
        case genericAssignment = "credential assignment"
    }

    public struct Finding: Equatable, Sendable {
        /// 1-based line number in the scanned text.
        public let line: Int
        public let kind: Kind
        /// A short REDACTED preview (never the full value): first 4 chars + …
        public let preview: String
    }

    /// Defaults key for the view-layer treatment (render slice reads it):
    /// unset/0 = warn badge only (default), 1 = mask with reveal-on-click,
    /// 2 = off.
    public static let treatmentDefaultsKey = "mdv.secretTreatment"

    /// Findings cap — a leaked .env with hundreds of entries doesn't need
    /// hundreds of badges to make the point.
    public static let maxFindings = 200

    // High-precision literal shapes. NSRegularExpression is fine here: the
    // patterns are anchored/narrow and the scan is per-line incremental.
    private static let literalRules: [(Kind, NSRegularExpression)] = {
        func rx(_ p: String) -> NSRegularExpression {
            // Patterns are static; a failure is a programmer error caught
            // by the corpus tests on first run.
            try! NSRegularExpression(pattern: p)
        }
        return [
            (.awsAccessKeyID, rx(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#)),
            (.privateKeyPEM, rx(#"-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY( BLOCK)?-----"#)),
            (.githubToken, rx(#"\bgh[poushr]_[A-Za-z0-9]{36,}\b"#)),
            (.slackToken, rx(#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#)),
            (.gcpAPIKey, rx(#"\bAIza[0-9A-Za-z_\-]{35}\b"#)),
            (.jwt, rx(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#)),
        ]
    }()

    /// A key ENDING in `password/secret/token/api_key/...` (so
    /// `SECRET_TOKEN=` matches — `\b` can't cross the underscore — while
    /// `tokenizer =` does not), then `=`/`:`, then a quoted or bare
    /// literal including common password symbols. The VALUE must then
    /// pass the entropy guard.
    private static let assignmentRule = try! NSRegularExpression(
        pattern: #"(?i)(password|passwd|secret|token|api[_-]?key|credentials?)\s*[:=]\s*["']?([A-Za-z0-9+/_\-.=!@#$%^&*?~]{12,})["']?"#)

    /// Scan one line. `lineNumber` is 1-based.
    public static func scan(line: String, lineNumber: Int) -> [Finding] {
        var out: [Finding] = []
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        for (kind, rule) in literalRules {
            for m in rule.matches(in: line, range: full) {
                out.append(Finding(
                    line: lineNumber, kind: kind,
                    preview: preview(ns.substring(with: m.range))))
            }
        }
        for m in assignmentRule.matches(in: line, range: full) where m.numberOfRanges > 2 {
            let value = ns.substring(with: m.range(at: 2))
            if isLikelySecretValue(value) {
                out.append(Finding(
                    line: lineNumber, kind: .genericAssignment,
                    preview: preview(value)))
            }
        }
        return out
    }

    /// Line-incremental whole-text scan, capped at `maxFindings`.
    public static func scan(text: String, maxFindings cap: Int = maxFindings) -> [Finding] {
        var out: [Finding] = []
        var n = 1
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(contentsOf: scan(line: String(line), lineNumber: n))
            if out.count >= cap { return Array(out.prefix(cap)) }
            n += 1
        }
        return out
    }

    // MARK: - The entropy guard (false-positive control)

    /// A generic assignment value counts only when it LOOKS like key
    /// material: length ≥ 12 (regex), mixed character classes, Shannon
    /// entropy ≥ 3.0 bits/char — and NOT a digest-shaped pure-hex string
    /// (git SHAs / sha256 sums are the classic false positive; a hex
    /// secret of exactly digest length is rare enough to trade away, and
    /// the miss is documented above).
    static func isLikelySecretValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        // Dictionary-word / placeholder shapes.
        if ["changeme", "placeholder", "example", "password", "yourpassword",
            "xxxxxxxxxxxx", "................"].contains(lower) { return false }
        let hexChars = Set("0123456789abcdef")
        if lower.allSatisfy({ hexChars.contains($0) }),
           [32, 40, 64, 128].contains(lower.count) {
            return false   // MD5/SHA-1/SHA-256/SHA-512 digest shapes
        }
        // Mixed classes: at least two of lower/upper/digit/symbol.
        var classes = 0
        if value.contains(where: { $0.isLowercase }) { classes += 1 }
        if value.contains(where: { $0.isUppercase }) { classes += 1 }
        if value.contains(where: { $0.isNumber }) { classes += 1 }
        if value.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        guard classes >= 2 else { return false }
        return shannonEntropy(value) >= 3.0
    }

    /// Bits per character.
    static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }

    /// Redacted preview: enough to recognize WHICH credential, never the
    /// credential itself.
    private static func preview(_ value: String) -> String {
        String(value.prefix(4)) + "…"
    }
}
