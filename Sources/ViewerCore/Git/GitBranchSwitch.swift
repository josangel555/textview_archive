import Foundation

/// Pure, subprocess-free decision logic for switching the checked-out
/// branch from the footer git chip (UX-C, #225).
///
/// A `git checkout <branch>` rewrites the working tree. If the tree has
/// uncommitted changes git itself will refuse for files that would be
/// clobbered — but it will *silently* carry over changes that happen not
/// to conflict, which is exactly the kind of "where did my edits go"
/// surprise the project's git lessons warn about (LESSONS.md: never
/// `git checkout --` over agent residue; stash, don't discard). So we
/// HARD-GATE in front of the checkout: a dirty tree REFUSES by default and
/// the caller must explicitly opt into stashing first. The decision is a
/// pure value transform over `git status --porcelain` output, so it is
/// host-safe and unit-testable (T1m) without spawning git.
///
/// The actual checkout / stash is performed by `GitClient` once the caller
/// has a non-`.refuse` decision in hand.
public enum GitBranchSwitch {

    /// The verdict for a requested branch switch. Carries enough context
    /// for the UI to render a clear message instead of a bare bool.
    public enum Decision: Equatable, Sendable {
        /// Working tree is clean (or only ignored files differ) — a plain
        /// `git checkout <branch>` is safe and non-destructive.
        case allow
        /// Already on the requested branch — nothing to do. Kept distinct
        /// from `.allow` so the UI can no-op silently rather than spawn a
        /// pointless checkout.
        case noop
        /// Working tree is dirty. We refuse to run a plain checkout (it
        /// could carry edits across or, for conflicting paths, fail
        /// mid-way). `dirtyCount` is the number of changed entries; the UI
        /// surfaces it ("3 uncommitted changes") and offers the stash path.
        case refuse(reason: String, dirtyCount: Int)

        /// True when the caller may proceed straight to `git checkout`
        /// without stashing or prompting. `.noop` is included because a
        /// no-op is trivially safe (the UI just dismisses).
        public var isSafeToCheckout: Bool {
            switch self {
            case .allow, .noop: return true
            case .refuse:       return false
            }
        }
    }

    /// Decide whether switching from `current` to `target` is safe, given
    /// the raw `git status --porcelain=v1` output for the working tree.
    ///
    /// - `current`: the branch currently checked out (`nil` for a detached
    ///   HEAD — we never short-circuit to `.noop` in that case).
    /// - `target`: the branch the user picked from the chip.
    /// - `porcelainStatus`: verbatim stdout of `git status --porcelain=v1`.
    ///   Untracked (`??`) entries count as dirty for switch safety — a
    ///   `git checkout` can clobber an untracked file that the target
    ///   branch tracks. Ignored (`!!`) entries are NOT counted (git never
    ///   touches them on checkout). The bare sweep already filters `!!` out
    ///   because we don't pass `--ignored`; we filter defensively anyway.
    ///
    /// Trimming/empty handling: an all-whitespace status is treated as
    /// clean. `target` is validated to be a plausible branch name (non-empty
    /// after trim, not an option-injection shape) — an unsafe name refuses
    /// rather than risk handing git a flag.
    public static func decide(
        current: String?,
        target: String,
        porcelainStatus: String
    ) -> Decision {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty, !trimmedTarget.hasPrefix("-") else {
            return .refuse(reason: "Invalid branch name.", dirtyCount: 0)
        }
        if let current, current == trimmedTarget {
            return .noop
        }
        let dirtyCount = dirtyEntryCount(porcelainStatus)
        guard dirtyCount == 0 else {
            let noun = dirtyCount == 1 ? "change" : "changes"
            return .refuse(
                reason: "\(dirtyCount) uncommitted \(noun) in the working tree. "
                    + "Commit or stash them before switching to \"\(trimmedTarget)\".",
                dirtyCount: dirtyCount
            )
        }
        return .allow
    }

    /// Count of working-tree entries that make a checkout unsafe. Mirrors
    /// the porcelain v1 grammar (`XY <path>`), counting every non-blank row
    /// except `!!` (ignored). Public for direct unit assertions; `decide`
    /// is the primary entry point.
    public static func dirtyEntryCount(_ porcelainStatus: String) -> Int {
        var count = 0
        for raw in porcelainStatus.split(separator: "\n", omittingEmptySubsequences: true) {
            // A porcelain row is `XY <space> <path>` — at least 3 chars.
            // Anything shorter is malformed; skip it.
            guard raw.count >= 3 else { continue }
            let chars = Array(raw)
            // Ignored entries (`!!`) never block a checkout — git leaves
            // them alone. Everything else (modified/added/deleted/renamed/
            // untracked `??`/conflicted) counts.
            if chars[0] == "!" && chars[1] == "!" { continue }
            count += 1
        }
        return count
    }
}
