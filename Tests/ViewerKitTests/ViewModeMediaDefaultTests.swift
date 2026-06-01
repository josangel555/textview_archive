import XCTest
@testable import ViewerKit

/// Bug B — a freshly-opened native-preview file (image/audio/video/pdf/sqlite)
/// must default to the first-class `.preview` ViewMode, NOT HEX.
///
/// ROOT CAUSE this guards: before the fix, no `.preview` ViewMode existed.
/// `ViewModeOptions.{defaultMode,availableModes}` returned `.hex` / `[.hex]`
/// for every native-preview category, so the picker selected HEX and the
/// persisted workspace snapshot carried `.hex` — the byte grid was one explicit
/// click away from tearing down the native viewer. The content was correct
/// (`.preview` document state), but the VIEW MODE was wrong, and three prior
/// contract tests *codified* HEX-as-default.
///
/// TEETH: pre-fix `defaultMode(png) == .hex` and `availableModes(png) == [.hex]`,
/// so every assertion here for `.preview` FAILS before the fix and PASSES after.
/// Pure functions over a URL — host-safe (T1), no FS, no UI.
final class ViewModeMediaDefaultTests: XCTestCase {

    // Every native-preview category, by representative URL extension.
    private let previewURLs: [(URL, FileCategory)] = [
        (URL(fileURLWithPath: "/tmp/pic.png"),  .image),
        (URL(fileURLWithPath: "/tmp/song.mp3"), .audio),
        (URL(fileURLWithPath: "/tmp/clip.mp4"), .video),
        (URL(fileURLWithPath: "/tmp/doc.pdf"),  .pdf),
        (URL(fileURLWithPath: "/tmp/db.sqlite"), .sqlite),
    ]

    func test_image_defaultMode_isPreview_notHex() {
        let png = URL(fileURLWithPath: "/tmp/pic.png")
        XCTAssertEqual(ViewModeOptions.defaultMode(for: png), .preview,
                       "a fresh image must default to Preview, not HEX")
        let modes = ViewModeOptions.availableModes(for: png)
        XCTAssertEqual(modes.first, .preview, "Preview is the primary mode")
        XCTAssertTrue(modes.contains(.hex), "HEX still offered as raw-bytes lens")
        XCTAssertEqual(modes.last, .hex, "HEX stays the terminal entry")
        XCTAssertEqual(modes, [.preview, .hex],
                       "image picker is exactly [Preview, HEX]")
    }

    func test_allNativePreviewCategories_defaultToPreview() {
        for (url, cat) in previewURLs {
            XCTAssertEqual(ViewModeOptions.defaultMode(for: url), .preview,
                           "\(cat) (\(url.lastPathComponent)) must default to Preview")
            XCTAssertEqual(ViewModeOptions.availableModes(for: url), [.preview, .hex],
                           "\(cat) picker must be exactly [Preview, HEX]")
        }
    }

    func test_binaryAndUnknown_stayHexOnly_noPreview() {
        // Files with no native preview keep HEX-only — they would hit
        // UnsupportedPreview, so `.preview` must NOT be offered.
        for url in [URL(fileURLWithPath: "/tmp/x.bak"),
                    URL(fileURLWithPath: "/tmp/blob.xyzzy")] {
            let modes = ViewModeOptions.availableModes(for: url)
            XCTAssertEqual(modes, [.hex], "\(url.lastPathComponent) must be HEX-only")
            XCTAssertFalse(modes.contains(.preview),
                           "\(url.lastPathComponent) has no native preview")
            XCTAssertEqual(ViewModeOptions.defaultMode(for: url), .hex)
        }
    }

    func test_textFiles_neverOfferPreview() {
        // Preview is exclusively for native-media categories.
        for url in [URL(fileURLWithPath: "/tmp/notes.txt"),
                    URL(fileURLWithPath: "/tmp/main.swift"),
                    URL(fileURLWithPath: "/tmp/README.md"),
                    URL(fileURLWithPath: "/tmp/data.csv"),
                    URL(fileURLWithPath: "/tmp/page.html")] {
            XCTAssertFalse(ViewModeOptions.availableModes(for: url).contains(.preview),
                           "text file \(url.lastPathComponent) must not offer Preview")
            XCTAssertNotEqual(ViewModeOptions.defaultMode(for: url), .preview)
        }
    }

    func test_hasNativePreview_partition() {
        let nativePreview: Set<FileCategory> = [.image, .audio, .video, .pdf, .sqlite]
        for cat in FileCategory.allCases {
            XCTAssertEqual(ViewModeOptions.hasNativePreview(cat),
                           nativePreview.contains(cat),
                           "\(cat) native-preview classification")
        }
    }
}
