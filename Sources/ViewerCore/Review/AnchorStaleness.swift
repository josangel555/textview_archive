import Foundation

// MARK: - AnchorState
//
// v2 §3.2: staleness of a comment's line anchor, computed on review load by
// comparing the `blobSha` frozen at comment-creation against the blob of the
// file's current content on the anchored side.
//
// This is a DERIVED signal — never stored on the `ReviewComment` / `Review`.
// The UI (`ReviewSession`) recomputes the per-comment map on every load. The
// enum + evaluator live in `ViewerCore` because they are pure data logic with
// no SwiftUI/AppKit dependency; only the *recompute-on-load* orchestration
// sits in the UI layer.

public enum AnchorState: String, Equatable, Sendable, CaseIterable {
    /// The anchored side's blob is byte-identical to capture time — the
    /// line numbers in the anchor are still valid; render inline.
    case current
    /// The blob changed since capture — the anchor's line numbers may now
    /// point at different code. Render against the frozen `HunkContext` with
    /// a "code changed since review" badge. NEVER silently re-anchored.
    case stale
    /// Can't make a claim: either we never captured a `blobSha` (helper
    /// failed at creation), or the file's current blob is unresolvable
    /// (deleted / untracked / binary). Render against frozen context with a
    /// neutral "anchor not verifiable" note.
    case unknown

    /// Evaluate staleness from the captured vs. live blob SHA.
    ///
    /// - `capturedBlobSha`: `LineAnchor.blobSha` frozen at comment creation.
    /// - `liveBlobSha`: the blob SHA of the file's current content on the
    ///   anchored side (from `GitClient.blobSha(...)`), or `nil` if it
    ///   couldn't be resolved.
    ///
    /// Truth table (§3.2):
    /// ```
    /// captured == nil               -> .unknown   (no claim possible)
    /// live     == nil               -> .unknown   (file gone / untracked / binary)
    /// live     == captured          -> .current   (byte-identical)
    /// otherwise                     -> .stale
    /// ```
    public static func evaluate(
        capturedBlobSha: String?,
        liveBlobSha: String?
    ) -> AnchorState {
        guard let captured = capturedBlobSha, !captured.isEmpty else { return .unknown }
        guard let live = liveBlobSha, !live.isEmpty else { return .unknown }
        return live == captured ? .current : .stale
    }

    /// Convenience over a `LineAnchor`.
    public static func evaluate(
        anchor: LineAnchor,
        liveBlobSha: String?
    ) -> AnchorState {
        evaluate(capturedBlobSha: anchor.blobSha, liveBlobSha: liveBlobSha)
    }
}
