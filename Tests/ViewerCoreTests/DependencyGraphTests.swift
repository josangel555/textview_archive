import CoreGraphics
import XCTest
@testable import ViewerCore

final class DependencyGraphTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepGraph-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func write(_ path: String, _ contents: String) -> URL {
        let url = tmpDir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Swift import parsing

    func test_parse_swift_imports_variants() {
        let src = """
        import Foundation
        @testable import ViewerCore
        import struct SwiftUI.Color
        import os.log
        // import CommentedOut
        let x = 1
        """
        let imps = DependencyGraph.parseImports(src, language: .swift)
        let modules = imps.map(\.module)
        XCTAssertEqual(modules, ["Foundation", "ViewerCore", "SwiftUI", "os"])
        XCTAssertFalse(modules.contains("CommentedOut"))
    }

    // MARK: - Python import parsing

    func test_parse_python_imports() {
        let src = """
        import os
        import sys, json
        import numpy as np
        from collections import OrderedDict
        from . import sibling
        from .pkg import thing
        # import skipme
        """
        let imps = DependencyGraph.parseImports(src, language: .python)
        let modules = imps.map(\.module)
        XCTAssertTrue(modules.contains("os"))
        XCTAssertTrue(modules.contains("sys"))
        XCTAssertTrue(modules.contains("json"))
        XCTAssertTrue(modules.contains("numpy"))
        XCTAssertTrue(modules.contains("collections"))
        // relative imports carry a relativePath
        XCTAssertTrue(imps.contains { $0.module == "sibling" && $0.relativePath != nil }
            || imps.contains { $0.module == "pkg" && $0.relativePath != nil })
        XCTAssertFalse(modules.contains("skipme"))
    }

    // MARK: - JS/TS import parsing

    func test_parse_js_imports_named_bare_and_require() {
        let src = """
        import React from 'react'
        import { foo } from "./util"
        import '../styles/side-effect'
        const lib = require('lodash/fp')
        export { x } from '@scope/pkg/sub'
        """
        let imps = DependencyGraph.parseImports(src, language: .javascript)
        // react → external (bare)
        XCTAssertTrue(imps.contains { $0.module == "react" && $0.relativePath == nil })
        // ./util → relative
        XCTAssertTrue(imps.contains { $0.relativePath == "./util" })
        // ../styles/side-effect → relative, module = last component
        XCTAssertTrue(imps.contains { $0.relativePath == "../styles/side-effect" })
        // lodash/fp → external, scoped to top component
        XCTAssertTrue(imps.contains { $0.module == "lodash" && $0.relativePath == nil })
        // @scope/pkg/sub → external, scope kept
        XCTAssertTrue(imps.contains { $0.module == "@scope/pkg" && $0.relativePath == nil })
    }

    // MARK: - Go / Rust import parsing

    func test_parse_go_imports() {
        let src = """
        import "fmt"
        import "github.com/owner/repo"
        """
        let modules = DependencyGraph.parseImports(src, language: .go).map(\.module)
        XCTAssertEqual(Set(modules), Set(["fmt", "github.com/owner/repo"]))
    }

    func test_parse_rust_imports() {
        let src = """
        use std::collections::HashMap;
        use crate::foo::Bar;
        extern crate serde;
        """
        let modules = DependencyGraph.parseImports(src, language: .rust).map(\.module)
        XCTAssertTrue(modules.contains("std"))
        XCTAssertTrue(modules.contains("crate"))
        XCTAssertTrue(modules.contains("serde"))
    }

    // MARK: - importGraph end-to-end resolution

    func test_importGraph_resolves_internal_swift_modules() {
        // B.swift defines a file basename `B`; A imports `B` → A→B edge.
        write("A.swift", "import B\nimport Foundation\n")
        write("B.swift", "let v = 1\n")
        let g = DependencyGraph.importGraph(root: tmpDir)

        let fileNodes = g.nodes.filter { $0.kind == .file }.map(\.label)
        XCTAssertEqual(Set(fileNodes), Set(["A.swift", "B.swift"]))

        // A.swift → B.swift internal edge present.
        let aID = g.nodes.first { $0.label == "A.swift" }!.id
        let bID = g.nodes.first { $0.label == "B.swift" }!.id
        XCTAssertTrue(g.edges.contains(DependencyGraph.Edge(from: aID, to: bID)))

        // Foundation is external.
        XCTAssertTrue(g.nodes.contains { $0.kind == .external && $0.label == "Foundation" })
        let extID = g.nodes.first { $0.label == "Foundation" }!.id
        XCTAssertTrue(g.edges.contains(DependencyGraph.Edge(from: aID, to: extID)))
    }

    func test_importGraph_resolves_js_relative_path() {
        write("src/app.js", "import { u } from './util'\nimport x from 'react'\n")
        write("src/util.js", "export const u = 1\n")
        let g = DependencyGraph.importGraph(root: tmpDir)

        let appID = g.nodes.first { $0.label == "app.js" }!.id
        let utilID = g.nodes.first { $0.label == "util.js" }!.id
        XCTAssertTrue(g.edges.contains(DependencyGraph.Edge(from: appID, to: utilID)),
                      "relative ./util should resolve to util.js")
        XCTAssertTrue(g.nodes.contains { $0.kind == .external && $0.label == "react" })
    }

