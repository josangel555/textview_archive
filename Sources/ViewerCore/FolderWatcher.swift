import Foundation
import CoreServices

/// Live mirror of a folder tree via macOS FSEvents. Used by the
/// sidebar to refresh its file-tree when files appear / disappear
/// in the open root from outside the app (Terminal, Finder, build
/// scripts, etc.).
///
/// The recursive flag is implicit — FSEvents watches the whole
/// subtree rooted at `url`. Per-file events are enabled so we know
/// which directory's `childrenCache` to invalidate (not just "some
/// descendant changed"). A debounce coalesces bursts (the typical
/// `git checkout` writes hundreds of files in <1 s).
///
/// Lifecycle:
///   - `init` starts the stream.
///   - `stop()` is idempotent; `deinit` also stops.
///   - The callback fires on the supplied `queue` (defaults to
///     `.main` so SidebarModel can mutate @MainActor state).
public final class FolderWatcher: @unchecked Sendable {

    public enum Error: Swift.Error {
        case streamCreateFailed
    }

    private let path: String
    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    private let onChange: @Sendable ([URL]) -> Void

    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pendingPaths: Set<String> = []
    private var debounceWork: DispatchWorkItem?
    private var stopped: Bool = false

    /// - Parameters:
    ///   - url:      folder to watch (recursive).
    ///   - latency:  FSEvents coalescing window — events arriving
    ///               within this interval are bundled into one
    ///               callback by the kernel. 0.25s is a good
    ///               balance between responsiveness and burst-load.
    ///   - debounce: additional Swift-side debounce on top of
    ///               FSEvents latency. Catches the case where the
    ///               kernel delivers in two adjacent batches.
    ///   - queue:    where the callback fires. `.main` by default
    ///               so @MainActor consumers can mutate state.
    ///   - onChange: invoked with the deduped set of changed
    ///               directory URLs. The set is the **parent
    ///               directories** of changed paths — that's the
    ///               cache key the sidebar uses.
    public init(
        url: URL,
        latency: CFTimeInterval = 0.25,
        debounce: DispatchTimeInterval = .milliseconds(200),
        queue: DispatchQueue = .main,
        onChange: @escaping @Sendable ([URL]) -> Void
    ) throws {
        self.path = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
        try start(latency: latency)
    }

    deinit { stop() }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        debounceWork?.cancel()
        debounceWork = nil
        pendingPaths.removeAll()
    }

    // MARK: - Private

    private func start(latency: CFTimeInterval) throws {
        // The FSEvents C stream stashes our `info` pointer for its
        // lifetime. With `passUnretained` + nil retain/release callbacks
        // the C side held a raw pointer to `self` with no ARC strong
        // count — if the Swift owner dropped the watcher before stop()
        // ran, the dispatch queue could fire a callback into freed
        // memory (UAF). Pass-retained + matching release callbacks make
        // the stream a strong owner; the retain is balanced by either
        // FSEventStreamRelease (in stop()) or the release callback the
        // framework invokes itself if the stream is torn down outside
        // our control.
        let retain: @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer? = { info in
            guard let info else { return nil }
            _ = Unmanaged<FolderWatcher>.fromOpaque(info).retain()
            return info
        }
        let release: @convention(c) (UnsafeRawPointer?) -> Void = { info in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).release()
        }
        // Pass `passUnretained` and let the framework's `retain`
        // callback bump the refcount when it stores the pointer. The
        // matching `release` callback decrements when the framework
        // drops its reference (via FSEventStreamRelease in stop, or
        // intrinsic teardown). Net: ARC counts the framework's
        // ownership accurately, so a callback fired after our owner
        // dropped this watcher still finds a live object.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: retain,
            release: release,
            copyDescription: nil
        )
        // `kFSEventStreamCreateFlagFileEvents` makes per-file events
        // available; without it FSEvents only reports the granularity
        // of the watched root. We need per-file so we can map back to
        // the correct parent directory for cache invalidation.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        let pathArray = [path] as CFArray
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            FolderWatcher.streamCallback,
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

    /// Called from the C callback. Coalesces events into a single
    /// debounced invocation of `onChange`. Suppressed entirely once
    /// `stop()` has run — guards against in-flight kernel events
    /// arriving on the dispatch queue after the user's stop() call.
    fileprivate func handleEvents(_ paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        for p in paths { pendingPaths.insert(p) }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isStopped = self.stopped
            let captured = self.pendingPaths
            self.pendingPaths.removeAll()
            self.debounceWork = nil
            self.lock.unlock()
            if isStopped { return }
            let dirs = FolderWatcher.directorySet(from: captured)
            self.onChange(dirs)
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Translate a set of changed file/dir paths into the set of
    /// **parent directories** the sidebar needs to refresh. If a
    /// changed path is itself a directory, include it directly
    /// (its own children may have changed). Always include the
    /// parent — the path could be a newly-deleted entry whose
    /// `fileExists` returns false.
    static func directorySet(from paths: Set<String>) -> [URL] {
        var out = Set<URL>()
        let fm = FileManager.default
        for p in paths {
            let url = URL(fileURLWithPath: p)
                .standardizedFileURL.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                out.insert(url)
            }
            let parent = url.deletingLastPathComponent()
                .standardizedFileURL.resolvingSymlinksInPath()
            // Don't bubble past `/`.
            if parent.path != "/" { out.insert(parent) }
        }
        return Array(out)
    }

    private static let streamCallback: FSEventStreamCallback = {
        _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info)
            .takeUnretainedValue()
        // Without kFSEventStreamCreateFlagUseCFTypes, eventPaths is
        // a `char **` we walk by index.
        let cstrs = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        var strs: [String] = []
        strs.reserveCapacity(count)
        for i in 0..<count {
            if let c = cstrs[i] { strs.append(String(cString: c)) }
        }
        watcher.handleEvents(strs)
    }
}
