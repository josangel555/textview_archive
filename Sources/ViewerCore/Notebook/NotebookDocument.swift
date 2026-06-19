import Foundation

/// A single notebook cell type (nbformat v4 `cell_type`).
public enum NotebookCellType: String, Equatable, Sendable, CaseIterable {
    case code
    case markdown
    case raw
}

/// One ordered cell of a notebook.
///
/// `source` is the editable text (joined from nbformat's line-array form).
/// `metadata` and, for code cells, `outputs` / `executionCount` are retained
/// OPAQUELY as `JSONValue` so we never drop fields we don't model (e.g.
/// `outputs[].data["image/png"]`, `metadata.collapsed`, attachment blobs).
public struct NotebookCell: Equatable, Sendable, Identifiable {
    /// Stable identity for SwiftUI lists + cell ops. Not persisted as the
    /// nbformat `id` unless one was present (see `nbformatID`).
    public let id: UUID
    public var cellType: NotebookCellType
    public var source: String
    /// Opaque per-cell metadata object (always an object; defaults to empty).
    public var metadata: JSONValue
    /// Code-cell outputs, retained opaquely (array of output objects). Nil for
    /// markdown/raw cells (where nbformat has no `outputs` key).
    public var outputs: JSONValue?
    /// Code-cell `execution_count` (number or null). Nil for non-code cells.
    public var executionCount: JSONValue?
    /// The nbformat v4.5 cell `id`, if present, preserved verbatim.
    public var nbformatID: String?
    /// Any extra top-level cell keys we don't explicitly model (e.g.
    /// `attachments`), in original order, so they round-trip.
    public var extraFields: [(String, JSONValue)]

    public init(
        id: UUID = UUID(),
        cellType: NotebookCellType,
        source: String,
        metadata: JSONValue = .object([]),
        outputs: JSONValue? = nil,
        executionCount: JSONValue? = nil,
        nbformatID: String? = nil,
        extraFields: [(String, JSONValue)] = []
    ) {
        self.id = id
        self.cellType = cellType
        self.source = source
        self.metadata = metadata
        self.outputs = outputs
        self.executionCount = executionCount
        self.nbformatID = nbformatID
        self.extraFields = extraFields
    }

    public static func == (lhs: NotebookCell, rhs: NotebookCell) -> Bool {
        guard lhs.id == rhs.id,
              lhs.cellType == rhs.cellType,
              lhs.source == rhs.source,
              lhs.metadata == rhs.metadata,
              lhs.outputs == rhs.outputs,
              lhs.executionCount == rhs.executionCount,
              lhs.nbformatID == rhs.nbformatID,
              lhs.extraFields.count == rhs.extraFields.count else { return false }
        for (a, b) in zip(lhs.extraFields, rhs.extraFields) where a.0 != b.0 || a.1 != b.1 {
            return false
        }
        return true
    }
}

/// A parsed Jupyter notebook (nbformat v4).
///
/// FOUNDATION SLICE of the notebooks epic: parse → typed ordered cells →
/// cell ops → serialize back, preserving everything we don't model
/// (`kernelspec`, `language_info`, top-level `metadata`, code-cell `outputs`,
/// `execution_count`, unknown keys) for a stable byte round-trip. NO kernel /
/// LSP / execution — that's later slices.
///
/// Pure + host-testable; uses the project-local order-preserving `JSONValue`
/// (Foundation-only, migration-safe). The dirty flag flips on any mutating op.
public struct NotebookDocument: Equatable, Sendable {
    public enum LoadError: Error, Equatable {
        case notJSON
        case notAnObject
        case missingCells
        case cellsNotArray
        case cellNotObject(Int)
        case unsupportedCellType(String)
    }

    public private(set) var cells: [NotebookCell]
    /// nbformat major version (the `nbformat` top-level key). Defaults to 4.
    public let nbformat: Int
    /// nbformat minor version (`nbformat_minor`). Defaults to 5.
    public let nbformatMinor: Int

    /// The original top-level object's member ORDER and any keys other than
    /// `cells` (e.g. `metadata`, `nbformat`, `nbformat_minor`). The `cells`
    /// member is a placeholder we substitute at serialize time; all other
    /// members serialize verbatim from here. This is what makes unknown
    /// top-level fields round-trip.
    private let envelope: [(String, JSONValue)]

    /// Whether the document has unsaved edits since load (or since the last
    /// `markClean()`).
    public private(set) var isDirty: Bool

    // MARK: Equatable

