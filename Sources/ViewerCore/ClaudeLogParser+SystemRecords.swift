import Foundation

// Extension of `ClaudeLogParser` adding the security-critical redaction
// layer and a few lightweight record-classification helpers used by
// `ClaudeSessionIndex`. Kept in a separate file so the core parser
// (`ClaudeLogParser.swift`) stays untouched.
//
// SECURITY: Claude Code transcripts embed material that must never be
// surfaced verbatim (see docs/research/autorun-2026-06-04/claude-dir.md §8.9):
//   - `thinking.signature` — opaque crypto blob on extended-thinking blocks.
//   - `system.api_error.error.headers` — raw HTTP response headers that can
//     include `set-cookie` (`_cfuvid=…`) and other session secrets.
//   - `image.source` — potentially-large base64 blobs (drop from any
//     list/summary surface; a detail view can lazy-load the raw line).
// The redaction here operates on the *decoded JSON object* so it composes
// with the streaming reader (which only ever decodes one line at a time).

public extension ClaudeLogParser {

    /// Keys whose values are stripped wholesale wherever they appear, because
    /// the value is an opaque secret with no display value.
    ///   - `signature`: extended-thinking signature blob.
    ///   - `headers`: HTTP response headers (set-cookie carrier).
    static let redactedKeys: Set<String> = ["signature", "headers"]

    /// Replacement token written in place of a redacted scalar/object.
    static let redactionToken = "[REDACTED]"

    /// Max retained length of an `image.source` (or any obviously-base64-ish
    /// blob) before it is collapsed to a short placeholder. Real image
    /// sources are tens-to-hundreds of KB of base64; we keep at most this
    /// many bytes so a list/summary surface never materializes the blob.
    static let maxImageSourceBytes = 256

    /// Recursively redact a decoded JSONL record in place of returning the
    /// raw object. Returns a structurally-identical object with secrets
    /// removed. Pure value transform — no I/O, safe to call per line.
    ///
    /// The transform is deliberately key-name driven (not path-driven) so it
    /// is robust to the loose, version-drifting record shapes: a `signature`
    /// or `headers` key is scrubbed wherever it nests, and an `image` block's
    /// `source` is truncated wherever an image block appears.
    static func redact(_ object: [String: Any]) -> [String: Any] {
        return redactDict(object)
    }

    private static func redactDict(_ dict: [String: Any]) -> [String: Any] {
        // Is this dict an image block? `{"type":"image","source":<base64>}`.
        let isImageBlock = (dict["type"] as? String) == "image"
        var out: [String: Any] = [:]
        out.reserveCapacity(dict.count)
        for (key, value) in dict {
            if redactedKeys.contains(key) {
                out[key] = redactionToken
                continue
            }
            if isImageBlock, key == "source" {
                out[key] = redactImageSource(value)
                continue
            }
            out[key] = redactValue(value)
        }
        return out
    }

    private static func redactValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return redactDict(dict)
        }
        if let arr = value as? [Any] {
            return arr.map { redactValue($0) }
        }
        return value
    }

    /// Collapse a large image source to a placeholder; keep tiny refs intact
    /// (a short `source` may be a URL/ref rather than an inline blob).
    private static func redactImageSource(_ value: Any) -> Any {
        if let s = value as? String {
            if s.utf8.count > maxImageSourceBytes {
                return "[image source omitted: \(s.utf8.count) bytes]"
            }
            return s
        }
        // Object form `{"type":"base64","media_type":...,"data":<blob>}`:
        // drop the `data` payload, keep the lightweight metadata.
        if let dict = value as? [String: Any] {
            var out = dict
            if let data = dict["data"] as? String, data.utf8.count > maxImageSourceBytes {
                out["data"] = "[image data omitted: \(data.utf8.count) bytes]"
            }
            return out
        }
        return value
    }

    // MARK: Lightweight record classification (no `message` envelope needed)

    /// Discriminator `type` of a decoded record, or `""` if absent.
    static func recordType(_ object: [String: Any]) -> String {
        return object["type"] as? String ?? ""
    }

    /// Absolute working directory carried by conversation records
    /// (`user`/`assistant`/`system`). The project-dir name is a lossy
    /// hyphenation of this — always read the real value from the record.
    static func recordCwd(_ object: [String: Any]) -> String? {
        guard let cwd = object["cwd"] as? String, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// In-record logical session id. NOTE: this diverges from the filename
    /// stem on resume/fork; callers must use the filename stem as the
    /// canonical session key. Exposed only for diagnostics.
    static func recordSessionId(_ object: [String: Any]) -> String? {
        object["sessionId"] as? String
    }

    /// Extract a sidecar title value if this record is a title record.
    /// Returns `(isCustom, title)` so the caller can apply the
    /// custom > ai precedence with last-wins semantics.
    static func titleRecord(_ object: [String: Any]) -> (isCustom: Bool, title: String)? {
        switch recordType(object) {
        case "custom-title":
            if let t = object["customTitle"] as? String, !t.isEmpty {
                return (true, t)
            }
        case "ai-title":
            if let t = object["aiTitle"] as? String, !t.isEmpty {
                return (false, t)
            }
        default:
            break
        }
        return nil
    }

    /// First user-prompt text from a `user` record whose `message.content`
    /// is a plain string (the canonical "first prompt" case). Returns `nil`
    /// for tool-result-bearing `user` records (block-array content) so the
    /// title fallback only latches onto real prompts.
    static func userPromptText(_ object: [String: Any]) -> String? {
        guard recordType(object) == "user",
              let message = object["message"] as? [String: Any],
              (message["role"] as? String ?? "user") == "user"
        else { return nil }
        if let s = message["content"] as? String, !s.isEmpty {
            return s
        }
        // Block-array form: take the first text block, if any. tool_result
        // records have no text block, so they yield nil.
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String, !t.isEmpty { return t }
            }
        }
        return nil
    }
}
