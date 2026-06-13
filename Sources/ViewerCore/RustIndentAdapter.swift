import Foundation
import RustCore

/// Indentation detection, served by the Rust core (`mdvcore_indent_detect`).
///
/// TSK-649 Stage B #1: the Swift `IndentDetector` twin has been DELETED. After
/// a quiet default-ON soak (Stage A), the gate, the env var, and the Swift
/// fallback all retire — this is now a direct, rust-only call. A bridge fault
/// can no longer silently fall back to Swift, so it degrades to the `"—"`
/// "no/unknown indent" sentinel (the same value the engine returns for an
/// un-indented file — a safe, non-crashing status-bar value) and is made LOUD
/// on the `rust-core` Obs channel (surfaced by the TSK-636 audit log) rather
/// than masked. The indent ABI capability bit stays required of the linked core
/// (`CoreCapabilities.requiredByShippingAdapters`).
public enum RustIndentAdapter {

    /// "No/unknown indentation" — the engine's own sentinel for an un-indented
    /// file, reused as the safe degraded value on a (now-unexpected) bridge fault.
    public static let unknown = "—"

    /// Detect the indentation style of `text` via the Rust core. Returns
    /// `unknown` (and logs) if the core call faults.
    public static func detect(in text: String, sampleLines: Int = 50) -> String {
        do {
            return try mdvCoreIndentDetect(text: text, sampleLines: sampleLines)
        } catch {
            Obs.shared.emit(
                .error, "rust-core",
                "indent detect faulted (no Swift fallback remains): \(error)",
                fields: ["capability": "indent"])
            return unknown
        }
    }
}
