import SwiftUI
import AppKit
import ViewerCore

/// Remotes sub-tab: name, URL, last-fetch (FETCH_HEAD mtime). Click to
/// open the web view in the default browser (ssh remotes are translated
/// to https for the URL open).
struct GitRemotesTab: View {
    @ObservedObject var model: GitPanelModel
    /// UX-F (#228): zoom-scale helper threaded from the host
    /// (`DocumentModel.uiSize`). Defaults to identity so call sites
    /// without a document model render at the base size.
    var uiSize: (CGFloat) -> CGFloat = { $0 }
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    var body: some View {
        if model.remoteEntries.isEmpty {
            ScrollView {
                SidebarEmptyPlaceholder(message: "No remotes.")
            }
            .frame(height: bodyHeight)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.remoteEntries, id: \.name) { row($0) }
                }
            }
            .frame(height: bodyHeight)
        }
    }

    private func row(_ r: GitClient.RemoteEntry) -> some View {
        Button(action: { openInBrowser(r) }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: uiSize(9)))
                        .foregroundStyle(.tertiary)
                    Text(r.name)
                        .font(.system(size: uiSize(12), weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Spacer(minLength: 4)
                    Text(lastFetchedLabel(r.lastFetchedAt))
                        .font(.system(size: uiSize(9)))
                        .foregroundStyle(.tertiary)
                }
                Text(r.url)
                    .font(.system(size: uiSize(10), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 16)
            }
            .padding(.horizontal, uiSize(10))
            .padding(.vertical, uiSize(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(r.url)
    }

    private func lastFetchedLabel(_ date: Date?) -> String {
        guard let date else { return "never fetched" }
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:        return "fetched just now"
        case ..<3600:      return "fetched \(Int(diff / 60))m ago"
        case ..<86_400:    return "fetched \(Int(diff / 3600))h ago"
        case ..<604_800:   return "fetched \(Int(diff / 86_400))d ago"
        default:           return "fetched \(Int(diff / 604_800))w ago"
        }
    }

    /// Translate any git remote URL (https, git@ scp-style, ssh://) to its
    /// `https://host/owner/repo` web page so the browser can open it.
    /// Delegates to the host-tested `ForgeRemote` parser
    /// (`ViewerCore/Git/ForgeRemote.swift`) — the canonical, pure-logic
    /// home for remote-URL parsing and forge web-URL derivation.
    static func webURL(from remote: String) -> URL? {
        ForgeRemote.parse(remote)?.webURL
    }

    private func openInBrowser(_ r: GitClient.RemoteEntry) {
        guard let url = Self.webURL(from: r.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
