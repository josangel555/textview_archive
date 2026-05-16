import SwiftUI
import ViewerCore

/// Sidebar widget showing Claude Code activity for the current
/// project. Reads ~/.claude/projects/<encoded-path>/*.jsonl
/// transcripts for the sidebar root, parses with ClaudeLogParser,
/// renders a compact reverse-chrono event list.
///
/// Hidden when no transcripts exist for the current project — keeps
/// the sidebar uncluttered for non-Claude-Code workflows.
struct ClaudeTimelineSection: View {
    @ObservedObject var model: DocumentModel
    @State private var isExpanded = false  // collapsed by default; logs can be huge
    @State private var events: [ClaudeEvent] = []
    @State private var refreshTask: Task<Void, Never>?
    @State private var transcriptCount: Int = 0

    var body: some View {
        Group {
            if transcriptCount > 0 {
                VStack(spacing: 0) {
                    header
                    if isExpanded { eventList }
                }
            } else {
                EmptyView()
            }
        }
        .onAppear { refresh() }
        .onChange(of: model.sidebar.rootURL) { _, _ in refresh() }
        .accessibilityIdentifier("mdv.claudeTimeline")
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text("CLAUDE")
                    .font(.system(size: model.uiSize(10), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(events.count)")
                    .font(.system(size: model.uiSize(10), weight: .medium))
                    .foregroundStyle(.tertiary)
                Button(action: { refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(events) { event in
                    row(event)
                }
                if events.isEmpty {
                    Text("No events parsed")
                        .font(.system(size: model.uiSize(11)))
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func row(_ event: ClaudeEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(kindBadge(event.kind))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(kindColor(event.kind))
                .frame(width: 28, alignment: .center)
            Text(event.summary)
                .font(.system(size: model.uiSize(11), design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .help(event.summary)
    }

    private func kindBadge(_ k: ClaudeEvent.Kind) -> String {
        switch k {
        case .userMessage:      return "user"
        case .assistantMessage: return "asst"
        case .thinking:         return "think"
        case .toolUse:          return "tool"
        case .toolResult:       return "out"
        }
    }

    private func kindColor(_ k: ClaudeEvent.Kind) -> Color {
        switch k {
        case .userMessage:      return .blue
        case .assistantMessage: return .green
        case .thinking:         return .purple
        case .toolUse:          return .orange
        case .toolResult:       return .gray
        }
    }

    private func refresh() {
        refreshTask?.cancel()
        guard let root = model.sidebar.rootURL else {
            events = []; transcriptCount = 0; return
        }
        let dir = ClaudeLogParser.transcriptDirectory(for: root)
        refreshTask = Task.detached(priority: .utility) {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            let jsonls = urls.filter { $0.pathExtension == "jsonl" }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
            let count = jsonls.count
            // Parse only the most recent transcript; users mostly care
            // about the active session.
            var parsed: [ClaudeEvent] = []
            if let latest = jsonls.first {
                let parser = ClaudeLogParser()
                parsed = (try? parser.events(from: latest)) ?? []
                // Reverse-chrono: most recent first.
                parsed.reverse()
                if parsed.count > 200 { parsed = Array(parsed.prefix(200)) }
            }
            await MainActor.run {
                self.events = parsed
                self.transcriptCount = count
            }
        }
    }
}
