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
    /// The item shown in the reader pane (slice 2). View-local — tapping an item
    /// sets it (and marks it read via the model).
    @State private var selectedItemID: String?

    var body: some View {
        HSplitView {
            // TSK-488 / CLAUDE.md compositor rule: the SwiftUI list panes share this
            // container with the opaque WKWebView reader (HTMLRenderedView), so each
            // gets its OWN layer via .compositingGroup() — else the representable's
            // CALayer composites OVER the earlier-painted SwiftUI siblings and blanks
            // them. (The on-screen occlusion check is WindowServer-pixel — owner/VM,
            // realized when slice 3 mounts this view.)
            feedSidebar
                .compositingGroup()
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            itemList
                .compositingGroup()
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 460)
            readerPane
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .accessibilityIdentifier("mdv.feedReader")
    }

    // MARK: - Reader pane (slice 2 — the selected item's content)

    private var selectedItem: FeedReaderModel.DisplayItem? {
        guard let id = selectedItemID else { return nil }
        return model.items.first { $0.id == id }
    }

    @ViewBuilder
    private var readerPane: some View {
        if let item = selectedItem {
            // The feed item's summaryHTML is UNTRUSTED — HTMLRenderedView sanitizes
            // internally (HTMLDocumentPolicy → HTMLSanitizer) + JS-default-deny, the
            // same hardened path the main HTML-doc view uses (TSK-1189). The item's
            // link is the base URL (relative-link resolution), else about:blank.
            HTMLRenderedView(
                rawHTML: item.item.summaryHTML,
                documentURL: item.item.link.flatMap { URL(string: $0) }
                    ?? URL(string: "about:blank")!)
                .accessibilityIdentifier("mdv.feedReader.reader")
        } else {
            Text("Select an item to read")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                    selectedItemID = di.id
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
