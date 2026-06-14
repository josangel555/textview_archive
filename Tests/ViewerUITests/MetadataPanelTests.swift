import XCTest
import ImageIO
import CoreGraphics
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

    // MARK: - Deep filesystem metadata (TSK-348)

    private func value(_ rows: [MetadataPanel.Row], _ label: String) -> String? {
        rows.first(where: { $0.label == label })?.value
    }

    func test_posixModeString_octalAndSymbolic() {
        XCTAssertEqual(MetadataPanel.posixModeString(0o644), "644 rw-r--r--")
        XCTAssertEqual(MetadataPanel.posixModeString(0o755), "755 rwxr-xr-x")
        XCTAssertEqual(MetadataPanel.posixModeString(0o600), "600 rw-------")
        XCTAssertEqual(MetadataPanel.posixModeString(0o777), "777 rwxrwxrwx")
        XCTAssertEqual(MetadataPanel.posixModeString(0o000), "0 ---------")
    }

    func test_posixModeString_masksHighBits() {
        // setuid/type bits above 0o777 must not leak into the perm string.
        XCTAssertEqual(MetadataPanel.posixModeString(0o104644), "644 rw-r--r--")
    }

    func test_filesystemRows_surfacesDeepFSMetadata() {
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [
            .posixPermissions: 0o640,
            .ownerAccountName: "jos",
            .groupOwnerAccountName: "staff",
            .referenceCount: 2,
            .systemFileNumber: 123456,
        ])
        XCTAssertEqual(value(rows, "Permissions"), "640 rw-r-----")
        XCTAssertEqual(value(rows, "Owner"), "jos")
        XCTAssertEqual(value(rows, "Group"), "staff")
        XCTAssertEqual(value(rows, "Hard links"), "2")
        XCTAssertEqual(value(rows, "Inode"), "123456")
    }

    func test_filesystemRows_omitsDeepFSMetadata_whenAbsentOrEmpty() {
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        // Sparse dict + empty owner/group + single link → none of the deep
        // rows should appear (no blank "Owner:" / no "Hard links: 1" noise).
        let rows = MetadataPanel.filesystemRows(url: url, attrs: [
            .ownerAccountName: "",
            .groupOwnerAccountName: "",
            .referenceCount: 1,
        ])
        XCTAssertNil(value(rows, "Permissions"))
        XCTAssertNil(value(rows, "Owner"))
        XCTAssertNil(value(rows, "Group"))
        XCTAssertNil(value(rows, "Hard links"))
        XCTAssertNil(value(rows, "Inode"))
    }

    // MARK: - Image EXIF/TIFF/GPS metadata (TSK-348)

    func test_imageRows_coreAttributes() {
        let props: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 1920,
            kCGImagePropertyPixelHeight: 1080,
            kCGImagePropertyColorModel: "RGB",
            kCGImagePropertyDepth: 8,
        ]
        let rows = MetadataPanel.imageRows(props: props)
        XCTAssertEqual(value(rows, "Dimensions"), "1920 × 1080")
        XCTAssertEqual(value(rows, "Color model"), "RGB")
        XCTAssertEqual(value(rows, "Bit depth"), "8")
    }

    func test_imageRows_exifTiffGps() {
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2024:05:01 12:00:00",
            kCGImagePropertyExifLensModel: "50mm f/1.8",
            kCGImagePropertyExifFocalLength: 50.0,
            kCGImagePropertyExifISOSpeedRatings: [200],
            kCGImagePropertyExifExposureTime: 1.0 / 250.0,
            kCGImagePropertyExifFNumber: 2.8,
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "Canon",
            kCGImagePropertyTIFFModel: "EOS R5",
            kCGImagePropertyTIFFSoftware: "Lightroom",
        ]
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 37.7749,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.4194,
            kCGImagePropertyGPSLongitudeRef: "W",
        ]
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyGPSDictionary: gps,
        ]
        let rows = MetadataPanel.imageRows(props: props)
        XCTAssertEqual(value(rows, "Date taken"), "2024:05:01 12:00:00")
        XCTAssertEqual(value(rows, "Lens"), "50mm f/1.8")
        XCTAssertEqual(value(rows, "Focal length"), "50 mm")
        XCTAssertEqual(value(rows, "ISO"), "200")
        XCTAssertEqual(value(rows, "Exposure"), "1/250 s")
        XCTAssertEqual(value(rows, "Aperture"), "f/2.8")
        XCTAssertEqual(value(rows, "Camera"), "Canon EOS R5")
        XCTAssertEqual(value(rows, "Software"), "Lightroom")
        XCTAssertEqual(value(rows, "GPS"), "37.774900 N, 122.419400 W")
    }

    func test_imageRows_exposureZero_omittedNotDivByZero() {
        let exif: [CFString: Any] = [kCGImagePropertyExifExposureTime: 0.0]
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]
        XCTAssertNil(value(MetadataPanel.imageRows(props: props), "Exposure"),
            "a 0 exposure must be skipped, never rendered as '1/inf s'")
    }

    func test_imageRows_emptyProps_yieldsNoRows() {
        XCTAssertTrue(MetadataPanel.imageRows(props: [:]).isEmpty)
    }

    func test_gpsCoordinate_nilWhenLongitudeMissing() {
        XCTAssertNil(MetadataPanel.gpsCoordinate([kCGImagePropertyGPSLatitude: 1.0]))
    }

    // MARK: - PDF metadata (TSK-348)

    func test_pdfRows_fullInfo_orderedAndLabeled() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        var info = MetadataPanel.PDFInfo()
        info.pageCount = 12
        info.title = "Spec"; info.author = "Jos"; info.subject = "Design"
        info.creator = "TextView"; info.producer = "PDFKit"; info.keywords = "a, b"
        info.created = created; info.pageSize = "612 × 792 pt"; info.isEncrypted = true
        let rows = MetadataPanel.pdfRows(info)
        XCTAssertEqual(value(rows, "Pages"), "12")
        XCTAssertEqual(value(rows, "Title"), "Spec")
        XCTAssertEqual(value(rows, "Author"), "Jos")
        XCTAssertEqual(value(rows, "Subject"), "Design")
        XCTAssertEqual(value(rows, "Keywords"), "a, b")
        XCTAssertEqual(value(rows, "Page Size"), "612 × 792 pt")
        XCTAssertEqual(value(rows, "Creator"), "TextView")
        XCTAssertEqual(value(rows, "Producer"), "PDFKit")
        XCTAssertEqual(value(rows, "Encrypted"), "Yes")
        XCTAssertNotNil(value(rows, "Created"))
        // Pages is always the first row.
        XCTAssertEqual(rows.first?.label, "Pages")
    }

    func test_pdfRows_minimal_onlyPages() {
        var info = MetadataPanel.PDFInfo()
        info.pageCount = 3
        let rows = MetadataPanel.pdfRows(info)
        XCTAssertEqual(rows.map(\.label), ["Pages"], "absent fields are omitted")
    }

    func test_pdfRows_notEncrypted_omitsEncryptedRow() {
        var info = MetadataPanel.PDFInfo()
        info.pageCount = 1
        info.isEncrypted = false
        XCTAssertNil(value(MetadataPanel.pdfRows(info), "Encrypted"))
    }

    /// End-to-end extraction: generate a real PDF (CoreGraphics PDF context with
    /// Title/Author + a 200×300 page) and assert pdfMetadata reads it back.
    func test_pdfMetadata_extractsFromRealPDF() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfmeta-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let docInfo: [CFString: Any] = [
            kCGPDFContextTitle: "MyDoc", kCGPDFContextAuthor: "Tester",
        ]
        let ctx = try XCTUnwrap(CGContext(tmp as CFURL, mediaBox: &box, docInfo as CFDictionary))
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()

        let rows = MetadataPanel.pdfMetadata(url: tmp)
        XCTAssertEqual(value(rows, "Pages"), "1")
        XCTAssertEqual(value(rows, "Page Size"), "200 × 300 pt")
        XCTAssertEqual(value(rows, "Title"), "MyDoc")
        XCTAssertEqual(value(rows, "Author"), "Tester")
    }
}
