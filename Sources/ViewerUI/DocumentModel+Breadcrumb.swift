import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Breadcrumb (file-path navigation, UX-A #224)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). The
// abbreviatable path breadcrumb of the current file + click-to-reveal. A clean
// verbatim move: pure derivation from `currentURL` plus a `revealInSidebar`
// forward — no stored state, no @Published, no private core helpers (both deps
// are already public), so no widening or vending was needed.
extension DocumentModel {
    /// One clickable segment of the current file's path breadcrumb.
    public struct BreadcrumbSegment: Identifiable, Equatable {
        /// Stable id = the absolute path up to and including this segment.
        public var id: String { url.path }
        /// Display name (the path component, or "~" / "/" for the roots).
        public let name: String
        /// The absolute URL this segment points at (a folder, except the
        /// last segment which is the file itself).
        public let url: URL
        /// True for the final segment (the file). The file segment reveals
        /// the file; folder segments reveal/navigate to that folder.
        public let isFile: Bool
    }

    /// Abbreviatable breadcrumb of the current file's path, home-relative
    /// (the `~` root collapses everything under `$HOME`). Each segment
    /// carries the absolute URL up to it so a click can reveal that folder
    /// in the sidebar. Empty when no file is open.
    ///
    /// The toolbar abbreviates the MIDDLE visually (leading "…") when the
    /// row is narrow; the full segment list is always available here so the
    /// overflow menu / tests see every component.
    public var pathBreadcrumb: [BreadcrumbSegment] {
        pathBreadcrumb(for: currentURL)
    }

    /// Per-URL variant (I-21 pane toolbars): each pane's breadcrumb renders
    /// ITS tab's path, not the app-wide current file's.
    public func pathBreadcrumb(for url: URL?) -> [BreadcrumbSegment] {
        guard let fileURL = url else { return [] }
        let std = fileURL.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
        let homePath = home.path
        let fullPath = std.path

        // Decide the display root: "~" when the file is under $HOME, else
        // the filesystem root "/". Build segments from there down.
        var segments: [BreadcrumbSegment] = []
        let underHome = fullPath == homePath
            || fullPath.hasPrefix(homePath + "/")
        let rootURL: URL = underHome ? home : URL(fileURLWithPath: "/")
        let rootName = underHome ? "~" : "/"
        segments.append(BreadcrumbSegment(
            name: rootName, url: rootURL, isFile: false))

        // Relative components from the root to the file.
        let rootPath = rootURL.path
        let rel: [String]
        if fullPath == rootPath {
            rel = []
        } else {
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            rel = String(fullPath.dropFirst(prefix.count))
                .split(separator: "/").map(String.init)
        }
        var cur = rootURL
        for (idx, comp) in rel.enumerated() {
            let isLast = idx == rel.count - 1
            cur = cur.appendingPathComponent(
                comp, isDirectory: !isLast || std.hasDirectoryPath)
            segments.append(BreadcrumbSegment(
                name: comp, url: cur, isFile: isLast))
        }
        return segments
    }

    /// Navigate to a breadcrumb segment: reveal the file (final segment)
    /// or the folder (any other segment) in the sidebar. Reuses the
    /// existing `revealInSidebar` (re-roots if needed, expands ancestors,
    /// selects). A folder segment that the sidebar can't reach (locked
    /// root, outside root) no-ops inside `revealInSidebar`.
    public func navigateToBreadcrumb(_ segment: BreadcrumbSegment) {
        revealInSidebar(segment.url)
    }
}