    // Hand-written because `envelope`'s `[(String, JSONValue)]` tuple array is
    // not auto-`Equatable`. Two documents are equal when their cells, version,
    // dirty flag, AND envelope (key order + values) match.
    public static func == (lhs: NotebookDocument, rhs: NotebookDocument) -> Bool {
        guard lhs.cells == rhs.cells,
              lhs.nbformat == rhs.nbformat,
              lhs.nbformatMinor == rhs.nbformatMinor,
              lhs.isDirty == rhs.isDirty,
              lhs.envelope.count == rhs.envelope.count else { return false }
        for (a, b) in zip(lhs.envelope, rhs.envelope) where a.0 != b.0 || a.1 != b.1 {
            return false
        }
        return true
    }

    // MARK: Parsing

    /// Parse nbformat v4 JSON text into a `NotebookDocument`.
    public init(jsonText: String) throws {
        let root: JSONValue
        do {
            root = try JSONValue.parse(jsonText)
        } catch {
            throw LoadError.notJSON
        }
        guard case let .object(members) = root else { throw LoadError.notAnObject }
        guard let cellsValue = members.first(where: { $0.0 == "cells" })?.1 else {
            throw LoadError.missingCells
        }
        guard case let .array(cellValues) = cellsValue else { throw LoadError.cellsNotArray }

        var parsedCells: [NotebookCell] = []
        parsedCells.reserveCapacity(cellValues.count)
        for (offset, cellValue) in cellValues.enumerated() {
            parsedCells.append(try NotebookDocument.parseCell(cellValue, at: offset))
        }

        self.cells = parsedCells
        self.envelope = members
        self.nbformat = NotebookDocument.intMember(members, "nbformat") ?? 4
        self.nbformatMinor = NotebookDocument.intMember(members, "nbformat_minor") ?? 5
        self.isDirty = false
    }

    private static func intMember(_ members: [(String, JSONValue)], _ key: String) -> Int? {
        guard let value = members.first(where: { $0.0 == key })?.1,
              case let .number(raw) = value else { return nil }
        return Int(raw)
    }

    private static func parseCell(_ value: JSONValue, at index: Int) throws -> NotebookCell {
        guard case let .object(members) = value else { throw LoadError.cellNotObject(index) }

        guard let typeValue = members.first(where: { $0.0 == "cell_type" })?.1,
              case let .string(typeRaw) = typeValue,
              let cellType = NotebookCellType(rawValue: typeRaw) else {
            // Unknown cell_type: surface so we don't silently coerce.
            if let typeValue = members.first(where: { $0.0 == "cell_type" })?.1,
               case let .string(typeRaw) = typeValue {
                throw LoadError.unsupportedCellType(typeRaw)
            }
            throw LoadError.cellNotObject(index)
        }

        let source = NotebookDocument.joinSource(members.first(where: { $0.0 == "source" })?.1)
        let metadata = members.first(where: { $0.0 == "metadata" })?.1 ?? .object([])
        let outputs = members.first(where: { $0.0 == "outputs" })?.1
        let executionCount = members.first(where: { $0.0 == "execution_count" })?.1
        let nbformatID: String? = {
            if case let .string(id)? = members.first(where: { $0.0 == "id" })?.1 { return id }
            return nil
        }()

        // Capture any keys we don't explicitly model, preserving order.
        let known: Set<String> = ["cell_type", "source", "metadata", "outputs", "execution_count", "id"]
        let extras = members.filter { !known.contains($0.0) }

        return NotebookCell(
            cellType: cellType,
            source: source,
            metadata: metadata,
            outputs: cellType == .code ? (outputs ?? .array([])) : outputs,
            executionCount: cellType == .code ? (executionCount ?? .null) : executionCount,
            nbformatID: nbformatID,
            extraFields: extras
        )
    }

    /// nbformat stores `source` as either a string or an array of line strings
    /// (each line typically keeping its trailing `\n`). Join to one string.
    private static func joinSource(_ value: JSONValue?) -> String {
        switch value {
        case let .string(text): return text
        case let .array(lines):
            return lines.compactMap { $0.stringValue }.joined()
        default: return ""
        }
    }

    // MARK: Serialization

    /// Serialize back to nbformat v4 JSON text. Top-level member order is
    /// preserved from the original; the `cells` array is rebuilt from the
    /// current (possibly edited) cell list. Unknown top-level keys
    /// (`metadata`/`kernelspec`/etc.) and per-cell opaque fields round-trip.
    /// A trailing newline is appended (Jupyter's writer convention).
    public func serialized() -> String {
        var members = envelope
        let cellsValue = JSONValue.array(cells.map { NotebookDocument.cellJSON($0) })
        if let cellsIndex = members.firstIndex(where: { $0.0 == "cells" }) {
            members[cellsIndex].1 = cellsValue
        } else {
            members.insert(("cells", cellsValue), at: 0)
        }
        return JSONValue.object(members).serialized() + "\n"
    }

