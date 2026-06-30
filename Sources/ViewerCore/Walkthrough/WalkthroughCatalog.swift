import Foundation

/// Read-side index of walkthrough scripts stored on disk — the data
/// model behind a future "Walkthroughs ▸" menu / library panel (the
/// catalog + management surface of TSK-316).
///
/// This is the FOUNDATION slice: pure ViewerCore logic, no SwiftUI,
/// fully host-testable. The player UI (a submenu listing every stored
/// script, "Open Walkthrough File…", per-script resume) consumes these
/// summaries later; nothing here imports AppKit.
///
/// **Where scripts live** (design `WALKTHROUGH.md` §8 "Script storage"):
///   - `~/Library/Application Support/MarkdownViewer/Walkthroughs/*.json`
///     — the durable, user-global library.
///   - `<repo>/.textview/walkthroughs/*.json` — repo-bound tours that
///     ship with a project (the `.vscode/launch.json` analog). Passed in
///     by the caller (it knows the frontmost window's working dir), not
///     discovered here, so the catalog stays a pure directory scanner.
///
/// **Why metadata summaries, not full scripts.** A library panel listing
/// 50 walkthroughs must not decode 50 full step arrays just to show
/// titles. `Entry` decodes only the lightweight header fields; the full
/// `WalkthroughScript` is loaded lazily (via `WalkthroughLoader`) when a
/// user actually starts one. The header is decoded leniently so a single
/// malformed file doesn't blank the whole list (matches
/// `JSONFileStore.readLenientArray`'s best-effort posture).
public enum WalkthroughCatalog {

    /// Lightweight summary of one stored script — enough to render a
    /// library row without decoding the full step list.
    ///
    /// `Identifiable` keys on `url` (not `id`): two files in different
    /// directories may legitimately carry the same script `id` (a
    /// repo-bound copy of a user-global tour), and a SwiftUI `List` needs
    /// stable per-row identity. The script `id` stays available for
    /// resume / history correlation.
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The on-disk file. Stable per-row identity for a list.
        public let url: URL
        /// `WalkthroughScript.id` — the stable identifier used for
        /// resume + completion-log correlation. May collide across
        /// directories; do NOT use as list identity.
        public let scriptID: String
        public let schema: WalkthroughScript.SchemaVersion
        public let title: String
        public let subtitle: String?
        public let author: String?
        public let createdAt: Date?
        public let estimatedDurationSec: Int?
        /// Number of steps. Decoded cheaply by counting the array without
        /// materializing each `Step`'s actions.
        public let stepCount: Int
        /// File modification time — the catalog's default sort key when
        /// the script omits `createdAt`.
        public let modifiedAt: Date?

        public var id: URL { url }

