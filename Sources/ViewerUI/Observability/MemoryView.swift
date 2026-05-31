import SwiftUI
import ViewerCore

/// Tool-window view rendering an *honest* memory readout.
///
/// Three numbers, deliberately framed so nothing is fabricated
/// (triage-instrumentation.md "Status bar: total + per-tab memory"):
///
///   1. **App footprint** — `task_info(TASK_VM_INFO).phys_footprint` of
///      the main process. Excludes WebKit helpers.
///   2. **WebKit helpers** — a *separate*, explicitly-shared line: the
///      best-effort sum of child `com.apple.WebKit.*` helper footprints.
///      Split across every tab's web view; not attributable per tab.
///   3. **Per-tab content** — a byte *proxy* (loaded document size), with
///      a tooltip stating it is NOT a per-tab RSS. There is no honest
///      per-tab RSS for a `WKWebView` app, so we never show one.
///
/// Polls via `ObservabilityProjection` (1 Hz `task_info`/pid-walk cap).
public struct MemoryView: View {

    @ObservedObject private var projection: ObservabilityProjection

    /// Per-tab content-byte proxies, supplied by the host (stage-2b
    /// populates from the live tab list). Empty when no host wiring is
    /// present — the per-tab section then shows a placeholder.
    private let tabs: [TabMemoryProxy]

    public init(projection: ObservabilityProjection, tabs: [TabMemoryProxy] = []) {
        self.projection = projection
        self.tabs = tabs
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                processSection
                Divider()
                perTabSection
                Divider()
                honestyFootnote
            }
            .padding(14)
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear { projection.start() }
        .onDisappear { projection.stop() }
        .accessibilityIdentifier("mdv.memory")
    }

    // MARK: - Process section

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Process memory")

            memoryRow(
                label: "App footprint",
                value: appFootprintText,
                help: "task_info phys_footprint of the main process. This is the app's own physical memory; it EXCLUDES the WebKit helper processes below.",
                emphasised: true)

            memoryRow(
                label: "WebKit helpers",
                value: webKitText,
                help: webKitHelp,
                emphasised: false)

            if let total = combinedText {
                memoryRow(
                    label: "Combined (best-effort)",
                    value: total,
                    help: "App footprint + the WebKit-helper sum. Approximate — helper enumeration is best-effort and the OS shares memory pages across processes, so this is not a simple add.",
                    emphasised: false)
            }
        }
    }

    private var appFootprintText: String {
        guard let bytes = projection.memory.appFootprintBytes else { return "—" }
        return ByteFormat.mib(bytes)
    }

    private var webKitText: String {
        let mem = projection.memory
        let base = ByteFormat.mib(mem.webKitHelperBytes)
        let suffix = mem.webKitHelperCount == 1 ? "helper" : "helpers"
        var s = "\(base) · \(mem.webKitHelperCount) \(suffix)"
        if !mem.helpersComplete { s += " (≥)" }
        return s
    }

    private var webKitHelp: String {
        var s = "Shared across ALL tabs/web views — Networking, GPU, and one WebContent process per rendering WKWebView. Not attributable to any single tab."
        if !projection.memory.helpersComplete {
            s += " The sum is a lower bound: some helpers may be reparented to launchd and not counted."
        }
        return s
    }

    private var combinedText: String? {
        guard let app = projection.memory.appFootprintBytes else { return nil }
        return ByteFormat.mib(app + projection.memory.webKitHelperBytes)
    }

    // MARK: - Per-tab section

    private var perTabSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                sectionTitle("Per-tab content size")
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("This is the loaded document's byte size — a PROXY, not the tab's RSS. A tab is not a process; a WKWebView tab's real memory lives in the shared WebKit helpers above and cannot be split per tab honestly.")
            }

            if tabs.isEmpty {
                Text("No open tabs (or host wiring not yet present).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(tabs) { tab in
                    tabRow(tab)
                }
            }
        }
    }

    private func tabRow(_ tab: TabMemoryProxy) -> some View {
        HStack(spacing: 8) {
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            if tab.hasLiveWebView {
                Image(systemName: "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Backed by a live WKWebView — its real memory is in the shared WebKit helpers, not in the byte figure shown here.")
            }
            Spacer(minLength: 8)
            Text(tab.contentBytes.map(ByteFormat.human) ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(tab.title): \(tab.contentBytes.map(ByteFormat.human) ?? "unknown") content"
            + (tab.hasLiveWebView ? ", live web view" : ""))
    }

    // MARK: - Footnote

    private var honestyFootnote: some View {
        Text("Why no per-tab MB? WKWebView splits resident memory across shared XPC helper processes (one WebContent per web view, plus shared GPU/Networking). There is no honest per-tab RSS — a confident per-tab MB number would be fabricated. For a true breakdown, attach Instruments or Activity Monitor.")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Building blocks

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
    }

    private func memoryRow(
        label: String,
        value: String,
        help: String,
        emphasised: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: emphasised ? 12 : 11,
                              weight: emphasised ? .medium : .regular))
                .help(help)
            Image(systemName: "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help(help)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: emphasised ? 13 : 11,
                              weight: emphasised ? .semibold : .regular,
                              design: .monospaced))
                .foregroundStyle(emphasised ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value). \(help)")
    }
}