    /// Rebuild a cell's JSON object in nbformat-canonical member order, splitting
    /// `source` back to the line-array form Jupyter uses.
    private static func cellJSON(_ cell: NotebookCell) -> JSONValue {
        var members: [(String, JSONValue)] = []
        members.append(("cell_type", .string(cell.cellType.rawValue)))
        if let id = cell.nbformatID { members.append(("id", .string(id))) }
        members.append(("metadata", cell.metadata))
        if cell.cellType == .code {
            members.append(("execution_count", cell.executionCount ?? .null))
        }
        members.append(("source", splitSource(cell.source)))
        // Re-append any unmodeled extras (e.g. attachments) in original order,
        // skipping ones we now own.
        let owned: Set<String> = ["cell_type", "id", "metadata", "execution_count", "source", "outputs"]
        for (key, value) in cell.extraFields where !owned.contains(key) {
            members.append((key, value))
        }
        if cell.cellType == .code {
            members.append(("outputs", cell.outputs ?? .array([])))
        }
        return .object(members)
    }

    /// Split a cell source string into nbformat's line-array form: each line
    /// keeps its trailing `\n` except the last (matching Jupyter's writer).
    /// An empty source becomes an empty array.
    static func splitSource(_ source: String) -> JSONValue {
        if source.isEmpty { return .array([]) }
        var lines: [JSONValue] = []
        var current = ""
        for ch in source {
            current.append(ch)
            if ch == "\n" {
                lines.append(.string(current))
                current = ""
            }
        }
        if !current.isEmpty { lines.append(.string(current)) }
        return .array(lines)
    }

    // MARK: Cell operations

    /// Insert a new cell at `index` (clamped to `[0, count]`).
    @discardableResult
    public mutating func insertCell(_ cell: NotebookCell, at index: Int) -> NotebookCell {
        let clamped = max(0, min(index, cells.count))
        cells.insert(cell, at: clamped)
        isDirty = true
        return cell
    }

    /// Append a new empty cell of the given type and return it.
    @discardableResult
    public mutating func appendCell(type: NotebookCellType, source: String = "") -> NotebookCell {
        let cell = NotebookCell(
            cellType: type,
            source: source,
            outputs: type == .code ? .array([]) : nil,
            executionCount: type == .code ? .null : nil
        )
        return insertCell(cell, at: cells.count)
    }

    /// Delete the cell with the given id. Returns true if a cell was removed.
    @discardableResult
    public mutating func deleteCell(id: UUID) -> Bool {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return false }
        cells.remove(at: index)
        isDirty = true
        return true
    }

    /// Move the cell with `id` to `destinationIndex` (clamped). Returns true on
    /// success.
    @discardableResult
    public mutating func moveCell(id: UUID, to destinationIndex: Int) -> Bool {
        guard let from = cells.firstIndex(where: { $0.id == id }) else { return false }
        let cell = cells.remove(at: from)
        let clamped = max(0, min(destinationIndex, cells.count))
        cells.insert(cell, at: clamped)
        isDirty = true
        return true
    }

    /// Replace the source text of the cell with `id`. Returns true on success.
    @discardableResult
    public mutating func editSource(id: UUID, to newSource: String) -> Bool {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return false }
        guard cells[index].source != newSource else { return false }
        cells[index].source = newSource
        isDirty = true
        return true
    }

    /// Change the `cell_type` of the cell with `id`. Switching TO code adds the
    /// empty `outputs`/`execution_count` the format requires; switching AWAY
    /// from code drops them. Returns true on success (false if id unknown or the
    /// type is unchanged).
    @discardableResult
    public mutating func changeCellType(id: UUID, to newType: NotebookCellType) -> Bool {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return false }
        guard cells[index].cellType != newType else { return false }
        cells[index].cellType = newType
        if newType == .code {
            if cells[index].outputs == nil { cells[index].outputs = .array([]) }
            if cells[index].executionCount == nil { cells[index].executionCount = .null }
        } else {
            cells[index].outputs = nil
            cells[index].executionCount = nil
        }
        isDirty = true
        return true
    }

    // MARK: Dirty tracking

    /// Reset the dirty flag (call after a successful save).
    public mutating func markClean() { isDirty = false }
}
