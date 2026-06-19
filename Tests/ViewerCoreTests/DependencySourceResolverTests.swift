import XCTest
@testable import ViewerCore

/// Coverage for the crate→github path-tracing core (TSK-692): resolving a
/// normalized `DependencyPackage` to the registry / docs / download / repo URLs
/// you'd hit to obtain its source. Pure logic, network-free — these pin the URL
/// construction, version-pinning, repository-URL normalization, and graceful
/// degradation. The fetch + cache + sourceview UI are later, VM-validated slices.
final class DependencySourceResolverTests: XCTestCase {

    // MARK: - Cargo resolution

    func test_cargo_pinnedVersion_resolvesAllStaticURLs() {
        let pkg = DependencyPackage(name: "serde", version: "1.0.0", kind: .direct, source: .cargo)
        let s = DependencySourceResolver.resolve(pkg)

        XCTAssertEqual(s.name, "serde")
        XCTAssertEqual(s.source, .cargo)
        XCTAssertEqual(s.registryMetadataURL?.absoluteString,
                       "https://crates.io/api/v1/crates/serde")
        XCTAssertEqual(s.registryPageURL?.absoluteString,
                       "https://crates.io/crates/serde")
        XCTAssertEqual(s.documentationURL?.absoluteString,
                       "https://docs.rs/serde/1.0.0")
        XCTAssertEqual(s.tarballURL?.absoluteString,
                       "https://static.crates.io/crates/serde/serde-1.0.0.crate")
        // Registry deps carry no manifest repo URL — that's traced via metadata.
        XCTAssertNil(s.repositoryURL)
    }

    func test_cargo_rangeVersion_noTarball_docsUnversioned() {
        // A caret range can't name a single artifact; tarball must be nil and
        // docs.rs falls back to the unversioned page.
        let pkg = DependencyPackage(name: "tokio", version: "^1.35", kind: .direct, source: .cargo)
        let s = DependencySourceResolver.resolve(pkg)
        XCTAssertNil(s.tarballURL)
        XCTAssertEqual(s.documentationURL?.absoluteString, "https://docs.rs/tokio")
        XCTAssertEqual(s.registryMetadataURL?.absoluteString,
                       "https://crates.io/api/v1/crates/tokio")
    }

    func test_cargo_nilVersion_noTarball() {
        let pkg = DependencyPackage(name: "anyhow", version: nil, kind: .direct, source: .cargo)
        let s = DependencySourceResolver.resolve(pkg)
        XCTAssertNil(s.tarballURL)
        XCTAssertEqual(s.documentationURL?.absoluteString, "https://docs.rs/anyhow")
    }

    func test_cargo_gitDependency_repositoryURLNormalized() {
        // A Cargo git dep carries its repo URL directly — traceable with NO
        // network round-trip.
        let pkg = DependencyPackage(name: "foo", version: nil, kind: .direct,
                                    source: .cargo,
                                    repository: "https://github.com/owner/foo.git")
        let s = DependencySourceResolver.resolve(pkg)
        XCTAssertEqual(s.repositoryURL?.absoluteString, "https://github.com/owner/foo")
    }

    // MARK: - npm resolution

    func test_npm_pinnedVersion_resolvesRegistryAndTarball() {
        let pkg = DependencyPackage(name: "react", version: "18.2.0", kind: .direct, source: .npm)
        let s = DependencySourceResolver.resolve(pkg)
        XCTAssertEqual(s.registryMetadataURL?.absoluteString,
                       "https://registry.npmjs.org/react")
        XCTAssertEqual(s.registryPageURL?.absoluteString,
                       "https://www.npmjs.com/package/react")
        XCTAssertEqual(s.tarballURL?.absoluteString,
                       "https://registry.npmjs.org/react/-/react-18.2.0.tgz")
        // npm has no universal docs site.
        XCTAssertNil(s.documentationURL)
    }

    func test_npm_scopedPackage_keepsScopeInPath_bareNameInTarball() {
        let pkg = DependencyPackage(name: "@babel/core", version: "7.0.0", kind: .dev, source: .npm)
        let s = DependencySourceResolver.resolve(pkg)
        XCTAssertEqual(s.registryMetadataURL?.absoluteString,
                       "https://registry.npmjs.org/@babel/core")
        XCTAssertEqual(s.registryPageURL?.absoluteString,
                       "https://www.npmjs.com/package/@babel/core")
        // Scoped tarball file uses the BARE package name, dir keeps the scope.
        XCTAssertEqual(s.tarballURL?.absoluteString,
                       "https://registry.npmjs.org/@babel/core/-/core-7.0.0.tgz")
    }

    func test_npm_rangeVersion_noTarball() {
        let pkg = DependencyPackage(name: "lodash", version: "^4.17.21", kind: .direct, source: .npm)
        let s = DependencySourceResolver.resolve(pkg)
        XCTAssertNil(s.tarballURL)
        XCTAssertEqual(s.registryMetadataURL?.absoluteString,
                       "https://registry.npmjs.org/lodash")
    }

    // MARK: - Pinned-version detection

