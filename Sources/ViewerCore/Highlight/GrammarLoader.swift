import Foundation
import SwiftTreeSitter
import ViewerKit

/// Runtime loader for TreeSitter grammar dylibs shipped under
/// `Contents/Frameworks/` in the app bundle. The main executable does
/// not statically link these grammars; we resolve them on first use via
/// `dlopen` + `dlsym` and cache the resulting `Language` value.
///
/// Three motivations:
///   1. Bundle size — the app's most-used languages (JSON / Swift /
///      Markdown) stay statically linked (the "eager keeplist"); the
///      rest move to dylibs the user only pays for when they open that
///      file type.
///   2. Cold-start memory — at process start the kernel only maps the
///      eager keeplist's parser tables. A user who never opens a
///      `.rs` file never resident-maps the Rust grammar.
///   3. Headroom for new grammars — adding Java/C/C++/etc. doesn't
///      blow the bundle-size cap because their cost is paid lazily.
///
/// Failure semantics are deliberately quiet: every public entry point
/// returns `nil` on failure (missing dylib, dlopen error, missing
/// symbol). Highlighting is best-effort decoration; a missing dylib
/// falls back to plain text and surfaces a single log line.
///
/// Thread-safety: an `NSLock` guards both caches. Lock is held only
/// across hash lookups — the `dlopen` call itself happens outside the
/// lock so a slow first-touch on one language can't block another.
public enum GrammarLoader {

    /// Identifier for a TreeSitter grammar. We don't reuse
    /// `HighlightLanguage` here because the loader is one layer below
    /// — it knows nothing about file extensions, code-fence detection,
    /// or the eager-vs-lazy split. The `HighlightLanguage` ↔ `Grammar`
    /// mapping lives in `TreeSitterEngine`.
    ///
    /// TSK-854: the grammar set is now exactly what code-FOLDS + structural
    /// search need (highlighting is rust-only — no Swift grammar fallback).
    /// The 8 highlight-only grammars (python, bash, java, c, cpp, c#, rust,
    /// lua) and their dylibs were removed to reclaim the ~16 MB double-carry.
    public enum Grammar: String, Sendable, CaseIterable {
        case xml
        case javascript
        case typescript
        /// JSX-aware TypeScript. Ships in the SAME dylib as `.typescript`
        /// (`tree-sitter-typescript` bundles both `typescript/parser.c`
        /// and `tsx/parser.c`), so `dylibBasename` points at the shared
        /// `libTreeSitterTypeScriptLazy`; only the `cSymbol` differs.
        /// The wrapper keeps an explicit `tree_sitter_tsx` keepalive so
        /// `-dead_strip` can't prune the symbol — see the lazy wrapper's
        /// `wrapper.c`.
        case tsx

        /// The `tree_sitter_<name>` C symbol exposed by the upstream grammar.
        var cSymbol: String {
            switch self {
            case .xml:        return "tree_sitter_xml"
            case .javascript: return "tree_sitter_javascript"
            case .typescript: return "tree_sitter_typescript"
            case .tsx:        return "tree_sitter_tsx"
            }
        }

        /// Filename (no path, no extension) of the dylib in
        /// `Contents/Frameworks/`. SwiftPM emits dynamic-library
        /// products as `lib<ProductName>.dylib` on macOS; we mirror
        /// that convention here so the copy step in `build-app.sh`
        /// can find each file by glob.
        var dylibBasename: String {
            switch self {
            case .xml:        return "libTreeSitterXMLLazy"
            case .javascript: return "libTreeSitterJavaScriptLazy"
            case .typescript: return "libTreeSitterTypeScriptLazy"
            // tsx ships in the typescript dylib — same file, both symbols.
            case .tsx:        return "libTreeSitterTypeScriptLazy"
            }
        }
    }

    // MARK: - Public API

