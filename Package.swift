// swift-tools-version: 6.0
import PackageDescription

// Absolute path to the Rust-core staging dir, where scripts/build-rust-core.sh
// writes libmdvcore_ffi.a (the STATICLIB — see that script for why static, not
// a dylib). Used as the linker `-L` search path; the .a is static-linked into
// the executable, so there is no runtime dylib to locate (no rpath needed).
// Context.packageDirectory is the package root, resolved at manifest-eval time
// — portable across checkouts.
let rustLinkDir = "\(Context.packageDirectory)/rust-core/link"

let package = Package(
    name: "MarkdownViewer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ViewerKit", targets: ["ViewerKit"]),
        .library(name: "ViewerCore", targets: ["ViewerCore"]),
        .library(name: "ViewerUI", targets: ["ViewerUI"]),
        // The Swift bridge over the Rust core's extern "C" boundary (in-proc
        // transport tier). Links libmdvcore_ffi.a; see rust-core/ +
        // scripts/build-rust-core.sh. A/B-able against the Swift CSVParser
        // behind the RustCSVGate feature flag (default OFF).
        .library(name: "RustCore", targets: ["RustCore"]),
        .executable(name: "MarkdownViewer", targets: ["MarkdownViewer"]),
        // Test-only helper: built on demand by `swift build --product
        // MDVFakeLSPServer` (or implicitly via `swift test`'s build
        // phase). Not in the app bundle.
        .executable(name: "MDVFakeLSPServer", targets: ["MDVFakeLSPServer"]),

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
        //
        // TSK-854: only the grammars code-FOLDS + structural search need
        // ship now — XML, JavaScript, TypeScript (tsx shares the TS dylib).
        // Highlighting is rust-only (`RustHighlightAdapter`), so the 8
        // highlight-only grammar dylibs (python, bash, java, c, cpp, c#,
        // rust, lua) were removed — the ~16 MB double-carry reclaim.
        .library(name: "TreeSitterXMLLazy",        type: .dynamic, targets: ["TreeSitterXMLLazy"]),
        .library(name: "TreeSitterJavaScriptLazy", type: .dynamic, targets: ["TreeSitterJavaScriptLazy"]),
        .library(name: "TreeSitterTypeScriptLazy", type: .dynamic, targets: ["TreeSitterTypeScriptLazy"]),
    ],
    dependencies: [
        // Pinned to the 0.8.x minor (the currently-resolved version).
        // swift-markdown is pre-1.0, so `from:` would let SwiftPM walk
        // to any future 0.x that bumps an arbitrary amount of API;
        // `.upToNextMinor` caps the drift to patch releases of 0.8.
        .package(url: "https://github.com/apple/swift-markdown.git", .upToNextMinor(from: "0.8.0")),
        // TreeSitter binding + grammars. Both pull-throughs (the ChimeHQ
        // URL is the canonical URL in the json grammar's Package.swift;
        // GitHub redirects to the new tree-sitter org).
        //
        // PIN POLICY (TSK-974): every grammar dependency is `exact:` —
        // NOT `from:`. `from:` is a caret range (SemVer: any version up
        // to the next major; for these pre-1.0 0.x packages SwiftPM
        // treats the MINOR as the major bound, so `from: "0.23.0"` would
        // silently walk to 0.24.x / 0.25.x on the next `swift package
        // update`). A parser-grammar bump can change tokenization,
        // node-kind names, and our vendored highlight `.scm` queries'
        // behavior with NO review — a supply-chain + correctness drift
        // surface. `exact:` makes every version change a deliberate,
        // reviewable one-line manifest edit (mirrors the swift-markdown
        // `.upToNextMinor` and tree-sitter-swift exact-revision intent).
        // The pinned versions are exactly what Package.resolved already
        // locked; bumping is a manual edit here + a re-resolve.
        // TSK-854: only the grammars code-FOLDS + structural search need
        // remain — json/swift/markdown (eager) + xml/javascript/typescript
        // (lazy; tsx ships in the TS grammar). Highlighting is rust-only, so
        // the 8 highlight-only grammar packages (python, bash, java, c, cpp,
        // c#, rust, lua) were dropped with their dylibs (~16 MB reclaim).
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter",               exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json",          exact: "0.24.8"),
        // alex-pinkus' main branch ships only grammar.json — parser.c
        // lives on the `with-generated-files` branch (and its tagged
        // -with-generated-files variants). We pin to an exact revision
        // rather than tracking the branch HEAD: a floating branch means
        // any push to `with-generated-files` silently rewrites our
        // generated parser on the next `swift package update`, with no
        // tag/version to review. This revision is the tip that
        // Package.resolved already locked. Re-pin deliberately (and
        // re-diff the generated parser.c) when bumping.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift",         revision: "7b7909f2f6b9414be0958275f4c8e5d69c3bca43"),
        // exact: pins (TSK-974) — see the PIN POLICY note above.
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-xml",  exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript",    exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript",    exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.3"),
    ],
    targets: [
        // Patch target — the upstream tree-sitter-javascript Package.swift
        // includes `scanner.c` via a `FileManager.fileExists` check
        // evaluated against SwiftPM's working directory, not the package
        // root, so the file is never added on real builds. The grammar's
        // parser.c references symbols defined in scanner.c, breaking link.
        // We vendor a copy of scanner.c + its private headers and compile
        // them ourselves so the linker resolves cleanly. Delete this target
        // if upstream ever fixes the bug. (TSK-854: the Python + Lua patch
        // twins went away with their grammars.)
        .target(
            name: "CTSPatchJavaScript",
            path: "Sources/CTSPatchJavaScript",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(name: "ViewerKit"),
        // --- Rust core bridge ---------------------------------------
        // systemLibrary: the cbindgen-generated C header + module map.
        // `scripts/build-rust-core.sh` builds the Rust workspace and
        // copies `mdvcore.h` here (gitignored) before any `swift build`.
        .systemLibrary(
            name: "CMdvCore",
            path: "Sources/CMdvCore"
        ),
        // The throwing Swift wrapper over the C ABI. Static-links the
        // Rust core via `-L <pkg>/rust-core/link -lmdvcore_ffi` (the .a,
        // chosen over a dylib because a load-time dylib dep of a
        // hardened-runtime self-signed exec is refused by dyld on a
        // Team-ID mismatch — see scripts/build-rust-core.sh). The link
        // dir is a deterministic in-repo path (gitignored) populated by
        // scripts/build-rust-core.sh; `unsafeFlags` is acceptable here
        // because RustCore is a leaf bridge consumed only inside this
        // package (it is NOT exported for downstream package use). The
        // shipping cross-platform setup will switch this to an
        // xcframework `binaryTarget` once the x86_64/lipo slice is built
        // (see docs/RUST_CSV_INTEGRATION.md — owner-review item).
        .target(
            name: "RustCore",
            dependencies: ["CMdvCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", rustLinkDir,
                    "-lmdvcore_ffi",
                ])
            ]
        ),
        .target(
            name: "ViewerCore",
            dependencies: [
                "ViewerKit",
                "RustCore",
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
        // Host-runnable fake LSP server used only by tests. Speaks
        // LSP framing on stdio with deterministic canned responses so
        // `LSPClient` / `LSPPool` can be exercised end-to-end without
        // sourcekit-lsp. Behavior is dialed in via env vars (see
        // `Sources/MDVFakeLSPServer/main.swift`). NOT shipped in the
        // app bundle — tests resolve the binary out of the build dir.
        .executableTarget(
            name: "MDVFakeLSPServer",
            path: "Sources/MDVFakeLSPServer"
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
        // Cross-language FFI-boundary tests + the A/B vs the Swift
        // CSVParser/CSVFilter. Headless (no UI / no NSApplication), so
        // safe on the host per CLAUDE.md testing rules. Depends on
        // ViewerCore for the Swift parity oracle.
        .testTarget(
            name: "RustCoreTests",
            dependencies: ["RustCore", "ViewerCore"]
        ),
    ]
)
