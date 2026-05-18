# TreeSitter lazy grammar loading

**Status:** Design — not yet implemented.
**Owner:** Jos. **Last update:** 2026-05-18.

## Problem

We want to expand TreeSitter from the current 8 grammars (Swift, JSON,
XML, Python, JS, TS, Markdown, Bash) to add 6 more — **Java, C, C++,
C#, Rust, Lua** (Kotlin deferred; `fwcd` fork has slow cadence). The
naive approach — `Package.swift` deps + `import TreeSitterX` —
statically links all of them into the executable, which would add
roughly **~9.8 MB** to the binary:

| Grammar | Δ binary (arm64 release) |
|---|---:|
| Java | ~1.2 MB |
| C | ~1.0 MB |
| C++ | ~3.5 MB |
| C# | ~2.0 MB |
| Rust | ~1.5 MB |
| Lua | ~0.6 MB |
| **Total** | **~9.8 MB** |

Bundle is currently ~24 MB; adding all six statically pushes it to
~34 MB, blowing the 25 MB cap enforced by
`scripts/check-bundle-size.sh`.

Worse, the eight grammars already linked account for ~22 MB of the
bundle's parser/data section — that's resident at process start
whether or not the user ever opens a `.py` or `.rs` file. The status
quo is already wasteful; this expansion just makes it acute.

## Goal

Each grammar lives in its own dylib inside `Contents/Frameworks/`.
The main executable does **not** statically link any grammar. On
first request for a language we `dlopen` its dylib and grab the
`tree_sitter_<lang>` symbol; subsequent requests hit a cache. App
launches faster, idle memory is lower, bundle stays roughly flat for
the user's actual language mix.

## Non-goals

- Plugin authoring API (users dropping in third-party grammars). That
  belongs in `docs/PLUGINS_DESIGN_v2.md` and shares plumbing with
  this but is a separate scope.
- Live grammar reload (edit `.scm`, see new highlights). Manual app
  restart is fine.

## Design

### Build-side

Each grammar becomes a SwiftPM **dynamic** library product:

```swift
.library(
    name: "TreeSitterCLazy",
    type: .dynamic,
    targets: ["TreeSitterCWrapper"]
),
.target(
    name: "TreeSitterCWrapper",
    dependencies: [
        .product(name: "TreeSitterC", package: "tree-sitter-c"),
    ],
    publicHeadersPath: "include"
)
```

The wrapper target re-exports just the `tree_sitter_c` symbol so the
dylib has a stable C ABI surface. SwiftPM's default static linkage on
the upstream `TreeSitterC` product is fine — the dynamic linkage
happens at the wrapper-product level.

`scripts/build-app.sh` then copies each generated `.dylib` into
`dist/TextView.app/Contents/Frameworks/`. The main executable gets
linked with `LD_RUNPATH_SEARCH_PATHS=@executable_path/../Frameworks`
so `dlopen("TreeSitterCLazy.dylib", RTLD_LAZY)` resolves.

### Runtime-side

New `ViewerCore/Highlight/GrammarLoader.swift`:

```swift
struct GrammarLoader {
    static func load(_ language: HighlightLanguage) -> Language? {
        // 1. cache hit?
        if let cached = cache[language] { return cached }
        // 2. resolve dylib name (.frameworkPath -> name lookup)
        guard let path = dylibPath(for: language) else { return nil }
        // 3. dlopen + dlsym
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            log("dlopen failed: \(String(cString: dlerror()))")
            return nil
        }
        guard let symbol = dlsym(handle, "tree_sitter_\(language.cName)") else {
            log("dlsym \(language) failed: \(String(cString: dlerror()))")
            return nil
        }
        // 4. Wrap into SwiftTreeSitter.Language
        let lang = Language(language: OpaquePointer(symbol))
        cache[language] = lang
        return lang
    }
}
```

`TreeSitterEngine.bundle(for:)` switches from compile-time
`TreeSitterC.tree_sitter_c()` calls to `GrammarLoader.load(.c)`.

### Eager vs lazy keeplist

A small whitelist stays statically linked because they're hot enough
that the first-tap dylib load latency is noticeable:

- JSON (used by jq integration, settings, workspaces)
- Swift (the app's own source — high recency in `BACKLOG.md`)
- Markdown (every `.md` open triggers code-fence highlighting)

The other ~11 grammars (XML, Python, JS, TS, Bash, Java, C, C++, C#,
Rust, Lua) lazy-load. First open of a `.rs` file takes one extra
~5 ms dlopen; subsequent opens are cache hits.

### Highlight queries (.scm)

Currently vendored under `Sources/ViewerCore/Highlight/Queries/`
(per the design decision noted in `Package.swift`). They stay there
— small text files, no link impact. Each query is loaded by
`TreeSitterEngine` on first language request alongside the dylib.

### Failure modes

| Failure | Behavior |
|---|---|
| dylib missing from app bundle | Fall back to no-highlight (plain text). Log once. |
| dlopen ABI mismatch with SwiftTreeSitter | Same fallback. Surface a "Highlight unavailable for <lang>" hint in the ModeBar tooltip. |
| Symbol name not `tree_sitter_<name>` | Defensive: try a couple of common aliases (`tree_sitter_cpp` for C++, `tree_sitter_c_sharp` for C#); else fallback. |

## Testing

Unit tests run in-process and need the dylibs co-located. Two paths:

1. **`testTarget` `resources:`** — declare the dylibs as test
   resources so they ship into the test bundle's
   `Contents/Resources/`. `GrammarLoader` checks both
   `Bundle.main.privateFrameworksPath` *and* the test bundle's
   resource path.
2. **Static-link in tests** — the test target statically links
   `TreeSitterC` etc. and inserts the language directly into
   `GrammarLoader`'s cache. Easier to set up; doesn't exercise dlopen.

Pick (1) so the dlopen path actually runs under test. Adds a
small build step.

## Scope estimate

- 0.5 day: design + Package.swift restructure
- 0.5 day: `GrammarLoader` + tests
- 0.5 day: build-app.sh copy step + signing
- 0.5 day: TreeSitterEngine migration + regression tests for all 8
  existing grammars
- 0.5 day: verify bundle size + smoke on VM
- **Total: ~2.5 dev days.**

Bundle after migration (estimate): ~14 MB main executable +
~30 MB total Frameworks/ — but launch reads only the eager keeplist
(~3 MB), making startup memory leaner than today.

## Open questions

- Does `LD_RUNPATH_SEARCH_PATHS` work with SwiftPM-built dylibs out
  of the box on macOS 15, or do we need an explicit `install_name_tool`
  step in build-app.sh?
- Codesign: every dylib in `Frameworks/` needs to be signed
  separately. `scripts/build-app.sh` currently signs only the main
  executable; need to extend the loop.
- Bundle-size check: `scripts/check-bundle-size.sh` currently caps
  the whole .app. After migration the *executable* is small but
  Frameworks/ is large. Reasonable cap: still 35 MB total, but
  separately enforce <15 MB on the main executable so we don't
  silently regress to static-linking.
