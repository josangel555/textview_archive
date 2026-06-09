import Foundation
import SwiftUI
import ViewerCore

// Standalone, decoupled "Claude session monitor" — a PoC master-detail
// browser over the read-only `~/.claude` index. It does NOT touch
// ContentView/DocumentModel: it is hosted in its own window via the
// `--claude-monitor` launch flag (see MarkdownViewer/main.swift) so it
// carries zero regression risk for the main document UI.
//
// Discipline mirrors the rest of the app:
//   - The session list comes from `ClaudeSessionIndex.summaries(root:)`,
//     a streaming, never-slurp scan; we run it off-main in a detached Task.
//   - The detail transcript is parsed off-main too, in a single streaming
//     pass over one held read-only `FileHandle` + `ClaudeLogParser`, with the
//     engine's REDACTION applied to every record BEFORE it is surfaced
//     (signatures, HTTP headers, inline image blobs). We never read
//     `.credentials.json` or any stats cache — only `projects/*/*.jsonl`,
//     read-only.

// MARK: - Model

/// `@MainActor` view-model for the Claude monitor. Holds the session
/// summaries and the selected session's parsed (redacted) events.
/// Heavy work (index scan, per-session parse) runs in `Task.detached`;
/// results are published back on the main actor.
@MainActor
final class ClaudeMonitorModel: ObservableObject {

    /// Root scanned for transcripts (`~/.claude`).
    let root: URL

    @Published private(set) var sessions: [ClaudeSessionSummary] = []
    @Published private(set) var isLoadingSessions = false
    /// Selected session key (`ClaudeSessionSummary.id`), or `nil`.
    @Published var selectedKey: String?
    @Published private(set) var events: [ClaudeEvent] = []
    @Published private(set) var isLoadingEvents = false
    /// Non-nil when the selected transcript truncated at the event cap.
    @Published private(set) var detailNotice: String?
    @Published var searchText: String = ""

    // MARK: Transcript content search (full-text, across all sessions)

    /// The full-text query. Distinct from `searchText` (which filters the
    /// session LIST by title/path); this searches transcript CONTENT via the
    /// host-tested `ClaudeTranscriptSearch` and yields per-event snippet matches.
    @Published var contentQuery: String = ""
    /// Most recent content-search results (each a session/event + snippet).
    @Published private(set) var contentMatches: [ClaudeTranscriptSearch.Match] = []
    @Published private(set) var isContentSearching = false
    /// Generation token so a stale content-search can't clobber a newer one.
    private var contentGeneration = 0

    /// Monotonic token so a stale detail-load (user clicked away fast)
    /// can't clobber the events of a newer selection when it finishes.
    private var detailGeneration = 0

