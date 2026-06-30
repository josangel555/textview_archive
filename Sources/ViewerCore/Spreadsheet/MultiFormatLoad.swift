import Foundation

/// File-load wrappers for the OOXML/ODF readers — the ZIP-container → content
/// part → parse step, mirroring ``XLSXDocument/load(_:)``. Both reuse
/// ``ArchiveCatalog``'s hardened `unzip -p` extraction (zero new deps); the
/// viewer routing that displays the result is the render tail.
public enum MultiFormatLoadError: Error, Equatable {
    /// The expected content part (`content.xml` / `word/document.xml`) was
    /// absent or unreadable in the container.
    case missingContentPart
}

public extension ODSContentParser {
    /// Load + parse the first table of a `.ods` file → row-major grid.
    static func load(_ url: URL) throws -> [[String]] {
        guard let data = try? ArchiveCatalog.zipEntryBytes(named: "content.xml", fromZipAt: url),
              let xml = String(data: data, encoding: .utf8) else {
            throw MultiFormatLoadError.missingContentPart
        }
        return parseFirstTableGrid(contentXML: xml)
    }
}

public extension DocxTextExtractor {
    /// Load + extract the body paragraphs of a `.docx` file.
    static func load(_ url: URL) throws -> [String] {
        guard let data = try? ArchiveCatalog.zipEntryBytes(named: "word/document.xml", fromZipAt: url),
              let xml = String(data: data, encoding: .utf8) else {
            throw MultiFormatLoadError.missingContentPart
        }
        return paragraphs(documentXML: xml)
    }

    /// Load + extract a `.docx` as structured Markdown (TSK-1338): headings,
    /// bullet/numbered lists, and bold/italic preserved (vs. `load`'s flat text).
    static func loadMarkdown(_ url: URL) throws -> String {
        guard let data = try? ArchiveCatalog.zipEntryBytes(named: "word/document.xml", fromZipAt: url),
              let xml = String(data: data, encoding: .utf8) else {
            throw MultiFormatLoadError.missingContentPart
        }
        return markdown(documentXML: xml)
    }
}
