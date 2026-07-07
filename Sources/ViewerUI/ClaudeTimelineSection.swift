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
    // Collapsed by default (logs can be huge) but PERSISTED (TSK-609):
    // as transient @State it reset to collapsed on every remount, and the
    // rail's reveal-on-toggle write had nothing to land on — the panel
    // toggle looked inert. Key = SidebarPanelKind.claudeTimeline.expandedStateKey.
    @AppStorage("MarkdownViewer.sidebar.claudeTimeline.expanded")
    private var isExpanded = false
    @State private var events: [ClaudeEvent] = []
    @State private var refreshTask: Task<Void, Never>?
    @State private var transcriptCount: Int = 0
    // TSK-336 slice (a): the Hooks sub-segment — live tool activity captured by
    // the `monitor-log.sh` Claude Code hook, scoped to this project's `cwd`.
    // Captured + parsed by `ClaudeMonitorLog` (long dead code with no UI
    // consumer); this surfaces it. Collapsed by default and persisted like the
    // parent section.
    @State private var hookEvents: [ClaudeMonitorEvent] = []
    @AppStorage("MarkdownViewer.sidebar.claudeTimeline.hooksExpanded")
    private var isHooksExpanded = false
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    var body: some View {
        Group {
            if transcriptCount > 0 || !hookEvents.isEmpty {
                VStack(spacing: 0) {
                    header
                    if isExpanded {
                        eventList
                        hooksSegment
                    }
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
                    uiSize: model.uiSize,
                    dragKind: .claudeTimeline
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

    // MARK: - Hooks sub-segment (TSK-336 slice (a))

    /// Collapsible "Hooks" segment nested under the Claude section, listing the
    /// live tool-activity events captured by the `monitor-log.sh` hook for this
    /// project. Hidden entirely when no hook events are attributed to the
    /// current `cwd` — non-monitor workflows see no extra chrome.
    @ViewBuilder private var hooksSegment: some View {
        if !hookEvents.isEmpty {
            VStack(spacing: 0) {
                hooksHeader
                if isHooksExpanded { hookEventList }
            }
        }
    }

    private var hooksHeader: some View {
        Button(action: { isHooksExpanded.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: isHooksExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: model.uiSize(8), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: model.uiSize(10))
                Text("Hooks")
                    .font(.system(size: model.uiSize(10), weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(hookEvents.count)")
                    .font(.system(size: model.uiSize(10), weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, model.uiSize(10))
            .padding(.vertical, model.uiSize(3))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mdv.claudeTimeline.hooks")
    }

    private var hookEventList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(hookEvents) { event in
                hookRow(event)
            }
        }
    }

    private func hookRow(_ event: ClaudeMonitorEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: hookGlyph(event))
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(event.isFailure ? Color.red : hookColor(event.event))
                .frame(width: model.uiSize(18), alignment: .center)
                .help(event.event)
                .accessibilityLabel(event.event)
            Text(event.summary)
                .font(.system(size: model.uiSize(11), design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(event.isFailure ? Color.red : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, model.uiSize(16))
        .padding(.vertical, model.uiSize(2))
        .help(event.summary)
    }

    private func hookGlyph(_ event: ClaudeMonitorEvent) -> String {
        if event.isFailure { return "exclamationmark.triangle.fill" }
        if event.tool != nil { return "hammer.fill" }
        switch event.event {
        case "UserPromptSubmit": return "person.fill"
        case "Stop":             return "stop.circle"
        case "SessionStart":     return "play.circle"
        case "SessionEnd":       return "xmark.circle"
        case "Notification":     return "bell.fill"
        default:                 return "bolt.fill"
        }
    }

    private func hookColor(_ event: String) -> Color {
        switch event {
        case "UserPromptSubmit": return .blue
        case "Stop", "SessionEnd": return .gray
        case "SessionStart": return .green
        case "Notification": return .purple
        default: return .orange
        }
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
            events = []; transcriptCount = 0; hookEvents = []; return
        }
        let dir = ClaudeLogParser.transcriptDirectory(for: root)
        let monitorDir = ClaudeMonitorLog.defaultMonitorDir()
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
            // Hook-monitor feed for this project (TSK-336 slice (a)). The
            // monitor envelope is privacy-bounded by the writer, so it needs no
            // redaction barrier — surface the project-scoped events directly.
            let hooks = ClaudeMonitorLog().projectEvents(inDir: monitorDir, root: root)
            await MainActor.run {
                self.events = parsed
                self.transcriptCount = count
                self.hookEvents = hooks
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
        cap: Int = 200
    ) -> [ClaudeEvent] {
        // Stage-B: rust is the only projection engine; redaction is pinned
        // core-side and re-asserted by ClaudeTimelineRedactionTests.
        var parsed = (try? RustTranscriptAdapter.redactedEvents(from: url)) ?? []
        parsed.reverse()                                    // most recent first
        if parsed.count > cap { parsed = Array(parsed.prefix(cap)) }
        return parsed
    }
}
