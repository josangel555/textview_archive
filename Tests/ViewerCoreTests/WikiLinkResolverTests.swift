import Testing
import Foundation
@testable import ViewerCore

/// `[[wikilink]]` / relative-link resolution (2026-08-01). The rendered
/// view intercepts a clicked local link and resolves it with this ladder:
/// beside the file → `.md` appended → (bare names only) the workspace
/// root → `.md` at the root. Pure, IO-injected — the whole policy pins
/// here on the host.
@Suite struct WikiLinkResolverTests {

    private let base = URL(fileURLWithPath: "/ws/docs", isDirectory: true)
    private let root = URL(fileURLWithPath: "/ws", isDirectory: true)

    private func resolve(_ clickedName: String, existing: Set<String>) -> URL? {
        WikiLinkResolver.resolve(
            clicked: base.appendingPathComponent(clickedName),
            baseDir: base,
            workspaceRoot: root,
            fileExists: { existing.contains($0) })
    }

    @Test("exact file beside the document wins")
    func exactBesideDoc() {
        #expect(resolve("notes.md", existing: ["/ws/docs/notes.md"])?.path
                == "/ws/docs/notes.md")
    }

    @Test("extensionless target gets .md appended (the Obsidian idiom)")
    func mdAppended() {
        #expect(resolve("Design", existing: ["/ws/docs/Design.md"])?.path
                == "/ws/docs/Design.md")
    }

    @Test("bare name falls back to the workspace root, then root + .md")
    func rootFallback() {
        #expect(resolve("README", existing: ["/ws/README"])?.path == "/ws/README")
        #expect(resolve("Roadmap", existing: ["/ws/Roadmap.md"])?.path
                == "/ws/Roadmap.md")
    }

    @Test("exact-beside beats the root fallback when both exist")
    func besideBeatsRoot() {
        #expect(resolve("Design", existing: ["/ws/docs/Design.md", "/ws/Design.md"])?.path
                == "/ws/docs/Design.md")
    }

    @Test("a pathed target never jumps to the root — deep relatives stay deliberate")
    func pathedTargetNoRootJump() {
        // Clicked resolves to /ws/other/Design (the author wrote ../other/Design);
        // /ws/Design.md existing must NOT hijack it.
        let clicked = URL(fileURLWithPath: "/ws/other/Design")
        let hit = WikiLinkResolver.resolve(
            clicked: clicked, baseDir: base, workspaceRoot: root,
            fileExists: { $0 == "/ws/Design.md" })
        #expect(hit == nil, "root fallback is for bare names only")
    }

    @Test("unresolvable comes back nil (the caller says so out loud)")
    func unresolvableIsNil() {
        #expect(resolve("Ghost", existing: []) == nil)
    }

    // MARK: - I-20 (owner 2026-08-11): absolute paths are first-class

    @Test("an absolute FILE path resolves directly — anywhere on disk")
    func absoluteFilePathResolvesDirect() {
        // `[link](/Users/x/notes/todo.md)` — WebKit hands the absolute file
        // URL through; step 1 must return it verbatim, no workspace ties.
        let clicked = URL(fileURLWithPath: "/Users/x/notes/todo.md")
        let hit = WikiLinkResolver.resolve(
            clicked: clicked, baseDir: base, workspaceRoot: root,
            fileExists: { $0 == "/Users/x/notes/todo.md" })
        #expect(hit?.path == "/Users/x/notes/todo.md")
    }

    @Test("an absolute FOLDER path resolves too (the open router folders it)")
    func absoluteFolderPathResolves() {
        // `fileExists(atPath:)` is true for directories; the resolver
        // returns the dir URL and `DocumentModel.openPath` routes it to
        // `openFolder` — absolute folder links open the folder in-app.
        let clicked = URL(fileURLWithPath: "/Users/x/projects/site")
        let hit = WikiLinkResolver.resolve(
            clicked: clicked, baseDir: base, workspaceRoot: root,
            fileExists: { $0 == "/Users/x/projects/site" })
        #expect(hit?.path == "/Users/x/projects/site")
    }
}
