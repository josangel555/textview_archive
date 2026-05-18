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
    public enum Grammar: String, Sendable, CaseIterable {
        case xml
        case python
        case javascript
        case typescript
        case bash
        case java
        case c
        case cpp
        case cSharp
        case rust
        case lua

        /// The `tree_sitter_<name>` C symbol exposed by the upstream
        /// grammar. Most are the obvious lowercased identifier; two
        /// canonical exceptions (`cpp`, `c_sharp`) come from the
        /// grammar authors' naming conventions and are not aliases we
        /// invent.
        var cSymbol: String {
            switch self {
            case .xml:        return "tree_sitter_xml"
            case .python:     return "tree_sitter_python"
            case .javascript: return "tree_sitter_javascript"
            case .typescript: return "tree_sitter_typescript"
            case .bash:       return "tree_sitter_bash"
            case .java:       return "tree_sitter_java"
            case .c:          return "tree_sitter_c"
            case .cpp:        return "tree_sitter_cpp"
            case .cSharp:     return "tree_sitter_c_sharp"
            case .rust:       return "tree_sitter_rust"
            case .lua:        return "tree_sitter_lua"
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
            case .python:     return "libTreeSitterPythonLazy"
            case .javascript: return "libTreeSitterJavaScriptLazy"
            case .typescript: return "libTreeSitterTypeScriptLazy"
            case .bash:       return "libTreeSitterBashLazy"
            case .java:       return "libTreeSitterJavaLazy"
            case .c:          return "libTreeSitterCLazy"
            case .cpp:        return "libTreeSitterCPPLazy"
            case .cSharp:     return "libTreeSitterCSharpLazy"
            case .rust:       return "libTreeSitterRustLazy"
            case .lua:        return "libTreeSitterLuaLazy"
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
    public static func _resetForTesting() {
        Locked.lock.lock()
        Locked.cache.removeAll()
        Locked.failed.removeAll()
        Locked.lock.unlock()
    }

    /// Test hook — pre-seed the cache with a `Language` resolved by
    /// the caller (typically a statically-linked grammar in tests
    /// where we can't ship a dylib). Production code never calls this.
    public static func _injectForTesting(_ grammar: Grammar, language: Language) {
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

        // 3. Same dir as the executable (raw `swift run` / `swift test`
        // where SwiftPM drops product dylibs into `.build/<config>/`).
        if let exe = Bundle.main.executablePath {
            let exeDir = (exe as NSString).deletingLastPathComponent
            let candidate = (exeDir as NSString).appendingPathComponent(basename)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // 4. Env-var override (CI / debugging).
        if let dir = ProcessInfo.processInfo.environment["GRAMMAR_DYLIB_DIR"] {
            let candidate = (dir as NSString).appendingPathComponent(basename)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        // Single-line stderr log — quiet by default but greppable.
        // We deliberately don't use `os_log` because this code runs
        // inside both the app and the xctest harness; the latter
        // routes os_log to a separate stream that's harder to capture.
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
