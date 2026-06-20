import Foundation

/// Content gate for Local History capture (TSK-1103, owner policy).
///
/// Local History must be **text-only** and must **never persist secrets**. The
/// repo has no general-purpose secret scanner — the only existing redaction is
/// the Rust `transcript::redact` (Claude-transcript-key specific) and the
/// UI-only `DiagnosticDump.redactContent`, neither reusable here — so this is a
/// small, conservative, dependency-free classifier:
///
///   - `isProbablyBinary`  — reject NUL bytes / a high control-char ratio.
///   - `looksLikeSecret`   — reject content whose lines match a conservative
///                            set of credential patterns.
///
/// Conservative on purpose: a false *positive* costs one missed history entry
/// (recoverable on the next clean save); a false *negative* persists a
/// credential to disk forever. We err toward NOT capturing.
public enum HistoryContentFilter {

    /// True if `content` is best treated as non-text (so we don't snapshot it).
    /// Heuristics, in order:
    ///   - any NUL byte ⇒ binary (the classic text/binary discriminator), or
    ///   - >10% of the first 8 KiB are control chars other than tab/newline/CR.
    /// Operates on a bounded prefix so a huge file is cheap to classify.
    public static func isProbablyBinary(_ content: String) -> Bool {
        let bytes = content.utf8
        if bytes.count == 0 { return false }
        var inspected = 0
        var control = 0
        for b in bytes {
            if b == 0 { return true }                 // NUL ⇒ binary
            // Control chars except \t (9), \n (10), \r (13).
            if b < 0x20, b != 9, b != 10, b != 13 { control += 1 }
            inspected += 1
            if inspected >= 8 * 1024 { break }        // bounded sample
        }
        return Double(control) / Double(inspected) > 0.10
    }

    /// True if `content` appears to carry a secret/credential we must not
    /// persist. Conservative pattern set (documented per case below). Scans
    /// line-by-line over a bounded prefix.
    public static func looksLikeSecret(_ content: String) -> Bool {
        // Bound the scan: a credential, if present, is overwhelmingly near the
        // top (config headers, .env, key files) — and we cap work on huge input.
        let scanLimit = 256 * 1024
        let head = content.utf8.count > scanLimit
            ? String(decoding: Array(content.utf8.prefix(scanLimit)), as: UTF8.self)
            : content

        for rawLine in head.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if lineLooksLikeSecret(line) { return true }
        }
        return false
    }

    // MARK: - Per-line classifier

    static func lineLooksLikeSecret(_ line: String) -> Bool {
        // 1) PEM private-key / OpenSSH header — the single most damaging leak.
        if line.contains("PRIVATE KEY-----") || line.contains("BEGIN OPENSSH PRIVATE KEY") {
            return true
        }

        // 2) Vendor token shapes with a recognisable prefix + entropy length.
        //    These are intentionally narrow (a fixed prefix) so prose can't
        //    trip them. Lengths are the documented minimums for each vendor.
        for token in vendorTokenPrefixes {
            if let r = line.range(of: token.prefix) {
                let tail = line[r.upperBound...]
                let run = tail.prefix(while: { isTokenChar($0) })
                if run.count >= token.minTailLen { return true }
            }
        }

        // 3) AWS access key id: literal "AKIA"/"ASIA" + 16 base32 chars.
        if let r = line.range(of: "AKIA") ?? line.range(of: "ASIA") {
            let tail = line[r.upperBound...].prefix(while: { $0.isUppercase || $0.isNumber })
            if tail.count >= 16 { return true }
        }

        // 4) .env / config-style assignment of a sensitive-named key to a
        //    non-trivial value: `SECRET=...`, `api_key: "..."`, `PASSWORD = ...`.
        //    Requires (a) a sensitive key NAME and (b) a value that has the
        //    length/shape of a real secret (≥12 chars, not an obvious
        //    placeholder), so `# set your password here` or `password:` (empty)
        //    don't trip it.
        if assignmentLooksSecret(line) { return true }

        return false
    }

    /// Vendor token prefixes: (literal prefix, minimum following token length).
    private static let vendorTokenPrefixes: [(prefix: String, minTailLen: Int)] = [
        ("ghp_", 20),     // GitHub personal access token
        ("gho_", 20),     // GitHub OAuth token
        ("ghs_", 20),     // GitHub server-to-server
        ("github_pat_", 20),
        ("xoxb-", 10),    // Slack bot token
        ("xoxp-", 10),    // Slack user token
        ("sk-", 20),      // OpenAI / Anthropic-style secret key
        ("sk-ant-", 20),  // Anthropic
        ("AIza", 30),     // Google API key
        ("glpat-", 16),   // GitLab personal access token
    ]

    private static func isTokenChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    /// `KEY = value` style assignment where KEY is sensitively named and value
    /// is a non-placeholder secret-shaped string.
    private static func assignmentLooksSecret(_ line: String) -> Bool {
        // Find the first `=` or `:` separator.
        guard let sepIdx = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return false }
        let keyPart = line[..<sepIdx]
            .trimmingCharacters(in: .whitespaces)
            // strip common quoting / export keywords
            .replacingOccurrences(of: "export ", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        guard !keyPart.isEmpty, keyPart.count <= 64 else { return false }

        let keyIsSensitive = sensitiveKeyTokens.contains { keyPart.contains($0) }
        guard keyIsSensitive else { return false }

        var value = line[line.index(after: sepIdx)...]
            .trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"',;"))
        guard value.count >= 12 else { return false }            // too short to be a real secret
        if isObviousPlaceholder(value) { return false }
        // A real secret value is mostly token chars (no spaces / sentences).
        let nonTokenCount = value.filter { !isTokenChar($0) && $0 != "." && $0 != "/" && $0 != "+" }.count
        return nonTokenCount <= 1
    }

    /// Substrings that, when present in a config KEY name, mark it sensitive.
    private static let sensitiveKeyTokens: [String] = [
        "secret", "password", "passwd", "token", "api_key", "apikey",
        "access_key", "accesskey", "private_key", "privatekey",
        "client_secret", "auth", "credential", "passphrase",
    ]

    /// Common placeholder values we should NOT treat as a real secret (so a
    /// `.env.example` or doc snippet isn't suppressed unnecessarily).
    private static func isObviousPlaceholder(_ value: String) -> Bool {
        let v = value.lowercased()
        if v.contains("xxxx") || v.contains("****") || v.contains("....") { return true }
        let placeholders: Set<String> = [
            "changeme", "your_token_here", "your-token-here", "placeholder",
            "todo", "example", "yourtokenhere", "your_api_key", "yourapikey",
            "your_secret", "<token>", "<secret>", "redacted",
        ]
        if placeholders.contains(v) { return true }
        // angle-bracket templated value like `<your-key>`
        if v.hasPrefix("<") && v.hasSuffix(">") { return true }
        if v.hasPrefix("${") || v.hasPrefix("$(") { return true }   // shell var ref, not a literal secret
        return false
    }
}
