import XCTest

/// Tier-1 validation of `scripts/Info.plist` — checked without running the
/// build script. Keeps the plist's expected schema asserted in code so
/// drift between the bundle template and the app's expectations is caught fast.
final class InfoPlistTests: XCTestCase {

    private static var infoPlistURL: URL {
        // #filePath = .../Tests/ViewerKitTests/InfoPlistTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ViewerKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("scripts/Info.plist")
    }

    private func loadPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.infoPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else {
            throw NSError(domain: "InfoPlistTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "plist root is not a dict"])
        }
        return plist
    }

    func test_infoPlistFileExists() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Self.infoPlistURL.path),
            "expected scripts/Info.plist at \(Self.infoPlistURL.path)"
        )
    }

    func test_infoPlistIsParseable() throws {
        _ = try loadPlist()
    }

    func test_requiredScalarKeys() throws {
        let p = try loadPlist()
        XCTAssertEqual(p["CFBundleIdentifier"] as? String, "com.markdownviewer.MarkdownViewer")
        XCTAssertEqual(p["CFBundleExecutable"] as? String, "MarkdownViewer")
        XCTAssertEqual(p["CFBundleName"] as? String, "MarkdownViewer")
        XCTAssertEqual(p["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(p["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(p["NSPrincipalClass"] as? String, "NSApplication")
        XCTAssertEqual(p["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertNotNil(p["CFBundleVersion"] as? String)
        XCTAssertNotNil(p["CFBundleShortVersionString"] as? String)
        XCTAssertNotNil(p["LSApplicationCategoryType"] as? String)
    }

    func test_declaresMarkdownDocumentType() throws {
        let p = try loadPlist()
        let docTypes = p["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        XCTAssertFalse(docTypes.isEmpty, "no CFBundleDocumentTypes declared")
        let allContentTypes = docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] }
        XCTAssertTrue(allContentTypes.contains("net.daringfireball.markdown"),
                      "missing net.daringfireball.markdown; got \(allContentTypes)")
    }

    func test_declaresPlainTextDocumentType() throws {
        let p = try loadPlist()
        let docTypes = p["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let allContentTypes = docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] }
        XCTAssertTrue(allContentTypes.contains("public.plain-text"),
                      "missing public.plain-text; got \(allContentTypes)")
    }

    func test_declaresFolderDocumentType() throws {
        let p = try loadPlist()
        let docTypes = p["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let allContentTypes = docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] }
        XCTAssertTrue(allContentTypes.contains("public.folder"),
                      "missing public.folder; got \(allContentTypes)")
    }

    func test_eachDocumentTypeHasViewerRole() throws {
        let p = try loadPlist()
        let docTypes = p["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        for dt in docTypes {
            XCTAssertEqual(dt["CFBundleTypeRole"] as? String, "Viewer",
                           "document type \(dt) should declare Viewer role")
        }
    }

    func test_versionStringsLookSensible() throws {
        let p = try loadPlist()
        let short = (p["CFBundleShortVersionString"] as? String) ?? ""
        XCTAssertTrue(short.matches(#"^\d+\.\d+(\.\d+)?$"#),
                      "CFBundleShortVersionString '\(short)' is not semver-ish")
        let build = (p["CFBundleVersion"] as? String) ?? ""
        XCTAssertTrue(build.matches(#"^\d+$"#),
                      "CFBundleVersion '\(build)' should be a build number")
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
