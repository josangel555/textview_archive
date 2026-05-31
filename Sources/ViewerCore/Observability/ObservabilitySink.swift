import Foundation

/// The single emit path for the whole core. Logs, warnings, and
/// metric mutations all funnel through one `ObservabilitySink` so that
/// the scattered point solutions (`LSPLog` stderr buffer, `MCPServer`'s
/// optional logger closure, `GrammarLoader`'s bare stderr writes) become
/// consumers of one stream instead of bespoke channels.
///
/// Implementations MUST be safe to call from any thread/queue — emit
/// happens from LSP parse paths, the MCP stdio background thread, and
/// the grammar dlopen path, none of which share an isolation domain.
public protocol ObservabilitySink: Sendable {
    /// Record a structured event.
    func emit(_ event: ObsEvent)

    /// Add `delta` to a counter series identified by `(name, tags)`.
    /// Counters are monotonic in intent (callers pass positive deltas);
    /// negative deltas are accepted but discouraged.
    func counter(_ name: String, _ delta: Int64, _ tags: [String: String])

    /// Set a gauge series identified by `(name, tags)` to `value`
    /// (last-write-wins).
    func gauge(_ name: String, _ value: Double, _ tags: [String: String])
}

extension ObservabilitySink {
    /// Ergonomic emit that stamps the timestamp and defaults `fields`.
    public func emit(
        _ level: ObsLevel,
        _ subsystem: String,
        _ message: String,
        fields: [String: String] = [:]
    ) {
        emit(ObsEvent(
            level: level,
            subsystem: subsystem,
            message: message,
            fields: fields))
    }

    public func counter(_ name: String, _ delta: Int64 = 1) {
        counter(name, delta, [:])
    }

    public func gauge(_ name: String, _ value: Double) {
        gauge(name, value, [:])
    }
}

/// A sink that drops everything on the floor. The safe default before
/// the app installs a real sink, and a useful baseline in tests that
/// don't care about output.
public struct NoopObservabilitySink: ObservabilitySink {
    public init() {}
    public func emit(_ event: ObsEvent) {}
    public func counter(_ name: String, _ delta: Int64, _ tags: [String: String]) {}
    public func gauge(_ name: String, _ value: Double, _ tags: [String: String]) {}
}
