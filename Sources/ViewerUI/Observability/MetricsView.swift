import SwiftUI
import ViewerCore

/// Tool-window view rendering the sink's metric registry — counters
/// (monotonic) and gauges (point-in-time) grouped by subsystem prefix.
///
/// Polls via `ObservabilityProjection`; the registry is a non-`@Published`
/// core actor and this view never observes-and-republishes per metric
/// mutation (that would re-introduce the keystroke-republish regression
/// LESSONS.md killed — metrics are written from hot paths). Refresh is
/// the projection's 1 Hz poll.
public struct MetricsView: View {

    @ObservedObject private var projection: ObservabilityProjection

    public init(projection: ObservabilityProjection) {
        self.projection = projection
    }

    public var body: some View {
        VStack(spacing: 0) {
            if grouped.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(grouped, id: \.subsystem) { group in
                            section(for: group)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            signpostNote
        }
        .frame(minWidth: 420, minHeight: 280)
        .onAppear { projection.start() }
        .onDisappear { projection.stop() }
        .accessibilityIdentifier("mdv.metrics")
    }

    // MARK: - Sections

    private func section(for group: MetricGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.subsystem.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(group.metrics, id: \.displayKey) { m in
                MetricRow(metric: m)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "chart.bar")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No metrics recorded yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Counters and gauges appear here as subsystems emit them.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - os_signpost note

    private var signpostNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Fine-grained timings (TreeSitter tokenize, file load, git, render) are emitted as os_signpost intervals — capture them in Instruments (Logging/Points of Interest), not here.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Grouping

    private struct MetricGroup {
        let subsystem: String
        let metrics: [DisplayMetric]
    }

    /// One metric series flattened for display. `displayKey` is stable
    /// across polls so `ForEach` doesn't churn rows.
    struct DisplayMetric {
        let name: String
        let kind: ObsMetricKind
        let value: Double
        let tags: [String: String]

        var displayKey: String {
            let tagStr = tags.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return tagStr.isEmpty ? name : "\(name){\(tagStr)}"
        }
    }

    /// Group by the metric name's first dotted segment (the convention
    /// the emit sites use: `subprocess.spawned`, `lsp.servers.active`,
    /// `highlight.cache.hit`). Sorted for stable ordering.
    private var grouped: [MetricGroup] {
        var byPrefix: [String: [DisplayMetric]] = [:]
        for m in projection.metrics {
            let prefix = m.name.split(separator: ".").first.map(String.init) ?? "other"
            byPrefix[prefix, default: []].append(
                DisplayMetric(name: m.name, kind: m.kind, value: m.value, tags: m.tags))
        }
        return byPrefix
            .sorted { $0.key < $1.key }
            .map { MetricGroup(
                subsystem: $0.key,
                metrics: $0.value.sorted { $0.displayKey < $1.displayKey }) }
    }
}

// MARK: - Row

private struct MetricRow: View {
    let metric: MetricsView.DisplayMetric

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kindIcon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .help(kindHelp)
            VStack(alignment: .leading, spacing: 0) {
                Text(metric.name)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                if !metric.tags.isEmpty {
                    Text(tagsText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(valueText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.name) \(valueText)")
    }

    private var kindIcon: String {
        switch metric.kind {
        case .counter: return "plus.forwardslash.minus"
        case .gauge:   return "gauge.with.dots.needle.50percent"
        }
    }

    private var kindHelp: String {
        switch metric.kind {
        case .counter: return "Counter (cumulative)"
        case .gauge:   return "Gauge (current value)"
        }
    }

    private var tagsText: String {
        metric.tags.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
    }

    /// Counters render as integers (they accumulate whole deltas);
    /// gauges keep one decimal place.
    private var valueText: String {
        switch metric.kind {
        case .counter:
            return String(Int64(metric.value.rounded()))
        case .gauge:
            if metric.value == metric.value.rounded() {
                return String(Int64(metric.value))
            }
            return String(format: "%.2f", metric.value)
        }
    }
}
