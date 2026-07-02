import Foundation
import RustCore

// Canvas M0 spike (TSK-1353) — the ViewerCore facade over the RustCore canvas
// session (the `Rust*Adapter` layering: ViewerUI cannot import RustCore, so
// this adapter exposes the patch loop in bridge vocabulary — `CVPatch`).

/// Adapter over the core's M0 canvas demo document.
@MainActor
public final class CanvasDemoAdapter {
    private let session: CanvasDemoSession

    /// Opens the ~200-node demo document in the Rust core.
    public init() throws {
        session = try CanvasDemoSession()
    }

    /// The core's one-shot HTML lowering of the whole document.
    public func html() throws -> String {
        try session.html()
    }

    /// Apply ops; returns the patch plan in bridge vocabulary plus the new
    /// revision and any rejected ids.
    public func apply(_ ops: [CanvasDemoOp]) throws -> (rev: UInt64, patches: [CVPatch], rejected: [UInt32]) {
        let plan = try session.apply(ops.map(\.request))
        let patches = plan.patches.map { p -> CVPatch in
            switch p {
            case let .setText(id, text):
                return CVPatch(op: .setText, id: id, text: text)
            case let .setStyle(id, key, value):
                return CVPatch(op: .setStyle, id: id, key: key, value: value)
            }
        }
        return (plan.rev, patches, plan.rejected)
    }
}

/// Adapter-level op vocabulary (mirrors `CanvasOpRequest` without exporting
/// RustCore types upward).
public enum CanvasDemoOp: Equatable, Sendable {
    case setText(id: UInt32, text: String)
    case setStyle(id: UInt32, key: String, value: String)

    var request: CanvasOpRequest {
        switch self {
        case let .setText(id, text): return .setText(id: id, text: text)
        case let .setStyle(id, key, value): return .setStyle(id: id, key: key, value: value)
        }
    }
}
