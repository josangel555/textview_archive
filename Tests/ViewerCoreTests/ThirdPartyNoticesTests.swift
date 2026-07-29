import XCTest

/// Guards the aggregated attribution file (THIRD_PARTY_NOTICES.md).
///
/// Distributing the bundled third-party components (swift-markdown,
/// cmark, the tree-sitter grammars, Mermaid, CodeMirror 6) requires
/// reproducing their licenses. This test asserts the generated file
/// exists and names every component we ship, so adding a dependency
/// without re-running `scripts/gen-third-party-notices.sh` fails CI.
final class ThirdPartyNoticesTests: XCTestCase {

    private var packageRoot: URL {
        // Tests/ViewerCoreTests/ThirdPartyNoticesTests.swift → up 3.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private func noticesText() throws -> String {
        let url = packageRoot.appendingPathComponent("THIRD_PARTY_NOTICES.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_notices_file_exists_and_nonempty() throws {
        let text = try noticesText()
        XCTAssertGreaterThan(
            text.count, 2000,
            "THIRD_PARTY_NOTICES.md looks truncated — regenerate via scripts/gen-third-party-notices.sh."
        )
        XCTAssertTrue(text.contains("Third-Party Notices"))
    }

    /// Every component we link or ship must be attributed by name. If
    /// this fails after adding a dependency, run
    /// `bash scripts/gen-third-party-notices.sh` (and add the package to
    /// SWIFTPM_PKGS in that script if it's a new SwiftPM dependency).
    func test_notices_cover_every_shipped_component() throws {
        let text = try noticesText()
        // TSK-854: the Swift package ships only the fold-grammar set now
        // (highlighting is rust-only). The 8 highlight-only grammars were
        // removed from Package.swift, so they're no longer attributed here.
        let required = [
            // SwiftPM
            "swift-markdown",
            "cmark",
            "SwiftTreeSitter",
            "tree-sitter",
            "tree-sitter-javascript",
            "tree-sitter-json",
            "tree-sitter-markdown",
            "tree-sitter-swift",
            "tree-sitter-typescript",
            "tree-sitter-xml",
            // Vendored JS bundles
            "Mermaid",
            "CodeMirror",
        ]
        for name in required {
            XCTAssertTrue(
                text.contains(name),
                "THIRD_PARTY_NOTICES.md is missing attribution for '\(name)'. "
                + "Regenerate via scripts/gen-third-party-notices.sh."
            )
        }
        // Sanity: the actual license bodies must be present, not just the
        // section labels — count MIT/license markers.
        XCTAssertTrue(text.contains("Permission is hereby granted"),
                      "Notices file appears to be section headers only — no license bodies.")
    }

    /// Audit THEME 4 (fixed 2026-07-29): the ~47 statically-linked Rust
    /// crates shipped UNATTRIBUTED — the generator only covered SwiftPM +
    /// vendored JS. Pin the section and its load-bearing members (the direct,
    /// owner-approved deps; the full closure is generated from `cargo tree`).
    func test_notices_cover_the_staticallyLinked_rustCrates() throws {
        let text = try noticesText()
        XCTAssertTrue(text.contains("Statically-linked Rust crates"),
                      "the rust-crate section is missing — regenerate")
        for crate in ["pulldown-cmark", "memchr", "regex-lite",
                      "tree-sitter-highlight", "unicode-ident"] {
            XCTAssertTrue(text.contains("`\(crate) v"),
                          "rust attribution is missing '\(crate)'")
        }
        // The list is real (generated), not a stub: every entry carries a
        // license expression.
        let crateLines = text.split(separator: "\n").filter { $0.hasPrefix("- `") }
        XCTAssertGreaterThan(crateLines.count, 30,
                             "the generated closure should list dozens of crates")
        XCTAssertTrue(crateLines.allSatisfy { $0.contains(" — ") },
                      "every crate line must name its license")
    }

    /// The other half of the ship-blocker: the generator's header always
    /// CLAIMED build-app.sh copies the file into the bundle, but no such cp
    /// existed — every assembled .app shipped with zero attribution. Pin the
    /// copy (and its hard-fail) so it can't silently vanish again.
    func test_buildScript_bundlesTheNoticesFile() throws {
        let script = try String(
            contentsOf: packageRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8)
        XCTAssertTrue(
            script.contains("Resources/THIRD_PARTY_NOTICES.md"),
            "build-app.sh must copy THIRD_PARTY_NOTICES.md into Contents/Resources")
        XCTAssertTrue(
            script.contains("cannot assemble a legally"),
            "a missing notices file must FAIL the build, not skip the copy")
    }
}
