import Foundation
import RustCore

// Canvas M1.S5c (TSK-1360) — the ViewerCore facade over the REAL canvas
// engine (the `Rust*Adapter` layering: ViewerUI cannot import RustCore).
// Replaces the M0 demo adapter; ops/patches in bridge vocabulary.

/// Adapter-level value.
public enum CanvasDocValue: Equatable, Sendable {
    case str(String)
    case num(Double)
    case bool(Bool)
    case token(String)

    var core: CanvasValue {
        switch self {
        case .str(let s): return .str(s)
        case .num(let n): return .num(n)
        case .bool(let b): return .bool(b)
        case .token(let t): return .token(t)
        }
    }
}

/// Adapter-level position.
public enum CanvasDocPosition: Equatable, Sendable {
    case first
    case last
    case before(String)
    case after(String)

    var core: CanvasPosition {
        switch self {
        case .first: return .first
        case .last: return .last
        case .before(let a): return .before(a)
        case .after(let a): return .after(a)
        }
    }
}

/// Adapter-level op.
public enum CanvasDocOp: Equatable, Sendable {
    case insert(
        id: String?, kind: String, parent: String, pos: CanvasDocPosition,
        props: [(String, CanvasDocValue)])
    case update(id: String, set: [(String, CanvasDocValue)], unset: [String])
    case move(id: String, parent: String, pos: CanvasDocPosition)
    case remove(id: String)

    public static func == (lhs: CanvasDocOp, rhs: CanvasDocOp) -> Bool {
        lhs.core == rhs.core
    }

    var core: CanvasOpRequest {
        switch self {
        case let .insert(id, kind, parent, pos, props):
            return .insert(
                id: id, kind: kind, parent: parent, pos: pos.core,
                props: props.map { ($0.0, $0.1.core) })
        case let .update(id, set, unset):
            return .update(id: id, set: set.map { ($0.0, $0.1.core) }, unset: unset)
        case let .move(id, parent, pos):
            return .move(id: id, parent: parent, pos: pos.core)
        case let .remove(id):
            return .remove(id: id)
        }
    }
}

/// One advisory lint finding (severity/code/id/message — plain values).
public struct CanvasDocLint: Equatable, Sendable {
    public let severity: String
    public let code: String
    public let id: String?
    public let message: String

    public init(severity: String, code: String, id: String?, message: String) {
        self.severity = severity
        self.code = code
        self.id = id
        self.message = message
    }
}

/// The apply result in bridge vocabulary.
public struct CanvasDocApplied: Sendable {
    public let rev: UInt64
    public let patches: [CVPatchInstruction]
    public let minted: [String]
    public let noop: Bool
    public let lint: [CanvasDocLint]
}

/// Adapter over a real canvas document.
@MainActor
public final class CanvasDocAdapter {
    private let session: CanvasDocSession

    /// The engine's root page id.
    public static var rootPage: String { CanvasDocSession.rootPage }

    /// Opens an EMPTY document (default theme + root page).
    public init() throws {
        session = try CanvasDocSession()
    }

    /// The engine's current revision.
    public func currentRev() throws -> UInt64 { try session.currentRev() }

    /// The full HTML lowering (theme block + page subtree).
    public func html() throws -> String {
        try session.html()
    }

    /// Apply ops against `baseRev`. `RustCore.CanvasRejection` surfaces
    /// as-is (kind/detail/currentRev are plain values).
    public func apply(baseRev: UInt64, _ ops: [CanvasDocOp]) throws -> CanvasDocApplied {
        let applied = try session.apply(baseRev: baseRev, ops: ops.map(\.core))
        return CanvasDocApplied(
            rev: applied.rev,
            patches: applied.patches.map(Self.instruction),
            minted: applied.minted,
            noop: applied.noop,
            lint: applied.lint.map {
                CanvasDocLint(
                    severity: $0.severity, code: $0.code, id: $0.id, message: $0.message)
            }
        )
    }

    /// Apply a DSL fragment under the root page.
    public func applyDSL(baseRev: UInt64, _ source: String) throws -> CanvasDocApplied {
        let applied = try session.applyDSL(baseRev: baseRev, source)
        return CanvasDocApplied(
            rev: applied.rev,
            patches: applied.patches.map(Self.instruction),
            minted: applied.minted,
            noop: applied.noop,
            lint: applied.lint.map {
                CanvasDocLint(
                    severity: $0.severity, code: $0.code, id: $0.id, message: $0.message)
            }
        )
    }

    /// Canonical JSON (persistence).
    public func save() throws -> String { try session.save() }

    /// Canonical DSL projection of the root page.
    public func renderDSL() throws -> String { try session.renderDSL() }

    /// Undo the last batch (nil = empty history); re-render via html().
    public func undo() throws -> UInt64? { try session.undo() }

    /// Anchored-subtree DSL projection (nil = unknown id).
    public func renderDSL(node id: String) throws -> String? {
        try session.renderDSL(node: id)
    }

    /// Registry-generated vocabulary.
    public func vocabulary(asJSON: Bool = false) throws -> String {
        try session.vocabulary(asJSON: asJSON)
    }

    /// Read one token's recorded literal (the kit-pin read-back; nil when
    /// the token doesn't exist). Derived from the vocabulary JSON — no new
    /// FFI surface.
    public func recordedKitPin(tokenPath: String) throws -> String? {
        let json = try session.vocabulary(asJSON: true)
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = obj["tokens"] as? [[String: Any]]
        else { return nil }
        let value = tokens.first { ($0["path"] as? String) == tokenPath }?["value"] as? String
        return value.flatMap { $0.hasPrefix("pin-") ? String($0.dropFirst(4)) : $0 }
    }

    /// Full-document lint findings.
    public func lintAll() throws -> [CanvasDocLint] {
        try session.lintAll().map {
            CanvasDocLint(severity: $0.severity, code: $0.code, id: $0.id, message: $0.message)
        }
    }

    /// Reopen from canonical JSON.
    public init(loading json: String) throws {
        session = try CanvasDocSession.load(json: json)
    }

    /// RustCore patch → bridge instruction (the bridge cannot import RustCore).
    private static func instruction(_ core: CanvasPatch) -> CVPatchInstruction {
        switch core {
        case let .setText(id, text): return .setText(id: id, text: text)
        case let .setStyle(id, prop, value): return .setStyle(id: id, prop: prop, value: value)
        case let .removeStyle(id, prop): return .removeStyle(id: id, prop: prop)
        case let .setAttr(id, attr, value): return .setAttr(id: id, attr: attr, value: value)
        case let .insertNode(parent, before, html):
            return .insertNode(parent: parent, before: before, html: html)
        case let .removeNode(id): return .removeNode(id: id)
        case let .moveNode(id, parent, before):
            return .moveNode(id: id, parent: parent, before: before)
        case let .replaceNode(id, html):
            return .replaceNode(id: id, html: html)
        case let .setTheme(css):
            return .setTheme(css: css)
        }
    }
}
