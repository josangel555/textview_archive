import Foundation

/// A `DiagramRenderer` registry + fenced-language / file-extension routing —
/// the foundation slice of the "diagram formats beyond Mermaid/Dot" epic
/// (TSK-713). Today the markdown render path classifies diagram fences
/// ad-hoc: `mermaid` is intercepted inline in `HTMLRenderer.visitCodeBlock`,
/// `.mmd`/`.mermaid` files in `FileTypeDetector`, and the Graphviz DOT parser
/// (`DotGraphParser`) lives unwired in `DotGraph.swift`. This centralizes the
/// "which renderer handles this fence language / file extension" decision
/// behind one registry so adding a new diagram format is a single
/// `register(_:)` call rather than another scattered `== "foo"` check.
///
/// Pure model, no SwiftUI/AppKit imports — lives in ViewerCore so the
/// HTML render path (`HTMLRenderer`) and the file classifier can both query
/// it. Each renderer declares the fence languages and file extensions it
/// accepts and produces a normalized ``DiagramDescriptor``; the registry
/// resolves a language/extension to exactly one renderer and is
/// order-independent (registration order doesn't change resolution) with
/// duplicate-language collision detection.

/// The diagram families the registry knows how to route to. Stable string
/// raw values double as a serialization key (e.g. for a `data-mdv-kind`
/// attribute or session snapshot) so a new case is additive.
public enum DiagramKind: String, Equatable, Sendable, CaseIterable {
    /// Mermaid diagrams — rendered client-side by the bundled mermaid runtime
    /// via the `mdv-mermaid` host `<div>` (`HTMLRenderer.renderMermaidHost`).
    case mermaid
    /// Graphviz DOT / GV graphs — parsed host-side by `DotGraphParser` into a
    /// structural outline (no layout engine; see `DotGraph`).
    case dot
    /// PlantUML diagrams (`@startuml … @enduml`). Pure-host detection only —
    /// no JS runtime / external dependency — rendered as a labeled source
    /// block until a layout backend lands (a later epic slice).
    case plantuml
}

/// Normalized output every ``DiagramRenderer`` produces from a chunk of
/// diagram source. Deliberately render-agnostic: it carries enough for the
/// HTML path to emit the right host element (or labeled fallback block)
/// without the call site re-classifying the language. A renderer that does
/// deeper parsing (e.g. DOT node/edge extraction) stashes the result under
/// ``metadata`` rather than widening this struct per format.
public struct DiagramDescriptor: Equatable, Sendable {
    /// Which diagram family produced this descriptor.
    public let kind: DiagramKind
    /// The raw diagram source, verbatim (the renderer does not mutate it).
    public let source: String
    /// The fence language / extension token that resolved to this renderer,
    /// lowercased (e.g. `"mermaid"`, `"dot"`, `"gv"`, `"plantuml"`). Useful
    /// for diagnostics and round-tripping the original token.
    public let language: String
    /// An optional stable identifier the renderer extracted from the source
    /// (e.g. mermaid's `%% @id <slug>`), surfaced so walkthrough drivers can
    /// target a specific diagram. `nil` when the format has none.
    public let id: String?
    /// Renderer-specific structured facts, string-keyed so the descriptor
    /// stays format-agnostic. Examples: DOT directedness/node-count,
    /// PlantUML's detected `@start<type>` keyword.
    public let metadata: [String: String]

    public init(
        kind: DiagramKind,
        source: String,
        language: String,
        id: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind
        self.source = source
        self.language = language
        self.id = id
        self.metadata = metadata
    }
}

/// A renderer for one diagram family. Declares the fenced-code info-string
/// languages and file extensions it accepts (all matched case-insensitively),
/// and turns a source string into a normalized ``DiagramDescriptor``.
///
/// `languages` and `fileExtensions` MUST be lowercased and contain no
/// duplicates within a single renderer; ``DiagramRegistry`` lowercases query
/// tokens before lookup. A renderer is a pure value type (no UI), so it can
/// be unit-tested and shared across threads.
public protocol DiagramRenderer: Sendable {
    /// The diagram family this renderer handles.
    var kind: DiagramKind { get }
    /// Fenced-code info-string languages this renderer claims, lowercased
    /// (e.g. `["mermaid"]`, `["dot", "gv", "graphviz"]`).
    var languages: [String] { get }
    /// File extensions (without the leading dot, lowercased) this renderer
    /// claims for standalone diagram files (e.g. `["mmd", "mermaid"]`).
    var fileExtensions: [String] { get }
    /// Produce a normalized descriptor for the given source. The `language`
    /// argument is the lowercased token that resolved to this renderer (the
    /// fence info-string or file extension), so a renderer serving multiple
    /// tokens can record which one was used.
    func descriptor(for source: String, language: String) -> DiagramDescriptor
}

