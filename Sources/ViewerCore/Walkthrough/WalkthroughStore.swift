import Foundation

/// Durable on-disk library of saved walkthrough scripts — the "save
/// walkthroughs" capability `docs/WALKTHROUGH_DESIGN_v2.md` §"Script
/// storage" promised but never shipped.
///
/// The drop transport (`WalkthroughDropTransport`) is a *consumption*
/// channel: an agent drops a `.json`, the engine runs it, the file is
/// transient. Nothing kept a saved copy the user could re-open later.
/// This store is the *retention* half: `save(_:)` writes a script to
/// the library; `list()`, `load(id:)`, `delete(id:)`, `exists(id:)`
/// manage it. The two layers compose — the file-drop delegate can call
/// `save(_:)` to durably retain every accepted script so the user can
/// replay it from `File ▸ Walkthroughs` without the agent re-publishing.
///
/// **Library location.** `<appSupport>/MarkdownViewer/Walkthroughs/`
/// (NO bundle-id prefix), matching the un-prefixed Application-Support
/// subdir documented in `CLAUDE.md` §"Persisted state lives under TWO
/// Application Support subdirs" — the same tree that holds `Sessions/`,
/// `bookmarks.json`, `history.json`. (The drop *inbox* lives under the
/// bundle-id-prefixed dir; retention lives with the rest of user state.)
///
/// **Filename = sanitized id + `.json`.** A script id is part of an
/// untrusted payload, so it is NOT trusted as a path component. The id
/// is sanitized to `[A-Za-z0-9._-]`, leading dots stripped, length
/// capped, and the result is required to be non-empty — defeating
/// `../`, absolute paths, and reserved names. The on-disk filename is
/// therefore always a single safe component inside the library dir.
///
/// **Atomic writes.** `save` writes to a sibling temp file then renames
/// (`Data.write(options: .atomic)` does the temp-then-rename dance), so
/// a crash mid-write never leaves a half-written script the loader would
/// reject as corrupt.
///
/// Pure logic + `FileManager` only — fully host-testable, no UI, no VM.
public struct WalkthroughStore: Sendable {

    /// Root directory of the saved-walkthrough library. Public so callers
    /// (menu builders, tests) can surface or seed it.
    public let libraryDirectory: URL

    // MARK: - Init

    /// - Parameter libraryDirectory: override for tests / non-default
    ///   installs. Defaults to the user-scoped Application Support
    ///   library (`defaultLibraryDirectory()`).
    public init(libraryDirectory: URL? = nil) {
        self.libraryDirectory =
            (libraryDirectory ?? Self.defaultLibraryDirectory())
            .standardizedFileURL
    }

