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

        // Lazy-loaded TreeSitter grammar dylibs. Each wraps a single
        // upstream grammar product into a `.dynamic` library that
        // build-app.sh copies into `Contents/Frameworks/`, where
        // `GrammarLoader` dlopens it on first use. ViewerCore does
        // NOT depend on these — they're loaded at runtime by symbol.
        //
        // The wrapper-target indirection exists so SwiftPM can give us
        // a single named dylib per grammar (instead of bundling
        // multiple parser archives into one fat dylib). See
        // `Sources/TreeSitterLazyWrappers/<name>/wrapper.c` for why
        // each wrapper file does a keepalive reference to the upstream
        // `tree_sitter_<x>` symbol.
        .library(name: "TreeSitterXMLLazy",        type: .dynamic, targets: ["TreeSitterXMLLazy"]),
        .library(name: "TreeSitterPythonLazy",     type: .dynamic, targets: ["TreeSitterPythonLazy"]),
        .library(name: "TreeSitterJavaScriptLazy", type: .dynamic, targets: ["TreeSitterJavaScriptLazy"]),
        .library(name: "TreeSitterTypeScriptLazy", type: .dynamic, targets: ["TreeSitterTypeScriptLazy"]),
        .library(name: "TreeSitterBashLazy",       type: .dynamic, targets: ["TreeSitterBashLazy"]),
        // Phase 5 grammars.
        .library(name: "TreeSitterJavaLazy",       type: .dynamic, targets: ["TreeSitterJavaLazy"]),
        .library(name: "TreeSitterCLazy",          type: .dynamic, targets: ["TreeSitterCLazy"]),
        .library(name: "TreeSitterCPPLazy",        type: .dynamic, targets: ["TreeSitterCPPLazy"]),
        .library(name: "TreeSitterCSharpLazy",     type: .dynamic, targets: ["TreeSitterCSharpLazy"]),
        .library(name: "TreeSitterRustLazy",       type: .dynamic, targets: ["TreeSitterRustLazy"]),
        .library(name: "TreeSitterLuaLazy",        type: .dynamic, targets: ["TreeSitterLuaLazy"]),
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
        // Phase 5 lazy grammars. Each lives in its own
        // `.library(.dynamic)` product so ViewerCore never pays for
        // them in the executable; the runtime loader dlopens by path.
        // Canonical upstream URLs only — picked for "tree-sitter org
        // or grammars org owns it" stability, not popularity.
        .package(url: "https://github.com/tree-sitter/tree-sitter-java",          from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c",             from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp",           from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp",       from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust",          from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-lua",  from: "0.2.0"),
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
        // Same upstream Package.swift bug — tree-sitter-grammars/tree-sitter-lua
        // gates `src/scanner.c` on a `FileManager.fileExists` check
        // evaluated against SwiftPM's working dir, not the package
        // root, so the file is skipped and link fails with
        // `tree_sitter_lua_external_scanner_*` undefined. Drop this
        // target if upstream fixes the gating.
        .target(
            name: "CTSPatchLua",
            path: "Sources/CTSPatchLua",
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
                // Eager keeplist — statically linked into the executable
                // because these grammars are hot enough that first-tap
                // dylib latency would be visible (JSON: jq/settings,
                // Swift: source files, Markdown: every .md open).
                .product(name: "TreeSitterJSON",          package: "tree-sitter-json"),
                .product(name: "TreeSitterSwift",         package: "tree-sitter-swift"),
                // Single product includes both TreeSitterMarkdown (block)
                // and TreeSitterMarkdownInline (inline) target modules. We
                // import the block one for now; inline injection is a v1.5
                // polish item once SwiftTreeSitterLayer is wired.
                .product(name: "TreeSitterMarkdown",      package: "tree-sitter-markdown"),
                // Note: XML, Python, JS, TS, Bash deliberately absent
                // here — they're dlopened at runtime via GrammarLoader
                // out of Contents/Frameworks/lib<Grammar>Lazy.dylib.
                // See the `.library(.dynamic)` products below.
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
        // --- Lazy grammar wrappers ----------------------------------
        // Each wrapper target compiles a one-file C shim that holds a
        // keepalive reference to the upstream `tree_sitter_<x>` symbol
        // (defeats `-dead_strip` of the parser archive members) and
        // depends on the upstream grammar product. When SwiftPM links
        // these into their corresponding `.dynamic` library product,
        // the upstream parser.c objects are pulled into the dylib and
        // the `tree_sitter_<x>` symbol becomes a dlsym target.
        .target(
            name: "TreeSitterXMLLazy",
            dependencies: [
                .product(name: "TreeSitterXML", package: "tree-sitter-xml"),
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterXMLLazy"
        ),
        .target(
            name: "TreeSitterPythonLazy",
            dependencies: [
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                "CTSPatchPython",
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterPythonLazy"
        ),
        .target(
            name: "TreeSitterJavaScriptLazy",
            dependencies: [
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                "CTSPatchJavaScript",
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterJavaScriptLazy"
        ),
        .target(
            name: "TreeSitterTypeScriptLazy",
            dependencies: [
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterTypeScriptLazy"
        ),
        .target(
            name: "TreeSitterBashLazy",
            dependencies: [
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterBashLazy"
        ),
        .target(
            name: "TreeSitterJavaLazy",
            dependencies: [
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterJavaLazy"
        ),
        .target(
            name: "TreeSitterCLazy",
            dependencies: [
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterCLazy"
        ),
        .target(
            name: "TreeSitterCPPLazy",
            dependencies: [
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterCPPLazy"
        ),
        .target(
            name: "TreeSitterCSharpLazy",
            dependencies: [
                .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterCSharpLazy"
        ),
        .target(
            name: "TreeSitterRustLazy",
            dependencies: [
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterRustLazy"
        ),
        .target(
            name: "TreeSitterLuaLazy",
            dependencies: [
                .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
                "CTSPatchLua",
            ],
            path: "Sources/TreeSitterLazyWrappers/TreeSitterLuaLazy"
        ),

        .testTarget(name: "ViewerKitTests", dependencies: ["ViewerKit"]),
        .testTarget(
            name: "ViewerCoreTests",
            dependencies: [
                "ViewerCore",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterJSON",  package: "tree-sitter-json"),
            ]
            // Note: lazy-grammar wrapper targets deliberately NOT
            // listed here. Linking them in would (a) defeat the dlopen
            // path we want to exercise, and (b) statically pull every
            // grammar back into the test bundle. Tests that need the
            // dylibs run `swift build --product <Lazy>` first (or rely
            // on the `swift test` run-once side-effect of the prior
            // `swift build`).
        ),
        .testTarget(
            name: "ViewerUITests",
            dependencies: ["ViewerUI", "ViewerCore", "ViewerKit"]
        ),
    ]
)
