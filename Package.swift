// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownViewer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ViewerKit", targets: ["ViewerKit"]),
        .library(name: "ViewerCore", targets: ["ViewerCore"]),
        .library(name: "ViewerUI", targets: ["ViewerUI"]),
        .executable(name: "MarkdownViewer", targets: ["MarkdownViewer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.3.0"),
        // Spike-only: TreeSitter binding + one grammar to validate
        // (a) Swift 6 strict-concurrency clean build, (b) binary-size
        // delta, (c) cold-build-time delta. Both pull-throughs (the
        // ChimeHQ URL is the canonical URL in the json grammar's
        // Package.swift; GitHub redirects to the new tree-sitter org).
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter",               from: "0.9.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json",          from: "0.24.0"),
        // alex-pinkus' main branch ships only grammar.json — parser.c
        // lives on the `with-generated-files` branch (and its tagged
        // -with-generated-files variants).
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift",         branch: "with-generated-files"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-xml",  from: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python",        from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript",    from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript",    from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.4.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash",          from: "0.23.0"),
    ],
    targets: [
        // Patch targets — the upstream tree-sitter-python and
        // tree-sitter-javascript Package.swifts include `scanner.c`
        // via a `FileManager.fileExists` check evaluated against
        // SwiftPM's working directory, not the package root, so the
        // file is never added on real builds. The grammars' parser.c
        // references symbols defined in scanner.c, breaking link.
        // We vendor a copy of scanner.c + its private headers and
        // compile them ourselves so the linker resolves cleanly.
        // Delete these targets if upstream ever fixes the bug.
        .target(
            name: "CTSPatchPython",
            path: "Sources/CTSPatchPython",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "CTSPatchJavaScript",
            path: "Sources/CTSPatchJavaScript",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(name: "ViewerKit"),
        .target(
            name: "ViewerCore",
            dependencies: [
                "ViewerKit",
                .product(name: "Markdown",                package: "swift-markdown"),
                .product(name: "SwiftTreeSitter",         package: "SwiftTreeSitter"),
                .product(name: "TreeSitterJSON",          package: "tree-sitter-json"),
                .product(name: "TreeSitterSwift",         package: "tree-sitter-swift"),
                .product(name: "TreeSitterXML",           package: "tree-sitter-xml"),
                .product(name: "TreeSitterPython",        package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript",    package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript",    package: "tree-sitter-typescript"),
                // Single product includes both TreeSitterMarkdown (block)
                // and TreeSitterMarkdownInline (inline) target modules. We
                // import the block one for now; inline injection is a v1.5
                // polish item once SwiftTreeSitterLayer is wired.
                .product(name: "TreeSitterMarkdown",      package: "tree-sitter-markdown"),
                .product(name: "TreeSitterBash",          package: "tree-sitter-bash"),
                "CTSPatchPython",
                "CTSPatchJavaScript",
            ],
            // Vendored highlight queries (one per supported language).
            // We copy these into the repo (per design doc decision C)
            // so an upstream grammar's .scm rename can't silently break
            // our highlighting.
            resources: [.copy("Highlight/Queries")]
        ),
        .target(
            name: "ViewerUI",
            dependencies: ["ViewerKit", "ViewerCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MarkdownViewer",
            dependencies: ["ViewerKit", "ViewerCore", "ViewerUI"]
        ),
        .testTarget(name: "ViewerKitTests", dependencies: ["ViewerKit"]),
        .testTarget(
            name: "ViewerCoreTests",
            dependencies: [
                "ViewerCore",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterJSON",  package: "tree-sitter-json"),
            ]
        ),
        .testTarget(
            name: "ViewerUITests",
            dependencies: ["ViewerUI", "ViewerCore", "ViewerKit"]
        ),
    ]
)
