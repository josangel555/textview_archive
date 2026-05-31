import Foundation
import Darwin

public enum FileWatcherError: Error, Equatable {
    case cannotOpen
}

/// Watches a single file for writes/renames/deletions. The handler fires on
/// any modification. Atomic writes via `Data.write(to:options:.atomic)` show
/// up as a rename of the temp file over the original; the watcher reattaches
/// to the path after such events so subsequent edits are still caught.
public final class FileWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable () -> Void
    public typealias LostHandler = @Sendable () -> Void

    private let url: URL
    private let handler: Handler
    private let onLost: LostHandler?
    private let queue: DispatchQueue
    private let reattachDelay: TimeInterval
    private let maxReattachAttempts: Int
    private let debounce: TimeInterval

    private let lock = NSLock()
    private var _source: DispatchSourceFileSystemObject?
    private var _stopped: Bool = false
    /// FW-5/FW-11: consecutive *attach failures*. Bumped only in the
    /// catch block of `reattachSoon` (once per real failure to re-open
    /// the path), reset to zero on a successful `attach()`. Drives both
    /// the backoff exponent and the exhaustion check. Previously the
    /// counter was bumped once per inbound rename/delete *event*, which
    /// conflated "the file was edited 5 times" with "we failed to
    /// re-open it 5 times" — a rapid burst of atomic writes could trip
    /// `onLost` even though every reattach was succeeding.
    private var failures: Int = 0
    /// Pending DispatchWorkItem for a scheduled reattach. stop() cancels
    /// this so a watcher that's been torn down doesn't keep firing
    /// reattach probes after the caller has moved on.
    private var _reattachWorkItem: DispatchWorkItem?
    /// FW-13: pending coalesced-handler work item. A burst of writes
    /// (chunked / streamed save) arrives as many `.write`/`.extend`
    /// events; without debounce each one fires `handler()` and the
    /// caller (DocumentModel) reloads the file once per chunk. Holding
    /// the latest work item here and cancelling it on each event
    /// coalesces the burst into a single reload after `debounce`.
    private var _debounceWorkItem: DispatchWorkItem?

    /// - `reattachDelay`: pause after a rename/delete before the watcher
    ///   re-opens the path. Default 50 ms gives atomic writes (temp + rename)
    ///   time to settle.
    /// - `maxReattachAttempts`: how many consecutive re-attach failures before
    ///   the watcher gives up and calls `onLost`. Each retry doubles the
    ///   delay (B2 — instead of silently zombieing when the file is deleted
    ///   without recreation).
    /// - `onLost`: fires once, on the watcher's queue, when re-attach gives up.
    /// - `debounce`: coalescing window for the change handler (FW-13).
    ///   A burst of writes within this window fires `handler()` exactly
    ///   once, on the trailing edge. Default 100 ms; pass `0` to fire
    ///   on every event (used by tests that count fires deterministically).
    public init(
        url: URL,
        queue: DispatchQueue = .main,
        reattachDelay: TimeInterval = 0.05,
        maxReattachAttempts: Int = 5,
        debounce: TimeInterval = 0.1,
        onLost: LostHandler? = nil,
        handler: @escaping Handler
    ) throws {
        self.url = url
        self.handler = handler
        self.onLost = onLost
        self.queue = queue
        self.reattachDelay = reattachDelay
        self.maxReattachAttempts = maxReattachAttempts
        self.debounce = max(0, debounce)
        try attach()
    }

    deinit {
        stop()
    }

    public func stop() {
        lock.lock()
        _stopped = true
        let src = _source
        _source = nil
        let pending = _reattachWorkItem
        _reattachWorkItem = nil
        let debounced = _debounceWorkItem
        _debounceWorkItem = nil
        lock.unlock()
        src?.cancel()
        pending?.cancel()
        debounced?.cancel()
    }

    /// Whether the watcher has stopped (either by user request or by
    /// exhausting reattach attempts).
    public var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    // MARK: - Private

    private func attach() throws {
        // FW-9: `O_CLOEXEC` so the watch fd doesn't leak into children
        // we spawn (git / jq / LSP / plugins). Without it the descriptor
        // survives `posix_spawn` and a hostile / buggy child could read
        // or fstat the watched file via an inherited fd, and the fd
        // count climbs across every spawn while a watcher is live.
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FileWatcherError.cannotOpen }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        // FW-4: capture both `self` and `src` weakly. Capturing `src`
        // strongly created a retain cycle (source -> handler closure ->
        // source) that kept the DispatchSource — and its fd — alive past
        // the watcher's own lifetime; the source was only ever freed
        // when its cancel handler ran, which depended on the very
        // reference we were leaking. Read the live source via
        // `self._source` under the lock instead of closing over `src`.
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            // After stop() the source is cancelled but any event
            // already queued on this serial queue still runs. Without
            // this guard, callers see a fired handler() after they
            // explicitly tore the watcher down — which causes spurious
            // reloads in DocumentModel during tab churn.
            self.lock.lock()
            let stopped = self._stopped
            // Only act on events from the *current* source. A stale
            // source whose teardown is still in flight must not drive
            // reload / reattach.
            let isCurrent = (self._source === src)
            let events = src.data
            self.lock.unlock()
            if stopped || !isCurrent { return }
            self.fireHandlerDebounced()
            if !events.intersection([.rename, .delete]).isEmpty {
                self.reattachSoon()
            }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        lock.lock()
        _source = src
        failures = 0  // a successful attach clears the failure counter
        lock.unlock()
    }

    /// FW-13: coalesce a burst of change events into a single
    /// `handler()` call on the trailing edge of `debounce`. With
    /// `debounce == 0` we fire synchronously so tests that count
    /// fires-per-event stay deterministic.
    private func fireHandlerDebounced() {
        if debounce <= 0 {
            handler()
            return
        }
        lock.lock()
        _debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.lock.lock()
            self._debounceWorkItem = nil
            self.lock.unlock()
            self.handler()
        }
        _debounceWorkItem = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// B1/B2: retry attach with exponential backoff capped at 1 second.
    /// If we exhaust `maxReattachAttempts`, mark the watcher stopped and
    /// call `onLost` once so the caller can surface a UI hint.
    ///
    /// FW-5/FW-11: backoff exponent and exhaustion are driven by
    /// `failures` (consecutive attach *failures*), not by an event
    /// counter. The current `failures` snapshot is read under the lock
    /// to compute the delay; the bump happens only inside the catch
    /// block when `attach()` actually fails, and `attach()` resets it
    /// on success. So a rename/delete event that re-opens cleanly does
    /// not advance the backoff or count toward exhaustion.
    ///
    /// Concurrency: cancellation of the prior work item, new work-item
    /// construction, and `_reattachWorkItem` assignment all happen
    /// under a single lock window. Two concurrent reattachSoon calls
    /// were previously able to interleave such that the first scheduled
    /// work item became unreachable via `_reattachWorkItem` and could
    /// not be cancelled by `stop()`.
    private func reattachSoon() {
        lock.lock()
        // Backoff exponent is the count of failures so far; 0 on the
        // first probe after an event (no delay penalty yet).
        let failureCount = failures
        _reattachWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.lock.lock()
            self._source?.cancel()
            self._source = nil
            self.lock.unlock()
            do {
                try self.attach()  // resets `failures` to 0 on success
            } catch {
                self.lock.lock()
                self.failures += 1
                let failed = self.failures
                self.lock.unlock()
                if failed >= self.maxReattachAttempts {
                    self.lock.lock(); self._stopped = true; self.lock.unlock()
                    self.onLost?()
                } else {
                    self.reattachSoon()
                }
            }
        }
        _reattachWorkItem = work
        lock.unlock()

        let cappedDelay = min(reattachDelay * pow(2.0, Double(failureCount)), 1.0)
        if cappedDelay <= 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + cappedDelay, execute: work)
        }
    }
}
