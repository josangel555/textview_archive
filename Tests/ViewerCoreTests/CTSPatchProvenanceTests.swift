import XCTest
import CryptoKit

/// Drift guard for the vendored TreeSitter external scanners.
///
/// `Sources/CTSPatch{Python,JavaScript,Lua}/scanner.c` are exact copies
/// of upstream `src/scanner.c` (the upstream Package.swift gates them
/// behind a broken `FileManager.fileExists` check — see each file's
/// PROVENANCE banner). Because they're hand-vendored rather than pulled
/// through SwiftPM, nothing else stops a stray local edit (or a silent
/// re-vendor against the wrong upstream revision) from changing parser
/// behavior with no review trail.
///
/// This test pins a SHA-256 of each file's full contents (PROVENANCE
/// banner + scanner body). Any change to a scanner.c must be a
/// deliberate re-vendor that also updates the pinned hash here in the
/// SAME commit — which is exactly the review checkpoint we want.
///
/// To re-pin after an intentional re-vendor:
///   shasum -a 256 Sources/CTSPatch*/scanner.c
/// and paste the new digests below.
final class CTSPatchProvenanceTests: XCTestCase {

    /// Vendored scanner → expected lowercase-hex SHA-256 of the file.
    private static let pinnedHashes: [(relativePath: String, sha256: String)] = [
        ("Sources/CTSPatchPython/scanner.c",
         "992edb330ddddce136dd95ac03b6b70552489bb15ab0dfc9f78bf582702ef778"),
        ("Sources/CTSPatchJavaScript/scanner.c",
         "cd3b5693248f9795ef3a14387454e92d04bbcfef1d931f54f3320bf175adbf36"),
        ("Sources/CTSPatchLua/scanner.c",
         "666d2c44632340d6be369ed7693dd01b78d243bb484bd0872a9f0cc6fb843e0d"),
    ]

    /// Package root, resolved at runtime from this file's location so it
    /// works under `swift test` regardless of the build dir.
    private static var packageRoot: URL {
        // Tests/ViewerCoreTests/CTSPatchProvenanceTests.swift → up 3.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    func test_vendored_scanners_match_pinned_hashes() throws {
        for entry in Self.pinnedHashes {
            let url = Self.packageRoot.appendingPathComponent(entry.relativePath)
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(
                hex, entry.sha256,
                """
                Vendored scanner \(entry.relativePath) drifted from its \
                pinned hash. If this was a deliberate re-vendor, update \
                its PROVENANCE banner (upstream revision/license) AND the \
                pinned digest in CTSPatchProvenanceTests.pinnedHashes in \
                the same commit. Otherwise revert the edit — these files \
                must stay byte-identical to the pinned upstream revision.
                """
            )
        }
    }

    /// Sanity: each vendored scanner carries a PROVENANCE banner naming
    /// its upstream source, pinned revision, and MIT license. Catches a
    /// future re-vendor that drops the attribution header.
    func test_vendored_scanners_carry_provenance_banner() throws {
        for entry in Self.pinnedHashes {
            let url = Self.packageRoot.appendingPathComponent(entry.relativePath)
            let src = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(src.contains("PROVENANCE"),
                          "\(entry.relativePath) is missing its PROVENANCE banner")
            XCTAssertTrue(src.contains("Revision:"),
                          "\(entry.relativePath) PROVENANCE banner must pin an upstream Revision")
            XCTAssertTrue(src.contains("License:"),
                          "\(entry.relativePath) PROVENANCE banner must state the License")
        }
    }
}
