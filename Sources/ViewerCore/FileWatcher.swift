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

    private let lock = NSLock()
    private var _source: DispatchSourceFileSystemObject?
    private var _stopped: Bool = false
    private var attempts: Int = 0

    /// - `reattachDelay`: pause after a rename/delete before the watcher
    ///   re-opens the path. Default 50 ms gives atomic writes (temp + rename)
    ///   time to settle.
    /// - `maxReattachAttempts`: how many consecutive re-attach failures before
    ///   the watcher gives up and calls `onLost`. Each retry doubles the
    ///   delay (B2 — instead of silently zombieing when the file is deleted
    ///   without recreation).
    /// - `onLost`: fires once, on the watcher's queue, when re-attach gives up.
    public init(
        url: URL,
        queue: DispatchQueue = .main,
        reattachDelay: TimeInterval = 0.05,
        maxReattachAttempts: Int = 5,
        onLost: LostHandler? = nil,
        handler: @escaping Handler
    ) throws {
        self.url = url
        self.handler = handler
        self.onLost = onLost
        self.queue = queue
        self.reattachDelay = reattachDelay
        self.maxReattachAttempts = maxReattachAttempts
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
        lock.unlock()
        src?.cancel()
    }

    /// Whether the watcher has stopped (either by user request or by
    /// exhausting reattach attempts).
    public var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    // MARK: - Private

    private func attach() throws {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { throw FileWatcherError.cannotOpen }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            self.handler()
            if !events.intersection([.rename, .delete]).isEmpty {
                self.reattachSoon()
            }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        lock.lock()
        _source = src
        attempts = 0  // a successful attach clears the retry counter
        lock.unlock()
    }

    /// B1/B2: retry attach with exponential backoff capped at 1 second.
    /// If we exhaust `maxReattachAttempts`, mark the watcher stopped and
    /// call `onLost` once so the caller can surface a UI hint.
    private func reattachSoon() {
        lock.lock()
        attempts += 1
        let attempt = attempts
        lock.unlock()

        let cappedDelay = min(reattachDelay * pow(2.0, Double(attempt - 1)), 1.0)
        let work = { [weak self] in
            guard let self, !self.isStopped else { return }
            self.lock.lock()
            self._source?.cancel()
            self._source = nil
            self.lock.unlock()
            do {
                try self.attach()
            } catch {
                if attempt >= self.maxReattachAttempts {
                    self.lock.lock(); self._stopped = true; self.lock.unlock()
                    self.onLost?()
                } else {
                    self.reattachSoon()
                }
            }
        }
        if cappedDelay <= 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + cappedDelay, execute: work)
        }
    }
}