    func test_importGraph_excludeExternal() {
        write("A.swift", "import Foundation\nimport B\n")
        write("B.swift", "let v = 1\n")
        var opts = DependencyGraph.Options()
        opts.includeExternal = false
        let g = DependencyGraph.importGraph(root: tmpDir, options: opts)
        XCTAssertFalse(g.nodes.contains { $0.kind == .external })
        // Internal edge survives.
        XCTAssertTrue(g.edges.contains { e in
            g.nodes.first { $0.id == e.from }?.label == "A.swift"
                && g.nodes.first { $0.id == e.to }?.label == "B.swift"
        })
    }

    func test_importGraph_skips_build_dirs() {
        write("A.swift", "import Foundation\n")
        write(".build/Generated.swift", "import Foundation\n")
        write("node_modules/pkg/index.js", "import x from 'y'\n")
        let g = DependencyGraph.importGraph(root: tmpDir)
        XCTAssertEqual(g.nodes.filter { $0.kind == .file }.count, 1)
        XCTAssertEqual(g.nodes.first { $0.kind == .file }?.label, "A.swift")
    }

    func test_importGraph_no_self_loops() {
        // A file basename equal to its own import shouldn't create a self-edge.
        write("Foo.swift", "import Foo\n")
        let g = DependencyGraph.importGraph(root: tmpDir)
        XCTAssertFalse(g.edges.contains { $0.from == $0.to })
    }

    func test_importGraph_ambiguous_name_stays_external() {
        // Two `Helpers.swift` → an `import Helpers` is ambiguous → external.
        write("a/Helpers.swift", "let x = 1\n")
        write("b/Helpers.swift", "let y = 1\n")
        write("Main.swift", "import Helpers\n")
        let g = DependencyGraph.importGraph(root: tmpDir)
        let mainID = g.nodes.first { $0.label == "Main.swift" }!.id
        // Edge target should be the external Helpers node, not a file node.
        let targets = g.edges.filter { $0.from == mainID }.map(\.to)
        XCTAssertTrue(targets.contains("ext:Helpers"))
    }

    func test_importGraph_empty_for_no_sources() {
        write("readme.md", "# hello\n")
        write("data.json", "{}\n")
        let g = DependencyGraph.importGraph(root: tmpDir)
        XCTAssertTrue(g.isEmpty)
    }

    // MARK: - Adjacency helpers

    func test_graph_dependencies_and_dependents() {
        let g = DependencyGraph.Graph(
            nodes: [
                DependencyGraph.Node(id: "a", label: "a", kind: .file),
                DependencyGraph.Node(id: "b", label: "b", kind: .file),
                DependencyGraph.Node(id: "c", label: "c", kind: .file),
            ],
            edges: [
                DependencyGraph.Edge(from: "a", to: "b"),
                DependencyGraph.Edge(from: "a", to: "c"),
                DependencyGraph.Edge(from: "b", to: "c"),
            ])
        XCTAssertEqual(Set(g.dependencies(of: "a")), Set(["b", "c"]))
        XCTAssertEqual(Set(g.dependents(of: "c")), Set(["a", "b"]))
        XCTAssertEqual(g.dependents(of: "a"), [])
    }

    // MARK: - Package manifest parsing

    func test_packageGraph_url_name_path_deps() {
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "MyApp",
            dependencies: [
                .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
                .package(name: "Local", path: "../Local"),
                .package(url: "https://github.com/foo/Bar", branch: "main"),
            ],
            targets: [ .target(name: "MyApp") ]
        )
        """
        let url = write("Package.swift", manifest)
        let g = DependencyGraph.packageGraph(manifestURL: url)

        XCTAssertEqual(g.nodes.first?.label, "MyApp")
        XCTAssertEqual(g.nodes.first?.kind, .package)

        let depLabels = g.nodes.dropFirst().map(\.label)
        XCTAssertTrue(depLabels.contains("swift-argument-parser"))
        XCTAssertTrue(depLabels.contains("Local"))
        XCTAssertTrue(depLabels.contains("Bar"))

        // root → each dep edge.
        let rootID = g.nodes.first!.id
        XCTAssertEqual(g.edges.count, 3)
        XCTAssertTrue(g.edges.allSatisfy { $0.from == rootID })
    }

    func test_parsePackageName_anchors_on_Package_call() {
        let manifest = """
        let package = Package(
            name: "RootPkg",
            targets: [ .target(name: "NotThePackageName") ]
        )
        """
        XCTAssertEqual(DependencyGraph.parsePackageName(manifest), "RootPkg")
    }

    func test_parsePackageDependencies_dedupes() {
        let manifest = """
        .package(name: "Same", from: "1.0.0")
        .package(name: "Same", from: "2.0.0")
        .package(url: "https://github.com/x/Other.git", from: "1.0.0")
        """
        let deps = DependencyGraph.parsePackageDependencies(manifest)
        XCTAssertEqual(deps, ["Same", "Other"])
    }

    func test_relativePath_strips_root_prefix() {
        let root = URL(fileURLWithPath: "/proj")
        let file = URL(fileURLWithPath: "/proj/Sources/A.swift")
        XCTAssertEqual(
            DependencyGraph.relativePath(of: file, root: root.standardizedFileURL.path),
            "Sources/A.swift")
    }
}
