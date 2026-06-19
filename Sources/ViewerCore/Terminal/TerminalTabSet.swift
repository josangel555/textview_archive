import Foundation

/// Pure, host-testable model of the terminal tool window's TABS (TSK-368) —
/// an ordered collection of named terminal tabs with an active id, plus the
/// new/close/select/reorder/rename operations and the persisted shape.
///
/// This is the value-type CORE the `@MainActor` `TerminalPaneStore` (ViewerUI)
/// delegates to: the store owns the live `TerminalModel`/PTY per tab (keyed by
/// the stable `id` here), while ALL ordering + selection + naming logic lives
/// here so it is unit-testable in `ViewerCoreTests` without spawning a shell.
/// Mirrors the `TabsState` idiom (the document tab bar): an `Equatable`,
/// `Sendable`, `Codable` value type whose mutation happens through value-type
/// mutating methods, with documented index-adjustment-on-close semantics.
///
/// Identity: each tab carries a stable `UUID` (the key the store maps to its
/// live `TerminalModel`), a monotonic display `number` (the default "Terminal
/// N" label, never reused while tabs are open), an optional user `customName`,
/// and an optional `cwd` (the spawn directory, used to derive a default title
/// when no custom name is set).
public struct TerminalTabSet: Equatable, Sendable, Codable {

    /// One terminal tab descriptor. Pure data — the live shell lives on the
    /// store's parallel id→`TerminalModel` map.
    public struct Tab: Equatable, Sendable, Codable, Identifiable {
        public let id: UUID
        /// Monotonic display number (the "Terminal N" default label). Stable
        /// for the tab's lifetime; the next number is handed out by `addTab`.
        public let number: Int
        /// User-chosen name, or nil to fall back to the default title.
        public var customName: String?
        /// The directory the shell was spawned in, if known — seeds the
        /// default title (its last path component) when no custom name is set.
        public var cwd: URL?

        public init(id: UUID = UUID(), number: Int, customName: String? = nil, cwd: URL? = nil) {
            self.id = id
            self.number = number
            self.customName = customName
            self.cwd = cwd
        }
    }

    public private(set) var tabs: [Tab]
    /// The active tab's id, or nil when the set is empty.
    public private(set) var activeID: UUID?
    /// The next display number to hand out. Monotonic while ≥1 tab is open;
    /// reset to 1 by `removeAll()` so a freshly-reopened pane starts at 1.
    private var nextNumber: Int

    public init(tabs: [Tab] = [], activeID: UUID? = nil) {
        self.tabs = tabs
        // Active id must reference a live tab; else fall back to the first.
        if let activeID, tabs.contains(where: { $0.id == activeID }) {
            self.activeID = activeID
        } else {
            self.activeID = tabs.first?.id
        }
        self.nextNumber = (tabs.map(\.number).max() ?? 0) + 1
    }

    // MARK: - Queries

    public var isEmpty: Bool { tabs.isEmpty }
    public var count: Int { tabs.count }

    /// The active tab, or nil when empty.
    public var active: Tab? {
        guard let activeID else { return nil }
        return tabs.first { $0.id == activeID }
    }

    /// Index of the active tab, or nil.
    public var activeIndex: Int? {
        guard let activeID else { return nil }
        return tabs.firstIndex { $0.id == activeID }
    }