    /// Defensive ceiling so a pathological transcript can't materialize an
    /// unbounded SwiftUI list. Real sessions are < 10k events.
    private let maxDetailEvents = 20_000

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)) {
        self.root = root
    }

    /// Filtered + most-recent-first session list driving the master pane.
    var filteredSessions: [ClaudeSessionSummary] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [ClaudeSessionSummary]
        if needle.isEmpty {
            base = sessions
        } else {
            base = sessions.filter { s in
                (s.title?.lowercased().contains(needle) ?? false)
                    || (s.cwd?.lowercased().contains(needle) ?? false)
                    || s.projectDirName.lowercased().contains(needle)
            }
        }
        return base.sorted { lhs, rhs in
            (lhs.lastTimestamp ?? .distantPast) > (rhs.lastTimestamp ?? .distantPast)
        }
    }

    var selectedSession: ClaudeSessionSummary? {
        guard let key = selectedKey else { return nil }
        return sessions.first { $0.key == key }
    }

    /// Kick off the off-main index scan. Idempotent-ish: a re-entrant call
    /// just runs another scan and republishes (cheap, read-only).
    func loadSessions() {
        isLoadingSessions = true
        let root = self.root
        Task.detached(priority: .utility) {
            // `summaries` streams each file line-by-line and never slurps;
            // safe to run for a directory of large transcripts.
            let index = ClaudeSessionIndex()
            let result = index.summaries(root: root)
            await MainActor.run {
                self.sessions = result
                self.isLoadingSessions = false
                // If the prior selection vanished (file deleted between
                // scans), drop the now-dangling detail.
                if let key = self.selectedKey,
                   !result.contains(where: { $0.key == key }) {
                    self.selectedKey = nil
                    self.events = []
                    self.detailNotice = nil
                }
            }
        }
    }

    /// Run a full-text search over EVERY transcript under `root` (the
    /// content-search counterpart to `filteredSessions`' title/path filter),
    /// off-main, then publish `contentMatches`. A blank query clears results.
    /// Re-entrant-safe: a generation token drops a stale search that finishes
    /// after a newer one was kicked off.
    func runContentSearch() {
        let query = contentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        contentGeneration += 1
        let generation = contentGeneration
        guard !query.isEmpty else {
            contentMatches = []
            isContentSearching = false
            return
        }
        isContentSearching = true
        let root = self.root
        Task.detached(priority: .userInitiated) {
            // ClaudeTranscriptSearch streams line-by-line + caps matches, so
            // it's safe over a directory of large transcripts.
            let matches = (try? ClaudeTranscriptSearch().search(query, root: root)) ?? []
            await MainActor.run {
                guard generation == self.contentGeneration else { return }
                self.contentMatches = matches
                self.isContentSearching = false
            }
        }
    }

    /// Load (and redact) the transcript for `summary` off-main, then publish.
    func selectSession(_ summary: ClaudeSessionSummary) {
        selectedKey = summary.key
        events = []
        detailNotice = nil
        isLoadingEvents = true
        detailGeneration += 1
        let generation = detailGeneration
        let url = URL(fileURLWithPath: summary.path)
        let cap = maxDetailEvents

        Task.detached(priority: .userInitiated) {
            let (parsed, truncated) = Self.loadRedactedEvents(url: url, cap: cap)
            await MainActor.run {
                // Drop the result if the user has since selected another
                // session (stale completion guard).
                guard generation == self.detailGeneration else { return }
                self.events = parsed
                self.isLoadingEvents = false
                self.detailNotice = truncated
                    ? "Transcript truncated at \(cap) events."
                    : nil
            }
        }
    }

    /// Read buffer size for the single streaming pass over a transcript.
    /// Matches `ClaudeSessionIndex.readChunkBytes`'s default so the detail
    /// load consumes the file in the same fixed chunks the summary scan does.
    nonisolated private static let detailReadChunkBytes = 256 * 1024

    /// Largest single JSONL line we'll attempt to decode. Mirrors
    /// `ClaudeSessionIndex.maxLineBytes` / `ClaudeLogParser.maxLineBytes`:
    /// over-long lines have their bytes dropped (not decoded) so a
    /// pathological line can't feed a multi-MB buffer to JSONSerialization.
    nonisolated private static let detailMaxLineBytes = 4 * 1024 * 1024

    /// Read the transcript in ONE streaming pass over a single held
    /// `FileHandle`, REDACT every decoded record (engine redaction), and
    /// re-serialize the redacted records into a JSONL buffer that
    /// `ClaudeLogParser.parse` consumes. This keeps redaction strictly in
    /// front of the parser — exactly as `ClaudeSessionIndex` does internally —
    /// using only the engine's public surface, and never surfaces secrets.
    ///
    /// Replaces the previous offset-table approach, which re-opened the file
    /// (`open`+`seek`+`read`+`close`) once PER physical line — ~29k syscall
    /// round-trips for a real 29k-line transcript, on top of a full streaming
    /// scan for the offsets. Now it is a single open and a single sequential
    /// pass; memory stays bounded by the chunk size plus one in-flight line.
    ///
    /// `nonisolated static` so it can run inside `Task.detached` without
    /// capturing the `@MainActor` model.
    nonisolated static func loadRedactedEvents(
        url: URL, cap: Int
    ) -> (events: [ClaudeEvent], truncated: Bool) {
        // Open read-only ONCE. `FileHandle(forReadingFrom:)` opens `O_RDONLY`,
        // so the monitor can never mutate the user's transcripts.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], false)
        }
        defer { try? handle.close() }

        // Re-serialize redacted records into one JSONL buffer; one
        // `JSONSerialization.data` per line keeps the redaction barrier
        // intact while reusing the parser's own block extraction.
        var redactedJSONL = Data()
        let newline: UInt8 = 0x0A

        // Bytes of the current (not-yet-terminated) line. Bounded by the
        // line cap; once a line overflows we drop its bytes (mirrors
        // `ClaudeSessionIndex`'s overflow handling) and resync on the next
        // newline so memory can't grow without limit.
        var pending = Data()
        var pendingOverflowed = false

        func appendSegment(_ segment: Data.SubSequence) {
            if pendingOverflowed { return }
            if pending.count + segment.count > detailMaxLineBytes {
                pendingOverflowed = true
                return
            }
            pending.append(contentsOf: segment)
        }

        func finalizeLine() {
            defer {
                pending.removeAll(keepingCapacity: true)
                pendingOverflowed = false
            }
            if pendingOverflowed || pending.isEmpty { return }
            guard let obj = try? JSONSerialization.jsonObject(
                    with: pending, options: []) as? [String: Any]
            else { return }
            let redacted = ClaudeLogParser.redact(obj)
            guard JSONSerialization.isValidJSONObject(redacted),
                  let out = try? JSONSerialization.data(
                    withJSONObject: redacted, options: [])
            else { return }
            redactedJSONL.append(out)
            redactedJSONL.append(newline)
        }

        while let chunk = try? handle.read(upToCount: detailReadChunkBytes),
              !chunk.isEmpty {
            var searchStart = chunk.startIndex
            while let nlIndex = chunk[searchStart...].firstIndex(of: newline) {
                appendSegment(chunk[searchStart..<nlIndex])
                finalizeLine()
                searchStart = chunk.index(after: nlIndex)
            }
            // Tail of the chunk (no newline yet) joins the pending line.
            if searchStart < chunk.endIndex {
                appendSegment(chunk[searchStart...])
            }
        }
        // Trailing line without a final newline.
        finalizeLine()

        let parser = ClaudeLogParser(maxEvents: cap)
        let parsed = parser.parse(redactedJSONL)
        return (parsed, parsed.count >= cap)
    }
}

