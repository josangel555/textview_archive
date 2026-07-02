import Foundation

// Canvas M3.S8 (TSK-1379) — the inspector/layers READ MODEL: one parse of
// the engine's canonical JSON (adapter.save()), no parallel store. The
// engine remains the single source of truth; this is a snapshot refreshed
// on every revision change.

/// One node in the document outline.
public struct CanvasOutlineNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    /// Props in canonical (key-sorted) order, values in display form.
    public let props: [(name: String, value: CanvasOutlineValue)]
    public var children: [CanvasOutlineNode]

    public static func == (lhs: CanvasOutlineNode, rhs: CanvasOutlineNode) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
            && lhs.children == rhs.children
            && lhs.props.map(\.name) == rhs.props.map(\.name)
            && lhs.props.map(\.value) == rhs.props.map(\.value)
    }
}

/// A displayable prop value (mirrors the engine's typed values).
public enum CanvasOutlineValue: Equatable, Sendable {
    case str(String)
    case num(Double)
    case bool(Bool)
    case token(String)

    /// Editor-facing text (the inspector's field contents).
    public var display: String {
        switch self {
        case .str(let s): return s
        case .num(let n):
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .token(let t): return "$\(t)"
        }
    }
}

public enum CanvasOutlineError: Error, Equatable {
    case notCanvasJSON(String)
}

/// Parse the engine's canonical document JSON into the outline tree.
public enum CanvasOutlineParser {

    public static func parse(_ json: String) throws -> CanvasOutlineNode {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rootID = obj["root"] as? String,
            let records = obj["records"] as? [[String: Any]]
        else {
            throw CanvasOutlineError.notCanvasJSON("missing root/records")
        }

        // Index records + children (by parent, in `index` order — the saved
        // records are id-sorted, so sort children by their FracIndex string:
        // lexicographic byte order IS the sibling order, by design).
        var byID: [String: [String: Any]] = [:]
        var childIDs: [String: [(id: String, index: String)]] = [:]
        for record in records {
            guard let id = record["id"] as? String else { continue }
            byID[id] = record
            if let parent = record["parent"] as? String,
                let index = record["index"] as? String {
                childIDs[parent, default: []].append((id, index))
            }
        }
        for key in childIDs.keys {
            childIDs[key]?.sort { $0.index < $1.index }
        }

        func value(from raw: Any) -> CanvasOutlineValue? {
            guard let dict = raw as? [String: Any],
                let type = dict["t"] as? String else { return nil }
            switch type {
            case "s": return (dict["v"] as? String).map(CanvasOutlineValue.str)
            case "tok": return (dict["v"] as? String).map(CanvasOutlineValue.token)
            case "b": return (dict["v"] as? Bool).map(CanvasOutlineValue.bool)
            case "n":
                if let n = dict["v"] as? Double { return .num(n) }
                if let i = dict["v"] as? Int { return .num(Double(i)) }
                return nil
            default: return nil
            }
        }

        func build(_ id: String) throws -> CanvasOutlineNode {
            guard let record = byID[id], let kind = record["kind"] as? String else {
                throw CanvasOutlineError.notCanvasJSON("dangling id \(id)")
            }
            var props: [(String, CanvasOutlineValue)] = []
            if let rawProps = record["props"] as? [String: Any] {
                for name in rawProps.keys.sorted() {
                    if let v = rawProps[name].flatMap(value(from:)) {
                        props.append((name, v))
                    }
                }
            }
            let kids = try (childIDs[id] ?? []).map { try build($0.id) }
            return CanvasOutlineNode(id: id, kind: kind, props: props, children: kids)
        }
        return try build(rootID)
    }

    /// Depth-first lookup.
    public static func find(_ id: String, in node: CanvasOutlineNode) -> CanvasOutlineNode? {
        if node.id == id { return node }
        for child in node.children {
            if let hit = find(id, in: child) { return hit }
        }
        return nil
    }
}

/// The registry-driven prop specs (the inspector's row source) — parsed ONCE
/// per document from the engine's vocabulary JSON (rot-proofed upstream).
public struct CanvasPropSpec: Equatable, Sendable {
    public let name: String
    public let note: String?
}

public enum CanvasVocabularyIndex {
    /// kind name → its allowed prop specs.
    public static func propSpecs(fromVocabularyJSON json: String) -> [String: [CanvasPropSpec]] {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kinds = obj["kinds"] as? [[String: Any]]
        else { return [:] }
        var specs: [String: [CanvasPropSpec]] = [:]
        for kind in kinds {
            guard let name = kind["name"] as? String,
                let props = kind["props"] as? [[String: Any]] else { continue }
            specs[name] = props.compactMap { p in
                (p["name"] as? String).map {
                    CanvasPropSpec(name: $0, note: p["note"] as? String)
                }
            }
        }
        return specs
    }
}