    /// Load a `Language` for `grammar`. Returns `nil` if the dylib is
    /// missing, fails to dlopen, or doesn't export the expected symbol.
    /// First call performs the dlopen; subsequent calls hit the cache.
    public static func load(_ grammar: Grammar) -> Language? {
        Locked.lock.lock()
        if let cached = Locked.cache[grammar] {
            Locked.lock.unlock()
            return cached
        }
        if Locked.failed.contains(grammar) {
            Locked.lock.unlock()
            return nil
        }
        Locked.lock.unlock()

        // dlopen outside the lock — first-touch for one grammar must
        // not stall first-touch for another. Worst case two threads
        // both dlopen the same grammar; dlopen returns the same handle
        // (reference-counted), the symbol pointer is identical, and we
        // simply overwrite an equivalent cache entry below.
        guard let language = resolve(grammar) else {
            Locked.lock.lock()
            Locked.failed.insert(grammar)
            Locked.lock.unlock()
            return nil
        }

        Locked.lock.lock()
        Locked.cache[grammar] = language
        Locked.lock.unlock()
        return language
    }

    /// Test hook — clears the cache so tests can re-exercise the
    /// dlopen path between runs. Production code never calls this.
    /// `internal` (not `public`): tests reach it via `@testable import`
    /// so it never widens ViewerCore's public API surface. See
    /// LESSONS.md "internal-for-testing hooks".
    static func _resetForTesting() {
        Locked.lock.lock()
        Locked.cache.removeAll()
        Locked.failed.removeAll()
        Locked.lock.unlock()
    }

    /// Test hook — pre-seed the cache with a `Language` resolved by
    /// the caller (typically a statically-linked grammar in tests
    /// where we can't ship a dylib). Production code never calls this.
    /// `internal` (not `public`): see `_resetForTesting`.
    static func _injectForTesting(_ grammar: Grammar, language: Language) {
        Locked.lock.lock()
        Locked.cache[grammar] = language
        Locked.lock.unlock()
    }

    // MARK: - dlopen resolution