/// Resolves a fenced-code language or file extension to the diagram renderer
/// that handles it. Registration is order-independent and collision-checked:
/// two renderers may not claim the same language or extension.
public final class DiagramRegistry: @unchecked Sendable {

    /// A duplicate-language / duplicate-extension registration was attempted.
    public enum RegistrationError: Error, Equatable, CustomStringConvertible {
        case duplicateLanguage(String, existingKind: DiagramKind, newKind: DiagramKind)
        case duplicateExtension(String, existingKind: DiagramKind, newKind: DiagramKind)

        public var description: String {
            switch self {
            case let .duplicateLanguage(lang, existing, new):
                return "diagram language '\(lang)' already claimed by \(existing.rawValue); \(new.rawValue) cannot also claim it"
            case let .duplicateExtension(ext, existing, new):
                return "diagram file extension '\(ext)' already claimed by \(existing.rawValue); \(new.rawValue) cannot also claim it"
            }
        }
    }

    private var byLanguage: [String: DiagramRenderer] = [:]
    private var byExtension: [String: DiagramRenderer] = [:]
    private let lock = NSLock()

    public init() {}

    /// Register a renderer. Throws ``RegistrationError`` if any of its
    /// languages or extensions is already claimed by ANY renderer (including
    /// another instance of the same kind) so the routing table can never
    /// become ambiguous. Callers build the registry once.
    public func register(_ renderer: DiagramRenderer) throws {
        lock.lock()
        defer { lock.unlock() }
        // Validate the whole renderer before mutating, so a partial failure
        // doesn't leave the table half-populated.
        for lang in renderer.languages {
            let key = lang.lowercased()
            if let existing = byLanguage[key] {
                throw RegistrationError.duplicateLanguage(key, existingKind: existing.kind, newKind: renderer.kind)
            }
        }
        for ext in renderer.fileExtensions {
            let key = ext.lowercased()
            if let existing = byExtension[key] {
                throw RegistrationError.duplicateExtension(key, existingKind: existing.kind, newKind: renderer.kind)
            }
        }
        for lang in renderer.languages {
            byLanguage[lang.lowercased()] = renderer
        }
        for ext in renderer.fileExtensions {
            byExtension[ext.lowercased()] = renderer
        }
    }

    /// The renderer claiming `language` (a fenced-code info-string token),
    /// or `nil` if none — the caller falls through to plain-code rendering.
    /// Matched case-insensitively.
    public func renderer(forLanguage language: String) -> DiagramRenderer? {
        lock.lock(); defer { lock.unlock() }
        return byLanguage[language.lowercased()]
    }

    /// The renderer claiming file `extension` (without leading dot), or `nil`.
    /// Matched case-insensitively.
    public func renderer(forFileExtension ext: String) -> DiagramRenderer? {
        lock.lock(); defer { lock.unlock() }
        return byExtension[ext.lowercased()]
    }

    /// Resolve + render in one step: returns the normalized descriptor for
    /// `source` under fence `language`, or `nil` if no renderer claims it.
    public func descriptor(for source: String, language: String) -> DiagramDescriptor? {
        guard let r = renderer(forLanguage: language) else { return nil }
        return r.descriptor(for: source, language: language.lowercased())
    }

    /// Every language token the registry currently routes, for diagnostics.
    public var registeredLanguages: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(byLanguage.keys)
    }

    /// Every file extension the registry currently routes, for diagnostics.
    public var registeredExtensions: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(byExtension.keys)
    }

    /// The process-wide default registry, pre-populated with the built-in
    /// renderers (mermaid, dot, plantuml). Built once; the render path queries
    /// this instead of hardcoded language checks. If a built-in collides
    /// (a programming error), we trap — the default set is fixed and tested.
    public static let standard: DiagramRegistry = {
        let registry = DiagramRegistry()
        do {
            try registry.register(MermaidDiagramRenderer())
            try registry.register(DotDiagramRenderer())
            try registry.register(PlantUMLDiagramRenderer())
        } catch {
            // The built-in renderer set has non-overlapping tokens by
            // construction; a collision here is a programmer error caught at
            // first use (and by `DiagramRegistryTests`).
            preconditionFailure("built-in diagram renderers collide: \(error)")
        }
        return registry
    }()
}

// MARK: - Built-in renderers

