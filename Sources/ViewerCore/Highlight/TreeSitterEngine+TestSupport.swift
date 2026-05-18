import Foundation
import TreeSitterJSON

/// Test-support shims. Compiled into ViewerCore (not gated by
/// `#if DEBUG`) because xctest runs against the release-shaped module,
/// but the leading underscore + `_ForTesting` suffix is the project's
/// convention for "do not call from production".
extension TreeSitterEngine {
    /// Returns the statically-linked JSON grammar's `TSLanguage *`.
    /// `GrammarLoaderTests` uses this as a non-null placeholder when
    /// asserting cache behavior — it's not a substitute for the real
    /// dlopen path that ships at runtime.
    public static func _jsonLanguagePointerForTesting() -> OpaquePointer {
        return tree_sitter_json()
    }
}
