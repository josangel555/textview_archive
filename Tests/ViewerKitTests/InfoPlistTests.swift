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
        // Bundle identifier stays as-is across the TextView rename so
        // TCC + LaunchServices grants survive. The executable name
        // matches the SwiftPM target. Display name is "TextView".
        XCTAssertEqual(p["CFBundleIdentifier"] as? String, "com.markdownviewer.MarkdownViewer",
                       "bundle id must stay stable so TCC grants survive renames")
        XCTAssertEqual(p["CFBundleExecutable"] as? String, "MarkdownViewer",
                       "executable name follows the SwiftPM target, not the display name")
        XCTAssertEqual(p["CFBundleName"] as? String, "TextView")
        XCTAssertEqual(p["CFBundleDisplayName"] as? String, "TextView")
        XCTAssertEqual(p["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(p["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(p["NSPrincipalClass"] as? String, "NSApplication")
        XCTAssertEqual(p["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertNotNil(p["CFBundleVersion"] as? String)
        XCTAssertNotNil(p["CFBundleShortVersionString"] as? String)
        XCTAssertNotNil(p["LSApplicationCategoryType"] as? String)
    }

    func test_appIcon_declared() throws {
        let p = try loadPlist()
        XCTAssertEqual(p["CFBundleIconFile"] as? String, "AppIcon",
                       "CFBundleIconFile must point at AppIcon.icns shipped in Resources")
        XCTAssertEqual(p["CFBundleIconName"] as? String, "AppIcon")
    }

    func test_TCC_usage_descriptions_present() throws {
        // Batch A: usage strings render in the system prompt and must
        // mention TextView so the prompt is honest to the user.
        let p = try loadPlist()
        let keys = ["NSDocumentsFolderUsageDescription",
                    "NSDesktopFolderUsageDescription",
                    "NSDownloadsFolderUsageDescription"]
        for k in keys {
            let v = p[k] as? String
            XCTAssertNotNil(v, "\(k) is required for clean TCC prompts")
            XCTAssertTrue(v!.contains("TextView"),
                          "\(k) should reference TextView, got '\(v ?? "")'")
        }
    }

    func test_services_entry_for_finder_quick_action() throws {
        // Batch C wired NSServices so Finder's right-click → Services
        // menu shows "Open in TextView". Regression-guard the schema.
        let p = try loadPlist()
        guard let services = p["NSServices"] as? [[String: Any]] else {
            return XCTFail("NSServices missing")
        }
        XCTAssertFalse(services.isEmpty)
        let openSvc = services.first(where: {
            ($0["NSMessage"] as? String) == "openInTextView"
        })
        XCTAssertNotNil(openSvc, "expected an NSMessage=openInTextView service entry")
        let menu = openSvc?["NSMenuItem"] as? [String: String]
        XCTAssertEqual(menu?["default"], "Open in TextView")
        let sendTypes = openSvc?["NSSendTypes"] as? [String]
        XCTAssertTrue(sendTypes?.contains("public.file-url") ?? false,
                      "service must accept file URLs")
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
