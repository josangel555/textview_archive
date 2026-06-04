import Foundation
import RustCore

/// Routes indentation detection through the Rust core (migration slice #7) when
/// the `.indent` gate is on, falling back to the Swift `IndentDetector`
/// otherwise — the single place the two implementations meet.
///
/// Fail-safe by construction (`RustCoreFallback`): gate off → Swift; Rust bridge
/// fault → Swift. Default-OFF.
public enum RustIndentAdapter {

    /// Detect the indentation style of `text`, routing per the `.indent` gate.
    public static func detect(in text: String, sampleLines: Int = 50) -> String {
        outcome(in: text, sampleLines: sampleLines).value
    }

    /// Same, but also reporting which engine produced the result (A/B / diag).
    public static func outcome(in text: String, sampleLines: Int = 50) -> CoreOutcome<String> {
        RustCoreFallback.run(
            .indent,
            rust: { try mdvCoreIndentDetect(text: text, sampleLines: sampleLines) },
            swift: { IndentDetector.detect(in: text, sampleLines: sampleLines) }
        )
    }
}
