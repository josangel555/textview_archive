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
    private let maxWait: DispatchTimeInterval
    private let onChange: @Sendable ([URL]) -> Void
    private let onRootChanged: (@Sendable () -> Void)?

    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pendingPaths: Set<String> = []
    private var debounceWork: DispatchWorkItem?
    private var stopped: Bool = false
    /// FW-12: wall-clock time of the first event in the current pending
    /// burst (`DispatchTime` from the kernel's monotonic clock). Reset
    /// to `nil` after every flush. Used to force a flush at least every
    /// `maxWait` even while events keep arriving and pushing the
    /// trailing-edge debounce out — without it, a continuous write
    /// stream (e.g. a long `npm install`) would starve `onChange`
    /// indefinitely because each event re-arms the debounce timer.
    private var firstPendingAt: DispatchTime?
    /// Off-main worker for `directorySet` (FW-3). `realpath` +
    /// `fileExists` per changed path is a syscall storm we don't want
    /// running on `.main` during a burst.
    private let resolveQueue = DispatchQueue(
        label: "FolderWatcher.resolve", qos: .utility
    )

    /// Background-resolved `realpath` cache for `directorySet`. macOS
    /// resolves the same parent dirs over and over during a burst
    /// (every file in `node_modules/x` shares the same parent); caching
    /// the input-string -> resolved-URL mapping avoids re-`realpath`ing.
    private var resolveCache: [String: URL] = [:]
    private let resolveCacheLock = NSLock()

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
    ///   - maxWait:  FW-12 — upper bound on how long a continuously-
    ///               churning tree can defer `onChange`. Even if events
    ///               keep arriving and re-arming the `debounce` timer,
    ///               we flush at least once per `maxWait` from the first
    ///               pending event. Default 1s.
    ///   - onRootChanged: FW-2 — invoked (on `queue`) when FSEvents
    ///               reports `kFSEventStreamEventFlagRootChanged`,
    ///               meaning the watched root itself was renamed,
    ///               moved, or deleted. The watched `path` no longer
    ///               resolves to the same inode; the consumer
    ///               (SidebarModel) must re-resolve the root and
    ///               rebuild the watcher. Without `WatchRoot` +
    ///               this signal, renaming the open folder silently
    ///               kills all further updates.
    public init(
        url: URL,
        latency: CFTimeInterval = 0.25,
        debounce: DispatchTimeInterval = .milliseconds(200),
        maxWait: DispatchTimeInterval = .seconds(1),
        queue: DispatchQueue = .main,
        onRootChanged: (@Sendable () -> Void)? = nil,
        onChange: @escaping @Sendable ([URL]) -> Void
    ) throws {
        self.path = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.queue = queue
        self.debounce = debounce
        self.maxWait = maxWait
        self.onChange = onChange
        self.onRootChanged = onRootChanged
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
        //
        // FW-2: `kFSEventStreamCreateFlagWatchRoot` asks the kernel to
        // also report changes to the *path to* the watched root (a
        // rename / move / delete of the root itself, or any ancestor).
        // Such an event arrives with `kFSEventStreamEventFlagRootChanged`
        // set on the per-event flags. Without WatchRoot, renaming the
        // open folder leaves the stream pointed at a now-dangling path
        // and we silently stop receiving updates.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
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
    ///
    /// FW-2: if any event in this batch carries
    /// `kFSEventStreamEventFlagRootChanged`, the watched root moved out
    /// from under us — fire `onRootChanged` (the only useful response
    /// is to re-resolve + rebuild the watcher) and skip the per-path
    /// bookkeeping for this batch (the paths are stale).
    fileprivate func handleEvents(_ paths: [String], rootChanged: Bool) {
        if rootChanged {
            lock.lock()
            let isStopped = stopped
            lock.unlock()
            if isStopped { return }
            if let onRootChanged { queue.async(execute: onRootChanged) }
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        for p in paths { pendingPaths.insert(p) }
        // FW-12: stamp the start of the burst on the first pending event.
        if firstPendingAt == nil { firstPendingAt = .now() }
        debounceWork?.cancel()

        // Pick the earlier of (now + debounce) and (firstPending +
        // maxWait) so a continuous event stream still flushes at least
        // every `maxWait`.
        let debounceDeadline = DispatchTime.now() + debounce
        let maxWaitDeadline = (firstPendingAt ?? .now()) + maxWait
        let deadline = min(debounceDeadline, maxWaitDeadline)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isStopped = self.stopped
            let captured = self.pendingPaths
            self.pendingPaths.removeAll()
            self.debounceWork = nil
            self.firstPendingAt = nil
            self.lock.unlock()
            if isStopped { return }
            // FW-3: resolve paths -> parent dirs off the callback queue
            // (`.main` by default). `realpath` + `fileExists` per path
            // is a syscall storm during a burst; hop back to the
            // caller's queue only for the lightweight `onChange`.
            self.resolveQueue.async {
                let dirs = self.directorySetCached(from: captured)
                self.lock.lock()
                let stillRunning = !self.stopped
                self.lock.unlock()
                guard stillRunning else { return }
                self.queue.async { self.onChange(dirs) }
            }
        }
        debounceWork = work
        // Schedule against the chosen deadline. `asyncAfter` clamps a
        // past deadline to "run ASAP", so a maxWait already exceeded
        // flushes on the next queue turn.
        queue.asyncAfter(deadline: deadline, execute: work)
    }

    /// FW-3: instance wrapper around the pure `directorySet` that adds
    /// a per-watcher `realpath` cache. The static form stays for tests
    /// and callers that don't want caching.
    private func directorySetCached(from paths: Set<String>) -> [URL] {
        var out = Set<URL>()
        let fm = FileManager.default
        for p in paths {
            resolveCacheLock.lock()
            let cached = resolveCache[p]
            resolveCacheLock.unlock()
            let url: URL
            if let cached {
                url = cached
            } else {
                // FW-3: a single `resolvingSymlinksInPath()` — the
                // original code resolved twice (once after
                // `standardizedFileURL`, again on the same URL), a
                // redundant `realpath` syscall.
                url = URL(fileURLWithPath: p).resolvingSymlinksInPath()
                resolveCacheLock.lock()
                // Bound the cache so a pathological burst across a huge
                // tree can't grow it without limit.
                if resolveCache.count > 4096 { resolveCache.removeAll() }
                resolveCache[p] = url
                resolveCacheLock.unlock()
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                out.insert(url)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path != "/" { out.insert(parent) }
        }
        return Array(out)
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
            // FW-3: single `realpath` (was resolved twice on the same
            // URL — `standardizedFileURL` then `resolvingSymlinksInPath`
            // then again on the parent). `resolvingSymlinksInPath` is a
            // superset of `standardizedFileURL` for our purposes.
            let url = URL(fileURLWithPath: p).resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                out.insert(url)
            }
            let parent = url.deletingLastPathComponent()
            // Don't bubble past `/`.
            if parent.path != "/" { out.insert(parent) }
        }
        return Array(out)
    }

    private static let streamCallback: FSEventStreamCallback = {
        _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info)
            .takeUnretainedValue()
        // Without kFSEventStreamCreateFlagUseCFTypes, eventPaths is
        // a `char **` we walk by index.
        let cstrs = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        var strs: [String] = []
        strs.reserveCapacity(count)
        // FW-2: scan per-event flags for RootChanged. The flag may be
        // OR'd onto any event in the batch (FSEvents doesn't deliver it
        // as a standalone event), so we check every entry.
        var rootChanged = false
        let rootFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        for i in 0..<count {
            if let c = cstrs[i] { strs.append(String(cString: c)) }
            if (eventFlags[i] & rootFlag) != 0 { rootChanged = true }
        }
        watcher.handleEvents(strs, rootChanged: rootChanged)
    }
}
