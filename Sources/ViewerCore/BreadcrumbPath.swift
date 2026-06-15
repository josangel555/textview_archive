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
