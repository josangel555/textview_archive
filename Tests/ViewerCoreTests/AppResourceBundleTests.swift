import Foundation
import Testing
@testable import ViewerCore

/// TSK-1257 — the prod `.app` crashed on clean machines because the
/// SwiftPM-generated `Bundle.module` resolves resource bundles from the `.app`
/// ROOT then a hardcoded dev-machine `.build` path, never `Contents/Resources`
/// (where `build-app.sh` ships + signs them). `Bundle.resolveResourceBundle`
/// fixes that by preferring the running app's own bundle. These tests pin the
/// resolution order so a revert to plain `Bundle.module` (or a wrong precedence)
/// goes red on the host gate — the regression guard the original bug lacked.
struct AppResourceBundleTests {

    /// Build a throwaway `<name>.bundle` dir under a fresh temp root, containing
    /// `<sub>/<base>.<ext>`. Returns the ROOT (the search-root we hand the
    /// resolver), not the bundle dir. Caller removes the root.
    private func makeBundleRoot(
        named name: String, sub: String?, base: String, ext: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-restest-\(UUID().uuidString)", isDirectory: true)
        let bundleDir = root.appendingPathComponent("\(name).bundle", isDirectory: true)
        let leaf = sub.map { bundleDir.appendingPathComponent($0, isDirectory: true) } ?? bundleDir
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: leaf.appendingPathComponent("\(base).\(ext)"))
        return root
    }

    @Test func resolvesFromSearchRootWhenBundlePresent() throws {
        let root = try makeBundleRoot(
            named: "MarkdownViewer_ViewerCore", sub: "Queries", base: "swift-folds", ext: "scm")
        defer { try? FileManager.default.removeItem(at: root) }

        let fallback = Bundle.main
        let resolved = Bundle.resolveResourceBundle(
            named: "MarkdownViewer_ViewerCore", fallback: fallback, searchRoots: [root])

        // It used the search root, NOT the fallback, and the subdirectory
        // resource lookup the tree-sitter engine relies on works.
        #expect(resolved !== fallback)
        #expect(resolved.url(
            forResource: "swift-folds", withExtension: "scm", subdirectory: "Queries") != nil)
    }

    @Test func fallsBackWhenBundleAbsent() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        // Under `swift test` / `swift run` the app search roots miss, so we MUST
        // defer to the supplied `Bundle.module` fallback (identity check).
        let fallback = Bundle.main
        let resolved = Bundle.resolveResourceBundle(
            named: "MarkdownViewer_ViewerCore", fallback: fallback, searchRoots: [empty])
        #expect(resolved === fallback)
    }

    /// `Contents/Resources` (search root 0) must beat any later root — modelling
    /// the app preferring its own sealed bundle over the dev `.build` fallback.
    @Test func prefersEarlierSearchRoot() throws {
        let first = try makeBundleRoot(
            named: "MarkdownViewer_ViewerCore", sub: "Queries", base: "from-first", ext: "scm")
        let second = try makeBundleRoot(
            named: "MarkdownViewer_ViewerCore", sub: "Queries", base: "from-second", ext: "scm")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let resolved = Bundle.resolveResourceBundle(
            named: "MarkdownViewer_ViewerCore", fallback: Bundle.main,
            searchRoots: [first, second])
        #expect(resolved.url(
            forResource: "from-first", withExtension: "scm", subdirectory: "Queries") != nil)
        #expect(resolved.url(
            forResource: "from-second", withExtension: "scm", subdirectory: "Queries") == nil)
    }

    /// A bare name (no `.bundle` suffix) and an explicit-suffix name resolve the
    /// same dir — the call sites pass bare names.
    @Test func acceptsNameWithOrWithoutSuffix() throws {
        let root = try makeBundleRoot(
            named: "MarkdownViewer_ViewerUI", sub: nil, base: "markdown", ext: "css")
        defer { try? FileManager.default.removeItem(at: root) }

        let bare = Bundle.resolveResourceBundle(
            named: "MarkdownViewer_ViewerUI", fallback: Bundle.main, searchRoots: [root])
        let suffixed = Bundle.resolveResourceBundle(
            named: "MarkdownViewer_ViewerUI.bundle", fallback: Bundle.main, searchRoots: [root])
        #expect(bare.url(forResource: "markdown", withExtension: "css") != nil)
        #expect(suffixed.url(forResource: "markdown", withExtension: "css") != nil)
    }
}
