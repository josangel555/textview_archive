import Foundation
import RustCore

/// Routes the HEX dump render through the Rust core (migration slice #4) when
/// the `.hex` gate is on, falling back to the Swift `HexDumpBuilder.buildAll`
/// otherwise — the single place the two implementations meet.
///
/// Fail-safe by construction (`RustCoreFallback`): gate off → Swift; Rust bridge
/// fault → Swift. Default-OFF; the HEX view is byte-identical to today until the
/// gate is flipped. Only the all-at-once render is routed — the chunked/streaming
/// `HexDumpBuilder.build(...onChunk:)` that fills `NSTextView` incrementally
/// stays in Swift (its callback can't cross the C boundary).
public enum RustHexAdapter {

    /// Render the whole dump for `file` at `width`, routing per the `.hex` gate.
    public static func buildAll(file: BinaryFile, width: Int) -> String {
        outcome(file: file, width: width).value
    }

    /// Same, but also reporting which engine produced the result (A/B / diag).
    public static func outcome(
        file: BinaryFile,
        width: Int,
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> CoreOutcome<String> {
        RustCoreFallback.run(
            .hex, defaults: defaults, environment: environment,
            rust: {
                try mdvCoreHexRender(
                    bytes: file.data,
                    width: width,
                    totalByteCount: file.totalByteCount,
                    isTruncated: file.isTruncated)
            },
            swift: { HexDumpBuilder.buildAll(file: file, width: width) }
        )
    }
}
