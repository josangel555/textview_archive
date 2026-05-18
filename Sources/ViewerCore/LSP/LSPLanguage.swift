import Foundation

/// Language descriptor used by the LSP layer. One value per LSP-supported
/// language. Adding a new language is two things:
///   1. Add a `LSPLanguage` case.
///   2. Register it in `LSPLanguageRegistry.default` with a server-spawner
///      closure and a workspace-root finder.
///
/// File-extension → language lookup goes through `LSPLanguageRegistry`,
/// not this enum, so a single language can claim multiple extensions
/// (`.swift` only for Swift; in future, `.py` + `.pyi` for Python, etc.).
public enum LSPLanguage: String, Sendable, Hashable, CaseIterable {
    case swift
    // Add cases here as servers land. Each new case requires a
    // registration in `LSPLanguageRegistry.default`.

    /// LSP `languageId` string passed in `textDocument/didOpen`. Spec
    /// defines a fixed set ([LSP 3.17 §TextDocumentItem][lsp-langid]);
    /// pick the canonical name.
    public var languageID: String {
        switch self {
        case .swift: return "swift"
        }
    }

    /// Display label for the dev diagnostics panel.
    public var displayName: String {
        switch self {
        case .swift: return "Swift (sourcekit-lsp)"
        }
    }
}

/// Plug-point a language registers to find the workspace root for a
/// given file URL. Closure returns nil if no enclosing root is found;
/// the caller may then fall back to "single-file mode" (server spawned
/// with the file's parent dir) at its discretion.
public typealias LSPRootFinder = @Sendable (URL) -> URL?

/// Plug-point a language registers to locate + launch its server.
/// Returns a fully-configured `LSPClient.Config` ready to hand to
/// `LSPClient.init`, or nil if the server binary can't be located.
///
/// `workspaceRoot` is the already-resolved root (per `LSPRootFinder`).
public typealias LSPServerLauncher = @Sendable (_ workspaceRoot: URL) -> LSPClient.Config?

/// One entry per language we know how to drive.
public struct LSPLanguageEntry: Sendable {
    public let language: LSPLanguage
    /// Lowercased file extensions (without leading dot) that map to
    /// this language. First match wins in `LSPLanguageRegistry.language(for:)`.
    public let fileExtensions: Set<String>
    public let rootFinder: LSPRootFinder
    public let serverLauncher: LSPServerLauncher

    public init(
        language: LSPLanguage,
        fileExtensions: Set<String>,
        rootFinder: @escaping LSPRootFinder,
        serverLauncher: @escaping LSPServerLauncher
    ) {
        self.language = language
        self.fileExtensions = fileExtensions
        self.rootFinder = rootFinder
        self.serverLauncher = serverLauncher
    }
}

/// Immutable registry. The `default` static is the only one we ship;
/// `LSPPool` reads it at construction time. Tests can inject a custom
/// registry to stub a language without touching real binaries.
public struct LSPLanguageRegistry: Sendable {

    public let entries: [LSPLanguageEntry]

    public init(entries: [LSPLanguageEntry]) {
        self.entries = entries
    }

    /// Resolve a file URL to a language entry by extension. Case-insensitive.
    /// Returns nil for unknown extensions; caller should treat that as
    /// "LSP not available for this file".
    public func language(for fileURL: URL) -> LSPLanguageEntry? {
        let ext = fileURL.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return entries.first { $0.fileExtensions.contains(ext) }
    }

    public func entry(for language: LSPLanguage) -> LSPLanguageEntry? {
        return entries.first { $0.language == language }
    }

    // MARK: - Default registry

    /// Built-in registry. Swift only, today. Adding Python/Rust/etc.
    /// means adding an entry here.
    public static let `default` = LSPLanguageRegistry(entries: [
        .init(
            language: .swift,
            fileExtensions: ["swift"],
            rootFinder: { fileURL in
                LSPDiscovery.swiftPackageRoot(for: fileURL)
            },
            serverLauncher: { workspaceRoot in
                guard let binary = LSPDiscovery.locateSourceKitLSP() else {
                    return nil
                }
                return LSPClient.Config(
                    executable: binary,
                    arguments: [],
                    workspaceRoot: workspaceRoot)
            }
        ),
    ])
}
