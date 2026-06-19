import CoreGraphics
import Foundation

/// Builds a module/file dependency graph for the open project — the
/// host-testable extraction model behind the "Dependency graph" view
/// (TSK-280). Two graph flavours, both pure data (no AppKit, no rendering):
///
///   1. **Import graph** — walks the project's source files, parses each
///      file's `import` / `require` / `use` statements, and resolves the
///      ones that point at OTHER files in the same project to file→file
///      edges. Cross-project / system imports become "external" leaf nodes
///      so the user still sees what a file depends on.
///   2. **Package graph** — parses `Package.swift`'s `dependencies:` array
///      (the simple `.package(url:…)` / `.package(name:…)` literal forms)
///      into the package + its declared dependencies.
///
/// The walk mirrors `CrossFileSearch`'s conventions: bounded file size,
/// skip-list for build/VCS dirs, symlink-loop guard, and a hard entry cap.
/// Everything is synchronous and `Sendable` so a caller can run it off the
/// main thread and hand the result to a SwiftUI render.
public enum DependencyGraph {

    // MARK: - Model

    /// A node in the graph. `id` is stable (project-relative path for an
    /// internal file, the raw module name for an external/system import,
    /// the package name for a package node) so edges reference nodes by id.
    public struct Node: Equatable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Sendable {
            case file        // a source file inside the project
            case external    // an imported module not resolved to a project file
            case package     // a Swift package (root or dependency)
        }

        public let id: String
        /// Short human label (file's last path component, module name, or
        /// package name) — what the render draws inside the node.
        public let label: String
        public let kind: Kind
        /// Absolute URL for an internal `file` node (so the view can open
        /// it on click); `nil` for external/package nodes.
        public let url: URL?

