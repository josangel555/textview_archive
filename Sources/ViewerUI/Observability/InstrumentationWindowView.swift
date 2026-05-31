import SwiftUI
import ViewerCore
import ViewerKit

/// Instrumentation tool window (WAVE 2b item 5). A tabbed host over the
/// WAVE 2a observability views — `LogsView` (ring-buffer event stream),
/// `MetricsView` (counter/gauge/timer aggregates), and `MemoryView`
/// (honest footprint readout). All three poll the SAME live
/// `RingBufferSink` (the one the app installs into `Obs` at launch), so
/// the Logs tab shows real events emitted across ViewerCore.
///
/// ## Gating
/// Surfaced only behind `DiagnosticGate.isEnabled` (DEBUG or
/// `MDV_ENABLE_DIAGNOSTICS=1`); the host menu item is built only when the
/// gate is on, and the AppDelegate opener re-checks. Like the diagnostic
/// window, this is a live view only — never added to the MCP tool catalog.
///
/// ## Projection lifetime
/// Each tab's view owns its own poll start/stop via `.onAppear` /
/// `.onDisappear` on its `ObservabilityProjection`. We build three
/// projections over the one shared sink rather than one shared projection
/// so a backgrounded tab's poll cleanly stops — the projection's 1 Hz
/// `task_info` / pid-walk has a non-trivial cost we don't want running for
/// hidden tabs (the views' own `.onDisappear` already enforces this).
public struct InstrumentationWindowView: View {

    private let model: DocumentModel
    private let sink: RingBufferSink

    public init(model: DocumentModel, sink: RingBufferSink) {
        self.model = model
        self.sink = sink
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case logs = "Logs"
        case metrics = "Metrics"
        case memory = "Memory"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .logs:    return "list.bullet.rectangle"
            case .metrics: return "chart.xyaxis.line"
            case .memory:  return "memorychip"
            }
        }
    }

    @State private var selection: Tab = .logs

    public var body: some View {
        VStack(spacing: 0) {
            if DiagnosticGate.isEnabled {
                Picker("", selection: $selection) {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .padding(8)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Instrumentation disabled.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 360, minHeight: 280)
        .accessibilityIdentifier("mdv.instrumentation")
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .logs:
            LogsView(projection: ObservabilityProjection(sink: sink))
        case .metrics:
            MetricsView(projection: ObservabilityProjection(sink: sink))
        case .memory:
            MemoryView(projection: ObservabilityProjection(sink: sink),
                       tabs: tabMemoryProxies())
        }
    }

    /// Build per-tab content-byte proxies from the live tab list. These
    /// are an honest *document size* proxy, never a per-tab RSS (see
    /// `TabMemoryProxy`). Loaded/binary tabs carry a byte count; other
    /// states (loading/error/empty/hostedView) carry `nil`.
    private func tabMemoryProxies() -> [TabMemoryProxy] {
        model.tabs.tabs.map { t in
            let bytes: Int?
            var hasWeb = false
            switch t.state {
            case .loaded(let f):
                bytes = f.byteCount
                // Markdown / mermaid render through a WKWebView.
                if let url = t.url {
                    let cat = FileTypeDetector.category(for: url)
                    hasWeb = (t.viewMode == .rendered)
                        && (cat == .markdown || cat == .mermaid)
                }
            case .binary(let b):
                bytes = b.totalByteCount
            default:
                bytes = nil
            }
            return TabMemoryProxy(
                id: t.id.uuidString,
                title: t.title,
                contentBytes: bytes,
                hasLiveWebView: hasWeb
            )
        }
    }
}
