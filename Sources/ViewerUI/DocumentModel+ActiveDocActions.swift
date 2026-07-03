import Foundation
import AppKit
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Active-document actions (tool windows + export)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). These
// open a hosted tool-window for, or export, the ACTIVE text file/folder:
// Annotations / Log Patterns / Package Explorer / Local History / Dependency
// Graph / Folder Treemap, and the docx/RTF/RTFD/copy-RTF exporters. The
// `activeTextFile()` helper is private to this group (every caller is here; the
// stayers in DocumentModel don't use it), so it moves with them. All other deps
// are public (`openHostedView`, `localHistoryStore`, `sidebar`, `openPath`).
// Behaviour-identical move; no @Published involved → zero render risk.
extension DocumentModel {

    /// The active tab's text + URL (live editor buffer if present, else the
    /// loaded-from-disk contents), or nil for a non-text tab — shared by the
    /// tool-window + export commands below (TSK-1121/1153/1144/…).
    private func activeTextFile() -> (text: String, url: URL)? {
        guard let tab = tabs.selected, let url = tab.url else { return nil }
        if let buf = editor.editorBuffers[tab.id] { return (buf.text, url) }
        if case .loaded(let f) = tab.state { return (f.contents, url) }
        return nil
    }

    /// TSK-1121 — open a navigable "Annotations" list for the ACTIVE text file
    /// (TODO/FIXME/HACK/XXX/NOTE/BUG via SourceAnnotationScanner) as a hosted tab;
    /// tapping a row jumps to the line. Returns the annotation count (0 = no-op:
    /// no active text file). The scan + jump (openPath atLine) are host-tested.
    @discardableResult
    public func showAnnotations() -> Int {
        guard let (text, url) = activeTextFile() else { return 0 }
        let annotations = SourceAnnotationScanner.scan(text)
        let view = AnnotationsView(
            annotations: annotations,
            onJump: { [weak self] line in self?.openPath(url, atLine: line) })
        _ = openHostedView(title: "Annotations — \(url.lastPathComponent)", rootView: view)
        return annotations.count
    }

    /// TSK-1153 — open a "Patterns" summary of the ACTIVE log/text file's repeated
    /// lines (LogPatternClusterer) as a hosted tab. Returns the distinct-pattern
    /// count (0 = no-op: no active text file). The clustering is host-tested.
    @discardableResult
    public func showLogPatterns() -> Int {
        guard let (text, url) = activeTextFile() else { return 0 }
        let result = LogPatternClusterer.cluster(text)
        _ = openHostedView(title: "Patterns — \(url.lastPathComponent)",
                           rootView: LogPatternsView(result: result))
        return result.distinctPatterns
    }

    /// TSK-1109 — open a read-only explorer of the ACTIVE package manifest's
    /// declared dependencies (package.json / Cargo.toml, via PackageManifestParser)
    /// as a hosted tab. Returns the dependency count (0 = no-op: the active file
    /// isn't a recognized manifest). The parse is host-tested.
    @discardableResult
    public func showPackageExplorer() -> Int {
        guard let (text, url) = activeTextFile() else { return 0 }
        let manifest: DependencyManifest
        switch url.lastPathComponent {
        case "package.json": manifest = PackageManifestParser.parsePackageJSON(text)
        case "Cargo.toml":   manifest = PackageManifestParser.parseCargoTOML(text)
        default: return 0
        }
        _ = openHostedView(title: "Dependencies — \(url.lastPathComponent)",
                           rootView: PackageExplorerView(manifest: manifest))
        return manifest.packages.count
    }

    /// TSK-1144 — export the ACTIVE text document (parsed as Markdown) to a Word
    /// `.docx` at `url`. Returns false when there's no active text file or the
    /// write fails. The parse (RichTextParser) + emit (DocxExporter) are host-tested.
    @discardableResult
    public func exportActiveAsDocx(to url: URL) -> Bool {
        guard let (text, _) = activeTextFile() else { return false }
        let data = DocxExporter.export(RichTextParser.parse(text))
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// TSK-1144 — export the ACTIVE text document (parsed as Markdown) to RTF at
    /// `url`. False when there's no active text file or the write fails.
    @discardableResult
    public func exportActiveAsRTF(to url: URL) -> Bool {
        guard let (text, _) = activeTextFile() else { return false }
        let rtf = RtfExporter.export(RichTextParser.parse(text))
        return (try? rtf.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// TSK-1144 — copy the ACTIVE document (Markdown → RTF) to the pasteboard as
    /// rich text, so it pastes formatted into Mail/Pages/etc. False when there's
    /// no active text file. Mirrors "Copy as HTML"; the RTF emit is host-tested.
    @discardableResult
    public func copyActiveAsRTF(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let (text, _) = activeTextFile(),
              let data = RtfExporter.export(RichTextParser.parse(text)).data(using: .utf8)
        else { return false }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .rtf)
        return true
    }

    /// TSK-1144 — export the ACTIVE document to an `.rtfd` package (a directory
    /// bundle whose `TXT.rtf` holds the RTF — the AppKit convention). False when
    /// there's no active text file or the write fails.
    @discardableResult
    public func exportActiveAsRTFD(to url: URL) -> Bool {
        guard let (text, _) = activeTextFile() else { return false }
        let rtf = RtfExporter.export(RichTextParser.parse(text))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try rtf.write(to: url.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// TSK-1103/TSK-1462 — open the active file's Local History as a hosted tab.
    /// Routes to the UNIFIED viewer (timeline + size deltas + diff-vs-current +
    /// range diff + confirmed Restore) — the File-menu path used to open the old
    /// minimal view-only list while the context menus got the full viewer.
    /// Returns the version count (0 = no active text file; the viewer still
    /// opens with its empty state explaining when snapshots are taken).
    @discardableResult
    public func showLocalHistory() -> Int {
        guard let (_, url) = activeTextFile() else { return 0 }
        openLocalHistory(for: url)
        return localHistoryStore.versions(for: url.standardizedFileURL.path).count
    }

    /// TSK-1100: open the project's import-dependency graph (DependencyGraphView)
    /// as a hosted tab — surfaces the built-but-unreachable TSK-280 feature.
    /// The extraction walks the source tree, so it's built OFF-MAIN; the view
    /// paints the laid-out result (model + layout are host-tested; the Canvas
    /// render is the VM/review residue). Clicking a node opens that file.
    /// No-op when no folder/project root is open.
    public func showDependencyGraph() {
        guard let root = sidebar.rootURL else { return }
        Task { [weak self] in
            let graph = await Task.detached(priority: .userInitiated) {
                DependencyGraph.importGraph(root: root)
            }.value
            guard let self else { return }
            let view = DependencyGraphView(
                graph: graph,
                onOpenFile: { [weak self] url in self?.openPath(url) })
            _ = self.openHostedView(title: "Dependency Graph", rootView: view)
        }
    }

    /// TSK-506: open a size-proportional treemap of a folder (FolderTreemapView)
    /// as a hosted tab — surfaces the built-but-unreachable view. The view's
    /// FolderTreemapModel scans the folder OFF-MAIN itself, so this just opens
    /// it. Defaults to the project root; no-op when no folder is open.
    public func showFolderTreemap(folder: URL? = nil) {
        guard let target = folder ?? sidebar.rootURL else { return }
        let view = FolderTreemapView(doc: self, folder: target)
        _ = openHostedView(
            title: "Folder Sizes: \(target.lastPathComponent)", rootView: view)
    }
}
