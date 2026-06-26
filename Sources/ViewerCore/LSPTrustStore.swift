import Foundation

/// TSK-1129 (security, slice 2 — model) — the persisted "one-time trust" store
/// for WORKSPACE-LOCAL language-server binaries, pairing with `LSPBinaryTrust`
/// (the pure decision core). A repo-local server binary (`node_modules/.bin/…`,
/// or a workspace `lsp.json` overriding `command`) is an RCE-on-browse vector;
/// the user confirms such a binary ONCE and the grant survives launches (the
/// "one-time" requirement).
///
/// This is the persistence + a convenience `decision()` that feeds the store's
/// trusted set into `LSPBinaryTrust.decision`. `LSPClient` CONSULTS it to WARN on
/// an untrusted spawn (observability — the vector is now visible instead of
/// silent). The BLOCK + the confirm-prompt UI are the owner-gated tail (block-by-
/// default would break legit local servers until the prompt ships — parked).
///
/// Persisted as a sorted `[String]` of canonical (standardized, symlink-resolved)
/// paths at `~/Library/Application Support/MarkdownViewer/lsp-trusted-binaries.json`.
public final class LSPTrustStore: @unchecked Sendable {

    /// Process-wide store over the default on-disk location.
    public static let shared = LSPTrustStore(storeURL: LSPTrustStore.defaultStoreURL())

    private let storeURL: URL
    private let maxEntries: Int
    private let maxStoreFileBytes: Int
    private let lock = NSLock()
    private var trusted: Set<String> = []

    /// `storeURL` is injectable so tests use a temp file (never the real one).
    public init(storeURL: URL, maxEntries: Int = 1024, maxStoreFileBytes: Int = 256 * 1024) {
        self.storeURL = storeURL
        self.maxEntries = maxEntries
        self.maxStoreFileBytes = maxStoreFileBytes
        load()
    }

    public static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("lsp-trusted-binaries.json", isDirectory: false)
    }

    /// The trusted canonical-path set — feeds `LSPBinaryTrust.decision`.
    public var trustedPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return trusted
    }

    public func isTrusted(_ binary: URL) -> Bool {
        let key = LSPBinaryTrust.canonicalPath(for: binary)
        lock.lock(); defer { lock.unlock() }
        return trusted.contains(key)
    }

    /// Record a one-time trust grant for `binary` (what the confirm prompt calls).
    /// Returns false if the entry cap is hit (a tampered/runaway store).
    @discardableResult
    public func grant(_ binary: URL) -> Bool {
        let key = LSPBinaryTrust.canonicalPath(for: binary)
        lock.lock()
        if trusted.contains(key) { lock.unlock(); return true }
        guard trusted.count < maxEntries else { lock.unlock(); return false }
        trusted.insert(key)
        lock.unlock()
        persist()
        return true
    }

    @discardableResult
    public func revoke(_ binary: URL) -> Bool {
        let key = LSPBinaryTrust.canonicalPath(for: binary)
        lock.lock()
        let removed = trusted.remove(key) != nil
        lock.unlock()
        if removed { persist() }
        return removed
    }

    /// The spawn decision for `binary` under `workspaceRoot`, consulting the
    /// persisted trusted set. `.needsTrust` ⇒ a workspace-local, unconfirmed binary.
    public func decision(binary: URL, workspaceRoot: URL) -> LSPBinaryTrust.Decision {
        LSPBinaryTrust.decision(
            binary: binary, workspaceRoot: workspaceRoot, trustedPaths: trustedPaths)
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              data.count <= maxStoreFileBytes,
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return }
        lock.lock()
        trusted = Set(arr.prefix(maxEntries))
        lock.unlock()
    }

    private func persist() {
        lock.lock()
        let snapshot = Array(trusted).sorted()
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}