        public init(
            url: URL,
            scriptID: String,
            schema: WalkthroughScript.SchemaVersion,
            title: String,
            subtitle: String? = nil,
            author: String? = nil,
            createdAt: Date? = nil,
            estimatedDurationSec: Int? = nil,
            stepCount: Int,
            modifiedAt: Date? = nil
        ) {
            self.url = url
            self.scriptID = scriptID
            self.schema = schema
            self.title = title
            self.subtitle = subtitle
            self.author = author
            self.createdAt = createdAt
            self.estimatedDurationSec = estimatedDurationSec
            self.stepCount = stepCount
            self.modifiedAt = modifiedAt
        }
    }

    /// Default user-global library directory:
    /// `~/Library/Application Support/MarkdownViewer/Walkthroughs/`.
    ///
    /// Note this is the **no-bundle-id** Application Support subtree
    /// (where Sessions/bookmarks/history live), matching `WALKTHROUGH.md`
    /// §8. The drop *inbox* (`WalkthroughDropTransport`) deliberately uses
    /// the bundle-id subtree because it's the untrusted automation
    /// channel; the curated library is the user-facing, durable store.
    public static func defaultLibraryDirectory() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("Walkthroughs", isDirectory: true)
    }

    /// Repo-bound walkthrough directory for a given repo root:
    /// `<repoRoot>/.textview/walkthroughs/`.
    public static func repoLibraryDirectory(repoRoot: URL) -> URL {
        repoRoot
            .appendingPathComponent(".textview", isDirectory: true)
            .appendingPathComponent("walkthroughs", isDirectory: true)
    }

    /// Maximum bytes the catalog will read for a single header decode.
    /// A library file with megabytes of steps still gets summarized (we
    /// only need the header + step count), but this caps the read so a
    /// tampered / runaway file can't inflate memory during a list scan.
    /// 4 MiB is far above any realistic walkthrough (50-step cap × even
    /// a fat narration is well under 1 MiB).
    public static let maxHeaderReadBytes = 4 * 1024 * 1024

    /// Enumerate `directory` and return a metadata summary for each
    /// `.json` file that decodes to a valid header. Files that fail to
    /// decode (corrupt JSON, unknown schema, missing required fields)
    /// are silently skipped — a single bad file must not blank the list.
    ///
    /// Returns `[]` (never throws) when the directory is missing or
    /// unreadable — an empty library is the natural first-launch state.
    ///
    /// Results are sorted newest-first by `createdAt` (falling back to
    /// file `modifiedAt`, then `title`) so the most relevant tour is on
    /// top. Pass `sorted: false` to get raw directory order (tests /
    /// callers that re-sort).
    public static func entries(
        in directory: URL,
        fileManager: FileManager = .default,
        sorted: Bool = true
    ) -> [Entry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var result: [Entry] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            // `.json` only — same convention as the drop transport.
            guard url.pathExtension.lowercased() == "json" else { continue }
            if let entry = entry(forFileAt: url, fileManager: fileManager) {
                result.append(entry)
            }
        }

        return sorted ? result.sorted(by: orderedBefore) : result
    }

    /// TSK-1211 — delete a catalog walkthrough by removing its file. Returns
    /// true on success. Best-effort: a missing file or a failed remove returns
    /// false rather than throwing into the browser's delete action.
    @discardableResult
    public static func delete(
        _ entry: Entry,
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            try fileManager.removeItem(at: entry.url)
            return true
        } catch {
            return false
        }
    }

    /// TSK-1211 — rename a catalog walkthrough's FILE to `newBaseName` (.json is
    /// enforced; the on-disk file is the user's library identity). Sanitizes to a
    /// single path component (no slashes / traversal), refuses to overwrite an
    /// existing sibling, and returns the new URL on success — nil on empty name,
    /// collision, or failure. Renames the file only; the in-script `title` (the
    /// row's primary text) is unchanged.
    public static func rename(
        _ entry: Entry,
        toBaseName newBaseName: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"),
              trimmed != ".", trimmed != ".." else { return nil }
        let base = trimmed.hasSuffix(".json") ? String(trimmed.dropLast(5)) : trimmed
        guard !base.isEmpty else { return nil }
        let dest = entry.url.deletingLastPathComponent()
            .appendingPathComponent(base + ".json")
        if dest == entry.url { return entry.url }                 // no-op
        guard !fileManager.fileExists(atPath: dest.path) else { return nil }  // refuse collision
        do {
            try fileManager.moveItem(at: entry.url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// TSK-1326 — a minimal, schema-valid STARTER walkthrough the in-app
    /// "New Walkthrough" action seeds, so authoring is discoverable (copy-and-edit,
    /// matching `docs/examples/sample-walkthrough.json` + `WALKTHROUGH_AUTHORING.md`).
    /// Three steps demonstrating the common action kinds; the narration tells the
    /// author what to change. Pinned valid by `WalkthroughCatalogCreateTests`.
    public static let starterTemplateJSON: String = """
    {
      "schema": "textview.walkthrough/v1",
      "id": "my-walkthrough",
      "title": "My Walkthrough",
      "subtitle": "Edit this starter to build your own guided tour",
      "author": "",
      "rootHint": ".",
      "steps": [
        {
          "id": "step-1",
          "narration": "This is your first step. Replace this narration, edit the title/id above, then add or remove steps below. See docs/WALKTHROUGH_AUTHORING.md for the full format.",
          "actions": [ { "kind": "narrateOnly" } ]
        },
        {
          "id": "step-2",
          "narration": "A step can drive the app — for example, open a file. Set rootHint to your project root; paths resolve relative to it.",
          "actions": [ { "kind": "openFile", "path": "README.md" } ]
        },
        {
          "id": "step-3",
          "narration": "It can also highlight lines to focus the reader. Change the path and line range to point at your own code.",
          "actions": [ { "kind": "highlightRange", "path": "README.md", "startLine": 1, "endLine": 5 } ]
        }
      ]
    }
    """

    /// TSK-1326 — create a NEW walkthrough file from `template` in `directory`,
    /// choosing a collision-free name derived from `baseName` ("<base>.json",
    /// "<base> 2.json", …). Creates the directory if missing. Sanitizes the base
    /// (no slashes/traversal, falls back to "My Walkthrough"). Returns the new
    /// file URL, or nil on failure. The browser's "New Walkthrough" wires to this;
    /// the discoverable copy-and-edit entry point the owner asked for.
    @discardableResult
    public static func create(
        baseName: String = "My Walkthrough",
        in directory: URL,
        template: String = starterTemplateJSON,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = (trimmed.isEmpty || trimmed.contains("/") || trimmed == "." || trimmed == "..")
            ? "My Walkthrough" : trimmed
        let base = safe.hasSuffix(".json") ? String(safe.dropLast(5)) : safe
        guard !base.isEmpty, let data = template.data(using: .utf8) else { return nil }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Collision-free filename (the file is the library identity, per `rename`).
        var candidate = directory.appendingPathComponent(base + ".json")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(n).json")
            n += 1
        }
        do {
            try data.write(to: candidate, options: .atomic)
            return candidate
        } catch {
            return nil
        }
    }

    /// Build one `Entry` from a single file, or nil if it can't be
    /// summarized. Exposed (not private) so a caller that already has a
    /// file URL — e.g. "Open Walkthrough File…" — can produce a row
    /// without re-scanning a directory.
    public static func entry(
        forFileAt url: URL,
        fileManager: FileManager = .default
    ) -> Entry? {
        // Size-cap the read (don't inflate a runaway file during a scan).
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > maxHeaderReadBytes {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              data.count <= maxHeaderReadBytes else { return nil }
        guard let header = try? WalkthroughLoader.defaultDecoder()
            .decode(Header.self, from: data) else {
            return nil
        }

        let modifiedAt = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

        return Entry(
            url: url,
            scriptID: header.id,
            schema: header.schema,
            title: header.title,
            subtitle: header.subtitle,
            author: header.author,
            createdAt: header.createdAt,
            estimatedDurationSec: header.estimatedDurationSec,
            stepCount: header.steps.count,
            modifiedAt: modifiedAt
        )
    }

    /// Catalog sort: newest-first. Primary key `createdAt`, fallback
    /// `modifiedAt`, final tiebreak `title` (ascending, case-insensitive)
    /// so the order is deterministic for equal timestamps (test stability).
    private static func orderedBefore(_ a: Entry, _ b: Entry) -> Bool {
        let ad = a.createdAt ?? a.modifiedAt
        let bd = b.createdAt ?? b.modifiedAt
        switch (ad, bd) {
        case let (x?, y?) where x != y:
            return x > y                        // newer first
        case (.some, .none):
            return true                         // dated entries before undated
        case (.none, .some):
            return false
        default:
            // Equal or both-nil dates → stable alphabetical by title.
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// Minimal decodable mirror of `WalkthroughScript`'s header. Decodes
    /// `steps` as a count-only array of placeholders so we pay for the
    /// JSON parse of the steps array's structure but NOT for materializing
    /// every `Action` payload — the catalog only needs the step *count*.
    ///
    /// Reuses `WalkthroughScript.SchemaVersion`'s own `Codable` so an
    /// unknown schema makes the whole header decode fail (the file is
    /// skipped) — consistent with the loader rejecting unknown versions.
    private struct Header: Decodable {
        let schema: WalkthroughScript.SchemaVersion
        let id: String
        let title: String
        let subtitle: String?
        let author: String?
        let createdAt: Date?
        let estimatedDurationSec: Int?
        let steps: [StepPlaceholder]

        enum CodingKeys: String, CodingKey {
            case schema, id, title, subtitle, author, createdAt
            case estimatedDurationSec, steps
        }
    }

    /// An empty struct that swallows whatever a step object contains.
    /// Decoding an array of these counts the steps without paying to
    /// decode each step's `actions` union.
    private struct StepPlaceholder: Decodable {
        init(from decoder: Decoder) throws {
            // Touch the keyed container so a non-object array element
            // (a malformed steps array) still fails the header decode
            // rather than silently counting garbage.
            _ = try decoder.container(keyedBy: AnyKey.self)
        }
        private struct AnyKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
    }
}
