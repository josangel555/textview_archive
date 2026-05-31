import AppKit
import SwiftUI
import ViewerCore

/// Debug-only diagnostic window (PRIORITIZED_PLAN item 17). Renders a
/// curated `DiagnosticSnapshot`: document/tab state, the temp files we own,
/// this process's open file descriptors, and live subprocesses (LSP servers).
///
/// ## Gating
/// Surfaced ONLY behind `DiagnosticGate.isEnabled` (DEBUG build OR
/// `MDV_ENABLE_DIAGNOSTICS=1`). The host (stage-2b wiring) must consult that
/// gate before constructing the window; this view also no-ops its content
/// when the gate is off as a defence in depth.
///
/// ## Never via MCP, never auto-persisted (guardrail #7)
/// This window is a content/path exfil surface. It is a LIVE view only — it
/// is never added to the MCP tool catalog, and the only way state leaves the
/// process is the explicit owner-invoked Export button (0600, paths redacted
/// by default).
///
/// ## No republish (guardrail #5)
/// The view does NOT observe `model.objectWillChange`. It captures a snapshot
/// into local `@State` on explicit Refresh (and once on appear). There is no
/// reactive subscription to the model, so opening this window cannot amplify
/// keystroke/scroll republishes.
public struct DiagnosticWindowView: View {

    /// Not `@ObservedObject`: we deliberately do NOT want this window to
    /// re-render on every model change. It's a plain reference used only to
    /// pull a fresh snapshot when the user asks.
    private let model: DocumentModel

    @State private var snapshot: DiagnosticSnapshot?
    @State private var selectedTab: Section = .state
    @State private var exportMessage: String?

    private enum Section: String, CaseIterable, Identifiable {
        case state = "State"
        case tempFiles = "Temp Files"
        case fds = "Open FDs"
        case subprocesses = "Subprocesses"
        var id: String { rawValue }
    }

    public init(model: DocumentModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if DiagnosticGate.isEnabled {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Defence in depth: if the window is ever constructed with the
                // gate off, render nothing useful.
                Text("Diagnostics disabled.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            // Initial capture (async to pick up the LSP subprocess list).
            await refresh()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedTab) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button("Refresh") { Task { await refresh() } }
            Button("Export…") { exportSnapshot() }
                .help("Write a 0600 JSON dump to the temp dir. Absolute paths are redacted.")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            switch selectedTab {
            case .state:        stateSection(snapshot)
            case .tempFiles:    tempFilesSection(snapshot)
            case .fds:          fdsSection(snapshot)
            case .subprocesses: subprocessesSection(snapshot)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sections

    private func stateSection(_ s: DiagnosticSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                keyValueGrid([
                    ("PID", String(s.pid)),
                    ("Build", s.isDebugBuild ? "DEBUG" : "release (opt-in)"),
                    ("Captured", Self.formatNanos(s.capturedAtUnixNanos)),
                    ("Sidebar root", s.sidebarRootPath ?? "—"),
                    ("Recents", String(s.recentsCount)),
                    ("Bookmarks", String(s.bookmarksCount)),
                    ("Obs buffered", String(s.obsBufferedEvents)),
                    ("Obs total emitted", String(s.obsTotalEmitted)),
                ])

                Text("Tabs (\(s.tabs.count))").font(.headline)
                if s.tabs.isEmpty {
                    Text("No open tabs.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(s.tabs.enumerated()), id: \.offset) { idx, tab in
                        let selected = (idx == s.selectedTabIndex)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(tab.title).bold()
                                if selected {
                                    Text("selected").font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                                if tab.isDirty {
                                    Text("dirty").font(.caption2).foregroundStyle(.orange)
                                }
                                if tab.diskState != "fresh" {
                                    Text(tab.diskState).font(.caption2).foregroundStyle(.red)
                                }
                            }
                            Text("\(tab.stateKind) · \(tab.viewMode)\(tab.byteCount.map { " · \($0) B" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                            if let p = tab.path {
                                Text(p).font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tempFilesSection(_ s: DiagnosticSnapshot) -> some View {
        listSection(rows: s.tempFiles, empty: "No mdv-* temp files.") { f in
            VStack(alignment: .leading, spacing: 2) {
                Text(f.path).font(.caption.monospaced()).textSelection(.enabled)
                Text("\(f.sizeBytes) B · \(Self.formatNanos(f.modifiedUnixNanos))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func fdsSection(_ s: DiagnosticSnapshot) -> some View {
        listSection(rows: s.openFDs, empty: "No open fds.") { fd in
            HStack(alignment: .top, spacing: 8) {
                Text(String(fd.fd)).font(.caption.monospaced()).frame(width: 36, alignment: .trailing)
                Text(fd.kind).font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                Text(fd.path ?? "—").font(.caption.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func subprocessesSection(_ s: DiagnosticSnapshot) -> some View {
        listSection(rows: s.subprocesses, empty: "No live subprocesses.") { p in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(p.subsystem).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                    Text(p.status).font(.caption2)
                        .foregroundStyle(p.status == "live" ? .green : (p.status == "dead" ? .red : .secondary))
                }
                Text(p.label).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    // MARK: - Reusable bits

    private func listSection<Row, RowView: View>(
        rows: [Row],
        empty: String,
        @ViewBuilder row: @escaping (Row) -> RowView
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if rows.isEmpty {
                    Text(empty).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        row(r)
                        Divider()
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyValueGrid(_ pairs: [(String, String)]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    Text(pair.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(pair.1).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func refresh() async {
        snapshot = await model.fullDiagnosticSnapshot()
    }

    /// Owner-invoked export: write a redacted 0600 JSON dump to the per-user
    /// tmpdir. NEVER automatic; NEVER through the MCP host.
    private func exportSnapshot() {
        guard let snapshot else { return }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-diagnostic-snapshot-\(getpid()).json").path
        do {
            try DiagnosticDumpWriter.write(
                snapshot, toPath: path,
                redactPaths: DiagnosticGate.redactPathsInExport)
            exportMessage = "Wrote \(path)"
        } catch {
            exportMessage = "Export failed: \(error)"
        }
    }

    private static func formatNanos(_ nanos: UInt64) -> String {
        guard nanos > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
