import XCTest
@testable import ViewerUI

/// Pure-logic coverage for `MetadataPanel` row builders. Batch B
/// (commit 2457015) shipped these untested; image/AV/PDF loaders rely
/// on system frameworks we don't unit-test, but the filesystem and
/// duration formatters are deterministic and easy to lock in.
@MainActor
final class MetadataPanelTests: XCTestCase {

    // MARK: - filesystemRows

    func test_filesystemRows_includes_name_and_path_always() {
        let url = URL(fileURLWithPath: "/tmp/example.png")
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [:])
        XCTAssertEqual(rows.first(where: { $0.label == "Name" })?.value, "example.png")
        XCTAssertEqual(rows.first(where: { $0.label == "Path" })?.value, "/tmp/example.png")
    }

    func test_filesystemRows_formats_size_with_ByteCountFormatter() {
        let url = URL(fileURLWithPath: "/tmp/x.bin")
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [.size: 1024 * 1024])
        let size = rows.first(where: { $0.label == "Size" })?.value
        XCTAssertNotNil(size)
        // ByteCountFormatter uses locale-aware unit; assert MB-ish.
        XCTAssertTrue(size!.contains("MB"), "expected MB-ish size, got '\(size!)'")
    }

    func test_filesystemRows_omits_size_when_absent() {
        let url = URL(fileURLWithPath: "/tmp/x.bin")
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [:])
        XCTAssertNil(rows.first(where: { $0.label == "Size" }))
    }

    func test_filesystemRows_includes_modified_date_when_present() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        let rows = MetadataPanel.filesystemRows(url: url,
                                                 attrs: [.modificationDate: when])
        let row = rows.first(where: { $0.label == "Modified" })
        XCTAssertNotNil(row)
        // The exact string is locale-dependent; assert non-empty
        // and that the formatter produced something with a digit.
        XCTAssertFalse(row!.value.isEmpty)
        XCTAssertTrue(row!.value.contains(where: \.isNumber))
    }

    func test_filesystemRows_includes_created_date_when_present() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        let rows = MetadataPanel.filesystemRows(url: url,
                                                 attrs: [.creationDate: when])
        XCTAssertNotNil(rows.first(where: { $0.label == "Created" }))
    }

    func test_filesystemRows_emits_UTI_for_known_extension() {
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [:])
        let uti = rows.first(where: { $0.label == "UTI" })?.value
        XCTAssertNotNil(uti, "expected a UTI for .png")
        XCTAssertTrue(uti!.contains("png") || uti!.contains("image"),
                      "UTI \(uti ?? "nil") should reference png/image")
    }

    func test_filesystemRows_emits_dyn_UTI_for_unknown_extension() {
        // macOS coins a synthetic `dyn.…` UTI for anything not in its
        // type database, so the row always appears; just sanity-check
        // the shape (prefix) so the assertion is portable.
        let url = URL(fileURLWithPath: "/tmp/file.qqqq")
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [:])
        let uti = rows.first(where: { $0.label == "UTI" })?.value
        XCTAssertNotNil(uti)
        XCTAssertTrue(uti!.hasPrefix("dyn."),
                      "unknown extensions get a synthetic dyn UTI, got '\(uti!)'")
    }

    func test_filesystemRows_omits_UTI_for_empty_extension() {
        // URLs without a path extension shouldn't have a UTI row.
        let url = URL(fileURLWithPath: "/tmp/file_no_extension")
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [:])
        XCTAssertNil(rows.first(where: { $0.label == "UTI" }))
    }

    func test_filesystemRows_emits_name_then_path_then_size_order() {
        // Order matters for the UI: name first, path next, then meta.
        let url = URL(fileURLWithPath: "/tmp/x.png")
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [.size: 2048])
        let labels = rows.map(\.label)
        let nameIdx = labels.firstIndex(of: "Name")
        let pathIdx = labels.firstIndex(of: "Path")
        let sizeIdx = labels.firstIndex(of: "Size")
        XCTAssertNotNil(nameIdx)
        XCTAssertNotNil(pathIdx)
        XCTAssertNotNil(sizeIdx)
        XCTAssertLessThan(nameIdx!, pathIdx!)
        XCTAssertLessThan(pathIdx!, sizeIdx!)
    }

    // MARK: - Row Identifiable contract

    func test_Row_id_is_the_label() {
        let r = MetadataPanel.Row("Width", "1920")
        XCTAssertEqual(r.id, "Width")
    }
}
