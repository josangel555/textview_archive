import Foundation

/// Languages the highlighter knows about. Lives in ViewerKit so both
/// ViewerCore (the regex highlighter) and ViewerUI (mode bar badge,
/// content routing) can reference it without dragging the engine
/// across module boundaries.
public enum HighlightLanguage: String, Sendable, CaseIterable {
    case swift
    case json
    case xml
    case python
    case javascript
    case typescript
    case tsx
    case markdown
    case shell
    case yaml
    case html
    case css
    case sql
    case go
    case rust
    case c
    case cpp
    case ruby
    case java
    case kotlin
    case csharp
    case lua
    case plainText = "plain"

    /// Best-effort detect from a file URL's extension. Falls back to
    /// `.plainText` for unknown extensions.
    public static func detect(from url: URL) -> HighlightLanguage {
        switch url.pathExtension.lowercased() {
        case "swift":                                  return .swift
        case "json", "jsonl":                          return .json
        case "xml", "plist", "xib", "storyboard",
             "svg":                                    return .xml
        case "py", "pyw", "pyi":                       return .python
        case "js", "mjs", "cjs", "jsx":                return .javascript
        case "ts":                                     return .typescript
        // `.tsx` needs the JSX-aware grammar — the plain TS grammar
        // cannot parse JSX and litters the tree with ERROR nodes,
        // wrecking highlighting for the whole file. See `Grammar.tsx`.
        case "tsx":                                    return .tsx
        case "md", "markdown", "mdown", "mkd", "mkdn": return .markdown
        case "sh", "bash", "zsh", "fish":              return .shell
        case "yaml", "yml":                            return .yaml
        case "html", "htm", "xhtml":                   return .html
        case "css", "scss", "sass":                    return .css
        case "sql":                                    return .sql
        case "go":                                     return .go
        case "rs":                                     return .rust
        case "c", "h":                                 return .c
        case "cpp", "cc", "cxx", "hpp", "hh":          return .cpp
        case "rb":                                     return .ruby
        case "java":                                   return .java
        case "kt", "kts":                              return .kotlin
        case "cs":                                     return .csharp
        case "lua":                                    return .lua
        default:                                       return .plainText
        }
    }

    /// Best-effort detect from a markdown code-fence info string
    /// (`swift`, `bash`, `js`, etc.) Lowercased + aliased. Returns
    /// `.plainText` for unrecognized strings.
    public static func detect(fromInfoString info: String) -> HighlightLanguage {
        let key = info.lowercased()
            .split(whereSeparator: { " \t".contains($0) })
            .first.map(String.init) ?? ""
        switch key {
        case "swift":                              return .swift
        case "json", "jsonl":                      return .json
        case "xml", "plist", "svg":                return .xml
        case "py", "python", "python3":            return .python
        case "js", "javascript", "node":           return .javascript
        case "ts", "typescript":                   return .typescript
        case "tsx":                                return .tsx
        case "md", "markdown":                     return .markdown
        case "sh", "bash", "zsh", "shell":         return .shell
        case "yaml", "yml":                        return .yaml
        case "html", "xhtml":                      return .html
        case "css", "scss", "sass":                return .css
        case "sql":                                return .sql
        case "go", "golang":                       return .go
        case "rs", "rust":                         return .rust
        case "c":                                  return .c
        case "cpp", "c++", "cc", "cxx":            return .cpp
        case "rb", "ruby":                         return .ruby
        case "java":                               return .java
        case "kt", "kotlin":                       return .kotlin
        case "cs", "csharp", "c#":                 return .csharp
        case "lua":                                return .lua
        default:                                   return .plainText
        }
    }

    /// Human-readable name for UI badges.
    public var displayName: String {
        switch self {
        case .swift:       return "Swift"
        case .json:        return "JSON"
        case .xml:         return "XML"
        case .python:      return "Python"
        case .javascript:  return "JavaScript"
        case .typescript:  return "TypeScript"
        case .tsx:         return "TSX"
        case .markdown:    return "Markdown"
        case .shell:       return "Shell"
        case .yaml:        return "YAML"
        case .html:        return "HTML"
        case .css:         return "CSS"
        case .sql:         return "SQL"
        case .go:          return "Go"
        case .rust:        return "Rust"
        case .c:           return "C"
        case .cpp:         return "C++"
        case .ruby:        return "Ruby"
        case .java:        return "Java"
        case .kotlin:      return "Kotlin"
        case .csharp:      return "C#"
        case .lua:         return "Lua"
        case .plainText:   return "Plain Text"
        }
    }
}
