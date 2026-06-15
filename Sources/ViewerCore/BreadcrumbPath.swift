import Foundation

/// Splits a file URL into clickable breadcrumb segments for the footer path bar
/// (TSK-933). Each segment carries the cumulative URL so a click can reveal that
/// ancestor folder (or the file itself). The home prefix collapses to a single
/// "~" segment (whose URL is the home dir). Pure — host-testable; the clickable
/// rendering is the VM tail.
public enum BreadcrumbPath {

    public struct Segment: Equatable, Sendable {
        public let name: String
        public let url: URL
        public init(name: String, url: URL) { self.name = name; self.url = url }
    }

    /// Right-click actions for a breadcrumb segment (TSK-934) — the footer's
    /// parity with the file-nav context menu. Folder segments get folder-nav
    /// verbs; the leaf file segment gets file verbs. The order IS the menu order.
    public enum Action: String, Equatable, Sendable, CaseIterable {
        case revealInSidebar
        case openFolder
        case openInDefaultApp
        case copyPath
        case revealInFinder
        case openInTerminal
    }

    /// The ordered context-menu actions for a segment. `isDirectory` is true for
    /// every segment except the leaf when the breadcrumb is for a file (the
    /// footer's usual case). Pure — host-testable; the menu rendering is VM tail.
    public static func menuActions(isDirectory: Bool) -> [Action] {
        if isDirectory {
            return [.revealInSidebar, .openFolder, .copyPath, .revealInFinder, .openInTerminal]
        } else {
            return [.revealInSidebar, .openInDefaultApp, .copyPath, .revealInFinder]
        }
    }

    public static func segments(for url: URL, home: URL) -> [Segment] {
        let std = url.standardizedFileURL
        let homeStd = home.standardizedFileURL
        if std.path == homeStd.path { return [Segment(name: "~", url: homeStd)] }

        let comps = std.pathComponents              // ["/", "Users", "jos", "proj", "f.txt"]
        guard !comps.isEmpty else { return [] }
        let homeComps = homeStd.pathComponents
        let underHome = comps.count > homeComps.count
            && Array(comps.prefix(homeComps.count)) == homeComps

        var segs: [Segment] = []
        var cumulative: [String]
        let start: Int
        if underHome {
            segs.append(Segment(name: "~", url: homeStd))
            cumulative = homeComps
            start = homeComps.count
        } else {
            cumulative = []
            start = 0
        }
        for i in start..<comps.count {
            cumulative.append(comps[i])
            let path = NSString.path(withComponents: cumulative)
            segs.append(Segment(name: comps[i], url: URL(fileURLWithPath: path)))
        }
        return segs
    }
}
