import Foundation

public extension Bundle {
    /// Candidate roots, in priority order, that may contain a SwiftPM resource
    /// bundle when the process is a packaged `.app`:
    /// 1. `Bundle.main.resourceURL` — `Foo.app/Contents/Resources` (where
    ///    `build-app.sh` ships the bundles and `codesign --deep` seals them).
    /// 2. `Bundle.main.bundleURL` — the bundle root; for a bare `swift run`
    ///    executable this is the directory next to the binary (`.build/<cfg>`),
    ///    which is exactly where SwiftPM drops the bundles.
    static var appResourceSearchRoots: [URL] {
        [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
    }

    /// Resolve a SwiftPM resource bundle (`<Package>_<Target>.bundle`) robustly,
    /// preferring the running app's OWN bundle over the generated `Bundle.module`.
    ///
    /// WHY this exists (TSK-1257) — a plain `swift build` (not Xcode) emits the
    /// *minimal* `resource_bundle_accessor.swift`, whose `Bundle.module` resolves
    /// a resource bundle by checking `Bundle.main.bundleURL/<name>.bundle` (the
    /// `.app` **root**, NOT `Contents/Resources`, where we ship + sign them) and
    /// then a **hardcoded absolute `.build/.../<name>.bundle`** path. On the build
    /// machine that `.build` path exists, so `Bundle.module` silently resolved
    /// there — masking that the hand-assembled `.app` never read its OWN bundle.
    /// On any clean machine (no `.build`) both candidates miss and the accessor
    /// `_assertionFailure`s at launch (the M5-Pro crash). Keeping the bundles in
    /// `Contents/Resources` (the canonical, notarizable, `codesign --strict`-clean
    /// layout) and resolving them from there fixes the crash without moving
    /// resources to the `.app` root (which `--strict`/notarization reject).
    ///
    /// `searchRoots` is injectable for host tests; production callers take the
    /// default. The `fallback` (each target's own `Bundle.module`) keeps
    /// `swift test` / `swift run` working — there `Bundle.main` is the test
    /// runner, so the search roots miss and we defer to SwiftPM.
    static func resolveResourceBundle(
        named name: String,
        fallback: @autoclosure () -> Bundle,
        searchRoots: [URL] = Bundle.appResourceSearchRoots
    ) -> Bundle {
        let fileName = name.hasSuffix(".bundle") ? name : name + ".bundle"
        let fm = FileManager.default
        for root in searchRoots {
            let candidate = root.appendingPathComponent(fileName)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue,
               let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return fallback()
    }

    /// ViewerCore's resource bundle (tree-sitter `Queries/*.scm`), resolved for
    /// the packaged app first. See `resolveResourceBundle(named:fallback:)`.
    static let viewerCoreResources: Bundle =
        resolveResourceBundle(named: "MarkdownViewer_ViewerCore", fallback: .module)
}
