import Foundation

/// Converts a JSON array-of-objects to CSV — "Copy as CSV" for a `.json`
/// document. The inverse of `CsvConvert.toJSON`, completing the CSV↔JSON
/// interop set. Pure + host-testable; uses Foundation's `JSONSerialization`
/// (not a project engine), so it's migration-safe.
public enum JsonConvert {

    /// Render JSON text as CSV when (and only when) the top level is an array
    /// whose every element is an object. Returns nil otherwise (not parseable,
    /// not an array, an element isn't an object, an empty array, or objects with
    /// no keys) — the caller surfaces a "needs an array of objects" message.
    ///
    /// Columns = the UNION of all object keys, sorted alphabetically (deterministic;
    /// `JSONSerialization` doesn't preserve per-object key order). Cells: strings
    /// verbatim; numbers compact (integers without a decimal point); booleans
    /// `true`/`false`; `null` and missing keys empty; nested objects/arrays as
    /// compact JSON (sorted keys). Fields are RFC-4180-quoted (a field with a
    /// comma, quote, or newline is wrapped in quotes with `"` doubled). Rows are
    /// LF-separated (macOS-native; the CSV parser accepts CRLF too).
    public static func toCSV(_ jsonText: String) -> String? {
        guard let data = jsonText.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data),
              let array = top as? [Any] else { return nil }

        let objects = array.compactMap { $0 as? [String: Any] }
        guard objects.count == array.count, !objects.isEmpty else { return nil }

        var keys = Set<String>()
        for object in objects { keys.formUnion(object.keys) }
        let columns = keys.sorted()
        guard !columns.isEmpty else { return nil }

        var lines = [columns.map(field).joined(separator: ",")]
        for object in objects {
            let row = columns.map { key in object[key].map { field(cell($0)) } ?? "" }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - helpers

    /// One JSON value → its CSV cell text (unquoted; `field` quotes it).
    static func cell(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let d = number.doubleValue
            if d.rounded() == d && abs(d) < 1e15 { return String(number.int64Value) }
            return number.stringValue
        }
        if let s = value as? String { return s }
        // Nested object / array → compact JSON in a single cell.
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    /// RFC-4180 field quoting.
    static func field(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else {
            return s
        }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
