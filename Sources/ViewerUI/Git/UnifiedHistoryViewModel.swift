import Foundation
import SwiftUI
import ViewerCore

/// View-model for `UnifiedHistoryView` — the SINGLE version-history + diff
/// view-model driving BOTH Local History and Git, per the owner's spec
/// (TSK-1103): list versions → click one to VIEW it or DIFF vs current
/// (toggle), or select a RANGE for a cumulative diff.
///
/// Generalizes the git-only `FileHistoryModel`: the only thing that was
/// git-specific there (every data call hit `GitClient`) is replaced by an
/// injected `VersionSource`. The proven selection state machine + off-main
/// last-write-wins load are preserved.
///
/// Concurrency: `@MainActor` so SwiftUI observes it safely; the blocking
/// source work (`listVersions`, `content`, the diff methods) runs on
/// `Task.detached` and hands back `Sendable` values. Each load carries a
/// monotonic token so a slow load can't overwrite a newer one.
@MainActor
final class UnifiedHistoryViewModel: ObservableObject {

    /// The injected back-end (LocalHistory or Git). Sendable, so the detached
    /// tasks capture it directly.
    private let source: VersionSource

    var displayName: String { source.displayName }
    var supportsRangeDiff: Bool { source.supportsRangeDiff }
    var sourceKind: VersionRef.Kind { kind }
    private let kind: VersionRef.Kind

    @Published private(set) var versions: [VersionRef] = []
    @Published private(set) var isLoadingVersions = false
    @Published private(set) var isLoadingDetail = false

    /// What the right detail pane renders.
    enum Detail: Equatable {
        case empty
        case content(String)   // the full text of a version ("view this version")
        case diff(String)      // unified-diff text (vs current / range / own-change)
    }
    @Published private(set) var detail: Detail = .empty

    /// Single-selection view mode (the owner's toggle). `.ownChange` shows the
    /// change this version introduced (vs its predecessor); `.diffVsCurrent`
    /// shows it against the live current file; `.viewVersion` shows the full
    /// content of the version.
    enum SingleMode: Hashable, Sendable {
        case viewVersion
        case diffVsCurrent
        case ownChange
    }
    @Published private(set) var singleMode: SingleMode = .ownChange

    /// The single-selected version's id (drives list highlight). nil in range
    /// mode or when nothing is picked.
    @Published private(set) var primarySelection: String?
    /// Ordered range selection (cap 2). Empty = no range.
    @Published private(set) var rangeSelection: [VersionRef] = []

    enum SelectionMode: Equatable { case none, single, range }
    var selectionMode: SelectionMode {
        if rangeSelection.count == 2 { return .range }
        if primarySelection != nil { return .single }
        return .none
    }