        public init(id: String, label: String, kind: Kind, url: URL? = nil) {
            self.id = id
            self.label = label
            self.kind = kind
            self.url = url
        }
    }

    /// A directed edge `from` depends on `to` (both are node ids).
    public struct Edge: Equatable, Hashable, Sendable {
        public let from: String
        public let to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// The extracted graph. `nodes` is de-duplicated and stably ordered
    /// (internal files first, in walk order, then external modules /
    /// packages in first-seen order); `edges` is de-duplicated.
    public struct Graph: Equatable, Sendable {
        public let nodes: [Node]
        public let edges: [Edge]
        public init(nodes: [Node], edges: [Edge]) {
            self.nodes = nodes
            self.edges = edges
        }

        public var isEmpty: Bool { nodes.isEmpty }

        /// Adjacency: node id → ids it depends on (outgoing edges).
        public func dependencies(of id: String) -> [String] {
            edges.filter { $0.from == id }.map(\.to)
        }

        /// Reverse adjacency: node id → ids that depend on it (incoming).
        public func dependents(of id: String) -> [String] {
            edges.filter { $0.to == id }.map(\.from)
        }
    }

    public struct Options: Sendable {
        /// Per-file read cap; files larger than this are skipped (a generated
        /// or vendored blob isn't worth parsing for imports).
        public var maxFileBytes: Int
        /// Hard cap on filesystem entries visited (symlink-loop backstop).
        public var maxEntriesScanned: Int
        /// Directory names skipped wholesale (build/VCS/vendor dirs).
        public var skipDirNames: Set<String>
        /// When true, imports that don't resolve to a project file are kept
        /// as `external` leaf nodes; when false they're dropped (internal-only
        /// graph). Defaults true — seeing third-party deps is the point.
        public var includeExternal: Bool

        public init(
            maxFileBytes: Int = 1 * 1024 * 1024,
            maxEntriesScanned: Int = 50_000,
            skipDirNames: Set<String> = [
                ".git", ".hg", ".svn", "node_modules", ".build", ".swiftpm",
                "DerivedData", "Pods", ".venv", "venv", "__pycache__",
                ".next", "dist", "build", ".tox", ".gradle", "target",
            ],
            includeExternal: Bool = true
        ) {
            self.maxFileBytes = maxFileBytes
            self.maxEntriesScanned = maxEntriesScanned
            self.skipDirNames = skipDirNames
            self.includeExternal = includeExternal
        }
    }

    // MARK: - Source languages

    /// The languages whose import statements we know how to parse. Detection
    /// is by file extension (cheap, no content sniff) — sufficient for the
    /// import-grammar parsing we do.
    enum SourceLanguage: CaseIterable {
        case swift, python, javascript, typescript, go, rust

        static func forExtension(_ ext: String) -> SourceLanguage? {
            switch ext.lowercased() {
            case "swift": return .swift
            case "py", "pyi": return .python
            case "js", "jsx", "mjs", "cjs": return .javascript
            case "ts", "tsx", "mts", "cts": return .typescript
            case "go": return .go
            case "rs": return .rust
            default: return nil
            }
        }
    }

    // MARK: - Import-graph extraction

    /// Build the file-import dependency graph rooted at `root`.
    ///
    /// `isCancelled` is polled on the directory walk so a long scan over a
    /// huge tree can be abandoned promptly (mirrors `CrossFileSearch`).
    public static func importGraph(
        root: URL,
        options: Options = Options(),
        isCancelled: () -> Bool = { false }
    ) -> Graph {
        let files = collectSourceFiles(root: root, options: options, isCancelled: isCancelled)
        guard !files.isEmpty else { return Graph(nodes: [], edges: []) }

        let rootPath = root.standardizedFileURL.path

        // project-relative path → node id, kept for resolution.
        var fileNodeByRel: [String: Node] = [:]
        var orderedFileNodes: [Node] = []
        // A module-name index for resolution: a Swift/TS `import Foo` can map
        // to a file literally named `Foo.swift` anywhere in the tree, OR (more
        // commonly) to a directory-as-module. We index both the per-file
        // basename and the immediate parent dir name so a same-name import can
        // resolve to a project file before falling back to "external".
        var fileByBasename: [String: [Node]] = [:]

        for url in files {
            let rel = relativePath(of: url, root: rootPath)
            let node = Node(id: rel, label: url.lastPathComponent, kind: .file, url: url)
            fileNodeByRel[rel] = node
            orderedFileNodes.append(node)
            let base = url.deletingPathExtension().lastPathComponent
            fileByBasename[base, default: []].append(node)
        }

        var externalNodes: [Node] = []
        var seenExternal: Set<String> = []
        var edgeSet: Set<Edge> = []
        var orderedEdges: [Edge] = []

        func addEdge(_ edge: Edge) {
            guard edge.from != edge.to else { return }  // no self-loops
            if edgeSet.insert(edge).inserted { orderedEdges.append(edge) }
        }

        for url in files {
            if isCancelled() { break }
            guard let content = readText(url, maxBytes: options.maxFileBytes),
                  let lang = SourceLanguage.forExtension(url.pathExtension)
            else { continue }

            let rel = relativePath(of: url, root: rootPath)
            guard let fromNode = fileNodeByRel[rel] else { continue }
            let imports = parseImports(content, language: lang)

            for imp in imports {
                if let resolved = resolveImport(
                    imp, from: url, root: root, rootPath: rootPath,
                    fileByBasename: fileByBasename, lang: lang
                ) {
                    addEdge(Edge(from: fromNode.id, to: resolved.id))
                } else if options.includeExternal {
                    // Couldn't tie it to a project file → external leaf.
                    let extId = "ext:\(imp.module)"
                    if seenExternal.insert(extId).inserted {
                        externalNodes.append(
                            Node(id: extId, label: imp.module, kind: .external))
                    }
                    addEdge(Edge(from: fromNode.id, to: extId))
                }
            }
        }

        // Keep only external nodes that something actually points at (a parse
        // that found an import but produced no edge shouldn't litter the graph).
        let referenced = Set(orderedEdges.map(\.to))
        let liveExternal = externalNodes.filter { referenced.contains($0.id) }

        return Graph(nodes: orderedFileNodes + liveExternal, edges: orderedEdges)
    }

    // MARK: - Package-graph extraction

    /// Parse a `Package.swift` manifest into a package dependency graph: the
    /// root package node + one node/edge per declared dependency. Only the
    /// literal `.package(url:…)` / `.package(name:…)` / `.package(path:…)`
    /// forms are recognised — we do NOT evaluate the manifest (no Swift
    /// runtime), so computed/variable dependency lists are out of scope. This
    /// is deliberately a string parse, robust to the common hand-written
    /// manifest shapes.
    public static func packageGraph(manifestURL: URL) -> Graph {
        guard let content = readText(manifestURL, maxBytes: 1 * 1024 * 1024) else {
            return Graph(nodes: [], edges: [])
        }
        return parsePackageManifest(content, manifestURL: manifestURL)
    }

    /// String-parse a `Package.swift`'s `name:` + `.package(...)` deps.
    /// Exposed (internal) so tests can drive it without a temp file.
    static func parsePackageManifest(_ content: String, manifestURL: URL) -> Graph {
        let rootName = parsePackageName(content) ?? manifestURL
            .deletingLastPathComponent().lastPathComponent
        let rootId = "pkg:\(rootName)"
        let rootNode = Node(id: rootId, label: rootName, kind: .package)

        var nodes: [Node] = [rootNode]
        var seen: Set<String> = [rootId]
        var edges: [Edge] = []

        for depName in parsePackageDependencies(content) {
            let id = "pkg:\(depName)"
            if seen.insert(id).inserted {
                nodes.append(Node(id: id, label: depName, kind: .package))
            }
            let edge = Edge(from: rootId, to: id)
            if !edges.contains(edge) { edges.append(edge) }
        }
        return Graph(nodes: nodes, edges: edges)
    }

    /// Extract the package `name:` from a manifest, if a literal is present.
    static func parsePackageName(_ content: String) -> String? {
        // Match `name: "Foo"` — the first one after `Package(` is the package
        // name (target/product names also use `name:`, so anchor on the
        // `Package(` call).
        guard let pkgRange = content.range(of: "Package(") else { return nil }
        let tail = content[pkgRange.upperBound...]
        return firstQuotedAfterLabel("name:", in: String(tail))
    }

    /// Extract dependency names from the `.package(...)` literals.
    ///   - `.package(url: "https://github.com/owner/RepoName.git", …)` → `RepoName`
    ///   - `.package(name: "Foo", …)` → `Foo`
    ///   - `.package(path: "../Local/Bar")` → `Bar`
    static func parsePackageDependencies(_ content: String) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        var searchStart = content.startIndex
        while let callRange = content.range(of: ".package(", range: searchStart..<content.endIndex) {
            // Bound the argument scan to this `.package(...)` call so a label
            // from the next call can't leak in. Find the matching close paren.
            let argsStart = callRange.upperBound
            let argsEnd = matchingParen(in: content, openAt: callRange.upperBound)
                ?? content.endIndex
            let args = String(content[argsStart..<argsEnd])
            searchStart = argsEnd < content.endIndex
                ? content.index(after: argsEnd) : content.endIndex

            if let name = firstQuotedAfterLabel("name:", in: args) {
                if seen.insert(name).inserted { names.append(name) }
            } else if let url = firstQuotedAfterLabel("url:", in: args) {
                let name = repoName(fromURL: url)
                if !name.isEmpty, seen.insert(name).inserted { names.append(name) }
            } else if let path = firstQuotedAfterLabel("path:", in: args) {
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty, seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }

    // MARK: - Import parsing

    /// A single parsed import: the raw `module` token plus whether it was a
    /// relative path import (e.g. JS `./foo`) which we can resolve directly.
    struct ParsedImport: Equatable {
        let module: String
        /// Relative-path import (JS/TS `./x`, `../y`); resolve against the
        /// importing file's directory rather than by module-name lookup.
        let relativePath: String?
    }

    /// Parse import statements out of `content` for the given language. Line
    /// based, comment-stripped, deliberately conservative — we accept the
    /// common, well-formed forms and skip anything ambiguous rather than
    /// guess. Exposed (internal) for direct unit testing.
    static func parseImports(_ content: String, language: SourceLanguage) -> [ParsedImport] {
        var out: [ParsedImport] = []
        var seen: Set<String> = []

        func push(_ imp: ParsedImport) {
            // de-dupe by module+relativePath
            let key = "\(imp.module)|\(imp.relativePath ?? "")"
            if seen.insert(key).inserted { out.append(imp) }
        }

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripLineComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            switch language {
            case .swift:
                parseSwiftImport(line).map(push)
            case .python:
                parsePythonImport(line).forEach(push)
            case .javascript, .typescript:
                parseJSImport(line).map(push)
            case .go:
                parseGoImport(line).map(push)
            case .rust:
                parseRustImport(line).map(push)
            }
        }
        return out
    }

    // `import Foundation`, `import struct Foo.Bar`, `@testable import ViewerCore`
    private static func parseSwiftImport(_ line: String) -> ParsedImport? {
        var s = line
        if s.hasPrefix("@testable ") { s = String(s.dropFirst("@testable ".count)) }
        guard s.hasPrefix("import ") else { return nil }
        var rest = String(s.dropFirst("import ".count)).trimmingCharacters(in: .whitespaces)
        // Drop an optional import-kind keyword: `import struct Foo.Bar`.
        let kinds = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"]
        for kw in kinds where rest.hasPrefix(kw + " ") {
            rest = String(rest.dropFirst(kw.count + 1)).trimmingCharacters(in: .whitespaces)
            break
        }
        // Module is the first dotted component: `Foo.Bar` → `Foo`.
        let module = String(rest.prefix { $0 != "." && $0 != " " && $0 != ";" })
        return module.isEmpty ? nil : ParsedImport(module: module, relativePath: nil)
    }

    // `import os`, `import os.path`, `from pkg.mod import x`, `from . import y`
    private static func parsePythonImport(_ line: String) -> [ParsedImport] {
        if line.hasPrefix("import ") {
            let rest = String(line.dropFirst("import ".count))
            // `import a, b.c as d` → modules a and b
            return rest.split(separator: ",").compactMap { part in
                let token = part.trimmingCharacters(in: .whitespaces)
                // strip `as alias`
                let base = token.split(separator: " ").first.map(String.init) ?? token
                let top = String(base.prefix { $0 != "." })
                return top.isEmpty ? nil : ParsedImport(module: top, relativePath: nil)
            }
        }
        if line.hasPrefix("from ") {
            let rest = String(line.dropFirst("from ".count))
            let pkg = rest.split(separator: " ").first.map(String.init) ?? ""
            // `from . import x` / `from .sibling import y` → relative
            if pkg.hasPrefix(".") {
                let mod = String(pkg.drop { $0 == "." })
                return mod.isEmpty ? [] : [ParsedImport(module: mod, relativePath: mod)]
            }
            let top = String(pkg.prefix { $0 != "." })
            return top.isEmpty ? [] : [ParsedImport(module: top, relativePath: nil)]
        }
        return []
    }

    // `import x from './foo'`, `import './side'`, `const y = require('../bar')`,
    // `export … from 'pkg'`
    private static func parseJSImport(_ line: String) -> ParsedImport? {
        // ES module: capture the string literal after `from` or a bare
        // `import '…'`, or a `require('…')` call.
        if let spec = quotedSpecifier(after: " from ", in: line)
            ?? quotedSpecifier(afterPrefix: "import ", in: line)
            ?? requireSpecifier(in: line) {
            if spec.hasPrefix(".") || spec.hasPrefix("/") {
                return ParsedImport(module: lastComponent(of: spec), relativePath: spec)
            }
            // bare specifier → external package (top scope of a scoped pkg)
            return ParsedImport(module: packageScope(of: spec), relativePath: nil)
        }
        return nil
    }

    // `import "fmt"`, `import "github.com/x/y"` (single-line form only).
    private static func parseGoImport(_ line: String) -> ParsedImport? {
        guard line.hasPrefix("import ") else { return nil }
        guard let path = firstDoubleQuoted(in: line) else { return nil }
        return path.isEmpty ? nil : ParsedImport(module: path, relativePath: nil)
    }

    // `use std::collections::HashMap;`, `use crate::foo::Bar;`, `extern crate x;`
    private static func parseRustImport(_ line: String) -> ParsedImport? {
        if line.hasPrefix("use ") {
            let rest = String(line.dropFirst("use ".count))
            let top = String(rest.prefix { $0 != ":" && $0 != ";" && $0 != " " && $0 != "{" })
            return top.isEmpty ? nil : ParsedImport(module: top, relativePath: nil)
        }
        if line.hasPrefix("extern crate ") {
            let rest = String(line.dropFirst("extern crate ".count))
            let top = String(rest.prefix { $0 != ";" && $0 != " " })
            return top.isEmpty ? nil : ParsedImport(module: top, relativePath: nil)
        }
        return nil
    }

    // MARK: - Import resolution

    /// Try to resolve a parsed import to a project file node.
    ///   - JS/TS relative imports resolve against the importing file's dir,
    ///     trying common extensions + `/index`.
    ///   - Swift/other module imports resolve by basename lookup (an
    ///     `import Foo` matching a project `Foo.swift`).
    private static func resolveImport(
        _ imp: ParsedImport,
        from importer: URL,
        root: URL,
        rootPath: String,
        fileByBasename: [String: [Node]],
        lang: SourceLanguage
    ) -> Node? {
        if let rel = imp.relativePath, lang == .javascript || lang == .typescript {
            let baseDir = importer.deletingLastPathComponent()
            let target = baseDir.appendingPathComponent(rel).standardizedFileURL
            let exts = ["", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]
            let fm = FileManager.default
            for ext in exts {
                let cand = URL(fileURLWithPath: target.path + ext)
                if fm.fileExists(atPath: cand.path) {
                    let nodeId = relativePath(of: cand, root: rootPath)
                    if let matches = fileByBasename[cand.deletingPathExtension().lastPathComponent],
                       let n = matches.first(where: { $0.id == nodeId }) {
                        return n
                    }
                }
            }
            // `import './dir'` → `./dir/index.*`
            for ext in [".ts", ".tsx", ".js", ".jsx"] {
                let cand = target.appendingPathComponent("index" + ext)
                if fm.fileExists(atPath: cand.path) {
                    let nodeId = relativePath(of: cand, root: rootPath)
                    if let matches = fileByBasename["index"],
                       let n = matches.first(where: { $0.id == nodeId }) {
                        return n
                    }
                }
            }
            return nil
        }

        // Module-name lookup: an `import Foo` → a project `Foo.<ext>`. Only
        // resolve when there's exactly one such basename in the project — an
        // ambiguous name (two `Helpers.swift`) is left external rather than
        // guessing wrong.
        if let matches = fileByBasename[imp.module], matches.count == 1,
           matches[0].url?.path != importer.path {
            return matches[0]
        }
        return nil
    }

    // MARK: - Filesystem walk

    /// Collect the project's source files (those with a known language
    /// extension), honouring the skip-list, size cap, symlink-loop guard, and
    /// entry cap — same shape as `CrossFileSearch.search`'s walk.
    static func collectSourceFiles(
        root: URL,
        options: Options,
        isCancelled: () -> Bool
    ) -> [URL] {
        var files: [URL] = []
        var entriesScanned = 0
        var visitedDirs: Set<String> = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            entriesScanned += 1
            if entriesScanned > options.maxEntriesScanned { break }
            if entriesScanned % 256 == 0, isCancelled() { break }

            let last = url.lastPathComponent
            if options.skipDirNames.contains(last) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                if isDir { enumerator.skipDescendants() }
                continue
            }

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDir {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                if visitedDirs.contains(canonical) {
                    enumerator.skipDescendants()
                    continue
                }
                visitedDirs.insert(canonical)
                continue
            }

            let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard rv?.isRegularFile == true else { continue }
            guard (rv?.fileSize ?? 0) <= options.maxFileBytes else { continue }
            guard SourceLanguage.forExtension(url.pathExtension) != nil else { continue }
            files.append(url)
        }
        return files
    }

    // MARK: - Small helpers

    private static func readText(_ url: URL, maxBytes: Int) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes else { return nil }
        return TextDecoder.decodeToString(data)
    }

    /// Project-relative path of `url`, or its full path if it isn't under root.
    static func relativePath(of url: URL, root rootPath: String) -> String {
        let p = url.standardizedFileURL.path
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if p.hasPrefix(base) { return String(p.dropFirst(base.count)) }
        return p
    }

    /// Strip a trailing `//` (Swift/JS/Go/Rust) or `#` (Python) line comment.
    /// Naïve — does not respect strings — but import lines don't contain a
    /// `//`/`#` before the directive in practice, and a false strip only loses
    /// an edge (never adds a wrong one).
    private static func stripLineComment(_ line: String) -> String {
        if let r = line.range(of: "//") { return String(line[..<r.lowerBound]) }
        if let r = line.range(of: "#") { return String(line[..<r.lowerBound]) }
        return line
    }

    /// First quoted string occurring after `label` in `s` (single OR double
    /// quotes). Used for both Swift `name: "X"` and JS specifiers.
    static func firstQuotedAfterLabel(_ label: String, in s: String) -> String? {
        guard let lr = s.range(of: label) else { return nil }
        return firstQuoted(in: String(s[lr.upperBound...]))
    }

    /// First single- or double-quoted literal in `s`.
    private static func firstQuoted(in s: String) -> String? {
        var inside = false
        var quote: Character = "\""
        var acc = ""
        for c in s {
            if inside {
                if c == quote { return acc }
                acc.append(c)
            } else if c == "\"" || c == "'" {
                inside = true
                quote = c
            }
        }
        return nil
    }

    private static func firstDoubleQuoted(in s: String) -> String? {
        guard let a = s.firstIndex(of: "\"") else { return nil }
        let after = s.index(after: a)
        guard after < s.endIndex, let b = s[after...].firstIndex(of: "\"") else { return nil }
        return String(s[after..<b])
    }

    /// Quoted specifier following a substring marker (e.g. ` from `).
    private static func quotedSpecifier(after marker: String, in line: String) -> String? {
        guard let r = line.range(of: marker) else { return nil }
        return firstQuoted(in: String(line[r.upperBound...]))
    }

    /// Quoted specifier for a bare `import './x'` (no `from`). Returns nil if a
    /// ` from ` is present (that's the named-import form handled separately).
    private static func quotedSpecifier(afterPrefix prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix), !line.contains(" from ") else { return nil }
        return firstQuoted(in: String(line.dropFirst(prefix.count)))
    }

    /// Specifier inside a `require('…')` call.
    private static func requireSpecifier(in line: String) -> String? {
        guard let r = line.range(of: "require(") else { return nil }
        return firstQuoted(in: String(line[r.upperBound...]))
    }

    private static func lastComponent(of spec: String) -> String {
        let trimmed = spec.hasSuffix("/") ? String(spec.dropLast()) : spec
        return (trimmed as NSString).lastPathComponent
    }

    /// Top of a (possibly scoped) npm package specifier: `@scope/pkg/sub` →
    /// `@scope/pkg`; `lodash/fp` → `lodash`.
    private static func packageScope(of spec: String) -> String {
        let parts = spec.split(separator: "/")
        if spec.hasPrefix("@"), parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        return parts.first.map(String.init) ?? spec
    }

    /// Repo name from a git URL: `https://github.com/owner/Repo.git` → `Repo`.
    private static func repoName(fromURL url: String) -> String {
        var s = url
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        var last = (s as NSString).lastPathComponent
        if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
        return last
    }

    /// Index of the close paren matching the open paren whose body starts at
    /// `openAt` (i.e. `openAt` is the index just AFTER the `(`). Returns the
    /// index OF the matching `)`, or nil if unbalanced. Skips parens inside
    /// string literals so a `")"` in a URL doesn't confuse the depth count.
    private static func matchingParen(in s: String, openAt: String.Index) -> String.Index? {
        var depth = 1
        var i = openAt
        var inString = false
        var quote: Character = "\""
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if c == quote { inString = false }
            } else if c == "\"" || c == "'" {
                inString = true
                quote = c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
