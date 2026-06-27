import Foundation

/// User-defined snippets, persisted as JSON, merged over the built-in starter
/// set (TSK-705, slice 4). Like VS Code's snippet JSON: the user can hand-edit
/// the file to add/override snippets even before there's a management UI — they
/// appear in the Insert-Snippet menu at next launch. A user snippet whose `id`
/// matches a built-in OVERRIDES it (user wins); other user snippets append.
///
/// Persistence mirrors `BookmarksStore` (JSON via `JSONFileStore`, off-main
/// coalesced writes). Main-actor-touched; thread-safety is not a goal.
public final class SnippetStore {
    public let storeURL: URL
    public let maxStoreFileBytes: Int
    private var userSnippets: [Snippet] = []

    public static func defaultStoreURL() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("snippets.json", isDirectory: false)
    }

    public init(storeURL: URL = SnippetStore.defaultStoreURL(),
                maxStoreFileBytes: Int = 1 * 1024 * 1024) {
        self.storeURL = storeURL
        self.maxStoreFileBytes = maxStoreFileBytes
        load()
    }

    /// Built-ins merged with user snippets: a user snippet with a built-in's
    /// `id` replaces it in place; brand-new user snippets follow the built-ins.
    public var all: [Snippet] {
        var out = SnippetLibrary.builtIns
        var indexByID = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.id, $0) })
        for s in userSnippets {
            if let i = indexByID[s.id] {
                out[i] = s                          // user overrides a built-in
            } else {
                indexByID[s.id] = out.count
                out.append(s)
            }
        }
        return out
    }

    /// The user-defined snippets only (what's persisted).
    public func userDefined() -> [Snippet] { userSnippets }

    /// Add (or replace, by id) a user snippet and persist.
    public func add(_ snippet: Snippet) {
        if let i = userSnippets.firstIndex(where: { $0.id == snippet.id }) {
            userSnippets[i] = snippet
        } else {
            userSnippets.append(snippet)
        }
        save()
    }

    /// Remove a user snippet by id and persist. (Built-ins can't be removed,
    /// only overridden.) No-op if absent.
    public func remove(id: String) {
        let before = userSnippets.count
        userSnippets.removeAll { $0.id == id }
        if userSnippets.count != before { save() }
    }

    /// Block until pending writes land (terminate-drain / round-trip tests).
    public func flush() { JSONFileStore.flushSync() }

    private func load() {
        userSnippets = JSONFileStore.read(
            [Snippet].self, from: storeURL, maxSize: maxStoreFileBytes
        ) ?? []
    }

    private func save() {
        JSONFileStore.enqueueWrite(userSnippets, to: storeURL)
    }
}
