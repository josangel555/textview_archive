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

            Button("Export…") {
                ReviewExportCoordinator.exportToClipboard(
                    session, instructions: draftInstructions
                )
            }
            .controlSize(.small)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(session.review.comments.isEmpty)
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