/// Routes the `mermaid` fence language and `.mmd`/`.mermaid` files to the
/// mermaid client-side runtime. Surfaces the `%% @id <slug>` directive (parsed
/// by `MermaidSourceParser`) as the descriptor `id` so the descriptor carries
/// the same stable identifier `HTMLRenderer.renderMermaidHost` emits.
public struct MermaidDiagramRenderer: DiagramRenderer {
    public let kind: DiagramKind = .mermaid
    public let languages: [String] = ["mermaid"]
    public let fileExtensions: [String] = ["mmd", "mermaid"]

    public init() {}

    public func descriptor(for source: String, language: String) -> DiagramDescriptor {
        let parsed = MermaidSourceParser.parse(source)
        var metadata: [String: String] = ["stepCount": String(parsed.steps.count)]
        if let id = parsed.id { metadata["declaredId"] = id }
        return DiagramDescriptor(
            kind: .mermaid,
            source: source,
            language: language,
            id: parsed.id,
            metadata: metadata
        )
    }
}

/// Routes the Graphviz `dot`/`gv`/`graphviz` fence languages and `.dot`/`.gv`
/// files through the existing `DotGraphParser`. The structural facts (graph
/// direction, node/edge counts, name) land in the descriptor `metadata` so a
/// later layout/render slice can consume them without re-parsing.
public struct DotDiagramRenderer: DiagramRenderer {
    public let kind: DiagramKind = .dot
    public let languages: [String] = ["dot", "gv", "graphviz"]
    public let fileExtensions: [String] = ["dot", "gv"]

    public init() {}

    public func descriptor(for source: String, language: String) -> DiagramDescriptor {
        var metadata: [String: String] = [:]
        var id: String? = nil
        if let graph = DotGraphParser.parse(source) {
            metadata["directed"] = graph.isDirected ? "true" : "false"
            metadata["nodeCount"] = String(graph.nodes.count)
            metadata["edgeCount"] = String(graph.edges.count)
            if let name = graph.name {
                metadata["name"] = name
                id = name
            }
        } else {
            // Source resolved to this renderer by token, but isn't a valid
            // DOT document — record that so the render path can fall back to
            // a labeled source block instead of trusting an empty graph.
            metadata["parsed"] = "false"
        }
        return DiagramDescriptor(
            kind: .dot,
            source: source,
            language: language,
            id: id,
            metadata: metadata
        )
    }
}

/// Routes the `plantuml`/`puml`/`uml` fence languages and `.puml`/`.plantuml`
/// files. PlantUML normally needs a Java backend (a dependency we deliberately
/// do NOT add), so this renderer is **pure host detection only**: it confirms
/// the source is PlantUML-shaped (`@start<type> … @end<type>`) and extracts
/// the diagram type, producing a descriptor the render path turns into a
/// labeled source block. The full image render is a later epic slice gated on
/// an owner-approved backend.
public struct PlantUMLDiagramRenderer: DiagramRenderer {
    public let kind: DiagramKind = .plantuml
    public let languages: [String] = ["plantuml", "puml", "uml"]
    public let fileExtensions: [String] = ["puml", "plantuml", "iuml"]

    public init() {}

    /// True if `source` contains a PlantUML start directive (`@startuml`,
    /// `@startmindmap`, `@startgantt`, etc.). Case-insensitive, ignores
    /// leading whitespace. Used so a `.puml` file or `plantuml` fence with
    /// junk content can be told apart from a real diagram.
    public static func isPlantUML(_ source: String) -> Bool {
        detectedType(in: source) != nil
    }

    /// The `@start<type>` keyword's `<type>` suffix (lowercased), e.g.
    /// `"uml"`, `"mindmap"`, `"gantt"`, `"json"`, `"salt"`. `nil` if no
    /// recognizable start directive is present.
    public static func detectedType(in source: String) -> String? {
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix("@start") else { continue }
            let suffix = line.dropFirst("@start".count)
            // The token is the run of letters right after `@start`, before any
            // space / argument (e.g. `@startuml MyName` → "uml").
            let typeChars = suffix.prefix { $0.isLetter }
            if !typeChars.isEmpty { return String(typeChars) }
            // Bare `@start` with no type is still PlantUML-shaped; normalize
            // to the generic "uml".
            return "uml"
        }
        return nil
    }

    public func descriptor(for source: String, language: String) -> DiagramDescriptor {
        var metadata: [String: String] = [:]
        if let type = Self.detectedType(in: source) {
            metadata["diagramType"] = type
            metadata["detected"] = "true"
        } else {
            metadata["detected"] = "false"
        }
        return DiagramDescriptor(
            kind: .plantuml,
            source: source,
            language: language,
            id: nil,
            metadata: metadata
        )
    }
}
