import Foundation
import ViewerKit

/// TSK-1476 — the query-help layer for structural search: insertable
/// EXAMPLES per language and a friendly ERROR presentation. Pure and
/// host-tested (every shipped example is asserted to actually parse); the
/// examples popover + the under-field error text are the render tail.
public enum StructuralSearchHelp {

    /// One insertable example: what it finds + the query to insert.
    public struct Example: Equatable, Sendable {
        public let label: String
        public let query: String
        public init(label: String, query: String) {
            self.label = label
            self.query = query
        }
    }

    /// The placeholder shown in an empty query field.
    public static let placeholder =
        "structural query — e.g. function_declaration name=$X   (click Examples for more)"

    /// Language-tailored examples, falling back to a generic set. The node
    /// KINDS differ per grammar (tree-sitter kind names), so each language
    /// gets idiomatic ones; the generic set uses cross-language shapes.
    public static func examples(for language: HighlightLanguage?) -> [Example] {
        switch language {
        case .swift:
            return [
                Example(label: "Functions (capture the name)", query: "function_declaration name=$X"),
                Example(label: "Calls to a function", query: "call_expression name=\"print\""),
                Example(label: "Classes containing a function", query: "class_declaration (function_declaration)"),
                Example(label: "Guard statements", query: "guard_statement"),
            ]
        case .python:
            return [
                Example(label: "Function definitions", query: "function_definition name=$X"),
                Example(label: "Calls to a function", query: "call function=\"print\""),
                Example(label: "Classes with a method", query: "class_definition (function_definition)"),
                Example(label: "Imports", query: "import_statement|import_from_statement"),
            ]
        case .javascript, .typescript, .tsx:
            return [
                Example(label: "Function declarations", query: "function_declaration name=$X"),
                Example(label: "Arrow functions", query: "arrow_function"),
                Example(label: "Calls to a function", query: "call_expression function=\"fetch\""),
                Example(label: "Classes with a method", query: "class_declaration (method_definition)"),
            ]
        case .rust:
            return [
                Example(label: "Functions (capture the name)", query: "function_item name=$X"),
                Example(label: "Impl blocks with a function", query: "impl_item (function_item)"),
                Example(label: "Macro invocations", query: "macro_invocation"),
                Example(label: "Struct definitions", query: "struct_item name=$X"),
            ]
        default:
            return [
                Example(label: "Any node of a kind (capture it)", query: "identifier @id"),
                Example(label: "Either of two kinds", query: "if_statement|guard_statement"),
                Example(label: "A field equals text", query: "call name=\"print\""),
                Example(label: "A parent containing a child", query: "function_declaration (return_statement)"),
            ]
        }
    }

    /// Turn a parser `ParseError` into a one-line, position-annotated message
    /// for the under-field error label. `query` is the text the user typed.
    public static func errorText(
        _ error: StructuralQueryParser.ParseError, in query: String
    ) -> String {
        let pos = max(0, min(error.position, query.count))
        return "Query error at \(pos): \(error.message)"
    }

    /// Validate a query, returning the friendly error text or nil if it
    /// parses. The view calls this on edit to show/clear the error label.
    public static func validationError(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }   // empty = no error, just idle
        do {
            _ = try StructuralQueryParser.parse(trimmed)
            return nil
        } catch let e as StructuralQueryParser.ParseError {
            return errorText(e, in: trimmed)
        } catch {
            return "Query error: \(error)"
        }
    }
}
