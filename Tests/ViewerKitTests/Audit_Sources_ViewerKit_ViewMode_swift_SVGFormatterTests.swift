import XCTest
@testable import ViewerKit

/// Audit S3 regression — `.svg` had three contradictory identities across the
/// ViewerKit type model: `FileTypeDetector.category` classifies it `.image`,
/// `HighlightLanguage.detect` maps it to `.xml`, and `ViewModeOptions`
/// additionally listed "svg" in `formatterExtensions`. Because
/// `availableModes` returns early on the `!hasTextRepresentation` path for any
/// `.image`, the `formatterExtensions` entry could NEVER be reached on the
/// normal (no-override) path — dead config plus a contract inconsistency.
///
/// The fix commits SVG to image/preview by dropping "svg" from
/// `formatterExtensions`. These assertions pin that contract:
///   - a plain `.svg` resolves to exactly `[.preview, .hex]` and never offers
///     `.formatted`, documenting the committed image/preview identity;
///   - the explicit "Open As… text" override path is UNAFFECTED — it surfaces
///     the structured modes (Formatted/Table) via `isTextOverride`, not via the
///     extension set, so a forced-text SVG still gets `.formatted`.
///
/// Pure functions over a URL — host-safe (T1), no FS, no UI.
final class Audit_Sources_ViewerKit_ViewMode_swift_SVGFormatterTests: XCTestCase {

    private let svg = URL(fileURLWithPath: "/tmp/icon.svg")

    func test_svg_normalPath_isPreviewAndHexOnly_neverFormatted() {
        // SVG is classified `.image`; the picker is exactly [Preview, HEX].
        let modes = ViewModeOptions.availableModes(for: svg)
        XCTAssertEqual(modes, [.preview, .hex],
                       "a plain .svg must resolve to [Preview, HEX]")
        XCTAssertFalse(modes.contains(.formatted),
                       ".svg commits to image/preview — no Formatted lens")
        XCTAssertEqual(ViewModeOptions.defaultMode(for: svg), .preview,
                       ".svg defaults to the native Preview lens")
    }

    func test_svg_textOverride_stillSurfacesStructuredModes() {
        // Open As… text: the override surfaces Formatted/Table via
        // `isTextOverride`, independent of the extension set. Dropping "svg"
        // from `formatterExtensions` must NOT regress this path.
        let modes = ViewModeOptions.availableModes(for: svg, forcedCategory: .code)
        XCTAssertTrue(modes.contains(.formatted),
                      "forced-text SVG still offers Formatted via the override path")
        XCTAssertTrue(modes.contains(.source),
                      "forced-text SVG offers a Source lens")
        XCTAssertFalse(modes.contains(.preview),
                       "forced-text SVG is inspected as text, not Preview")
    }
}
