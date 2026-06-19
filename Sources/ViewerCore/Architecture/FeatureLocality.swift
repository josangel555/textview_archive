import Foundation

// MARK: - Core/Swift split: the executable companion to CORE_SWIFT_SPLIT_DESIGN.
//
// TSK-805 — "How to separate core yet still use Swift/macOS features for
// value-added features?"
//
// The remote-core track (epic TSK-651) moves the engine families into
// `mdvcore-core` and exposes them over a transport-agnostic frame contract so
// the core can run on another host. The inverse, undesigned angle this file
// answers: WHERE the boundary sits, and HOW Swift/macOS-only value-add features
// layer on top WITHOUT polluting the remoteable core.
//
// The design doc states the boundary in prose; this file makes the central
// claim MACHINE-CHECKABLE. Every feature surface is assigned a `FeatureTier`
// AND the set of host dependencies it genuinely needs. The *minimum* tier is
// then DERIVED from those dependencies (`FeatureTier.minimum(for:)`), and a
// consistency check flags any surface whose declared tier contradicts what its
// dependencies require. So a future change that, say, gives a `remoteableCore`
// feature an AppKit dependency fails a host test instead of silently breaking
// the remote story.

/// The architectural tier a feature surface belongs to. Ordered from most
/// portable (runs anywhere the engine runs, including a remote host) to least
/// (pinned to the local Mac by an OS dependency it cannot shed).
///
/// The whole point of the split is that **work flows downhill, never up**: a
/// `remoteableCore` engine must never reach for `hostOrchestrated` IO or
/// `localOnlySwift` system frameworks, because the same engine code must run
/// unchanged inside `mdv-serve` on a headless box. The tiers are a one-way
/// dependency lattice.
public enum FeatureTier: Int, Sendable, Hashable, CaseIterable, Comparable, Codable {
    /// Pure, sans-IO computation that lives (or belongs) in `mdvcore-core` and
    /// is reachable over the FFI/remote frame contract verbatim. Parsing,
    /// rendering structure, diffing, searching, fuzzy matching, formatting.
    /// MUST NOT depend on any host capability — it takes bytes in, returns
    /// bytes out. This is the layer `mdv-serve` and `mdv-web` already serve.
    case remoteableCore = 0

    /// Needs IO or process orchestration, but that IO can be performed *where
    /// the files live* — so it works remotely too, just not as a pure engine
    /// call. It is brokered by a host layer: locally the Swift app, remotely
    /// `mdv-serve` (fs.*, git.*, transcript.*, lsp pipe). The protocol is
    /// transport-agnostic; the orchestration is symmetric across local/remote.
    case hostOrchestrated = 1

    /// Inherently bound to the local Mac because it depends on a macOS-only
    /// framework, the local GUI/WindowServer, local hardware, or interactive
    /// pointer/keyboard surfaces that have no meaning on a remote engine.
    /// These are the Swift/macOS value-add features. They are NEVER remoteable
    /// and MUST NOT be a dependency of any lower tier — explicitly
    /// "[Remote not supported]".
    case localOnlySwift = 2

    public static func < (lhs: FeatureTier, rhs: FeatureTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short stable id used in docs / diagnostics.
    public var id: String {
        switch self {
        case .remoteableCore:  return "remoteable-core"
        case .hostOrchestrated: return "host-orchestrated"
        case .localOnlySwift:  return "local-only-swift"
        }
    }

    public var title: String {
        switch self {
        case .remoteableCore:   return "Remoteable Core"
        case .hostOrchestrated: return "Host-Orchestrated"
        case .localOnlySwift:   return "Local-Only Swift / macOS"
        }
    }
}

/// A host capability a feature can depend on. The classification is driven by
/// these: each capability pins the *minimum* tier a feature that uses it can
/// occupy. The boundary criteria from the design doc are encoded here once.
public enum HostCapability: String, Sendable, Hashable, CaseIterable, Codable {
    // --- remoteableCore-compatible (pure compute; no host dependency) ---
    /// Pure, sans-IO computation: takes bytes/values in, returns bytes/values
    /// out. Reachable over the frame contract verbatim.
    case pureCompute

    // --- hostOrchestrated (IO/process, but symmetric local/remote) ---
    /// Reading/listing bytes from a filesystem — performed where files live.
    case filesystemIO
    /// Spawning/observing a subprocess (git, an LSP server) on the host.
    case subprocess
    /// Server-push / duplex streaming (fs.watch, transcript.follow).
    case pushStream

