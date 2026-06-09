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
    /// PERF #1: observe the sidebar directly so `.onChange(of:
    /// sidebar.rootURL)` fires from the sidebar's own publisher
    /// rather than via the (removed) DocumentModel forwarding.
    @ObservedObject var sidebar: SidebarModel
    /// True when the rail button forced this panel on (`PanelOverride.shown`)
    /// despite there being no transcripts. Renders a placeholder instead of
    /// `EmptyView()` so the toggle visibly works (bug4).
    var forcedShown: Bool = false
    @State private var isExpanded = false  // collapsed by default; logs can be huge
    @State private var events: [ClaudeEvent] = []
    @State private var refreshTask: Task<Void, Never>?
    @State private var transcriptCount: Int = 0
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    var body: some View {
        Group {
            if transcriptCount > 0 {
                VStack(spacing: 0) {
                    header
                    if isExpanded { eventList }
                }
                .sidebarSectionContainer()
            } else if forcedShown {
                // No transcripts, but the user forced the panel on — show a
                // placeholder so the rail toggle has a visible effect.
                VStack(spacing: 0) {
                    header
                    if isExpanded {
                        SidebarEmptyPlaceholder(message: "No Claude activity for this project.")
                    }
                }
                .sidebarSectionContainer()
            } else {
                // No transcripts for this project — keep the section
                // entirely hidden (no card, no placeholder). Users
                // without Claude Code workflows don't need the chrome.
                EmptyView()
            }
        }
        .onAppear { refresh() }
        .onChange(of: sidebar.rootURL) { _, _ in refresh() }
        .accessibilityIdentifier("mdv.claudeTimeline")
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                SidebarSectionHeaderLabel(
                    title: "Claude",
                    isExpanded: isExpanded,
                    uiSize: model.uiSize
                )
                Spacer()
                Text("\(events.count)")
                    .font(.system(size: model.uiSize(10), weight: .medium))
                    .foregroundStyle(.tertiary)
                Button(action: { refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: model.uiSize(9)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(IconHoverButtonStyle(cornerRadius: 4))
                .helpInfo(title: "Refresh", description: "Re-scan the Claude transcript timeline")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHeaderRow(uiSize: model.uiSize)
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(events) { event in
                    row(event)
                }
                if events.isEmpty {
                    SidebarEmptyPlaceholder(message: "No events parsed.")
                }
            }
        }
        .frame(height: bodyHeight)
    }

    private func row(_ event: ClaudeEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // SF Symbol glyph instead of text badge — visually denser
            // and matches the iconography used in the rest of the
            // sidebar (FileIconView, etc.).
            Image(systemName: kindGlyph(event.kind))
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(kindColor(event.kind))
                .frame(width: model.uiSize(18), alignment: .center)
                .help(kindLabel(event.kind))
                // .help only sets tooltip; VoiceOver still reads the
                // raw SF Symbol name ("person fill image") without an
                // explicit label. accessibilityLabel overrides that
                // with the human-readable role.
                .accessibilityLabel(kindLabel(event.kind))
            Text(event.summary)
                .font(.system(size: model.uiSize(11), design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, model.uiSize(10))
        .padding(.vertical, model.uiSize(2))
        .help(event.summary)
    }

    private func kindGlyph(_ k: ClaudeEvent.Kind) -> String {
        switch k {
        case .userMessage:      return "person.fill"
        case .assistantMessage: return "sparkles"
        case .thinking:         return "brain"
        case .toolUse:          return "hammer.fill"
        case .toolResult:       return "arrow.uturn.left"
        }
    }

    private func kindLabel(_ k: ClaudeEvent.Kind) -> String {
        switch k {
        case .userMessage:      return "User"
        case .assistantMessage: return "Assistant"
        case .thinking:         return "Thinking"
        case .toolUse:          return "Tool call"
        case .toolResult:       return "Tool result"
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
        guard let root = sidebar.rootURL else {
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
                // Load through the testable redaction kernel (see `timelineEvents`).
                parsed = Self.timelineEvents(from: latest)
            }
            await MainActor.run {
                self.events = parsed
                self.transcriptCount = count
            }
        }
    }

    /// Pure, host-testable kernel that loads the timeline's events for a
    /// transcript at `url`: parse through the MANDATORY redaction barrier
    /// (`redactedEvents`, NEVER the non-redacting `events`), then reverse-chrono
    /// + cap. Extracted from the inline `refresh()` closure so the redaction
    /// contract is regression-guarded by a host test (TSK-178).
    ///
    /// SECURITY (TSK-178): this sidebar renders `event.summary` directly (rows +
    /// `.help` tooltips), so it must surface ONLY redacted content — same
    /// contract as the monitor window and transcript search. Reverting to
    /// `parser.events(from:)` here would leak raw secrets (e.g. a tool-call
    /// `headers` value) into the UI; `ClaudeTimelineRedactionTests` fails if it
    /// does.
    nonisolated static func timelineEvents(
        from url: URL,
        parser: ClaudeLogParser = ClaudeLogParser(),
        cap: Int = 200
    ) -> [ClaudeEvent] {
        var parsed = (try? parser.redactedEvents(from: url)) ?? []
        parsed.reverse()                                    // most recent first
        if parsed.count > cap { parsed = Array(parsed.prefix(cap)) }
        return parsed
    }
}
