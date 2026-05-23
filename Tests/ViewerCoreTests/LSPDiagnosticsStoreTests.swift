import XCTest
@testable import ViewerCore

/// Pure-logic coverage of `LSPDiagnosticsStore`. Verifies the four
/// operations the rest of the app cares about: append (via replace),
/// replace-by-URL (one URL's diags wipe + reinsert atomically),
/// clear-on-close, and severity filtering.
@MainActor
final class LSPDiagnosticsStoreTests: XCTestCase {

    private let url1 = URL(fileURLWithPath: "/tmp/a.swift")
    private let url2 = URL(fileURLWithPath: "/tmp/b.swift")

    private func diag(line: Int, severity: LSPDiagnostic.Severity = .error,
                      message: String = "msg") -> LSPDiagnostic {
        LSPDiagnostic(
            range: .init(start: .init(line: line, character: 0),
                         end: .init(line: line, character: 4)),
            severity: severity, code: nil, source: nil, message: message)
    }

    func test_replace_storesPerURL() {
        let store = LSPDiagnosticsStore()
        store.replace(url: url1, with: [diag(line: 0), diag(line: 1)])
        store.replace(url: url2, with: [diag(line: 0)])
        XCTAssertEqual(store.byURL.count, 2)
        XCTAssertEqual(store.byURL[url1]?.count, 2)
        XCTAssertEqual(store.byURL[url2]?.count, 1)
    }

    func test_replace_withEmpty_removesEntry() {
        // Servers re-publish an empty array to clear a file's diags;
        // we honor that by removing the URL key so `byURL.count`
        // doubles as "files-with-problems".
        let store = LSPDiagnosticsStore()
        store.replace(url: url1, with: [diag(line: 0)])
        store.replace(url: url1, with: [])
        XCTAssertNil(store.byURL[url1])
        XCTAssertEqual(store.totalCount, 0)
    }

    func test_replace_isAtomic_perURL() {
        // The second publish for the same URL must wipe the prior set,
        // not append. LSP publish semantics are "current state".
        let store = LSPDiagnosticsStore()
        store.replace(url: url1, with: [diag(line: 0), diag(line: 1)])
        store.replace(url: url1, with: [diag(line: 5)])
        XCTAssertEqual(store.byURL[url1]?.count, 1)
        XCTAssertEqual(store.byURL[url1]?.first?.range.start.line, 5)
    }

    func test_clear_url_removesOnlyThatURL() {
        let store = LSPDiagnosticsStore()
        store.replace(url: url1, with: [diag(line: 0)])
        store.replace(url: url2, with: [diag(line: 0)])
        store.clear(url: url1)
        XCTAssertNil(store.byURL[url1])
        XCTAssertNotNil(store.byURL[url2])
    }

    func test_clearAll_wipesStore() {
        let store = LSPDiagnosticsStore()
        store.replace(url: url1, with: [diag(line: 0)])
        store.replace(url: url2, with: [diag(line: 0)])
        store.clearAll()
        XCTAssertTrue(store.byURL.isEmpty)
    }

    func test_filtered_bySeverity() {
        let store = LSPDiagnosticsStore()
        store.replace(url: url1, with: [
            diag(line: 0, severity: .error),
            diag(line: 1, severity: .warning),
            diag(line: 2, severity: .information),
        ])
        XCTAssertEqual(store.errorsOnly.count, 1)
        XCTAssertEqual(store.filtered(by: .warning).count, 1)
        XCTAssertEqual(store.filtered(by: .information).count, 1)
        XCTAssertEqual(store.errorCount, 1)
        XCTAssertEqual(store.warningCount, 1)
        XCTAssertEqual(store.totalCount, 3)
    }

    func test_allFlat_sortsByPathThenLine() {
        let store = LSPDiagnosticsStore()
        store.replace(url: url2, with: [diag(line: 5), diag(line: 1)])
        store.replace(url: url1, with: [diag(line: 10), diag(line: 0)])
        let flat = store.allFlat
        XCTAssertEqual(flat.count, 4)
        // url1 sorts before url2 (`/tmp/a` < `/tmp/b`); within each
        // URL, by line.
        XCTAssertEqual(flat[0].url, url1)
        XCTAssertEqual(flat[0].diagnostic.range.start.line, 0)
        XCTAssertEqual(flat[1].url, url1)
        XCTAssertEqual(flat[1].diagnostic.range.start.line, 10)
        XCTAssertEqual(flat[2].url, url2)
        XCTAssertEqual(flat[2].diagnostic.range.start.line, 1)
        XCTAssertEqual(flat[3].url, url2)
        XCTAssertEqual(flat[3].diagnostic.range.start.line, 5)
    }
}