    /// `<appSupport>/MarkdownViewer/Walkthroughs/`. Mirrors the
    /// un-prefixed Application-Support subdir the rest of the app's
    /// persisted user state lives under (Sessions, bookmarks, history).
    public static func defaultLibraryDirectory() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("Walkthroughs", isDirectory: true)
    }

    // MARK: - Save

    /// Persist `script` to the library, keyed by its (sanitized) id.
    /// Overwrites any existing script with the same sanitized id —
    /// re-saving an edited tour is the common case, so this is upsert,
    /// not insert-only. Returns the URL written.
    ///
    /// Throws `StoreError.invalidID` if the script's id sanitizes to
    /// empty (e.g. id was `"../"` or all-dots), `.ioFailed` on a
    /// filesystem error. The serialized JSON is canonical: sorted keys +
    /// pretty-printed so a saved tour diffs cleanly in git when a repo
    /// ships its own `.textview/walkthroughs/`.
    @discardableResult
    public func save(_ script: WalkthroughScript) throws -> URL {
        let url = try fileURL(forID: script.id)
        try ensureLibraryDirectory()
        let data: Data
        do {
            data = try Self.encoder().encode(script)
        } catch {
            throw StoreError.encodeFailed(error.localizedDescription)
        }
        do {
            // .atomic = write to a temp sibling then rename; a crash
            // mid-write leaves the prior file intact, never a torn one.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: - Load

    /// Decode the saved script with the given id, or `nil` if no file
    /// exists for it. Validation (path-escape etc.) runs through
    /// `WalkthroughLoader` so a tampered-on-disk file is rejected the
    /// same way a freshly-dropped one is.
    ///
    /// Throws `.invalidID` for an unsanitizable id and `.loadFailed`
    /// when the file exists but fails to decode/validate.
    public func load(id: String) throws -> WalkthroughScript? {
        let url = try fileURL(forID: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        switch WalkthroughLoader.load(fileAt: url) {
        case .success(let script):
            return script
        case .failure(let err):
            throw StoreError.loadFailed("\(err)")
        }
    }

    // MARK: - List

    /// Lightweight metadata for every saved script, newest-created
    /// first (then by id for stable ordering when `createdAt` ties or
    /// is absent). Decodes each file's *header* fields only — it does
    /// NOT materialize the full step list — so listing a library of
    /// hundreds of tours for a menu stays cheap. Files that fail to
    /// decode are skipped (a corrupt file shouldn't blank the menu);
    /// the count of skipped files is available via `listResult()`.
    public func list() -> [SavedWalkthrough] {
        listResult().items
    }

    /// `list()` plus the count of files that were present but
    /// undecodable — surfaced separately so a caller can warn the user
    /// ("2 saved walkthroughs are corrupt") without polluting the menu.
    public func listResult() -> ListResult {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: libraryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            // No directory yet ⇒ empty library, not an error.
            return ListResult(items: [], skipped: 0)
        }

        var items: [SavedWalkthrough] = []
        var skipped = 0
        let decoder = Self.decoder()
        for url in entries {
            guard url.pathExtension.lowercased() == "json" else { continue }
            guard let data = try? Data(contentsOf: url) else {
                skipped += 1
                continue
            }
            // Decode only the header — a small struct that ignores
            // `steps` — so we don't pay to materialize every action.
            guard let header = try? decoder.decode(Header.self, from: data) else {
                skipped += 1
                continue
            }
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? nil
            items.append(SavedWalkthrough(
                id: header.id,
                title: header.title,
                subtitle: header.subtitle,
                author: header.author,
                createdAt: header.createdAt,
                stepCount: header.steps.count,
                fileURL: url,
                modifiedAt: modified
            ))
        }
        // Newest created first; nil createdAt sorts last; id breaks ties.
        items.sort { a, b in
            switch (a.createdAt, b.createdAt) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?):                 return false
            case (_?, nil):                 return true
            default:                        return a.id < b.id
            }
        }
        return ListResult(items: items, skipped: skipped)
    }

    // MARK: - Delete / exists

    /// Remove the saved script with the given id. Returns `true` if a
    /// file was deleted, `false` if none existed (idempotent delete).
    @discardableResult
    public func delete(id: String) throws -> Bool {
        let url = try fileURL(forID: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
        return true
    }

    /// Whether a saved script exists for the given id.
    public func exists(id: String) -> Bool {
        guard let url = try? fileURL(forID: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Filename derivation

    /// Resolve a script id to its on-disk URL inside the library,
    /// sanitizing the id to a single safe path component. Throws
    /// `.invalidID` if the id sanitizes to empty.
    ///
    /// Exposed so callers can show the path they'd write to and tests
    /// can assert the containment property directly.
    public func fileURL(forID id: String) throws -> URL {
        let safe = Self.sanitizedFilename(forID: id)
        guard !safe.isEmpty else { throw StoreError.invalidID(id) }
        return libraryDirectory.appendingPathComponent(safe + ".json",
                                                       isDirectory: false)
    }

    /// Map an arbitrary (untrusted) id to a safe single filename
    /// component (without the `.json` suffix). The result is guaranteed
    /// to contain no path separators, no `..`, no leading dot, so it
    /// can never escape the library directory.
    ///
    /// Rules:
    ///   - keep only `[A-Za-z0-9._-]`; every other char ⇒ `_`.
    ///   - collapse runs of `_` so `a//b` and `a..b` don't bloat.
    ///   - strip leading dots (`.`/`..`/`.hidden` would be a dotfile or
    ///     traversal) and leading/trailing `_`.
    ///   - cap at 120 chars (HFS+/APFS allow 255; leave room for the
    ///     `.json` suffix and headroom).
    /// An id that reduces to empty (e.g. `"../"`, `"..."`, `"///"`)
    /// yields `""`, which `fileURL(forID:)` rejects.
    public static func sanitizedFilename(forID id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var out = String()
        out.reserveCapacity(id.count)
        var lastWasUnderscore = false
        for ch in id {
            if allowed.contains(ch) {
                out.append(ch)
                lastWasUnderscore = (ch == "_")
            } else {
                // Replace a disallowed run with a single underscore.
                if !lastWasUnderscore { out.append("_") }
                lastWasUnderscore = true
            }
        }
        // Strip leading dots (dotfile / traversal) and surrounding `_`.
        while let f = out.first, f == "." || f == "_" { out.removeFirst() }
        while let l = out.last, l == "_" { out.removeLast() }
        if out.count > 120 { out = String(out.prefix(120)) }
        // A trailing dot after the prefix-cut would make `<name>.json`
        // read oddly; trim it.
        while let l = out.last, l == "." { out.removeLast() }
        return out
    }

    // MARK: - Helpers

    private func ensureLibraryDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: libraryDirectory,
                withIntermediateDirectories: true,
                // 0o700: saved tours may carry developer-machine paths;
                // owner-only on shared-user hosts, matching the drop dir.
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Header-only view of a saved script — every top-level field
    /// EXCEPT the full step bodies (we keep `steps` here so the count is
    /// exact, but it decodes against `Step` which is cheap relative to
    /// re-validating). Used by `list()` to avoid paying full validation.
    private struct Header: Decodable {
        let id: String
        let title: String
        let subtitle: String?
        let author: String?
        let createdAt: Date?
        let steps: [Step]
    }
}

// MARK: - Listing model

/// Library-listing row: the script's identity + metadata, no step
/// bodies. Enough to render a `File ▸ Walkthroughs` menu entry or a
/// picker row without decoding the whole tour.
public struct SavedWalkthrough: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let author: String?
    public let createdAt: Date?
    public let stepCount: Int
    public let fileURL: URL
    public let modifiedAt: Date?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        author: String? = nil,
        createdAt: Date? = nil,
        stepCount: Int,
        fileURL: URL,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.author = author
        self.createdAt = createdAt
        self.stepCount = stepCount
        self.fileURL = fileURL
        self.modifiedAt = modifiedAt
    }
}

/// `list()` result with a corrupt-file count alongside the items.
public struct ListResult: Sendable, Equatable {
    public let items: [SavedWalkthrough]
    public let skipped: Int

    public init(items: [SavedWalkthrough], skipped: Int) {
        self.items = items
        self.skipped = skipped
    }
}

// MARK: - Errors

public enum StoreError: Error, Equatable, Sendable {
    /// The script id sanitizes to an empty filename (e.g. `"../"`,
    /// `"..."`, all-disallowed-chars) so it has no safe on-disk name.
    case invalidID(String)
    /// `JSONEncoder` failed to serialize the script.
    case encodeFailed(String)
    /// A filesystem operation (write / mkdir / remove) failed.
    case ioFailed(String)
    /// The file exists but failed to decode or validate on load.
    case loadFailed(String)
}