    // --- localOnlySwift (pinned to the local Mac) ---
    /// AppKit / SwiftUI / WindowServer rendering — the on-screen UI.
    case appKitUI
    /// A macOS-only system framework (AVFoundation, CoreMIDI, PDFKit,
    /// NSPasteboard, UTType, ScreenCaptureKit, Quick Look, …).
    case macSystemFramework
    /// Local hardware: audio device, MIDI port, camera, GPU surface.
    case localHardware
    /// Live interactive pointer / keyboard / drag surface tied to THIS
    /// window — has no meaning addressed to a remote engine.
    case interactivePointer

    /// The minimum tier a feature that uses this capability can occupy.
    /// This is the boundary criterion, expressed as data.
    public var minimumTier: FeatureTier {
        switch self {
        case .pureCompute:
            return .remoteableCore
        case .filesystemIO, .subprocess, .pushStream:
            return .hostOrchestrated
        case .appKitUI, .macSystemFramework, .localHardware, .interactivePointer:
            return .localOnlySwift
        }
    }
}

/// One classified feature surface in the app.
public struct FeatureSurface: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    /// Human label.
    public let name: String
    /// The tier we DECLARE this surface belongs to.
    public let tier: FeatureTier
    /// The host capabilities this surface genuinely needs. Drives the derived
    /// minimum tier and the consistency check.
    public let dependencies: Set<HostCapability>
    /// Where the work lives today / where it should land (free-form note used
    /// by the design doc and diagnostics, not by the invariant logic).
    public let locus: String

    public init(
        id: String,
        name: String,
        tier: FeatureTier,
        dependencies: Set<HostCapability>,
        locus: String
    ) {
        self.id = id
        self.name = name
        self.tier = tier
        self.dependencies = dependencies
        self.locus = locus
    }

    /// The minimum tier this surface's dependencies force it into — the
    /// HIGHEST `minimumTier` across all of its dependencies (work flows
    /// downhill: one local-only dependency pins the whole surface local).
    public var derivedMinimumTier: FeatureTier {
        FeatureTier.minimum(for: dependencies)
    }

    /// True when the declared tier is exactly the minimum its dependencies
    /// allow. A surface declared HIGHER (more portable) than its dependencies
    /// permit is a real architecture violation (it would break the remote
    /// story); declared LOWER than necessary is a missed-portability smell we
    /// also flag, so the classification stays honest.
    public var isConsistent: Bool {
        tier == derivedMinimumTier
    }
}

extension FeatureTier {
    /// The minimum tier a feature with these dependencies can occupy. A feature
    /// with no declared dependencies is treated as pure compute (the most
    /// portable floor).
    public static func minimum(for dependencies: Set<HostCapability>) -> FeatureTier {
        dependencies.map(\.minimumTier).max() ?? .remoteableCore
    }
}

