import Foundation
import CoreServices

/// Watches a filesystem drop directory for new `.json` walkthrough
/// scripts. The simplest viable transport: an external agent (Claude
/// Code via Bash, the user via Finder, a test fixture) drops a file
/// into the inbox and the engine wakes up.
///
/// On detection the transport:
///   1. Parses + validates via `WalkthroughLoader`.
///   2. On success, notifies the delegate with the parsed script.
///   3. On failure, surfaces the rejection via the delegate's reject
///      hook. (The file is left in place — caller decides whether to
///      move it to `rejected/`; this keeps the transport pure-read.)
///
/// FSEvents (via `FSEventStreamCreate`) is reused from `FolderWatcher`
/// — same retain/release C-callback pattern, same dispatch-queue model,
/// same stop()-is-idempotent contract. We do not share the watcher
/// type because the responsibilities diverge: `FolderWatcher` reports
/// "dirs that changed" for cache invalidation, whereas this transport
/// reports "new walkthrough scripts to run".
///
/// Lifecycle:
///   - `init` creates the drop directory if missing and starts the
///     stream.
///   - `stop()` is idempotent; `deinit` also stops.
///   - The delegate is invoked on `queue` (defaults to `.main`).
public final class WalkthroughDropTransport: @unchecked Sendable {

    public enum Error: Swift.Error {
        case streamCreateFailed
        case dropDirCreateFailed(String)
    }

    /// Default drop directory.
    /// `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Walkthroughs/drop/`.
    /// Created on first launch by `init` if absent.
    public static func defaultDropDirectory() -> URL {
        let fm = FileManager.default
        // `applicationSupportDirectory` is user-scoped; on a normal
        // install it resolves to `~/Library/Application Support`.
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("com.markdownviewer.MarkdownViewer", isDirectory: true)
            .appendingPathComponent("Walkthroughs", isDirectory: true)
            .appendingPathComponent("drop", isDirectory: true)
    }

    public weak var delegate: WalkthroughDropTransportDelegate?

    public let dropDirectory: URL

    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    private let latency: CFTimeInterval

    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var stopped: Bool = false
    private var debounceWork: DispatchWorkItem?
    /// Set of file URLs we've already delivered. Prevents repeated
    /// delivery when FSEvents re-fires for unrelated changes in the
    /// directory (e.g. the user opens a Finder window over the inbox).
    private var delivered: Set<String> = []

    public init(
        dropDirectory: URL? = nil,
        latency: CFTimeInterval = 0.25,
        debounce: DispatchTimeInterval = .milliseconds(200),
        queue: DispatchQueue = .main,
        delegate: WalkthroughDropTransportDelegate? = nil
    ) throws {
        self.dropDirectory = (dropDirectory ?? Self.defaultDropDirectory())
            .standardizedFileURL
        self.queue = queue
        self.debounce = debounce
        self.latency = latency
        self.delegate = delegate

        let fm = FileManager.default
        do {
            // 0o700 = owner-only rwx. Drop scripts may contain
            // developer-machine paths or credentials-adjacent context;
            // restrict to the owner even on shared-user macOS hosts.
            try fm.createDirectory(
                at: self.dropDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Error.dropDirCreateFailed(error.localizedDescription)
        }

        try startStream()

        // Scan existing contents on startup so a script written while
        // the app was offline is still picked up. The scan runs on the
        // delivery queue so ordering matches future events.
        queue.async { [weak self] in
            self?.scan()
        }
    }

    deinit { stop() }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        debounceWork?.cancel()
        debounceWork = nil
        delivered.removeAll()
    }

    // MARK: - Private

    private func startStream() throws {
        // Identical retain/release plumbing to `FolderWatcher`. See
        // that file's comments for the UAF rationale.
        let retain: @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer? = { info in
            guard let info else { return nil }
            _ = Unmanaged<WalkthroughDropTransport>.fromOpaque(info).retain()
            return info
        }
        let release: @convention(c) (UnsafeRawPointer?) -> Void = { info in
            guard let info else { return }
            Unmanaged<WalkthroughDropTransport>.fromOpaque(info).release()
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: retain,
            release: release,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        let pathArray = [dropDirectory.path] as CFArray
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            WalkthroughDropTransport.streamCallback,
            &context,
            pathArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw Error.streamCreateFailed
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    fileprivate func handleEvents(_ paths: [String]) {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return }

        // Coalesce a burst of writes (atomic-rename in particular fires
        // a flurry of CREATE/RENAMED events) before re-scanning.
        let work = DispatchWorkItem { [weak self] in
            self?.scan()
        }
        lock.lock()
        debounceWork?.cancel()
        debounceWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Enumerate the drop directory and deliver any `.json` file we
    /// haven't already delivered. We re-scan rather than acting on the
    /// FSEvents path list directly because FSEvents may report a path
    /// that's already gone (atomic rename), and a directory enumeration
    /// is the cheapest source of truth for "what's there right now".
    private func scan() {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dropDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return
        }

        for url in entries.sorted(by: { $0.path < $1.path }) {
            // `.json` only. We deliberately reject `.json.tmp` /
            // `.json.partial` so writers can do atomic rename.
            guard url.pathExtension.lowercased() == "json" else { continue }

            lock.lock()
            let alreadyDelivered = delivered.contains(url.path)
            if !alreadyDelivered {
                // Bound the set so a long-running session that sees
                // many distinct .json filenames doesn't grow it
                // forever. 1024 is well above the typical drop-rate.
                // FIFO eviction is fine — re-delivery of an old file
                // costs at most one reparse and a delegate callback.
                if delivered.count >= 1024 {
                    delivered.removeAll(keepingCapacity: true)
                }
                delivered.insert(url.path)
            }
            lock.unlock()
            if alreadyDelivered { continue }

            let result = WalkthroughLoader.load(fileAt: url)
            switch result {
            case .success(let script):
                delegate?.walkthroughDropTransport(self, didReceive: script, from: url)
            case .failure(let err):
                delegate?.walkthroughDropTransport(self, didReject: err, at: url)
            }
        }
    }

    private static let streamCallback: FSEventStreamCallback = {
        _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let transport = Unmanaged<WalkthroughDropTransport>
            .fromOpaque(info).takeUnretainedValue()
        let cstrs = eventPaths.assumingMemoryBound(
            to: UnsafePointer<CChar>?.self
        )
        var strs: [String] = []
        strs.reserveCapacity(count)
        for i in 0..<count {
            if let c = cstrs[i] { strs.append(String(cString: c)) }
        }
        transport.handleEvents(strs)
    }
}

// MARK: - Delegate

public protocol WalkthroughDropTransportDelegate: AnyObject, Sendable {

    /// A new (or newly-readable) script appeared in the drop directory
    /// and parsed cleanly. `url` is the file that produced it; the
    /// host may move it to `accepted/` after consuming.
    func walkthroughDropTransport(
        _ transport: WalkthroughDropTransport,
        didReceive script: WalkthroughScript,
        from url: URL
    )

    /// A file appeared but failed parse / validation. Default impl is
    /// a no-op so callers that only care about success can opt out.
    func walkthroughDropTransport(
        _ transport: WalkthroughDropTransport,
        didReject error: WalkthroughLoadError,
        at url: URL
    )
}

public extension WalkthroughDropTransportDelegate {
    func walkthroughDropTransport(
        _ transport: WalkthroughDropTransport,
        didReject error: WalkthroughLoadError,
        at url: URL
    ) {}
}
