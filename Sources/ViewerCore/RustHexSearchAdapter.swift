import Foundation
import RustCore

/// Routes HEX-view byte search through the Rust core (migration slice #5) when
/// the `.hexSearch` gate is on, falling back to the Swift `HexSearchEngine`
/// otherwise — the single place the two implementations meet.
///
/// Fail-safe by construction (`RustCoreFallback`): gate off → Swift; Rust bridge
/// fault → Swift. Default-OFF. Routes `search` (parse + non-overlapping find);
/// the cheap single-byte click-highlight (`offsets(ofByte:)`) stays Swift-only.
public enum RustHexSearchAdapter {

    /// Parse `query` per `mode` and return non-overlapping match offsets in
    /// `data`, routing per the `.hexSearch` gate.
    public static func search(_ query: String, mode: HexSearchMode, in data: Data) -> [Int] {
        outcome(query, mode: mode, in: data).value
    }

    /// Same, but also reporting which engine produced the result (A/B / diag).
    public static func outcome(
        _ query: String,
        mode: HexSearchMode,
        in data: Data,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CoreOutcome<[Int]> {
        RustCoreFallback.run(
            .hexSearch, defaults: defaults, environment: environment,
            rust: { try mdvCoreHexSearch(data: data, query: query, mode: kind(mode)) },
            swift: { HexSearchEngine.search(query, mode: mode, in: data) }
        )
    }

    private static func kind(_ m: HexSearchMode) -> HexSearchKind {
        switch m {
        case .hex: return .hex
        case .ascii: return .ascii
        }
    }
}
