import SwiftUI
import ViewerCore

/// Tool-window view rendering the observability sink's ring buffer.
///
/// Level filter (min severity), subsystem filter, free-text tail/search,
/// newest-last (tail) ordering, copy-to-clipboard. Driven by
/// `ObservabilityProjection` — polls the sink, never observes per-emit
/// (see the projection's no-republish rationale).
///
/// Security note: the buffer holds raw `message` strings (LSP config
/// text, file paths). This view is an owner-only, in-process surface —
/// it is never reachable through the MCP automation host
/// (PRIORITIZED_PLAN §5 #7). Do not add an export-to-MCP affordance.
public struct LogsView: View {

    @ObservedObject private var projection: ObservabilityProjection

    @State private var minLevel: ObsLevel = .trace
    @State private var subsystemFilter: String = LogsView.allSubsystems
    @State private var query: String = ""

    static let allSubsystems = "All"

    public init(projection: ObservabilityProjection) {
        self.projection = projection
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear { projection.start() }
        .onDisappear { projection.stop() }
        .accessibilityIdentifier("mdv.logs")
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Min-level picker.
            Picker("Level", selection: $minLevel) {
                ForEach(ObsLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show events at this severity or higher")
            .accessibilityIdentifier("mdv.logs.levelFilter")

            // Subsystem picker.
            Picker("Subsystem", selection: $subsystemFilter) {
                Text(LogsView.allSubsystems).tag(LogsView.allSubsystems)
                ForEach(subsystems, id: \.self) { sub in
                    Text(sub).tag(sub)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Filter by emitting subsystem")
            .accessibilityIdentifier("mdv.logs.subsystemFilter")

            // Search / tail.
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search messages…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("mdv.logs.search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Spacer(minLength: 6)

            Button {
                copyVisibleToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy visible log lines")
            .accessibilityIdentifier("mdv.logs.copy")

            Button(role: .destructive) {
                projection.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear the log buffer")
            .accessibilityIdentifier("mdv.logs.clear")
        }
        .padding(8)
    }

    // MARK: - Table

    private var table: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { (idx, event) in
                        LogRow(event: event)
                            .id(idx)
                            .background(
                                idx.isMultiple(of: 2)
                                    ? Color.clear
                                    : Color.primary.opacity(0.03))
                    }
                    // Tail anchor.
                    Color.clear.frame(height: 1).id("tail")
                }
            }
            // Keep the newest line in view as the buffer grows (tail-f
            // behaviour). Keyed on the projection version so it scrolls
            // only when new events land, not on every render.
            .onChange(of: projection.version) { _, _ in
                proxy.scrollTo("tail", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "text.alignleft")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if projection.totalEmitted == 0 {
            return "No log events yet."
        }
        return "No events match the current filters."
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(countSummary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if droppedCount > 0 {
                Text("\(droppedCount) older events dropped")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("The ring buffer is full; oldest events were overwritten.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var countSummary: String {
        "\(filtered.count) shown · \(projection.events.count) buffered / \(projection.bufferCapacity) cap"
    }

    private var droppedCount: Int {
        let total = projection.totalEmitted
        let buffered = UInt64(projection.events.count)
        return total > buffered ? Int(total - buffered) : 0
    }

    // MARK: - Filtering

    /// Distinct subsystems present in the buffer, sorted — drives the
    /// subsystem picker so it only offers what actually emitted.
    private var subsystems: [String] {
        Array(Set(projection.events.map(\.subsystem))).sorted()
    }

    private var filtered: [ObsEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return projection.events.filter { e in
            guard e.level >= minLevel else { return false }
            if subsystemFilter != LogsView.allSubsystems,
               e.subsystem != subsystemFilter { return false }
            if !q.isEmpty {
                let haystack = (e.message + " " + e.subsystem
                    + " " + e.fields.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                    .lowercased()
                if !haystack.contains(q) { return false }
            }
            return true
        }
    }

    private func copyVisibleToPasteboard() {
        let text = filtered.map(LogsView.line).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Single-line rendering for copy/export. Mirrors
    /// `RingBufferSink.format` plus a timestamp prefix.
    static func line(_ e: ObsEvent) -> String {
        let ts = LogTimestamp.string(e.tsNanos)
        var s = "\(ts) [\(e.subsystem)] \(e.level.label) \(e.message)"
        if !e.fields.isEmpty {
            let rendered = e.fields.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            s += " {\(rendered)}"
        }
        return s
    }
}

// MARK: - Row

private struct LogRow: View {
    let event: ObsEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LogTimestamp.string(event.tsNanos))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .leading)
            Text(event.level.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 42, alignment: .leading)
            Text(event.subsystem)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.message)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !event.fields.isEmpty {
                    Text(fieldsText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(event.level.label) \(event.subsystem): \(event.message)")
    }

    private var fieldsText: String {
        event.fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
    }

    private var levelColor: Color {
        switch event.level {
        case .trace: return .secondary
        case .debug: return .gray
        case .info:  return .blue
        case .warn:  return .orange
        case .error: return .red
        }
    }
}

// MARK: - Timestamp formatting

/// Renders an `ObsEvent.tsNanos` (Unix-epoch nanoseconds) as a
/// `HH:mm:ss.SSS` wall-clock string. Cached `DateFormatter` (formatter
/// construction is expensive; one per process).
enum LogTimestamp {
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func string(_ tsNanos: UInt64) -> String {
        let seconds = Double(tsNanos) / 1_000_000_000.0
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