/// The candidate classification of the app's feature surfaces against the
/// core/Swift split (TSK-805). This is the data the design doc tabulates; the
/// tests pin it so the boundary stays enforced as the app grows.
///
/// Adding a surface here without matching its declared tier to its real
/// dependencies fails `FeatureCatalogConsistencyTests` — that is the teeth.
public enum FeatureLocalityCatalog {
    public static let surfaces: [FeatureSurface] = [
        // ---- Remoteable core: the engine families (mdvcore-core) ----
        .init(id: "markdown.render", name: "Markdown structural render",
              tier: .remoteableCore, dependencies: [.pureCompute],
              locus: "mdvcore-core::markdown (+ Swift sanitizer/highlight chunks)"),
        .init(id: "diff.parse", name: "Diff parse",
              tier: .remoteableCore, dependencies: [.pureCompute],
              locus: "mdvcore-core::diff"),
        .init(id: "csv.engine", name: "CSV parse / filter / sort",
              tier: .remoteableCore, dependencies: [.pureCompute],
              locus: "mdvcore-core::csv"),
        .init(id: "hex.engine", name: "Hex dump + search",
              tier: .remoteableCore, dependencies: [.pureCompute],
              locus: "mdvcore-core::hex"),
        .init(id: "find.engine", name: "In-buffer find engine",
              tier: .remoteableCore, dependencies: [.pureCompute],
              locus: "mdvcore-core::find_engine"),
        .init(id: "fuzzy.match", name: "Fuzzy matcher",
              tier: .remoteableCore, dependencies: [.pureCompute],
              locus: "mdvcore-core::fuzzy"),
        .init(id: "transcript.parse", name: "Transcript parse",
              tier: .remoteableCore, dependencies: [.pureCompute],
              locus: "mdvcore-core::transcript"),
        .init(id: "indent.detect", name: "Indent detection",
              tier: .remoteableCore, dependencies: [.pureCompute],
              locus: "mdvcore-core::indent"),

        // ---- Host-orchestrated: IO/process, symmetric local/remote ----
        .init(id: "fs.read", name: "Windowed file read",
              tier: .hostOrchestrated, dependencies: [.filesystemIO],
              locus: "Swift TextFileLoader / remote fs.read (TSK-654)"),
        .init(id: "fs.tree", name: "File tree / sidebar listing",
              tier: .hostOrchestrated, dependencies: [.filesystemIO],
              locus: "Swift FileTreeService / remote fs.tree (TSK-654)"),
        .init(id: "fs.watch", name: "File watching",
              tier: .hostOrchestrated, dependencies: [.filesystemIO, .pushStream],
              locus: "Swift FileWatcher (FSEvents) / remote fs.watch (TSK-655)"),
        .init(id: "search.cross", name: "Cross-file search",
              tier: .hostOrchestrated, dependencies: [.filesystemIO],
              locus: "Swift CrossFileSearch / remote search (TSK-656)"),
        .init(id: "git.client", name: "Git status / log / branches",
              tier: .hostOrchestrated, dependencies: [.subprocess, .filesystemIO],
              locus: "Swift GitClient / remote git.* (TSK-657)"),
        .init(id: "transcript.discover", name: "Transcript discovery + tail",
              tier: .hostOrchestrated, dependencies: [.filesystemIO, .pushStream],
              locus: "Swift discovery / remote transcript.list/follow (TSK-658/663)"),
        .init(id: "lsp.session", name: "LSP server session (JSON-RPC pipe)",
              tier: .hostOrchestrated, dependencies: [.subprocess, .pushStream],
              locus: "Swift LSP client / remote lsp pipe (TSK-659)"),

        // ---- Local-only Swift / macOS value-add ([Remote not supported]) ----
        .init(id: "ui.lenses", name: "View lenses (WKWebView / CM6 / native chrome)",
              tier: .localOnlySwift, dependencies: [.appKitUI],
              locus: "ViewerUI lenses + ContentView"),
        .init(id: "find.bar.native", name: "In-document native find bars",
              tier: .localOnlySwift, dependencies: [.appKitUI, .interactivePointer],
              locus: "ViewerUI MarkdownFindBar / NSTextView search (searches what's on screen)"),
        .init(id: "image.editor", name: "Image editor",
              tier: .localOnlySwift, dependencies: [.macSystemFramework, .appKitUI],
              locus: "ViewerUI ImageEditorView (CoreImage/AppKit)"),
        .init(id: "audio.editor", name: "Audio editor / playback",
              tier: .localOnlySwift, dependencies: [.macSystemFramework, .localHardware],
              locus: "ViewerUI AudioEditorView (AVFoundation)"),
        .init(id: "au.midi", name: "AudioUnit hosting + CoreMIDI (TSK-956)",
              tier: .localOnlySwift, dependencies: [.macSystemFramework, .localHardware],
              locus: "AVAudioEngine + CoreMIDI"),
        .init(id: "universal.paste", name: "Universal Paste (TSK-958)",
              tier: .localOnlySwift, dependencies: [.macSystemFramework],
              locus: "NSPasteboard type-precedence dispatcher"),
        .init(id: "terminal.pty", name: "Embedded PTY terminal",
              tier: .localOnlySwift, dependencies: [.subprocess, .interactivePointer, .appKitUI],
              locus: "ViewerUI Terminal (local PTY; remote terminal = ssh/tmux, not in mdv-serve)"),
        .init(id: "quicklook.preview", name: "Quick Look / media preview",
              tier: .localOnlySwift, dependencies: [.macSystemFramework, .appKitUI],
              locus: "ViewerUI MediaPreviewView / Quick Look"),
        .init(id: "macros.replay", name: "Editor macros (record/replay, TSK-957)",
              tier: .localOnlySwift, dependencies: [.appKitUI, .interactivePointer],
              locus: "ViewerCore Commands + ViewerUI dispatch"),
    ]

    /// Lookup by id.
    public static func surface(_ id: String) -> FeatureSurface? {
        surfaces.first { $0.id == id }
    }

    /// All surfaces in a given tier.
    public static func surfaces(in tier: FeatureTier) -> [FeatureSurface] {
        surfaces.filter { $0.tier == tier }
    }

    /// Any surface whose declared tier contradicts what its dependencies
    /// require. Empty == the classification is internally consistent.
    public static var inconsistencies: [FeatureSurface] {
        surfaces.filter { !$0.isConsistent }
    }
}