    /// "old → new" label for the range toolbar.
    var rangeLabel: String {
        guard rangeSelection.count == 2 else { return "" }
        let sorted = rangeSelection.sorted {
            ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast)
        }
        return "\(sorted[0].shortLabel) → \(sorted[1].shortLabel)"
    }

    private var detailToken = 0
    private var loaded = false

    init(source: VersionSource, kind: VersionRef.Kind,
         initialMode: SingleMode = .ownChange) {
        self.source = source
        self.kind = kind
        self.singleMode = initialMode
    }

    // MARK: - Version load

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        isLoadingVersions = true
        let src = source
        Task { @MainActor [weak self] in
            let list = await Task.detached(priority: .userInitiated) {
                src.listVersions()
            }.value
            guard let self else { return }
            self.versions = list
            self.isLoadingVersions = false
            // Auto-select the newest so the pane isn't blank.
            if let first = list.first {
                self.click(version: first, command: false)
            }
        }
    }

    /// Test seam: synchronous reload (used by host tests that don't want to
    /// await the detached task). Production uses `loadIfNeeded`.
    func reloadVersionsSync() {
        versions = source.listVersions()
    }

    // MARK: - Selection state machine

    /// Plain click selects a single version; Cmd-click arms/extends a
    /// two-version range. Mirrors `FileHistoryModel.click`.
    func click(version: VersionRef, command: Bool) {
        if command && supportsRangeDiff {
            armRange(version)
        } else {
            primarySelection = version.id
            rangeSelection = []
            loadSingleDetail(version)
        }
    }

    private func armRange(_ version: VersionRef) {
        if rangeSelection.count >= 2 {
            rangeSelection = primaryVersion.map { [$0] } ?? []
        }
        if rangeSelection.isEmpty {
            if let primary = primaryVersion, primary.id != version.id {
                rangeSelection = [primary]
            }
        }
        if !rangeSelection.contains(where: { $0.id == version.id }) {
            rangeSelection.append(version)
        }
        if rangeSelection.count == 2 {
            loadRangeDiff()
        } else if rangeSelection.count == 1 {
            primarySelection = rangeSelection[0].id
            loadSingleDetail(rangeSelection[0])
        }
    }

    func clearRange() {
        rangeSelection = []
        if let primary = primaryVersion {
            loadSingleDetail(primary)
        } else {
            detail = .empty
        }
    }

    func setSingleMode(_ mode: SingleMode) {
        guard mode != singleMode else { return }
        singleMode = mode
        if let primary = primaryVersion, rangeSelection.count != 2 {
            loadSingleDetail(primary)
        }
    }

    /// The currently single-selected `VersionRef` (resolved from the id).
    var primaryVersion: VersionRef? {
        guard let id = primarySelection else { return nil }
        return versions.first { $0.id == id }
    }

    // MARK: - Detail load (off-main, last-write-wins)

    private func loadSingleDetail(_ version: VersionRef) {
        detailToken += 1
        let token = detailToken
        isLoadingDetail = true
        let src = source
        let mode = singleMode
        Task { @MainActor [weak self] in
            let result: Detail = await Task.detached(priority: .userInitiated) { () -> Detail in
                switch mode {
                case .viewVersion:
                    return .content(src.content(of: version) ?? "")
                case .diffVsCurrent:
                    return .diff(src.diffAgainstCurrent(version))
                case .ownChange:
                    return .diff(src.diff(from: version, to: nil))
                }
            }.value
            guard let self, token == self.detailToken else { return }
            self.detail = result
            self.isLoadingDetail = false
        }
    }

    private func loadRangeDiff() {
        guard rangeSelection.count == 2 else { return }
        detailToken += 1
        let token = detailToken
        isLoadingDetail = true
        let src = source
        let selection = rangeSelection
        Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                src.cumulativeDiff(in: selection)
            }.value
            guard let self, token == self.detailToken else { return }
            self.detail = .diff(text)
            self.isLoadingDetail = false
        }
    }

    // MARK: - Restore

    /// The content of the version to restore (single-selected). Synchronous —
    /// callers (the Restore button) use it to push text into the editor buffer
    /// as an UNDOABLE edit, not a disk write. Returns nil when nothing is
    /// single-selected or the content can't be loaded.
    func restoreCandidateContent() -> String? {
        guard let primary = primaryVersion else { return nil }
        return source.content(of: primary)
    }

    // MARK: - Size annotation (TSK-1462)

    /// Timeline row annotation: this version's size plus its delta vs the
    /// immediate predecessor, e.g. "2.1 KB (+340 B)". nil when the version
    /// carries no size (git). The predecessor is the NEXT entry in the
    /// newest-first list; the oldest version shows its plain size.
    func sizeAnnotation(for version: VersionRef) -> String? {
        guard let idx = versions.firstIndex(where: { $0.id == version.id }) else {
            return Self.sizeAnnotation(bytes: version.byteSize, olderBytes: nil)
        }
        let olderBytes = idx + 1 < versions.count ? versions[idx + 1].byteSize : nil
        return Self.sizeAnnotation(bytes: version.byteSize, olderBytes: olderBytes)
    }

    /// Pure formatting seam (host-tested): "size (±delta)". nil when `bytes`
    /// is nil; the delta part is omitted when there is no older version, and
    /// shows "(±0 B)" for an equal-size save so the row still reads as "this
    /// save didn't change the size".
    nonisolated static func sizeAnnotation(bytes: Int?, olderBytes: Int?) -> String? {
        guard let bytes else { return nil }
        guard let olderBytes else { return byteLabel(bytes) }
        let delta = bytes - olderBytes
        if delta == 0 { return "\(byteLabel(bytes)) (±0 B)" }
        let sign = delta > 0 ? "+" : "−"
        return "\(byteLabel(bytes)) (\(sign)\(byteLabel(abs(delta))))"
    }

    /// Deterministic, locale-independent compact byte label ("999 B",
    /// "1.2 KB", "3.4 MB"). Hand-rolled instead of ByteCountFormatter so host
    /// tests pin exact strings regardless of machine locale.
    nonisolated static func byteLabel(_ n: Int) -> String {
        if n < 1000 { return "\(n) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(n)
        var unit = ""
        for u in units {
            value /= 1000
            unit = u
            if value < 1000 { break }
        }
        // One decimal below 10, whole numbers above ("1.2 KB", "34 KB").
        return value < 10
            ? String(format: "%.1f %@", value, unit)
            : String(format: "%.0f %@", value, unit)
    }
}
