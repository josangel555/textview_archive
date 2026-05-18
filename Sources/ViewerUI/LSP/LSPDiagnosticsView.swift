import SwiftUI
import ViewerCore

/// Dev-only diagnostics panel — shows pool state, per-server status,
/// last response time, crash count, last error. Polls the pool every
/// 2 s; cheap.
///
/// Wire by adding `LSPDiagnosticsView(pool: pool)` to the Settings
/// scene behind a debug-build flag.
public struct LSPDiagnosticsView: View {

    @StateObject private var model: LSPDiagnosticsModel

    public init(pool: LSPPool) {
        _model = StateObject(wrappedValue: LSPDiagnosticsModel(pool: pool))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LSP servers").font(.headline)
                Spacer()
                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
            if model.entries.isEmpty {
                Text("No LSP servers active.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Table(model.entries) {
                    TableColumn("Language") { e in
                        Text(e.key.language.displayName)
                    }
                    TableColumn("Root") { e in
                        Text(e.key.workspaceRoot.path)
                            .truncationMode(.middle)
                    }
                    TableColumn("State") { e in
                        if e.isLive {
                            Label("live", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if e.isDead {
                            Label("dead", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        } else {
                            Label("starting", systemImage: "hourglass")
                                .foregroundStyle(.orange)
                        }
                    }
                    TableColumn("Reqs") { e in
                        Text("\(e.status.requestCount)")
                    }
                    TableColumn("Last ms") { e in
                        if let ms = e.status.lastResponseMillis {
                            Text(String(format: "%.0f", ms))
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Crashes") { e in
                        Text("\(e.status.crashCount)")
                    }
                    TableColumn("Last error") { e in
                        Text(e.status.lastError ?? "—")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .padding()
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

@MainActor
final class LSPDiagnosticsModel: ObservableObject {

    struct Row: Identifiable {
        let id: String
        let key: LSPPool.Key
        let isLive: Bool
        let isDead: Bool
        let status: LSPPool.LSPServerStatus
    }

    @Published private(set) var entries: [Row] = []

    private let pool: LSPPool
    private var pollTask: Task<Void, Never>?

    init(pool: LSPPool) { self.pool = pool }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let snapshot = await self.pool.snapshot()
            self.entries = snapshot.map {
                Row(id: $0.key.description,
                    key: $0.key,
                    isLive: $0.isLive,
                    isDead: $0.isDead,
                    status: $0.status)
            }.sorted { $0.id < $1.id }
        }
    }
}
