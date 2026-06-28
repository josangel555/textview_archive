import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Footer git chip (UX-C, #225)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). The
// footer git chip's repo-root memo + branch-switch actions. A clean verbatim
// move: no @Published stored state (the root memo is a private static cache that
// moves with the group), no private core machinery; all deps (currentURL /
// sidebar / openFolderInNewSession / reloadCurrentFile) already public.
extension DocumentModel {
    /// Repo working-tree root for the footer git chip. Prefers the current
    /// file's repo (so the chip tracks the focused document even when it
    /// lives outside the sidebar tree), falling back to the sidebar root.
    ///
    /// Memoized so the footer body doesn't FS-walk (`discoverRoot` does up
    /// to 32 `fileExists` syscalls) on every re-eval — keyed by the input
    /// URL, recomputed only when the focused URL changes. Cheap and pure.
    public var gitChipRepoRoot: URL? {
        let anchor = currentURL ?? sidebar.rootURL
        guard let anchor else { return nil }
        if let hit = Self.gitChipRootCache, hit.anchor == anchor {
            return hit.root
        }
        let root = GitClient.discoverRoot(from: anchor)
        Self.gitChipRootCache = (anchor, root)
        return root
    }

    nonisolated(unsafe) private static var gitChipRootCache:
        (anchor: URL, root: URL?)? = nil

    /// Open a worktree directory in a NEW window/session — the
    /// non-destructive branch-switch path (each worktree is its own
    /// checkout, so nothing in the current tree is touched). Routes through
    /// the same `openFolderInNewSession` closure the sidebar's "Open in New
    /// Session" uses. No-op when no coordinator is wired (previews/tests).
    public func openWorktreeInNewWindow(_ path: URL) {
        guard let openInNew = openFolderInNewSession else {
            Obs.shared.emit(.warn, "git",
                "openWorktreeInNewWindow skipped: no new-session closure wired")
            return
        }
        openInNew(path)
    }

    /// Hard-gated branch switch from the footer chip (UX-C #225, step 2).
    ///
    /// Runs ENTIRELY off the main actor for the git I/O (`status`,
    /// `checkout`, optional `stash`), then hops back to the main actor for
    /// any NSAlert + the post-checkout reload. The dirty-gate decision is
    /// `GitBranchSwitch.decide` (pure, T1m-tested): a dirty tree REFUSES and
    /// offers a stash-then-switch escape hatch rather than risking the
    /// silent carry-over a plain `git checkout` can do.
    ///
    /// `forceStash == true` means the user already accepted the stash offer
    /// from a prior refusal — we stash, then proceed past the gate.
    public func switchBranch(to target: String, forceStash: Bool = false) {
        guard let root = gitChipRepoRoot else { return }
        let current = SessionGitInfo.badge(for: root).branch
        Task.detached { [weak self] in
            let client = GitClient(repoRoot: root, statusTimeout: 10)
            let status = client.status()
                .map { "\($0.indexStatus)\($0.workingStatus) \($0.path)" }
                .joined(separator: "\n")
            let decision = GitBranchSwitch.decide(
                current: current, target: target, porcelainStatus: status)

            switch decision {
            case .noop:
                return
            case .refuse(let reason, _):
                if forceStash {
                    let stash = client.stashPushAll(
                        message: "TextView: auto-stash before switch to \(target)")
                    guard stash.ok else {
                        await self?.presentGitSwitchAlert(
                            title: "Couldn’t stash changes",
                            message: stash.message, offerStash: false, target: target)
                        return
                    }
                    // Stash succeeded — don't return; let control leave the
                    // switch and run the checkout below.
                } else {
                    await self?.presentGitSwitchAlert(
                        title: "Switch blocked — working tree is dirty",
                        message: reason, offerStash: true, target: target)
                    return
                }
            case .allow:
                break
            }

            let result = client.checkout(branch: target)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.ok {
                    // Reload the focused file so the new branch's bytes
                    // show. The sidebar tree refreshes itself via its
                    // FSEvents watcher (a branch switch rewrites files on
                    // disk — see SidebarModel.onFolderChange); we just drop
                    // the children cache so a re-expand re-reads. The chip's
                    // branch label re-reads `.git/HEAD` on the next body
                    // pass, so invalidate the memoized root + republish.
                    Self.gitChipRootCache = nil
                    self.sidebar.clearCache()
                    self.reloadCurrentFile()
                    self.objectWillChange.send()
                } else {
                    Task { await self.presentGitSwitchAlert(
                        title: "git checkout failed",
                        message: result.message, offerStash: false, target: target) }
                }
            }
        }
    }

    /// Present the branch-switch NSAlert on the main actor. When
    /// `offerStash` is true the alert offers "Stash & Switch" (which
    /// re-invokes `switchBranch(forceStash: true)`) alongside Cancel.
    @MainActor
    private func presentGitSwitchAlert(
        title: String, message: String, offerStash: Bool, target: String
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = offerStash ? .warning : .critical
        if offerStash {
            alert.addButton(withTitle: "Stash & Switch")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        let response = alert.runModal()
        if offerStash, response == .alertFirstButtonReturn {
            switchBranch(to: target, forceStash: true)
        }
    }
}
