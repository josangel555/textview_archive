import Foundation
import ViewerCore
import ViewerKit

/// TSK-1161 — controller for the Structural Search panel (the UI surface over the
/// host-built engine + grammar, TSK-723). The user types a structural query (the
/// tree-sitter-inspired DSL — `function_declaration name=$X`, `call_expression name="print"`,
/// etc.), parsed by `StructuralQueryParser`, run by `TreeSitterEngine.structuralSearch`
/// over the active buffer's text + language, yielding ranged matches the panel lists (and
/// a future jump-to-match consumes via each match's NSRange).
///
/// Host-tested model layer; the SwiftUI panel + DocumentModel wiring + trigger are the
/// render companions (VM-validated like the Script Console, TSK-698).
@MainActor
public final class StructuralSearchViewModel: ObservableObject {

    /// The structural query string (the DSL parsed by StructuralQueryParser).
    @Published public var query: String = ""
    /// The buffer to search (the active document's content).
    @Published public var inputText: String
    /// The buffer's language (node kinds are that grammar's named types).
    @Published public var language: HighlightLanguage

    /// Matches from the last run (ascending document order), or [] before/on error.
    @Published public private(set) var matches: [StructuralMatch] = []
    /// A human error from the last run (a query parse error), or nil.
    @Published public private(set) var errorMessage: String?
    /// True once run() has executed at least once (drives "no matches" vs "run a query").
    @Published public private(set) var didRun = false

    public init(inputText: String = "", language: HighlightLanguage = .plainText) {
        self.inputText = inputText
        self.language = language
    }

    /// Parse `query` and run it over `inputText`/`language`, publishing `matches` or a
    /// one-line `errorMessage`. Synchronous: structuralSearch is bounded (highlight byte
    /// cap) and a fast DFS.
    public func run() {
        didRun = true
        errorMessage = nil
        let parsed: StructuralQuery
        do {
            parsed = try StructuralQueryParser.parse(query)
        } catch let error as StructuralQueryParser.ParseError {
            errorMessage = "Query error: \(error.message)"
            matches = []
            return
        } catch {
            errorMessage = "Invalid query."
            matches = []
            return
        }
        matches = TreeSitterEngine.shared.structuralSearch(parsed, in: inputText, language: language)
    }
}