    private static func resolve(_ grammar: Grammar) -> Language? {
        guard let path = dylibPath(for: grammar) else {
            log("grammar dylib not found for \(grammar.rawValue)")
            return nil
        }
        // RTLD_LAZY: we only need one symbol (tree_sitter_<name>);
        // resolve other lazily-bound references on demand. RTLD_LOCAL:
        // prevent grammar symbols from leaking into the global
        // namespace where two grammars' duplicate static helpers could
        // collide (every parser.c defines functions like
        // `ts_parser_eq_subtree` with the same name).
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown"
            log("dlopen failed for \(grammar.rawValue) at \(path): \(err)")
            return nil
        }
        // Note: we intentionally never `dlclose`. Grammar pointers
        // returned by `tree_sitter_<name>` reference static const data
        // inside the dylib's __DATA segment; closing the handle would
        // unmap that and crash subsequent parses. We hold the handle
        // for process lifetime, matching how a statically linked
        // grammar would behave.
        guard let symbol = dlsym(handle, grammar.cSymbol) else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown"
            log("dlsym \(grammar.cSymbol) failed in \(path): \(err)")
            return nil
        }
        // `tree_sitter_<name>` is a `const TSLanguage *(void)` — call
        // it through a function pointer to obtain the language handle.
        typealias TSLanguageFn = @convention(c) () -> OpaquePointer?
        let fn = unsafeBitCast(symbol, to: TSLanguageFn.self)
        guard let langPtr = fn() else {
            log("\(grammar.cSymbol) returned NULL")
            return nil
        }
        return Language(language: langPtr)
    }

    /// Resolve the dylib path for a grammar. Search order:
    ///   1. `Bundle.main`'s `Contents/Frameworks/` — production case.
    ///   2. The executable's own `Frameworks` sibling — useful for
    ///      raw `swift run` smoke tests where there's no .app bundle.
    ///   3. `.build/<config>/` next to the test binary — host-side
    ///      tests run from `swift test` where dylibs land alongside
    ///      the xctest harness.
    ///   4. `GRAMMAR_DYLIB_DIR` env var — explicit override for CI.
    private static func dylibPath(for grammar: Grammar) -> String? {
        let basename = grammar.dylibBasename + ".dylib"

        // 0. Env-var override — when set, this is the ONLY path we
        // check. Lets tests force-resolve against a specific dir
        // (or force-not-resolve by pointing at an empty one) without
        // the auto-search fallbacks below kicking in. Was previously
        // a last-resort fallback, which made the "missing dylib"
        // contract untestable on host (SwiftPM auto-builds dylibs
        // into `.build/<config>/` next to the xctest bundle).
        if let dir = ProcessInfo.processInfo.environment["GRAMMAR_DYLIB_DIR"] {
            let candidate = (dir as NSString).appendingPathComponent(basename)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            return nil
        }

        // 1. App-bundle Frameworks dir.
        if let frameworks = Bundle.main.privateFrameworksPath {
            let candidate = (frameworks as NSString).appendingPathComponent(basename)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // 2. Sibling of executable (Contents/MacOS → ../Frameworks).
        if let exe = Bundle.main.executablePath {
            let exeDir = (exe as NSString).deletingLastPathComponent
            let frameworksGuess = (exeDir as NSString)
                .deletingLastPathComponent
            let candidate = ((frameworksGuess as NSString)
                .appendingPathComponent("Frameworks") as NSString)
                .appendingPathComponent(basename)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // 3. Same dir as the executable (raw `swift run` where
        // SwiftPM drops product dylibs into `.build/<config>/`).
        if let exe = Bundle.main.executablePath {
            let exeDir = (exe as NSString).deletingLastPathComponent
            let candidate = (exeDir as NSString).appendingPathComponent(basename)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // 3b. xctest bundle layout: `.build/<arch>/<config>/Foo.xctest/
        // Contents/MacOS/Foo`. Walk three levels up from the executable
        // to land in `.build/<arch>/<config>/`, where SwiftPM emits
        // dynamic-library products. This is how `swift test` finds the
        // grammars without needing `GRAMMAR_DYLIB_DIR` set. We anchor
        // on the executable rather than Bundle.main so the search is
        // robust when xctest is loaded as a plugin and Bundle.main
        // reports Xcode (host process) instead of the test bundle.
        if let exe = Bundle.main.executablePath {
            var dir = (exe as NSString).deletingLastPathComponent
            for _ in 0..<3 { dir = (dir as NSString).deletingLastPathComponent }
            let candidate = (dir as NSString).appendingPathComponent(basename)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // 3c. xctest with non-app-style Bundle.main: anchor on the
        // class bundle path instead. This matches both
        // `Bundle(for: ...)` and `Bundle.allBundles` patterns and is
        // the path actually used in unit-test runs where Bundle.main
        // resolves to /Applications/Xcode.app/.../xctest.
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            let dir = (bundle.bundlePath as NSString).deletingLastPathComponent
            let candidate = (dir as NSString).appendingPathComponent(basename)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // (Env-var override is checked first — see step 0 at the top.)

        return nil
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        // Route to the unified observability sink (subsystem "grammar").
        // The sink ring-buffers the event and only fans out to os_log if
        // the app explicitly configured that fan-out.
        Obs.shared.emit(.warn, "grammar", message)

        // Single-line stderr log — quiet by default but greppable.
        // Preserved as the PRIMARY channel: this code runs inside both
        // the app and the xctest harness, and the latter routes os_log
        // to a separate stream that's harder to capture. stderr stays
        // the reliable capture path regardless of sink configuration.
        FileHandle.standardError.write(Data("[GrammarLoader] \(message)\n".utf8))
    }

    // MARK: - Locked state

    /// Wraps mutable state in a nested type so the public surface of
    /// `GrammarLoader` stays a pure namespace (no stored static
    /// properties leak into the public API surface review).
    private enum Locked {
        static let lock = NSLock()
        // `nonisolated(unsafe)`: every access in this file is bracketed
        // by `Locked.lock.lock()` / `.unlock()`, which is the
        // mutual-exclusion guarantee Swift 6's actor model can't
        // statically prove from inside an `enum`-namespace. Audited
        // call sites: `load`, `_resetForTesting`, `_injectForTesting`.
        nonisolated(unsafe) static var cache: [Grammar: Language] = [:]
        nonisolated(unsafe) static var failed: Set<Grammar> = []
    }
}
