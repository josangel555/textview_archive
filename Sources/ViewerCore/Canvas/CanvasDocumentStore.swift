import Foundation
import RustCore

// Canvas M2.S2 (TSK-1367) — the lifecycle registry the agent surface
// addresses documents through (M2-PLAN §S2). Doc ids are STABLE and
// tab-independent (a canvas doc need not be open in any tab; M3 bridges
// the two): file-backed docs are keyed by their standardized file URL
// path, untitled docs by "untitled-N". Saves go through EditorWriter —
// the editor's atomic, metadata-preserving, symlink-safe write path —
// because a .canvas file IS text (the engine's canonical JSON).

/// One open canvas document.
@MainActor
public final class CanvasOpenDocument {
    public let id: String
    public let adapter: CanvasDocAdapter
    /// Backing file, when file-backed (nil for untitled).
    public private(set) var url: URL?
    /// Engine revision as of the last apply/undo THROUGH THIS STORE's
    /// accessors (the engine holds the truth; this is the agent's cache).
    public internal(set) var lastKnownRev: UInt64 = 0

    init(id: String, adapter: CanvasDocAdapter, url: URL?) {
        self.id = id
        self.adapter = adapter
        self.url = url
    }

    fileprivate func markSaved(to url: URL) {
        self.url = url
    }
}

/// Faults surfaced to the tool layer (plain values — agent-readable).
public enum CanvasStoreError: Error, Equatable {
    case unknownDoc(String)
    case notCanvasFile(String)
    case loadFailed(String)
    case saveFailed(String)
    case untitledNeedsPath(String)
}

/// The @MainActor registry of open canvas documents.
@MainActor
public final class CanvasDocumentStore {
    public private(set) var docs: [String: CanvasOpenDocument] = [:]
    private var untitledCounter = 0

    public init() {}

    /// Stable id for a file URL (standardized path).
    public static func docID(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Create a fresh untitled document (default theme + root page).
    public func create() throws -> CanvasOpenDocument {
        untitledCounter += 1
        let id = "untitled-\(untitledCounter)"
        let doc = CanvasOpenDocument(id: id, adapter: try CanvasDocAdapter(), url: nil)
        docs[id] = doc
        return doc
    }

    /// Open (or return the already-open handle for) a .canvas file.
    /// Double-open DEDUPES: one engine doc per file, so two tools editing
    /// "the same file" see one revision stream, not silent forks.
    public func open(url: URL) throws -> CanvasOpenDocument {
        guard url.pathExtension.lowercased() == "canvas" else {
            throw CanvasStoreError.notCanvasFile(url.lastPathComponent)
        }
        let id = Self.docID(for: url)
        if let existing = docs[id] {
            return existing
        }
        let json: String
        do {
            json = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CanvasStoreError.loadFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        let adapter: CanvasDocAdapter
        do {
            adapter = try CanvasDocAdapter(loading: json)
        } catch let rejection as CanvasRejection {
            throw CanvasStoreError.loadFailed("\(url.lastPathComponent): \(rejection.detail)")
        } catch {
            throw CanvasStoreError.loadFailed("\(url.lastPathComponent): \(error)")
        }
        let doc = CanvasOpenDocument(id: id, adapter: adapter, url: url)
        docs[id] = doc
        return doc
    }

    /// Look up an open document by id.
    public func doc(_ id: String) throws -> CanvasOpenDocument {
        guard let d = docs[id] else {
            let open = docs.keys.sorted().joined(separator: ", ")
            throw CanvasStoreError.unknownDoc(
                "no open canvas doc '\(id)'; open docs: [\(open)]")
        }
        return d
    }

    /// Save a document — to its backing file, or to `path` (which then
    /// becomes the backing file and RE-KEYS the doc id). Canonical bytes
    /// via the engine; atomic write via EditorWriter.
    @discardableResult
    public func save(_ id: String, to path: URL? = nil) throws -> URL {
        let d = try doc(id)
        guard let target = path ?? d.url else {
            throw CanvasStoreError.untitledNeedsPath(
                "doc '\(id)' is untitled — pass a target path")
        }
        guard target.pathExtension.lowercased() == "canvas" else {
            throw CanvasStoreError.notCanvasFile(target.lastPathComponent)
        }
        let json: String
        do {
            json = try d.adapter.save()
        } catch {
            throw CanvasStoreError.saveFailed("engine serialize: \(error)")
        }
        do {
            try EditorWriter.save(json, to: target)
        } catch {
            throw CanvasStoreError.saveFailed("\(target.lastPathComponent): \(error)")
        }
        // Re-key untitled→file-backed (and moves) so the id stays the truth.
        let newID = Self.docID(for: target)
        if newID != d.id {
            docs[newID] = CanvasOpenDocument(id: newID, adapter: d.adapter, url: target)
            docs[d.id] = nil
        } else {
            d.markSaved(to: target)
        }
        return target
    }

    /// Close (drops the handle; the engine doc frees with it).
    public func close(_ id: String) {
        docs[id] = nil
    }
}