// MARK: - View

/// Master-detail browser for Claude Code sessions. Public so the host
/// (`MarkdownViewer/main.swift`) can wrap it in an `NSHostingController`.
public struct ClaudeMonitorView: View {
    @StateObject private var model: ClaudeMonitorModel

    /// Default root is `~/.claude`. The override is for tests / screenshots
    /// that point at a fixture tree.
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude", isDirectory: true)) {
        _model = StateObject(wrappedValue: ClaudeMonitorModel(root: root))
    }

    public var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(Palette.windowBackground)
        .onAppear { model.loadSessions() }
        .accessibilityIdentifier("mdv.claudeMonitor")
    }

    // MARK: Master pane

    private var sessionList: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if model.isLoadingSessions && model.sessions.isEmpty {
                centeredHint("Scanning \(model.root.path)…")
            } else if model.filteredSessions.isEmpty {
                centeredHint(model.sessions.isEmpty
                    ? "No Claude sessions found under \(model.root.path)."
                    : "No sessions match the filter.")
            } else {
                List(selection: Binding(
                    get: { model.selectedKey },
                    set: { newKey in
                        if let key = newKey,
                           let s = model.sessions.first(where: { $0.key == key }) {
                            model.selectSession(s)
                        }
                    }
                )) {
                    ForEach(model.filteredSessions) { session in
                        sessionRow(session)
                            .tag(session.key)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Palette.controlBackground)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by title or path", text: $model.searchText)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button(action: { model.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Button(action: { model.loadSessions() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Re-scan ~/.claude")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func sessionRow(_ s: ClaudeSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.title?.isEmpty == false ? s.title! : s.key)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                Text(Self.relativeDate(s.lastTimestamp))
                Text("·")
                Text("\(s.messageCount) msg")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            if let cwd = s.cwd {
                Text(Self.abbreviateHome(cwd))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detail: some View {
        if let session = model.selectedSession {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(session)
                Divider()
                if model.isLoadingEvents {
                    centeredHint("Loading transcript…")
                } else if model.events.isEmpty {
                    centeredHint("No displayable events in this transcript.")
                } else {
                    transcript
                }
            }
        } else {
            centeredHint("Select a session to view its transcript.")
        }
    }

    private func detailHeader(_ s: ClaudeSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.title?.isEmpty == false ? s.title! : s.key)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 10) {
                label("doc.text", "\(s.messageCount) messages")
                label("list.bullet", "\(s.eventCount) events")
                if let cwd = s.cwd {
                    label("folder", Self.abbreviateHome(cwd))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if let notice = model.detailNotice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.events) { event in
                    eventCard(event)
                }
            }
            .padding(12)
        }
    }

    private func eventCard(_ event: ClaudeEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: kindGlyph(event.kind))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(kindColor(event.kind))
                    .accessibilityLabel(kindLabel(event.kind))
                Text(kindLabel(event.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(kindColor(event.kind))
                Spacer()
                if let ts = event.timestamp {
                    Text(Self.timeFormatter.string(from: ts))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(detailText(event))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Palette.sidebarPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Event rendering helpers

    /// Full text/summary for the detail card. Tool calls render
    /// `name` + a compact arg dump; the redaction has already scrubbed
    /// secrets out of the underlying record.
    private func detailText(_ event: ClaudeEvent) -> String {
        switch event.kind {
        case .userMessage(let text), .assistantMessage(let text):
            return text
        case .thinking(let text):
            return text
        case .toolUse(_, let name, let input):
            let args = input
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            return args.isEmpty ? name : "\(name)\n\(args)"
        case .toolResult(_, let summary):
            return summary
        }
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

    // MARK: Small reusable bits

    private func label(_ glyph: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: glyph)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
    }

    private func centeredHint(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Formatting

    /// `nonisolated(unsafe)` shared formatters — same discipline as
    /// `ClaudeLogParser`'s ISO formatters. `DateFormatter`/`RelativeDateTimeFormatter`
    /// are read-only-thread-safe in practice; the view body is `@MainActor`
    /// anyway, so these are only ever touched from the main thread here.
    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
