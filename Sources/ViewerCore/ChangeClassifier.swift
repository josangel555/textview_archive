import Foundation

/// TSK-1195(a) — the render-verification CLASSIFIER: given the files a change
/// touches, decide whether the agent can self-certify on the HOST or must go
/// to the VM. This is the "false-done killer" — the recurring failure is an
/// agent reporting a render-path fix "done" on host-green evidence when the
/// pixels were never checked. `classify` encodes the project's own test-tier
/// map (CLAUDE.md): ViewerCore/ViewerKit/rust-core = host-provable; ViewerUI =
/// render-path (host covers the MODEL only); WebView resources = VM-only.
/// Pure + host-tested. (Part (b), the render-CHECK tool/skill + eval approach,
/// is the owner-gated half — this classifier needs no such decision.)
public enum ChangeClass: String, Sendable, Equatable, CaseIterable {
    /// Pure logic / model / FFI — unit + headless gate fully certify it.
    case hostProvable
    /// SwiftUI/AppKit view code — host tests cover the model, but the on-screen
    /// result needs the VM (T4 LiveApp / T5 pixel).
    case renderPath
    /// WebView (CodeMirror/canvas HTML/JS) — pixel/behaviour is VM-only; host
    /// can't composite it at all.
    case needsVM
    /// A test file — the change IS the evidence; no separate certification.
    case testOnly
    /// Docs / scripts / config — no app behaviour to certify.
    case nonCode
    /// Unrecognized path — classify conservatively (treat as not self-certifiable).
    case needsReview

    /// Higher = more restrictive for "can the agent self-certify on the host".
    /// The aggregate verdict is the max over the change's CODE files.
    var restrictiveness: Int {
        switch self {
        case .nonCode, .testOnly: return 0
        case .hostProvable: return 1
        case .needsReview: return 2
        case .renderPath: return 3
        case .needsVM: return 4
        }
    }

    /// Whether a host-green gate is sufficient proof for this class alone.
    public var hostCertifiable: Bool {
        switch self {
        case .hostProvable, .testOnly, .nonCode: return true
        case .renderPath, .needsVM, .needsReview: return false
        }
    }
}

public enum ChangeClassifier {

    /// Classify a single repo-relative path.
    public static func classify(_ path: String) -> ChangeClass {
        let p = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        let lower = p.lowercased()

        // WebView surfaces first — VM-only regardless of enclosing dir.
        if lower.hasSuffix(".html") || lower.hasSuffix(".js")
            || p.contains("/Resources/codemirror/") || p.contains("/Resources/canvas/")
            || p.contains("/Resources/mermaid/") {
            return .needsVM
        }
        // Test files — the test is the evidence.
        if p.hasPrefix("Tests/") || p.contains("/Tests/") {
            return .testOnly
        }
        // SwiftUI/AppKit render layer.
        if p.hasPrefix("Sources/ViewerUI/") || p.hasPrefix("Sources/MarkdownViewer/") {
            return .renderPath
        }
        // Host-testable code: pure engines, kit, rust core, C shims.
        if p.hasPrefix("Sources/ViewerCore/") || p.hasPrefix("Sources/ViewerKit/")
            || p.hasPrefix("Sources/RustCore/") || p.hasPrefix("Sources/CMdvCore/")
            || p.hasPrefix("Sources/TreeSitterLazyWrappers/")
            || p.hasPrefix("Sources/CTSPatchJavaScript/")
            || p.hasPrefix("rust-core/") {
            return .hostProvable
        }
        // Docs / scripts / config / manifests.
        if lower.hasSuffix(".md") || p.hasPrefix("docs/") || p.hasPrefix("scripts/")
            || p.hasPrefix("schemas/") || lower.hasSuffix(".json")
            || lower.hasSuffix(".yml") || lower.hasSuffix(".yaml")
            || p == "Package.swift" || p.hasPrefix(".github/") {
            return .nonCode
        }
        return .needsReview
    }

    /// The aggregate verdict for a whole changeset.
    public struct Verdict: Equatable, Sendable {
        /// The most-restrictive class across the change (drives the gate).
        public let overall: ChangeClass
        /// Whether a host-green gate ALONE certifies this change (false the
        /// moment any file is render-path / VM / unrecognized).
        public let hostCertifiable: Bool
        /// Per-file breakdown (input order preserved).
        public let perFile: [(path: String, cls: ChangeClass)]

        public static func == (l: Verdict, r: Verdict) -> Bool {
            l.overall == r.overall && l.hostCertifiable == r.hostCertifiable
                && l.perFile.map(\.path) == r.perFile.map(\.path)
                && l.perFile.map(\.cls) == r.perFile.map(\.cls)
        }
    }

    /// Classify a changeset. `overall` is the max restrictiveness over the
    /// files; an EMPTY change is `nonCode`/host-certifiable (nothing to prove).
    public static func classify(paths: [String]) -> Verdict {
        let perFile = paths.map { (path: $0, cls: classify($0)) }
        let overall = perFile.map(\.cls).max { $0.restrictiveness < $1.restrictiveness } ?? .nonCode
        // Host-certifiable only if EVERY file is (a single render/VM/unknown
        // file forces VM/owner validation).
        let hostOK = perFile.allSatisfy { $0.cls.hostCertifiable }
        return Verdict(overall: overall, hostCertifiable: hostOK, perFile: perFile)
    }
}
