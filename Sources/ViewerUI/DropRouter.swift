import AppKit
import Foundation

/// Shared drop-handler logic for `ContentView.onDrop`. Pulled out so
/// `DragDropTests` can exercise the same code path the production
/// View body uses. Previously the test inlined a copy of the
/// callback body — any divergence between the two would silently
/// drop test coverage.
///
/// The handler is intentionally stateless: it walks the providers,
/// collects every resolvable URL in drag order, filters out paths
/// that don't exist on disk, and hands the resolved list to a single
/// completion closure. Production wires the completion to
/// `DocumentModel.openMultiple`; tests wire it to a probe that records
/// what was received.
///
/// Existence filtering lives *here* (not in the test, and not solely
/// in the model) so the production drop path and the test exercise the
/// identical filter. Folder *opening* is the model's concern (G1); the
/// router only guarantees the URLs it forwards point at something that
/// currently exists on disk, so a stale or dead drag payload can't
/// manufacture a tab for a path that was deleted mid-drag.
public enum DropRouter {

    /// How long to wait for every provider's `loadObject` completion
    /// before flushing whatever has resolved so far. A drag whose
    /// source process dies, or a provider that simply never invokes
    /// its completion, would otherwise leave the drop a silent no-op:
    /// `handle` returned `true` (we claimed the drop) but `onResolved`
    /// never fires. The deadline guarantees forward progress.
    public static let providerDeadline: TimeInterval = 5.0

    /// Walk `providers` (each a `NSItemProvider` from a file-URL drop),
    /// resolve every URL, filter to paths that exist on disk, and call
    /// `onResolved` once with the in-drag-order list. The closure runs
    /// on the main actor.
    ///
    /// `onResolved` fires exactly once: either when every provider's
    /// load completion has reported in, or when `deadline` elapses with
    /// at least one provider still pending (the partial set is flushed
    /// and the stragglers are logged). It is never called twice.
    ///
    /// Returns `true` when there is at least one provider to load
    /// (matching SwiftUI's `.onDrop` boolean contract — true means we
    /// own the drop and the completion will deliver later); `false`
    /// when the provider list is empty.
    @discardableResult
    public static func handle(
        _ providers: [NSItemProvider],
        deadline: TimeInterval = providerDeadline,
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        onResolved: @MainActor @Sendable @escaping ([URL]) -> Void
    ) -> Bool {
        let total = providers.count
        guard total > 0 else { return false }
        // Box the in-progress array so the load-callback closures
        // share state via an NSLock without ever touching a `var`
        // captured by reference (which would trip strict-concurrency).
        let box = Box(total: total, deadline: deadline, fileExists: fileExists, onResolved: onResolved)
        // `loadObject(ofClass:)` returns a non-optional Progress;
        // every provider accepts the load, the caller just doesn't
        // know the *result* until the completion fires. The boolean
        // return preserves SwiftUI's `.onDrop` contract — true means
        // we own the drop (and the completion will deliver later).
        for (i, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                box.set(index: i, url: url)
            }
        }
        // Arm the deadline. If every provider has already reported by
        // the time this fires, `flushIfPending` is a no-op (the
        // all-resolved path already fired the completion).
        Task {
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            box.flushIfPending()
        }
        return true
    }

    /// Thread-safe accumulator. The `loadObject` completion fires on
    /// a private queue per item; we lock around every mutation. Owns
    /// the once-only fire of `onResolved` (whichever of "all resolved"
    /// or "deadline elapsed" happens first wins; the other is a no-op).
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [URL?]
        private var completed = 0
        private var fired = false
        private let total: Int
        private let deadline: TimeInterval
        private let fileExists: @Sendable (URL) -> Bool
        private let onResolved: @MainActor @Sendable ([URL]) -> Void

        init(
            total: Int,
            deadline: TimeInterval,
            fileExists: @escaping @Sendable (URL) -> Bool,
            onResolved: @MainActor @Sendable @escaping ([URL]) -> Void
        ) {
            self.total = total
            self.deadline = deadline
            self.collected = Array(repeating: nil, count: total)
            self.fileExists = fileExists
            self.onResolved = onResolved
        }

        /// Record one resolved URL. Fires the completion once this was
        /// the *last* slot to fill.
        func set(index: Int, url: URL?) {
            lock.lock()
            // Guard against a duplicate completion for the same index
            // (defensive — `loadObject` shouldn't double-fire, but a
            // misbehaving provider must not over-count `completed`).
            if collected[index] == nil { completed += 1 }
            collected[index] = url
            let isLast = completed == total && !fired
            if isLast { fired = true }
            let snapshot = collected
            lock.unlock()
            if isLast { fire(snapshot) }
        }

        /// Deadline path: if not every provider has reported yet, flush
        /// whatever resolved so far and log the stragglers. No-op once
        /// the completion has already fired.
        func flushIfPending() {
            lock.lock()
            guard !fired else { lock.unlock(); return }
            fired = true
            let snapshot = collected
            let pending = total - completed
            lock.unlock()
            if pending > 0 {
                // Best-effort observability — a stuck provider is rare
                // and benign (we still open what resolved), but worth a
                // breadcrumb when diagnosing a "drop did nothing" report.
                NSLog("DropRouter: %d of %d drop provider(s) never resolved before %.1fs deadline; opening %d resolved URL(s).",
                      pending, total, deadline, snapshot.compactMap { $0 }.count)
            }
            fire(snapshot)
        }

        private func fire(_ snapshot: [URL?]) {
            let resolved = snapshot.compactMap { $0 }.filter { fileExists($0) }
            let cb = onResolved
            Task { @MainActor in
                cb(resolved)
            }
        }
    }
}
