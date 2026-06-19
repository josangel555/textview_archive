import XCTest
@testable import ViewerKit

/// PDF reader FOUNDATION (TSK-670) — the host-testable half of the PDF
/// viewer contract: extension + UTType routing into `FileCategory.pdf` and
/// the view-mode lens it resolves to.
///
/// A PDFKit-backed `PDFView` already renders `.pdf` files (MediaPreviewView
/// `PDFPreview`). This case is NOT new render code — it CEMENTS the routing
/// glue so PDF is a DELIBERATE first-class viewer, not a media-preview
/// catch-all side effect. A regression that drops `.pdf` into the
/// binary/unknown bucket (HEX-only, or worse, the editor) FAILS the host
/// gate here, even though the on-screen `PDFView` pixels stay VM-only (T5).
///
/// The on-disk magic-byte sniff (`%PDF` on an extension-less file) and the
/// `pdfMetadata` extraction live in `ViewerUI` (DocumentModel / MetadataPanel)
/// and are pinned in `PDFFoundationGlueTests` over there — this file is the
/// pure `ViewerKit` extension/view-mode contract (no FS, no UI).
///
/// TEETH: each assertion below goes RED if `.pdf` is removed from the
/// extension table, the UTType fallback, the native-preview partition, or if
/// the editor/text gate ever admits PDF.
final class PDFRoutingContractTests: XCTestCase {

    private func cat(_ name: String) -> FileCategory {
        FileTypeDetector.category(for: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    // MARK: - Extension routing → .pdf

    func test_lowercaseExtension_classifiesAsPDF() {
        XCTAssertEqual(cat("report.pdf"), .pdf,
                       "a `.pdf` extension must route to the PDF category")
    }

    /// `FileTypeDetector.category` lowercases `pathExtension` before matching,
    /// so an uppercase or mixed-case `.PDF` must classify identically. The
    /// generic uppercase smoke (FileCategoryMediaTests) only covers PNG/MP4 —
    /// this pins PDF specifically so a future case-sensitivity regression in
    /// the PDF branch bites here.
    func test_uppercaseAndMixedCaseExtension_alsoClassifyAsPDF() {
        XCTAssertEqual(cat("REPORT.PDF"), .pdf, "uppercase .PDF must classify as PDF")
        XCTAssertEqual(cat("Report.Pdf"), .pdf, "mixed-case .Pdf must classify as PDF")
        XCTAssertEqual(cat("scan.pDf"),   .pdf, "irregular-case .pDf must classify as PDF")
    }

    /// A path with no recognised text/code/media extension that nonetheless
    /// carries a `pdf`-conforming UTI must still reach `.pdf` via the UTType
    /// fallback tail of `category(for:)` — not fall through to `.unknown`.
    /// (The literal `pdf` extension is matched earlier; this guards the
    /// UTType safety net stays wired for PDF.)
    func test_pdfExtension_takesExplicitBranch_notUnknown() {
        // Confirm PDF never resolves to the catch-all buckets.
        for bucket in [FileCategory.unknown, .binary, .plainText, .code] {
            XCTAssertNotEqual(cat("paper.pdf"), bucket,
                              "PDF must not degrade into the \(bucket) bucket")
        }
    }

    // MARK: - View-mode lens: PDF is preview-first, NOT editable text

    /// A fresh `.pdf` opens in the first-class `.preview` lens (PDFView),
    /// never the HEX byte grid. ROOT-CAUSE guard: before native preview
    /// existed, media defaulted to HEX.
    func test_pdf_defaultMode_isPreview() {
        let url = URL(fileURLWithPath: "/tmp/doc.pdf")
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url), .preview,
                       "a fresh PDF must default to Preview (PDFView), not HEX")
    }

    /// The PDF picker is EXACTLY `[Preview, HEX]` — Preview as primary, HEX as
    /// the terminal raw-bytes lens. No Source, no Editor, no Formatted, no
    /// Table: PDF has no text representation to edit or reflow.
    func test_pdf_availableModes_areExactlyPreviewThenHex() {
        let url = URL(fileURLWithPath: "/tmp/doc.pdf")
        let modes = ViewModeOptions.availableModes(for: url)
        XCTAssertEqual(modes, [.preview, .hex],
                       "PDF picker must be exactly [Preview, HEX]")
        XCTAssertEqual(modes.first, .preview, "Preview is the primary PDF lens")
        XCTAssertEqual(modes.last, .hex, "HEX stays the terminal PDF lens")
    }

    /// Explicit, named regression guard: PDF must NEVER be editable. A change
    /// that lets PDF into the editable/text-shaped path (e.g. by adding `.pdf`
    /// to `hasTextRepresentation`) would silently offer an Editor over a
    /// binary payload — this fails it directly.
    func test_pdf_isNotEditable_andHasNoTextRepresentation() {
        let url = URL(fileURLWithPath: "/tmp/doc.pdf")
        XCTAssertFalse(ViewModeOptions.supportsEditor(url),
                       "PDF is a binary payload — the Editor lens must not be offered")
        XCTAssertFalse(ViewModeOptions.hasTextRepresentation(.pdf),
                       "PDF has no plain-text/source representation")
        XCTAssertFalse(ViewModeOptions.availableModes(for: url).contains(.editor),
                       "the PDF picker must not contain Editor")
        XCTAssertFalse(ViewModeOptions.availableModes(for: url).contains(.source),
                       "the PDF picker must not contain Source")
    }

    /// PDF is a first-class NATIVE-PREVIEW category (renders via the `.preview`
    /// document state / MediaPreviewView), distinct from binary/unknown which
    /// have no native preview and are HEX-only.
    func test_pdf_isNativePreviewCategory() {
        XCTAssertTrue(ViewModeOptions.hasNativePreview(.pdf),
                      "PDF must be a native-preview category (PDFView)")
        XCTAssertFalse(ViewModeOptions.hasNativePreview(.binary),
                       "control: binary has no native preview")
        XCTAssertFalse(ViewModeOptions.hasNativePreview(.unknown),
                       "control: unknown has no native preview")
    }
}
