import AppKit
import Foundation

/// Shared drop-handler logic for `ContentView.onDrop`. Pulled out so
/// `DragDropTests` can exercise the same code path the production
/// View body uses. Previously the test inlined a copy of the
/// callback body — any divergence between the two would silently
/// drop test coverage.
///
/// The handler is intentionally stateless: it walks the providers,
/// collects every resolvable URL in drag order, and hands the
/// resolved list to a single completion closure. Production wires
/// the completion to `DocumentModel.openMultiple`; tests wire it to
/// a probe that records what was received.
public enum DropRouter {

    /// Walk `providers` (each a `NSItemProvider` from a file-URL drop),
    /// resolve every URL, and call `onResolved` once with the in-drag-
    /// order list. The closure runs on the main actor.
    ///
    /// Returns `true` when at least one provider accepts the load
    /// callback (matching SwiftUI's `.onDrop` boolean contract); `false`
    /// when none do.
    @discardableResult
    public static func handle(
        _ providers: [NSItemProvider],
        onResolved: @MainActor @Sendable @escaping ([URL]) -> Void
    ) -> Bool {
        let total = providers.count
        guard total > 0 else { return false }
        // Box the in-progress array so the load-callback closures
        // share state via an NSLock without ever touching a `var`
        // captured by reference (which would trip strict-concurrency).
        let box = Box(total: total)
        // `loadObject(ofClass:)` returns a non-optional Progress;
        // every provider accepts the load, the caller just doesn't
        // know the *result* until the completion fires. The boolean
        // return preserves SwiftUI's `.onDrop` contract — true means
        // we own the drop (and the completion will deliver later).
        for (i, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let snapshot = box.set(index: i, url: url)
                if let urls = snapshot {
                    let resolved = urls.compactMap { $0 }
                    Task { @MainActor in
                        onResolved(resolved)
                    }
                }
            }
        }
        return true
    }

    /// Thread-safe accumulator. The `loadObject` completion fires on
    /// a private queue per item; we lock around every mutation.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [URL?]
        private var completed = 0
        private let total: Int

        init(total: Int) {
            self.total = total
            self.collected = Array(repeating: nil, count: total)
        }

        /// Record one resolved URL. Returns a snapshot of the full
        /// array when this was the *last* slot to fill, otherwise
        /// nil. Caller treats the non-nil return as "all done; fire
        /// the completion".
        func set(index: Int, url: URL?) -> [URL?]? {
            lock.lock()
            defer { lock.unlock() }
            collected[index] = url
            completed += 1
            return completed == total ? collected : nil
        }
    }
}
