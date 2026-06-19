import XCTest

/// Exact-pin policy guard for the *project's own* `Package.swift` (TSK-974,
/// security H8). Distinct from `PackageManifestTests`, which exercises the
/// in-app manifest *parser* feature — this reads OUR `Package.swift` off disk
/// and fails if any remote source-control dependency uses a caret range
/// (`from:`) instead of an exact pin.
///
/// Why: `from:` is SemVer caret semantics — SwiftPM is free to walk to any
/// version below the next major on the next `swift package update`. For the
/// pre-1.0 (0.x) TreeSitter grammars that means a silent jump across MINOR
/// versions (`from: "0.23.0"` → 0.24.x / 0.25.x), and a grammar bump can
/// change tokenization, node-kind names, and how our vendored highlight
/// `.scm` queries behave — a supply-chain + correctness drift surface with
/// no review trail. The manifest's own comments already declare an exact-pin
/// discipline (swift-markdown `.upToNextMinor`, tree-sitter-swift pinned to
/// an exact revision); this test enforces it for every other dependency.
///
/// Allowed pin forms (each is an explicit, reviewable point):
///   - `exact: "X.Y.Z"`        — pinned to one version
///   - `revision: "<sha>"`     — pinned to one commit
///   - `.upToNextMinor(from:)` — caps drift to patch releases of one minor
///   - `branch: "<name>"`      — explicit branch tracking (none today)
/// Disallowed: a bare `from:` caret range.
final class PackageManifestPinPolicyTests: XCTestCase {

    /// Package root, resolved at runtime from this file's location so it
    /// works under `swift test` regardless of the build dir.
    /// Tests/ViewerCoreTests/<thisfile>.swift → up 3.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var manifestURL: URL {
        packageRoot.appendingPathComponent("Package.swift")
    }

    /// One non-comment `.package(url: …)` declaration, normalized to a single
    /// physical-line string (the manifest wraps the long URL + pin onto one
    /// line, but be defensive about future wrapping by stripping comments and
    /// collapsing whitespace per line first).
    private func packageDeclarationLines(_ manifest: String) -> [String] {
        manifest
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                // Strip a trailing `// …` line comment. URLs here never
                // contain `//` outside the `https://` scheme, so guard that.
                var s = String(line)
                if let range = s.range(of: "//") {
                    // Keep `https://`; only treat `//` as a comment if it is
                    // NOT immediately preceded by a colon (scheme separator).
                    let before = s[s.startIndex..<range.lowerBound]
                    if !before.hasSuffix(":") {
                        s = String(before)
                    }
                }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { $0.contains(".package(url:") }
    }

    func test_manifest_exists_and_declares_grammar_packages() throws {
        let manifest = try String(contentsOf: Self.manifestURL, encoding: .utf8)
        let decls = packageDeclarationLines(manifest)
        XCTAssertFalse(decls.isEmpty,
                       "Expected at least one `.package(url:)` declaration in Package.swift")
        // Sanity: the TreeSitter grammars we care about are present.
        XCTAssertTrue(decls.contains { $0.contains("tree-sitter-python") },
                      "tree-sitter-python dependency vanished from the manifest")
        XCTAssertTrue(decls.contains { $0.contains("tree-sitter-rust") },
                      "tree-sitter-rust dependency vanished from the manifest")
    }

    func test_no_source_control_dependency_uses_a_caret_range() throws {
        let manifest = try String(contentsOf: Self.manifestURL, encoding: .utf8)
        let decls = packageDeclarationLines(manifest)

        var offenders: [String] = []
        for decl in decls {
            // A bare `from:` is the caret range we forbid. `.upToNextMinor(from:`
            // also contains the substring `from:` but is an allowed bounded
            // range — exclude it.
            let hasUpToNextMinor = decl.contains(".upToNextMinor(from:")
            // Match an argument-position `from:` (preceded by a comma/space,
            // i.e. a version-requirement argument), not one embedded in an
            // identifier.
            let hasBareFrom = decl.contains(" from:") || decl.contains(",from:")
            if hasBareFrom && !hasUpToNextMinor {
                offenders.append(decl)
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Package.swift dependencies must be EXACTLY pinned (TSK-974). \
            These use a `from:` caret range, which lets SwiftPM silently \
            drift to a newer version on `swift package update`:

            \(offenders.joined(separator: "\n"))

            Replace `from:` with `exact: "X.Y.Z"` (or `revision:` / \
            `.upToNextMinor(from:)` if a bounded range is genuinely \
            intended). Pin to the version already locked in Package.resolved.
            """
        )
    }

    func test_every_remote_dependency_has_an_explicit_pin() throws {
        let manifest = try String(contentsOf: Self.manifestURL, encoding: .utf8)
        let decls = packageDeclarationLines(manifest)

        // Every remote package declaration must carry one of the explicit
        // pin forms. Catches a future dep added with NO version requirement
        // (which SwiftPM treats as "any version" — the worst caret of all).
        let explicitPinTokens = ["exact:", "revision:", "branch:", ".upToNextMinor(from:"]
        var unpinned: [String] = []
        for decl in decls {
            if !explicitPinTokens.contains(where: { decl.contains($0) }) {
                unpinned.append(decl)
            }
        }

        XCTAssertTrue(
            unpinned.isEmpty,
            """
            Package.swift dependencies must carry an explicit pin \
            (exact:/revision:/branch:/.upToNextMinor) — TSK-974. These have \
            no recognized version requirement:

            \(unpinned.joined(separator: "\n"))
            """
        )
    }
}
