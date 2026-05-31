import Foundation
import TreeSitterJSON

/// Test-support shims.
///
/// Gated behind `#if DEBUG` so this `OpaquePointer`-returning C-interop
/// hook never compiles into a release build of ViewerCore — keeping a
/// raw `TSLanguage *` accessor out of the shipped binary's symbol table.
/// `swift test` builds debug, so host tests still see it. The leading
/// underscore + `_ForTesting` suffix + `internal` (reachable only via
/// `@testable import`) is the project's convention for "do not call from
/// production". See LESSONS.md "internal-for-testing hooks".
#if DEBUG
extension TreeSitterEngine {
    /// Returns the statically-linked JSON grammar's `TSLanguage *`.
    /// `GrammarLoaderTests` uses this as a non-null placeholder when
    /// asserting cache behavior — it's not a substitute for the real
    /// dlopen path that ships at runtime.
    static func _jsonLanguagePointerForTesting() -> OpaquePointer {
        return tree_sitter_json()
    }
}
#endif
