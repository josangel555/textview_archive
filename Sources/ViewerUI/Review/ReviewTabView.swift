import SwiftUI
import AppKit
import ViewerCore

/// The top-level review document surface (§6.4): a review-aware `DiffView`
/// with a comment sidebar and an export toolbar. Hosting it as a first-class
/// document tab (the fileless `DocumentState` arm) is deferred follow-up
/// wiring; this view is self-contained so it can be presented from a sheet /
/// the Git panel today and slotted into the tab host later without change.
struct ReviewTabView: View {
    @ObservedObject var doc: DocumentModel
    @ObservedObject var session: ReviewSession

    @State private var draftInstructions: String = ReviewExporter.defaultInstructions
    @State private var sidebarVisible = true

    /// TSK-912: when set, the toolbar "Add comment" sheet is presented for this
    /// target (the first anchorable line of the loaded diff). nil = no sheet.
    @State private var addTarget: ReviewSession.AddTarget?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                // Review-aware diff — the SAME DiffView, with a session.
                DiffView(text: "", doc: doc, reviewSession: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .center) {
                        if session.diffFiles.isEmpty {
                            Text("No diff loaded.\nReload the review to populate it.")
                                .multilineTextAlignment(.center)
                                .font(.system(size: doc.uiSize(12)))
                                .foregroundStyle(.secondary)
                        }
                    }
                if sidebarVisible {
                    Divider()
                    CommentSidebar(
                        doc: doc,
                        comments: session.review.comments.filter { $0.parentId == nil },
                        onSelect: { _ in /* VM-owed: scroll-to-anchor */ }
                    )
                    .frame(width: 280)
                }
            }
        }
        .onAppear { session.reload() }
        .sheet(isPresented: addCommentSheetBinding) {
            if let target = addTarget {
                addCommentSheet(target: target)
            }
        }
    }

    /// Presents the toolbar composer while a target is set. Dismissing clears
    /// the target so the next "Add comment" re-resolves the first line.
    private var addCommentSheetBinding: Binding<Bool> {
        Binding(
            get: { addTarget != nil },
            set: { if !$0 { addTarget = nil } }
        )
    }

    /// The toolbar-driven composer (TSK-912). Captures + appends via the
    /// session's `addComment(at:)` closure; no diff-line hover required.
    private func addCommentSheet(target: ReviewSession.AddTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add comment")
                .font(.system(size: doc.uiSize(13), weight: .semibold))
            Text("On \(targetDescription(target))")
                .font(.system(size: doc.uiSize(10)))
                .foregroundStyle(.secondary)
            CommentEditorView(
                doc: doc,
                onCommit: { severity, body in
                    _ = session.addComment(at: target, severity: severity, body: body)
                    addTarget = nil
                },
                onCancel: { addTarget = nil }
            )
        }
        .padding(14)
        .frame(width: 360)
        .accessibilityIdentifier("mdv.review.toolbarComposer")
    }

    private func targetDescription(_ t: ReviewSession.AddTarget) -> String {
        let path = session.diffFiles.indices.contains(t.fileIndex)
            ? { let f = session.diffFiles[t.fileIndex]
                return f.newPath.isEmpty ? f.oldPath : f.newPath }()
            : "file"
        return "\(path):\(t.lineNo)"
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.review.title)
                    .font(.system(size: doc.uiSize(13), weight: .semibold))
                    .lineLimit(1)
                Text(stateLine)
                    .font(.system(size: doc.uiSize(10)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // TSK-912: the visible add-comment entry point. Resolves the first
            // anchorable diff line and opens the composer sheet. Disabled when
            // the diff has no reviewable lines (nothing to anchor to).
            Button {
                addTarget = session.firstAddTarget
            } label: {
                Label("Add Comment", systemImage: "plus.bubble")
            }
            .controlSize(.small)
            .help("Add a review comment on the first changed line")
            .disabled(session.firstAddTarget == nil)
            .accessibilityIdentifier("mdv.review.toolbarAddComment")

            Button {
                sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle comments")

            Button("Mark Complete") {
                _ = session.setState(.complete)
            }
            .controlSize(.small)
            .disabled(!session.review.state.canTransition(to: .complete))

            // TSK-530: two export modes. The menu's primary action (clicking
            // the label) keeps the with-code default + the ⇧⌘E shortcut; the
            // disclosure offers the without-code payload (comments + anchors
            // only — leaner, and the source never leaves the machine).
            Menu {
                Button("Copy with Code Snippets") {
                    ReviewExportCoordinator.exportToClipboard(
                        session, instructions: draftInstructions, mode: .withCode
                    )
                }
                .accessibilityIdentifier("mdv.review.exportWithCode")
                Button("Copy without Code Snippets") {
                    ReviewExportCoordinator.exportToClipboard(
                        session, instructions: draftInstructions, mode: .withoutCode
                    )
                }
                .accessibilityIdentifier("mdv.review.exportWithoutCode")
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            } primaryAction: {
                ReviewExportCoordinator.exportToClipboard(
                    session, instructions: draftInstructions, mode: .withCode
                )
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Copy the review to the clipboard (with or without code snippets)")
            .disabled(session.review.comments.isEmpty)
            .accessibilityIdentifier("mdv.review.exportMenu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stateLine: String {
        let total = session.review.comments.filter { $0.parentId == nil }.count
        let unresolved = session.review.comments.filter { $0.parentId == nil && !$0.resolved }.count
        return "\(session.review.state.rawValue) · \(total) comments · \(unresolved) unresolved"
    }
}
