import SwiftUI
import ViewerCore

/// TSK-1149 (slice 1) — the feed-reader tool-window SHELL: a sidebar of feed
/// summaries (with unread counts) beside the selected feed's item list. Binds the
/// host-tested `FeedReaderViewModel` — its behaviour (selectFeed / markRead /
/// summaries / items) is pinned by `FeedReaderViewModelTests`, so the action
/// closures the buttons fire are already under test; this view is the render tail
/// (owner/VM closes the on-screen pixels).
///
/// Deferred slices: the per-item reader pane (a sanitized WKWebView) is slice 2 —
/// it shares this container with the SwiftUI lists, so it MUST apply the
/// compositor-occlusion rule (CLAUDE.md / TSK-488): give the SwiftUI side
/// `.compositingGroup().zIndex(1)` vs the WebView `zIndex(0)`. The DockedToolWindow
/// mount + the refresh wiring are slice 3.
struct FeedReaderView: View {
    @ObservedObject var model: FeedReaderViewModel

    var body: some View {
        HSplitView {
            feedSidebar
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 340)
            itemList
                .frame(minWidth: 280, maxWidth: .infinity)
        }
        .accessibilityIdentifier("mdv.feedReader")
    }

    // MARK: - Feed sidebar (summaries + unread rollups)

    private var feedSidebar: some View {
        List {
            ForEach(model.summaries) { summary in
                Button {
                    model.selectFeed(summary.subscription.url)
                } label: {
                    HStack(spacing: 6) {
                        Text(summary.subscription.title.isEmpty
                             ? summary.subscription.url.absoluteString
                             : summary.subscription.title)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if summary.unread > 0 {
                            Text("\(summary.unread)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    summary.subscription.url == model.selectedFeedURL
                        ? Color.accentColor.opacity(0.15) : Color.clear)
                .accessibilityIdentifier("mdv.feedReader.feed")
            }
        }
        .overlay {
            if model.summaries.isEmpty {
                Text("No feeds").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Item list (the selected feed, newest-first, read-annotated)

    private var itemList: some View {
        List {
            ForEach(model.items) { di in
                Button {
                    model.markRead(itemID: di.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(di.item.title.isEmpty ? "(untitled)" : di.item.title)
                            .fontWeight(di.isRead ? .regular : .semibold)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let author = di.item.author, !author.isEmpty {
                                Text(author).lineLimit(1)
                            }
                            if let published = di.item.published {
                                Text(published, style: .date)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mdv.feedReader.item")
            }
        }
        .overlay {
            if model.selectedFeedURL == nil {
                Text("Select a feed").foregroundStyle(.secondary)
            } else if model.items.isEmpty {
                Text("No items").foregroundStyle(.secondary)
            }
        }
    }
}
