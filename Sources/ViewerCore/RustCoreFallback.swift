import Foundation

/// Which engine produced a routed result — for A/B diagnostics and tests.
public enum CoreResultSource: Sendable, Equatable {
    /// The Rust core produced it (gate on AND the bridge succeeded).
    case rust
    /// The Rust bridge threw and we fell back to Swift.
    case swiftFallback
    /// The gate was off, so Swift ran without ever calling Rust.
    case swiftBecauseGateOff
}

/// A routed result plus its provenance.
public struct CoreOutcome<T>: Sendable where T: Sendable {
    public let value: T
    public let source: CoreResultSource

    /// `true` iff the Rust core produced this value.
    public var usedRust: Bool { source == .rust }

    public init(value: T, source: CoreResultSource) {
        self.value = value
        self.source = source
    }
}

/// The generalization of `RustCSVAdapter`'s try-Rust / fall-back-to-Swift
/// pattern to every slice: one place the two implementations meet, with a
/// uniform fail-safe contract and a provenance tag.
///
/// Contract (identical to the CSV beachhead's behaviour):
///   • gate OFF                → run `swift()`, tag `.swiftBecauseGateOff`;
///   • gate ON, `rust()` ok    → its value, tag `.rust`;
///   • gate ON, `rust()` throws → run `swift()`, tag `.swiftFallback`.
///
/// A bridge fault therefore degrades to today's proven Swift behaviour rather
/// than surfacing as a feature break — the non-negotiable property that lets a
/// slice ship behind a default-OFF flag without risking the shipped path.
public enum RustCoreFallback {

    public static func run<T: Sendable>(
        _ capability: RustCoreCapability,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rust: () throws -> T,
        swift: () -> T
    ) -> CoreOutcome<T> {
        guard RustCoreGates.isEnabled(capability, defaults: defaults, environment: environment) else {
            return CoreOutcome(value: swift(), source: .swiftBecauseGateOff)
        }
        do {
            return CoreOutcome(value: try rust(), source: .rust)
        } catch {
            return CoreOutcome(value: swift(), source: .swiftFallback)
        }
    }
}
