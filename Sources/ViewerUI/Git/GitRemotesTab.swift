import SwiftUI
import AppKit
import ViewerCore

/// Remotes sub-tab: name, URL, last-fetch (FETCH_HEAD mtime). Click to
/// open the web view in the default browser (ssh remotes are translated
/// to https for the URL open).
struct GitRemotesTab: View {
    @ObservedObject var model: GitPanelModel
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
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(r.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Spacer(minLength: 4)
                    Text(lastFetchedLabel(r.lastFetchedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(r.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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

    /// Translate git@host:owner/repo(.git)? and ssh://host/owner/repo to
    /// https://host/owner/repo so the browser can open them. Leaves
    /// http(s):// URLs alone.
    static func webURL(from remote: String) -> URL? {
        if remote.hasPrefix("http://") || remote.hasPrefix("https://") {
            var s = remote
            if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
            return URL(string: s)
        }
        if remote.hasPrefix("git@") {
            // git@github.com:foo/bar.git → https://github.com/foo/bar
            let body = String(remote.dropFirst("git@".count))
            guard let colon = body.firstIndex(of: ":") else { return nil }
            let host = body[..<colon]
            var path = String(body[body.index(after: colon)...])
            if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
            return URL(string: "https://\(host)/\(path)")
        }
        if remote.hasPrefix("ssh://") {
            // ssh://git@host/foo/bar.git → https://host/foo/bar
            var s = remote.dropFirst("ssh://".count)
            if let at = s.firstIndex(of: "@") { s = s[s.index(after: at)...] }
            var str = String(s)
            if str.hasSuffix(".git") { str = String(str.dropLast(4)) }
            return URL(string: "https://\(str)")
        }
        return nil
    }

    private func openInBrowser(_ r: GitClient.RemoteEntry) {
        guard let url = Self.webURL(from: r.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
