import Foundation

/// TSK-1440 — the value of reading a notebook is the cell OUTPUTS, which
/// `NotebookCell.outputs` currently retains only OPAQUELY (raw `JSONValue`).
/// This is the pure, host-tested PARSE half: project the nbformat outputs
/// array into a typed model the UI renders (text / base64 image / error /
/// stream). Rendering (SwiftUI Text + Image(base64) + long-output collapse)
/// is the render tail; parsing untrusted notebook JSON is exactly the kind
/// of thing to pin host-side.
public enum NotebookOutput: Equatable, Sendable {
    /// `stream` output — stdout/stderr text (name = "stdout" | "stderr").
    case stream(name: String, text: String)
    /// `execute_result` / `display_data` text/plain payload.
    case text(String)
    /// `execute_result` / `display_data` image payload (mime + base64 bytes).
    case image(mime: String, base64: String)
    /// `error` output — exception name, message, and joined traceback.
    case error(ename: String, evalue: String, traceback: String)
    /// A forward-compat output_type this build doesn't model.
    case unknown(outputType: String)
}

public enum NotebookOutputParser {

    /// Image mimes we surface, in preference order (a display_data may carry
    /// several representations; pick the richest renderable one).
    static let imageMimes = ["image/png", "image/jpeg", "image/gif"]

    /// Parse a cell's opaque `outputs` JSONValue into the typed model. A
    /// non-array (or nil) yields `[]`; an unrecognized item becomes
    /// `.unknown` rather than being dropped (so a count stays faithful).
    public static func parse(_ outputs: JSONValue?) -> [NotebookOutput] {
        guard case let .array(items)? = outputs else { return [] }
        return items.map(parseOne)
    }

    static func parseOne(_ v: JSONValue) -> NotebookOutput {
        guard let type = v["output_type"]?.stringValue else {
            return .unknown(outputType: "")
        }
        switch type {
        case "stream":
            return .stream(name: v["name"]?.stringValue ?? "stdout",
                           text: coalesceText(v["text"]))
        case "execute_result", "display_data":
            let data = v["data"]
            if let img = imageEntry(in: data) {
                return .image(mime: img.mime, base64: img.base64)
            }
            return .text(coalesceText(data?["text/plain"]))
        case "error":
            return .error(ename: v["ename"]?.stringValue ?? "",
                          evalue: v["evalue"]?.stringValue ?? "",
                          traceback: coalesceText(v["traceback"]))
        default:
            return .unknown(outputType: type)
        }
    }

    /// nbformat text fields are EITHER a JSON string OR an array of strings
    /// (the multiline convention — each element is a line). Coalesce to one
    /// string; a string array joins with "" (lines already carry their own
    /// newlines per nbformat), and anything else → "".
    static func coalesceText(_ v: JSONValue?) -> String {
        switch v {
        case let .string(s)?: return s
        case let .array(parts)?: return parts.compactMap(\.stringValue).joined()
        default: return ""
        }
    }

    /// The first renderable image representation in a `data` object.
    static func imageEntry(in data: JSONValue?) -> (mime: String, base64: String)? {
        guard let data else { return nil }
        for mime in imageMimes {
            if let payload = data[mime] {
                let b64 = coalesceText(payload)
                if !b64.isEmpty { return (mime, b64) }
            }
        }
        return nil
    }
}
