import Foundation
import Testing
import ViewerCore
import ViewerKit

/// The stack behind File ▸ Recently Closed and ⇧⌘T.
@Suite("RecentlyClosedStore")
struct RecentlyClosedStoreTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("newest closed comes back first")
    func newestFirst() {
        let s = RecentlyClosedStore()
        s.record(url: url("a"), at: t0)
        s.record(url: url("b"), at: t0.addingTimeInterval(1))
        #expect(s.entries.map(\.url) == [url("b"), url("a")])
        #expect(s.popMostRecent()?.url == url("b"))
    }

    /// Repeated ⇧⌘T must WALK BACK through the history, not hand back the
    /// same file forever.
    @Test("each pop steps further back, then runs out")
    func popWalksBack() {
        let s = RecentlyClosedStore()
        for n in ["a", "b", "c"] { s.record(url: url(n), at: t0) }
        #expect(s.popMostRecent()?.url == url("c"))
        #expect(s.popMostRecent()?.url == url("b"))
        #expect(s.popMostRecent()?.url == url("a"))
        #expect(s.popMostRecent() == nil)
        #expect(s.isEmpty)
    }

    /// Closing the same file repeatedly must not fill the menu with one path.
    @Test("re-closing the same file moves it to the front instead of duplicating")
    func dedupes() {
        let s = RecentlyClosedStore()
        s.record(url: url("a"), at: t0)
        s.record(url: url("b"), at: t0)
        s.record(url: url("a"), at: t0.addingTimeInterval(5))
        #expect(s.entries.count == 2)
        #expect(s.entries.map(\.url) == [url("a"), url("b")])
    }

    @Test("the list is bounded, dropping the oldest")
    func bounded() {
        let s = RecentlyClosedStore(limit: 3)
        for n in ["a", "b", "c", "d"] { s.record(url: url(n), at: t0) }
        #expect(s.entries.count == 3)
        #expect(s.entries.map(\.url) == [url("d"), url("c"), url("b")])
    }

    @Test("taking a specific entry removes it")
    func takeRemoves() {
        let s = RecentlyClosedStore()
        for n in ["a", "b", "c"] { s.record(url: url(n), at: t0) }
        #expect(s.take(url: url("b"))?.url == url("b"))
        #expect(s.entries.map(\.url) == [url("c"), url("a")])
        #expect(s.take(url: url("b")) == nil)
    }

    /// Reopening a file by any other route must drop it from the list — the
    /// menu should never offer to "reopen" something already open.
    @Test("forget drops an entry without reopening it")
    func forget() {
        let s = RecentlyClosedStore()
        s.record(url: url("a"), at: t0)
        s.forget(url: url("a"))
        #expect(s.isEmpty)
        s.forget(url: url("nope"))   // unknown url is a no-op, not a crash
    }

    @Test("the closed lens is remembered so reopening restores the view")
    func remembersViewMode() {
        let s = RecentlyClosedStore()
        s.record(url: url("a"), viewMode: .rendered, at: t0)
        #expect(s.popMostRecent()?.viewMode == .rendered)
    }

    @Test("clear empties the list")
    func clear() {
        let s = RecentlyClosedStore()
        s.record(url: url("a"), at: t0)
        s.clear()
        #expect(s.isEmpty)
    }

    @Test("display name is the file name, not the whole path")
    func displayName() {
        let s = RecentlyClosedStore()
        s.record(url: URL(fileURLWithPath: "/a/b/notes.md"), at: t0)
        #expect(s.entries.first?.displayName == "notes.md")
    }
}

/// Persistence contract (2026-08-01): ⇧⌘T survives a relaunch. A nil
/// storeURL (every test above) stays purely in-memory.
@Suite struct RecentlyClosedPersistenceTests {

    private let tmp: URL
    private let store: URL

    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = tmp.appendingPathComponent("recently-closed.json")
    }

    private func realFile(_ name: String) throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try Data("x".utf8).write(to: u)
        return u
    }

    @Test("entries survive a relaunch (new instance, same file)")
    func roundTrip() throws {
        let a = try realFile("a.md")
        let b = try realFile("b.md")
        let first = RecentlyClosedStore(storeURL: store)
        first.record(url: a, viewMode: .source)
        first.record(url: b)
        JSONFileStore.flushSync()

        let relaunched = RecentlyClosedStore(storeURL: store)
        #expect(relaunched.entries.map(\.url) == [b, a])
        #expect(relaunched.entries.last?.viewMode == .source,
                "the remembered lens survives too")
    }

    @Test("files deleted since the last run do not resurrect")
    func deletedFilesFiltered() throws {
        let kept = try realFile("kept.md")
        let doomed = try realFile("doomed.md")
        let first = RecentlyClosedStore(storeURL: store)
        first.record(url: doomed)
        first.record(url: kept)
        JSONFileStore.flushSync()
        try FileManager.default.removeItem(at: doomed)

        let relaunched = RecentlyClosedStore(storeURL: store)
        #expect(relaunched.entries.map(\.url) == [kept],
                "a deleted file must not be offered for reopening")
    }

    @Test("a corrupt store file reads as empty, never fatal")
    func corruptTolerated() throws {
        try Data("{not json".utf8).write(to: store)
        let s = RecentlyClosedStore(storeURL: store)
        #expect(s.isEmpty)
        // …and the store still works from there.
        s.record(url: try realFile("after.md"))
        #expect(s.entries.count == 1)
    }

    @Test("load respects the limit even if the file grew beyond it")
    func loadCaps() throws {
        let s1 = RecentlyClosedStore(limit: 20, storeURL: store)
        for i in 0..<12 { s1.record(url: try realFile("f\(i).md")) }
        JSONFileStore.flushSync()
        let small = RecentlyClosedStore(limit: 5, storeURL: store)
        #expect(small.entries.count == 5, "load trims to the configured cap")
    }
}