    public func index(of id: UUID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    public func tab(_ id: UUID) -> Tab? {
        tabs.first { $0.id == id }
    }

    // MARK: - Mutation

    /// Open a new tab (with an optional spawn `cwd`) and make it active.
    /// Returns the new tab's id (the store keys its live `TerminalModel` on it).
    @discardableResult
    public mutating func addTab(cwd: URL? = nil) -> UUID {
        let tab = Tab(number: nextNumber, cwd: cwd)
        nextNumber += 1
        tabs.append(tab)
        activeID = tab.id
        return tab.id
    }

    /// Select a tab by id. No-op for an unknown id or when already active.
    /// Returns `true` if the active id changed.
    @discardableResult
    public mutating func select(_ id: UUID) -> Bool {
        guard activeID != id, tabs.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    /// Cycle to the next (`forward`) / previous tab, wrapping around. No-op
    /// with fewer than two tabs. Returns the new active id (or nil).
    @discardableResult
    public mutating func cycle(forward: Bool) -> UUID? {
        guard tabs.count > 1, let cur = activeIndex else { return activeID }
        let n = tabs.count
        let next = forward ? (cur + 1) % n : (cur - 1 + n) % n
        activeID = tabs[next].id
        return activeID
    }

    /// Close a tab by id, adjusting the active id so a neighbor stays selected:
    /// - closing a NON-active tab → active id unchanged,
    /// - closing the active tab → select the tab that takes its index slot
    ///   (the right neighbor), or the new last tab if it was the last,
    /// - closing the LAST remaining tab → `activeID` becomes nil (the store
    ///   reads this to close the whole pane).
    /// Returns `true` if a tab was removed.
    @discardableResult
    public mutating func close(_ id: UUID) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let wasActive = (activeID == id)
        tabs.remove(at: idx)
        if tabs.isEmpty {
            activeID = nil
            nextNumber = 1   // a freshly-reopened pane restarts numbering at 1
        } else if wasActive {
            activeID = tabs[min(idx, tabs.count - 1)].id
        }
        // closing a non-active tab leaves the active id untouched
        return true
    }

    /// Remove every tab and reset numbering (pane fully closed).
    public mutating func removeAll() {
        tabs.removeAll()
        activeID = nil
        nextNumber = 1
    }

    /// Reorder: move the tab at `from` so it lands at index `to` in the
    /// post-removal list (drag-reorder semantics, mirroring `TabsState.move`).
    /// The active TAB stays active across the move (its id is tracked, not its
    /// index). Out-of-range indices are a no-op.
    public mutating func move(from: Int, to: Int) {
        guard tabs.indices.contains(from), to >= 0, to <= tabs.count else { return }
        let tab = tabs.remove(at: from)
        let insertAt = (from < to) ? (to - 1) : to
        let bounded = min(max(insertAt, 0), tabs.count)
        tabs.insert(tab, at: bounded)
        // activeID is id-based, so reordering never changes which tab is active.
    }

    /// Rename a tab. A whitespace-only/empty proposal CLEARS the custom name
    /// (reverting to the default title); otherwise it trims and stores it (a
    /// no-op when unchanged, matching `SessionRename.sanitize`). Returns `true`
    /// if the stored name changed.
    @discardableResult
    public mutating func rename(_ id: UUID, to proposed: String) -> Bool {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard tabs[i].customName != nil else { return false }
            tabs[i].customName = nil
            return true
        }
        guard tabs[i].customName != trimmed else { return false }
        tabs[i].customName = trimmed
        return true
    }

    /// Record (or update) the spawn directory for a tab — the store calls this
    /// once the shell's cwd is known, so the default title can reflect it.
    /// No-op for an unknown id or an unchanged value.
    public mutating func setCwd(_ id: UUID, to cwd: URL?) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].cwd != cwd else { return }
        tabs[i].cwd = cwd
    }

    // MARK: - Titles

    /// The full title for a tab: the custom name if set, else the cwd-derived
    /// default ("Terminal N — <folder>"), else the bare "Terminal N".
    public func title(for tab: Tab) -> String {
        TerminalTabTitle.title(number: tab.number, customName: tab.customName, cwd: tab.cwd)
    }

    /// The short chip label: the custom name if set, else the cwd folder name,
    /// else the bare number.
    public func label(for tab: Tab) -> String {
        TerminalTabTitle.label(number: tab.number, customName: tab.customName, cwd: tab.cwd)
    }
}

/// Pure default-title derivation for a terminal tab (TSK-368). Separated so
/// both the title and the chip label share one cwd→name rule and it is
/// trivially host-testable.
public enum TerminalTabTitle {

    /// The default name component derived from a spawn `cwd`: its last path
    /// component, with `/` resolving to "/" and the user's home resolving to
    /// "~". Returns nil when there's no usable directory.
    public static func folderName(for cwd: URL?) -> String? {
        guard let cwd, cwd.isFileURL else { return nil }
        let standardized = cwd.standardizedFileURL
        let path = standardized.path
        if path == "/" { return "/" }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return "~" }
        let name = standardized.lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Full title: `customName` wins; else "Terminal N — <folder>" when a cwd
    /// folder is derivable; else "Terminal N".
    public static func title(number: Int, customName: String?, cwd: URL?) -> String {
        if let customName, !customName.isEmpty { return customName }
        if let folder = folderName(for: cwd) {
            return "Terminal \(number) — \(folder)"
        }
        return "Terminal \(number)"
    }

    /// Short chip label: `customName` wins; else the cwd folder name; else the
    /// bare number.
    public static func label(number: Int, customName: String?, cwd: URL?) -> String {
        if let customName, !customName.isEmpty { return customName }
        if let folder = folderName(for: cwd) { return folder }
        return "\(number)"
    }
}
