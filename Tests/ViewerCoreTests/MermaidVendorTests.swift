import XCTest
import CryptoKit
import Foundation

/// Vendor-integrity check for `mermaid.min.js`. We can't `@testable import
/// ViewerUI` from a SwiftUI-bearing target into a non-UI test target, so
/// instead of going through `Bundle.module` (which would require the test
/// to live in ViewerUITests), this test locates the source file by
/// walking up from the test bundle to the package root. That keeps the
/// check in ViewerCoreTests where the bulk of fast unit tests already
/// live, and avoids hitting the slow ViewerUITests build graph.
///
/// What this asserts:
///   1. The vendored file exists at the documented source-tree path.
///   2. Its SHA-256 matches the hash recorded in `VENDOR.md`.
///   3. It is under the 3 MB per-file ceiling (mermaid 11.x is ~2.5 MB;
///      a 3 MB ceiling catches "someone vendored a non-minified build"
///      while leaving slack for normal patch upgrades).
final class MermaidVendorTests: XCTestCase {

    /// The package root. Walks up from this source file's location until
    /// it finds `Package.swift`. Used to locate the vendored mermaid
    /// resources without requiring `Bundle.module` (which is target-scoped).
    private static func packageRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private static func resource(_ name: String) -> URL? {
        guard let root = packageRoot() else { return nil }
        return root
            .appendingPathComponent("Sources/ViewerUI/Resources/mermaid")
            .appendingPathComponent(name)
    }

    func test_vendoredBundleExists() throws {
        guard let url = Self.resource("mermaid.min.js") else {
            XCTFail("could not locate package root")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "mermaid.min.js missing at \(url.path)")
    }

    func test_vendoredBundleMatchesRecordedSHA() throws {
        guard let jsURL = Self.resource("mermaid.min.js"),
              let mdURL = Self.resource("VENDOR.md") else {
            XCTFail("could not locate vendored resources")
            return
        }

        let md = try String(contentsOf: mdURL, encoding: .utf8)
        let pattern = #"SHA-256:\s+([0-9a-fA-F]{64})"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(md.startIndex..., in: md)
        guard let m = regex.firstMatch(in: md, range: range),
              let r = Range(m.range(at: 1), in: md) else {
            XCTFail("SHA-256 not found in VENDOR.md")
            return
        }
        let recorded = md[r].lowercased()

        let data = try Data(contentsOf: jsURL)
        let digest = SHA256.hash(data: data)
        let actual = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(recorded, actual, """
            Vendored mermaid.min.js does not match the SHA recorded in VENDOR.md.
            recorded: \(recorded)
            actual:   \(actual)
            If the bundle was deliberately refreshed, update VENDOR.md.
            """)
    }

    func test_bundleSizeUnderCeiling() throws {
        guard let jsURL = Self.resource("mermaid.min.js") else {
            XCTFail("could not locate mermaid.min.js")
            return
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: jsURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 1_000_000,
            "mermaid.min.js looks suspiciously small (\(size) bytes) — incomplete download?")
        XCTAssertLessThan(size, 3_145_728,
            "mermaid.min.js exceeds 3 MB ceiling — did someone vendor a non-minified build?")
    }

    func test_licenseFileShipped() throws {
        guard let url = Self.resource("LICENSE") else {
            XCTFail("could not locate vendored LICENSE")
            return
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("MIT License"), "expected MIT License header in vendored LICENSE")
        XCTAssertTrue(text.contains("Knut Sveidqvist"), "expected upstream copyright in vendored LICENSE")
    }
}
