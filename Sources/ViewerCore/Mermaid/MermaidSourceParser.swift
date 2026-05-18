import Foundation
import CryptoKit

/// Pure parsing of mermaid-source directive comments. Lives in ViewerCore
/// (no SwiftUI / AppKit imports) so HTMLRenderer can call it during the
/// fenced-code intercept (`HTMLRenderer.visitCodeBlock` → mermaid path).
///
/// Recognized directives (mermaid comments, syntactically transparent to
/// the mermaid runtime which strips lines starting with `%%`):
///
///   %% @id <slug>     — diagram identifier; surfaces as `data-mdv-id`.
///                       Stable across re-renders so walkthrough drivers
///                       can target a specific diagram.
///   %% @step N        — step annotation; the JS shim associates this
///                       directive with the *next non-comment, non-blank*
///                       line, making that line (and its successors until
///                       the next `@step` directive) step `N`.
///
/// All of this could be pushed JS-side, but parsing here keeps the JS
/// shim from re-walking the source string and produces a deterministic
/// JSON manifest the shim consumes verbatim.
public enum MermaidSourceParser {

    public struct StepAnnotation: Equatable, Sendable, Codable {
        public let step: Int
        /// 0-based line index of the `%% @step N` directive itself.
        /// The JS shim uses this to find the next visible statement.
        public let line: Int

        public init(step: Int, line: Int) {
            self.step = step
            self.line = line
        }
    }

    public struct Parsed: Equatable, Sendable {
        /// Explicit `%% @id <slug>` value if present.
        public var id: String?
        /// Step annotations in document order.
        public var steps: [StepAnnotation]

        public init(id: String? = nil, steps: [StepAnnotation] = []) {
            self.id = id
            self.steps = steps
        }
    }

    public static func parse(_ source: String) -> Parsed {
        var id: String? = nil
        var steps: [StepAnnotation] = []
        // Preserve empty trailing lines so the line index stays in sync
        // with how the JS shim splits the same string.
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("%%") else { continue }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("@step") {
                // Tolerate "@stepN" with no space; treat that as a malformed
                // directive (must be "@step <int>") to avoid false-positive
                // matches against arbitrary identifiers like "@steplabel".
                let after = body.dropFirst("@step".count)
                guard after.first == " " || after.first == "\t" || after.isEmpty else { continue }
                let rest = after.trimmingCharacters(in: .whitespaces)
                if let n = Int(rest), n >= 1 {
                    steps.append(StepAnnotation(step: n, line: i))
                }
            } else if body.hasPrefix("@id") {
                let after = body.dropFirst("@id".count)
                guard after.first == " " || after.first == "\t" || after.isEmpty else { continue }
                let rest = after.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    id = String(rest)
                }
            }
        }
        return Parsed(id: id, steps: steps)
    }

    /// Compact JSON encoding of step annotations. The output goes into a
    /// `data-mdv-steps="…"` attribute (HTML-attribute-escaped by the
    /// caller). Stable key ordering courtesy of `sortedKeys`, so tests
    /// can assert exact attribute contents.
    /// Shared encoder — previously allocated per call. Markdown
    /// documents with many mermaid blocks call this once per block
    /// per render of the rendered-HTML cache miss path.
    private static let stepsEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static func encodeSteps(_ steps: [StepAnnotation]) -> String {
        guard let data = try? stepsEncoder.encode(steps),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    /// 8-char hex prefix of SHA-256(source). Stable + collision-tolerant
    /// for per-document use (a doc with >2^16 diagrams isn't a real
    /// concern; the hash is also the fallback `data-mdv-id`).
    public static func shortHash(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
