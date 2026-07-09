import Foundation
import ViewerCore

/// TSK-1171 — the view model behind the 3-pane conflict-resolution UI. Holds the
/// `ThreeWayMerge.Result`, one pending `Resolution?` per conflict (nil = the user
/// hasn't chosen yet), and derives the final resolved text once EVERY conflict has
/// a choice. The choice bookkeeping is pure + host-testable; the 3-pane SwiftUI
/// view that renders base/ours/theirs and drives `select` is the render tail.
@MainActor
public final class ConflictResolutionModel: ObservableObject {

    /// The classified merge (base ⨯ ours ⨯ theirs).
    public let result: ThreeWayMerge.Result
    /// Labels for the two sides (e.g. "My edits" / "On disk").
    public let oursLabel: String
    public let theirsLabel: String

    /// One entry per conflict region, in document order; nil until the user picks.
    @Published public private(set) var choices: [ThreeWayMerge.Resolution?]

    public init(result: ThreeWayMerge.Result,
                oursLabel: String = "ours", theirsLabel: String = "theirs") {
        self.result = result
        self.oursLabel = oursLabel
        self.theirsLabel = theirsLabel
        self.choices = Array(repeating: nil, count: result.conflictCount)
    }

    /// The conflict slices to render, in document order (index-aligned with `choices`).
    public var conflicts: [(base: [String], ours: [String], theirs: [String])] {
        result.conflicts
    }

    /// Set (or change) the resolution for conflict `index`. Out-of-range is ignored.
    public func select(_ resolution: ThreeWayMerge.Resolution, at index: Int) {
        guard choices.indices.contains(index) else { return }
        choices[index] = resolution
    }

    /// The number of conflicts still needing a choice.
    public var unresolvedCount: Int { choices.lazy.filter { $0 == nil }.count }

    /// True once every conflict has a choice (Apply becomes enabled).
    public var allResolved: Bool { unresolvedCount == 0 }

    /// The fully-resolved document, or nil until every conflict is resolved.
    public var resolvedText: String? {
        guard allResolved else { return nil }
        return result.resolvedText(choices.compactMap { $0 })
    }

    /// Convenience: resolve every remaining (unchosen) conflict with `resolution`
    /// — backs a "Take all ours / all theirs" bulk action.
    public func resolveAllRemaining(with resolution: ThreeWayMerge.Resolution) {
        for i in choices.indices where choices[i] == nil { choices[i] = resolution }
    }
}
