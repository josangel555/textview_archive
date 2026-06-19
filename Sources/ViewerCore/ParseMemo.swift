import Foundation

/// A tiny single-slot memoizer keyed by a String (e.g. document text).
/// `resolve` recomputes only when the key changes, otherwise returns the
/// cached value. Used to stop query-independent work (e.g. re-parsing the
/// active file's headings) from running on every keystroke of an
/// incremental filter (TSK-887: command-palette `@` symbol mode re-parsed
/// the whole file per keystroke). Single-threaded use (main actor); not
/// Sendable by design.
public final class ParseMemo<Value> {
    private var key: String?
    private var value: Value

    public init(_ initial: Value) { self.value = initial }

    /// Return the cached value if `key` is unchanged since the last call;
    /// otherwise run `compute(key)`, cache it under `key`, and return it.
    public func resolve(_ key: String, _ compute: (String) -> Value) -> Value {
        if key != self.key {
            self.key = key
            self.value = compute(key)
        }
        return value
    }
}
