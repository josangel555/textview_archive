import Foundation

/// One reusable snippet (TSK-705, slice 2). `body` uses the snippet syntax
/// parsed by `SnippetExpansion`; `name` is the menu/palette label.
public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let body: String

    public init(id: String, name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }

    /// The parsed form (segments / plainText / tab stops).
    public var parsed: ParsedSnippet { SnippetExpansion.parse(body) }
}

/// The shipped, built-in snippets (slice 2). Markdown/code-oriented, since
/// that's what this app edits. A later slice adds user-defined snippets +
/// persistence + a management UI; this is the read-only starter set so
/// "Insert Snippet" is useful out of the box.
public enum SnippetLibrary {
    public static let builtIns: [Snippet] = [
        Snippet(id: "md.table", name: "Markdown Table",
                body: "| ${1:Column} | ${2:Column} |\n| --- | --- |\n| $3 | $4 |\n$0"),
        Snippet(id: "md.codeFence", name: "Code Fence",
                body: "```${1:swift}\n$0\n```"),
        Snippet(id: "md.link", name: "Markdown Link",
                body: "[${1:text}](${2:https://})"),
        Snippet(id: "md.details", name: "Collapsible Section",
                body: "<details>\n<summary>${1:Summary}</summary>\n\n$0\n\n</details>"),
        Snippet(id: "md.todo", name: "TODO Comment",
                body: "<!-- TODO: $0 -->"),
    ]
}
