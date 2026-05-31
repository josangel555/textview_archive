import Foundation

/// Severity for an `ObsEvent`. Backed by `UInt8` so the record stays
/// FFI-shaped — when the core eventually moves to Rust and events cross
/// an RPC boundary, this serialises as a single byte with a stable
/// numeric ordering (`trace < debug < info < warn < error`).
///
/// Do NOT reorder or renumber existing cases: the raw value is part of
/// the wire contract once subsystems emit against it.
public enum ObsLevel: UInt8, Sendable, Comparable, CaseIterable {
    case trace = 0
    case debug = 1
    case info  = 2
    case warn  = 3
    case error = 4

    public static func < (lhs: ObsLevel, rhs: ObsLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short uppercase tag for stderr / os_log formatting.
    public var label: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// One observability event. **FFI-shaped by contract** (PRIORITIZED_PLAN
/// §5 guardrail #2): flat, value-typed, `Sendable`, built only from
/// primitives + `[String: String]`. There are deliberately NO
/// Foundation/AppKit reference types in the payload — paths are passed
/// as `String`, not `URL`; there are no closures, no `NSAttributedString`,
/// no `Date` (we carry a raw `UInt64` nanosecond clock instead). This
/// keeps the record trivially serialisable across the eventual
/// Swift↔Rust RPC boundary; changing the shape later means touching
/// every emit site *and* the RPC schema, so it is a one-way door.
public struct ObsEvent: Sendable, Equatable {

    /// Monotonic-ish wall-clock timestamp in nanoseconds since the Unix
    /// epoch. Captured at emit time. Stored as a raw integer (not
    /// `Date`) so the record carries no Foundation reference type and
    /// crosses FFI as a plain `u64`.
    public let tsNanos: UInt64

    /// Severity.
    public let level: ObsLevel

    /// Coarse origin tag — `"lsp"`, `"mcp"`, `"grammar"`, `"process"`,
    /// `"git"`, etc. Stable, low-cardinality strings; used for filtering.
    public let subsystem: String

    /// Human-readable message. May contain file paths / config text, so
    /// the buffer that holds these is a content-leak surface — see
    /// `RingBufferSink` notes. Never auto-persisted, never exposed via
    /// the MCP host.
    public let message: String

    /// Structured key→value detail. String→String ONLY (FFI contract).
    public let fields: [String: String]

    public init(
        tsNanos: UInt64,
        level: ObsLevel,
        subsystem: String,
        message: String,
        fields: [String: String] = [:]
    ) {
        self.tsNanos = tsNanos
        self.level = level
        self.subsystem = subsystem
        self.message = message
        self.fields = fields
    }

    /// Convenience initialiser that stamps `tsNanos` from the current
    /// wall clock. Most call sites use this; the explicit-timestamp
    /// initialiser exists for tests and replay.
    public init(
        level: ObsLevel,
        subsystem: String,
        message: String,
        fields: [String: String] = [:]
    ) {
        self.init(
            tsNanos: ObsClock.nowNanos(),
            level: level,
            subsystem: subsystem,
            message: message,
            fields: fields)
    }
}

/// Wall-clock source for event timestamps. Isolated behind a type so a
/// future Rust core can swap in its own monotonic clock without
/// touching call sites.
public enum ObsClock {
    /// Nanoseconds since the Unix epoch. Uses `gettimeofday` via
    /// `Date.timeIntervalSince1970` — microsecond resolution on macOS,
    /// widened to nanoseconds. Cheap; called once per emit.
    public static func nowNanos() -> UInt64 {
        let seconds = Date().timeIntervalSince1970
        // Guard against negative clocks (pre-1970) which can't happen on
        // a sane system but keep the cast total.
        guard seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }
}

/// Kind of a scalar metric. Counters are monotonic (sum of deltas);
/// gauges are last-write-wins point-in-time values.
public enum ObsMetricKind: UInt8, Sendable, CaseIterable {
    case counter = 0
    case gauge   = 1
}

/// A point-in-time snapshot of one metric series. FFI-shaped like
/// `ObsEvent`: flat, `Sendable`, primitives + `[String: String]` tags.
///
/// The `(name, tags)` pair identifies a series; `value` is the current
/// aggregate (cumulative for counters, latest for gauges).
public struct ObsMetric: Sendable, Equatable {
    public let name: String
    public let kind: ObsMetricKind
    public let value: Double
    public let tags: [String: String]

    public init(
        name: String,
        kind: ObsMetricKind,
        value: Double,
        tags: [String: String] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.value = value
        self.tags = tags
    }
}
