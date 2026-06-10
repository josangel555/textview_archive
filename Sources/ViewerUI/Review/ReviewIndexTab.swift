import SwiftUI
import ViewerCore

/// The Git-panel "Review" tab (§6.4): a flat list of reviews stored in the
/// repo's project-local `.textview/reviews/`, plus a "New review…" affordance.
///
/// Stage 2 lands the wiring (the `.review` tab case routes here) with a
/// minimal list. Stage 3 fleshes out row interaction, the new-review sheet,
/// and navigation into `ReviewTabView`. Kept window-free and headless-safe.
struct ReviewIndexTab: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var doc: DocumentModel

    @State private var summaries: [ReviewSummary] = []

    var body: some View {
        Group {
            // TSK-523: an active session takes over the tab — the
            // review-aware DiffView (inline structured diff + comments).
            if let session = model.activeReviewSession {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            model.closeActiveReview()
                            reload()
                        } label: {
                            Label("Reviews", systemImage: "chevron.left")
                                .font(.system(size: doc.uiSize(11)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mdv.review.back")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    Divider()
                    ReviewTabView(doc: doc, session: session)
                }
            } else if model.repoRoot == nil {
                placeholder("Open a file in a git repository to start a review.")
            } else if summaries.isEmpty {
                placeholder("No reviews yet.\nStart one from a diff or a commit.")
            } else {
                List(summaries) { s in
                    ReviewSummaryRow(summary: s, doc: doc)
                        .contentShape(Rectangle())
                        .onTapGesture { model.openReview(id: s.id) }
                }
                .listStyle(.inset)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.repoRoot) { _, _ in reload() }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Text(text)
                .multilineTextAlignment(.center)
                .font(.system(size: doc.uiSize(12)))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        guard let root = model.repoRoot else {
            summaries = []
            model.reviewCount = nil
            return
        }
        let store = ReviewStore.projectLocal(repoRoot: root)
        summaries = store.list()
        // Badge the tab with the total unresolved count across reviews.
        let unresolved = summaries.reduce(0) { $0 + $1.unresolvedCount }
        model.reviewCount = unresolved == 0 ? nil : unresolved
    }
}

/// One row in the review index. Severity-agnostic summary; Stage 3 adds the
/// state pill + click-to-open.
struct ReviewSummaryRow: View {
    let summary: ReviewSummary
    @ObservedObject var doc: DocumentModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.system(size: doc.uiSize(12), weight: .medium))
                    .lineLimit(1)
                Text(stateLine)
                    .font(.system(size: doc.uiSize(10)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if summary.unresolvedCount > 0 {
                Text("\(summary.unresolvedCount)")
                    .font(.system(size: doc.uiSize(10), weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
        }
        .padding(.vertical, 2)
    }

    private var stateLine: String {
        let n = summary.commentCount
        let word = n == 1 ? "comment" : "comments"
        return "\(summary.state.rawValue) · \(n) \(word)"
    }
}