    func test_pinnedVersion_acceptsExactForms() {
        XCTAssertEqual(DependencySourceResolver.pinnedVersion("1.2.3"), "1.2.3")
        XCTAssertEqual(DependencySourceResolver.pinnedVersion("=1.2.3"), "1.2.3")   // Cargo exact
        XCTAssertEqual(DependencySourceResolver.pinnedVersion("v1.2.3"), "1.2.3")   // tag-style
        XCTAssertEqual(DependencySourceResolver.pinnedVersion(" 1.2.3 "), "1.2.3")  // whitespace
        XCTAssertEqual(DependencySourceResolver.pinnedVersion("1.2.3-beta.1"), "1.2.3-beta.1")
    }

    func test_pinnedVersion_rejectsRangesAndWildcards() {
        for range in ["^1.2.3", "~1.2", ">=1.0", "<2", "1.*", "1.x", "*",
                      "latest", ">= 1, < 2", "1.0 || 2.0", ""] {
            XCTAssertNil(DependencySourceResolver.pinnedVersion(range),
                         "\(range) should not be treated as a pinned version")
        }
        XCTAssertNil(DependencySourceResolver.pinnedVersion(nil))
    }

    // MARK: - Repository URL normalization

    func test_repositoryURL_normalizesGitRemoteSpellings() {
        let cases: [(String, String?)] = [
            ("https://github.com/o/r.git",        "https://github.com/o/r"),
            ("https://github.com/o/r",            "https://github.com/o/r"),
            ("https://github.com/o/r/",           "https://github.com/o/r"),
            ("git+https://github.com/o/r.git",    "https://github.com/o/r"),
            ("git://github.com/o/r.git",          "https://github.com/o/r"),
            ("ssh://git@github.com/o/r.git",      "https://github.com/o/r"),
            ("git@github.com:o/r.git",            "https://github.com/o/r"),
            ("git@gitlab.com:group/sub/repo.git", "https://gitlab.com/group/sub/repo"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DependencySourceResolver.normalizedRepositoryURL(input)?.absoluteString,
                           expected, "failed normalizing \(input)")
        }
    }

    func test_repositoryURL_rejectsEmptyAndNonWeb() {
        XCTAssertNil(DependencySourceResolver.normalizedRepositoryURL(nil))
        XCTAssertNil(DependencySourceResolver.normalizedRepositoryURL(""))
        XCTAssertNil(DependencySourceResolver.normalizedRepositoryURL("   "))
        // A bare local path is not a browsable repo URL.
        XCTAssertNil(DependencySourceResolver.normalizedRepositoryURL("../local/path"))
    }

    // MARK: - Graceful degradation

    func test_emptyName_degradesToNilURLs() {
        let pkg = DependencyPackage(name: "", version: "1.0.0", kind: .direct, source: .cargo)
        let s = DependencySourceResolver.resolve(pkg)
        XCTAssertNil(s.registryMetadataURL)
        XCTAssertNil(s.registryPageURL)
        XCTAssertNil(s.documentationURL)
        XCTAssertNil(s.tarballURL)
    }

    func test_nameWithSpaces_isPercentEncoded_notBroken() {
        // A pathological name shouldn't yield an invalid URL string.
        let pkg = DependencyPackage(name: "weird name", version: nil, kind: .direct, source: .cargo)
        let s = DependencySourceResolver.resolve(pkg)
        XCTAssertEqual(s.registryPageURL?.absoluteString,
                       "https://crates.io/crates/weird%20name")
    }

    // MARK: - Manifest-level resolution

    func test_resolveManifest_preservesPackageOrder() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "root"

        [dependencies]
        serde = "1.0.0"
        tokio = "1.35.0"
        """)
        let sources = DependencySourceResolver.resolve(m)
        XCTAssertEqual(sources.map(\.name), ["serde", "tokio"])
        XCTAssertEqual(sources[0].tarballURL?.absoluteString,
                       "https://static.crates.io/crates/serde/serde-1.0.0.crate")
    }

    // MARK: - Parser: git repository capture (the manifest-side path trace)

    func test_parser_cargoInlineGitDep_capturesRepository() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"

        [dependencies]
        mycrate = { git = "https://github.com/owner/mycrate" }
        """)
        let dep = m.packages.first(where: { $0.name == "mycrate" })
        XCTAssertEqual(dep?.repository, "https://github.com/owner/mycrate")
        XCTAssertNil(dep?.version)
        // End-to-end: parser → resolver yields a clean repo URL.
        let s = DependencySourceResolver.resolve(dep!)
        XCTAssertEqual(s.repositoryURL?.absoluteString, "https://github.com/owner/mycrate")
    }

    func test_parser_cargoSubTableGitDep_capturesRepository() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"

        [dependencies.othercrate]
        git = "https://github.com/owner/othercrate.git"
        branch = "main"
        """)
        let dep = m.packages.first(where: { $0.name == "othercrate" })
        XCTAssertEqual(dep?.repository, "https://github.com/owner/othercrate.git")
        let s = DependencySourceResolver.resolve(dep!)
        XCTAssertEqual(s.repositoryURL?.absoluteString, "https://github.com/owner/othercrate")
    }

    func test_parser_cargoRegistryDep_noRepository() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"

        [dependencies]
        serde = "1.0"
        tokio = { version = "1.35", features = ["full"] }
        """)
        XCTAssertNil(m.packages.first(where: { $0.name == "serde" })?.repository)
        XCTAssertNil(m.packages.first(where: { $0.name == "tokio" })?.repository)
    }
}
