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

    private let url: URL
    private let handler: Handler
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var stopped: Bool = false

    public init(url: URL, queue: DispatchQueue = .main, handler: @escaping Handler) throws {
        self.url = url
        self.handler = handler
        self.queue = queue
        try attach()
    }

    deinit {
        stop()
    }

    public func stop() {
        stopped = true
        source?.cancel()
        source = nil
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
            // For atomic writes / deletions, the FD is now stale.
            if !events.intersection([.rename, .delete]).isEmpty {
                self.reattachSoon()
            }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        fileDescriptor = fd
        source = src
    }

    private func reattachSoon() {
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.stopped else { return }
            self.source?.cancel()
            self.source = nil
            try? self.attach()
        }
    }
}
