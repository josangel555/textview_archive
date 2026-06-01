import SwiftUI
import ViewerCore

// MARK: - Severity presentation
//
// Shared color/label mapping for the 6 `ReviewComment.Severity` cases.
// Kept here so the editor, thread card, and sidebar agree.

extension ReviewComment.Severity {
    var dotColor: Color {
        switch self {
        case .blocker:    return .red
        case .issue:      return .orange
        case .suggestion: return .blue
        case .question:   return .purple
        case .info:       return .secondary
        case .praise:     return .green
        }
    }
    var label: String {
        switch self {
        case .blocker:    return "Blocker"
        case .issue:      return "Issue"
        case .suggestion: return "Suggestion"
        case .question:   return "Question"
        case .info:       return "Info"
        case .praise:     return "Praise"
        }
    }
}

extension AnchorState {
    /// Badge text + color for the §3.2 staleness signal. `nil` for `.current`
    /// (no badge — the anchor is valid, render inline silently).
    var badge: (text: String, color: Color)? {
        switch self {
        case .current: return nil
        case .stale:   return ("code changed since review", .orange)
        case .unknown: return ("anchor not verifiable", .secondary)
        }
    }
}

// MARK: - CommentEditorView (§6.3)
//
// Inline composer: severity picker + markdown body. Reuses SwiftUI's
// TextEditor and the in-tree font sizing — NO markdown lib (bundle cap +
// dependency rule). Preview rendering is deferred polish; v2 ships the raw
// editor (the body is markdown, surfaced verbatim).

struct CommentEditorView: View {
    @ObservedObject var doc: DocumentModel

    /// Prefilled when editing an existing comment; empty for a new one.
    @State var severity: ReviewComment.Severity
    @State var bodyText: String

    let onCommit: (_ severity: ReviewComment.Severity, _ body: String) -> Void
    let onCancel: () -> Void

    init(
        doc: DocumentModel,
        severity: ReviewComment.Severity = .issue,
        body: String = "",
        onCommit: @escaping (_ severity: ReviewComment.Severity, _ body: String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.doc = doc
        _severity = State(initialValue: severity)
        _bodyText = State(initialValue: body)
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Severity", selection: $severity) {
                ForEach(ReviewComment.Severity.allCases, id: \.self) { sev in
                    Text(sev.label).tag(sev)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 160, alignment: .leading)

            TextEditor(text: $bodyText)
                .font(.system(size: doc.uiSize(12), design: .monospaced))
                .frame(minHeight: 56, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .controlSize(.small)
                Button("Comment") {
                    let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onCommit(severity, trimmed)
                }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - CommentThreadView (§6.3)
//
// A rendered thread card under an anchored diff line: parent comment +
// replies, severity dot, author·time, the staleness badge, and the
// Edit/Resolve/Reply/Delete actions.

struct CommentThreadView: View {
    @ObservedObject var doc: DocumentModel
    let parent: ReviewComment
    let replies: [ReviewComment]
    let anchorState: AnchorState

    let onResolveToggle: () -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(parent)
            if let badge = anchorState.badge {
                Label(badge.text, systemImage: "exclamationmark.triangle")
                    .font(.system(size: doc.uiSize(9)))
                    .foregroundStyle(badge.color)
            }
            Text(parent.body)
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(parent.resolved ? .secondary : .primary)
                .strikethrough(parent.resolved)

            ForEach(replies) { reply in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(reply.body)
                        .font(.system(size: doc.uiSize(11)))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            }

            actions
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(parent.severity.dotColor.opacity(0.4), lineWidth: 0.75)
        )
    }

    private func header(_ c: ReviewComment) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(c.severity.dotColor)
                .frame(width: 8, height: 8)
            Text(c.severity.label)
                .font(.system(size: doc.uiSize(10), weight: .semibold))
                .foregroundStyle(c.severity.dotColor)
            Text("· line \(c.anchor.startLine == c.anchor.endLine ? "\(c.anchor.startLine)" : "\(c.anchor.startLine)–\(c.anchor.endLine)")")
                .font(.system(size: doc.uiSize(10)))
                .foregroundStyle(.tertiary)
            Spacer()
            if c.resolved {
                Text("resolved")
                    .font(.system(size: doc.uiSize(9)))
                    .foregroundStyle(.green)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(parent.resolved ? "Reopen" : "Resolve", action: onResolveToggle)
            Button("Reply", action: onReply)
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
            Spacer()
        }
        .buttonStyle(.plain)
        .font(.system(size: doc.uiSize(10)))
        .foregroundStyle(.tint)
    }
}

// MARK: - CommentSidebar (§6.3)
//
// Right-rail index: severity dot + file:line + body snippet, click-to-scroll.
// Stage-3 structural; the scroll-to wiring is VM-owed interaction.

struct CommentSidebar: View {
    @ObservedObject var doc: DocumentModel
    let comments: [ReviewComment]
    let onSelect: (ReviewComment) -> Void

    var body: some View {
        if comments.isEmpty {
            Text("No comments yet.")
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(comments) { c in
                Button { onSelect(c) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(c.severity.dotColor).frame(width: 7, height: 7)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(c.filePath):\(c.anchor.startLine)")
                                .font(.system(size: doc.uiSize(10), design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(c.body)
                                .font(.system(size: doc.uiSize(11)))
                                .foregroundStyle(c.resolved ? .tertiary : .primary)
                                .lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }
}
