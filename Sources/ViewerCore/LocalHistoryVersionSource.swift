import Foundation

/// `VersionSource` over `LocalHistoryStore` — the Local-History back-end for the
/// unified version viewer (TSK-1103). Uses ONLY the store's stable public API
/// (`versions`/`contentString`); a sibling agent's switch to diff-based on-disk
/// storage is invisible here.
///
/// Diffs between two local versions (and version-vs-current) are produced by the
/// pure-Swift `UnifiedDiffGenerator`, since Local History has no git to emit
/// unified text. The output is the exact dialect the shared renderer parses.
///
/// `currentContent` is a closure (not a stored String) so it always reflects the
/// LIVE editor buffer — "diff vs current" must compare against unsaved edits,
/// not a stale disk read. The closure is `@Sendable` because this source is used
/// off the main actor. `Sendable` overall: an immutable store ref, an immutable
/// path/name, and a `@Sendable` closure.
public struct LocalHistoryVersionSource: VersionSource {
    private let store: LocalHistoryStore
    /// Absolute file path the store keys versions by.
    private let path: String
    public let displayName: String
    /// Live current content (editor buffer, falling back to disk). Returns nil
    /// when there is no current content (e.g. file gone) — diffs against current
    /// then treat current as empty.
    private let currentContent: @Sendable () -> String?

    public init(
        store: LocalHistoryStore,
        path: String,
        displayName: String,
        currentContent: @escaping @Sendable () -> String?
    ) {
        self.store = store
        self.path = path
        self.displayName = displayName
        self.currentContent = currentContent
    }

    public func listVersions() -> [VersionRef] {
        store.versions(for: path).map { v in
            VersionRef(
                id: v.id,
                shortLabel: Self.label(for: v.savedAt),
                timestamp: v.savedAt,
                author: nil,
                subject: nil,
                kind: .localHistory)
        }
    }

    public func content(of version: VersionRef) -> String? {
        guard let v = storeVersion(for: version) else { return nil }
        return store.contentString(of: v, for: path)
    }

    public func diffAgainstCurrent(_ version: VersionRef) -> String {
        guard let old = content(of: version) else { return "" }
        let current = currentContent() ?? ""
        return UnifiedDiffGenerator.generate(old: old, new: current, path: displayName)
    }

    public func diff(from: VersionRef, to: VersionRef?) -> String {
        if let to {
            // Order the pair oldest→newest by timestamp so the diff reads
            // forward regardless of click order.
            let (a, b) = ordered(from, to)
            guard let aText = content(of: a), let bText = content(of: b) else { return "" }
            return UnifiedDiffGenerator.generate(old: aText, new: bText, path: displayName)
        }
        // to == nil → this version's own change vs its immediate predecessor.
        guard let fromText = content(of: from) else { return "" }
        let all = listVersions()   // newest-first
        guard let idx = all.firstIndex(of: from) else {
            // Unknown version: show it as an all-add against empty.
            return UnifiedDiffGenerator.generate(old: "", new: fromText, path: displayName)
        }
        // The predecessor is the NEXT entry (older) in the newest-first list.
        let predIdx = idx + 1
        let predText: String = predIdx < all.count ? (content(of: all[predIdx]) ?? "") : ""
        return UnifiedDiffGenerator.generate(old: predText, new: fromText, path: displayName)
    }

    public func cumulativeDiff(in selection: [VersionRef]) -> String {
        let sorted = oldestToNewest(selection)
        guard let oldest = sorted.first, let newest = sorted.last,
              oldest != newest else { return "" }
        guard let oldText = content(of: oldest), let newText = content(of: newest) else { return "" }
        return UnifiedDiffGenerator.generate(old: oldText, new: newText, path: displayName)
    }

    // MARK: - Helpers

    /// Map a `VersionRef` back to a `LocalHistoryStore.Version`. The store's
    /// `contentString` needs a `Version`; we reconstruct it from the ref's id +
    /// timestamp (byteSize is unused by `contentString`).
    private func storeVersion(for ref: VersionRef) -> LocalHistoryStore.Version? {
        guard ref.kind == .localHistory else { return nil }
        return LocalHistoryStore.Version(
            id: ref.id,
            savedAt: ref.timestamp ?? Date(timeIntervalSince1970: 0),
            byteSize: 0)
    }

    /// Order a pair oldest→newest by timestamp (id as a tiebreaker).
    private func ordered(_ a: VersionRef, _ b: VersionRef) -> (VersionRef, VersionRef) {
        if isOlder(a, than: b) { return (a, b) }
        return (b, a)
    }

    private func oldestToNewest(_ refs: [VersionRef]) -> [VersionRef] {
        refs.sorted { isOlder($0, than: $1) }
    }

    private func isOlder(_ a: VersionRef, than b: VersionRef) -> Bool {
        let ta = a.timestamp ?? .distantPast
        let tb = b.timestamp ?? .distantPast
        if ta != tb { return ta < tb }
        // Same timestamp (same-ms bump): fall back to the numeric id.
        return (Int64(a.id.split(separator: "_").first.map(String.init) ?? a.id) ?? 0)
             < (Int64(b.id.split(separator: "_").first.map(String.init) ?? b.id) ?? 0)
    }

    /// Compact "yyyy-MM-dd HH:mm:ss" label for a snapshot timestamp.
    static func label(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}
