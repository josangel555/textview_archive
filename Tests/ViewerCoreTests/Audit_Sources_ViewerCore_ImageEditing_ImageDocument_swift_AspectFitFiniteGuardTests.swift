import CoreGraphics
import XCTest
@testable import ViewerCore

/// Regression coverage for the audit finding at
/// `Sources/ViewerCore/ImageEditing/ImageDocument.swift:96`:
/// `EditOp.aspectFit` trapped (SIGTRAP, LLVM fptosi overflow) when handed a
/// NaN/Inf CGFloat — the `> 0` guard is silently false for NaN, so a degenerate
/// box fell into the else branch and crashed on the very `Int()` advertised as
/// the graceful fallback; an Inf box that *passed* `> 0` produced an Inf
/// `scale` and trapped on the happy path.
///
/// These cases would crash the whole test process (not fail) on the
/// pre-fix code, so their mere completion is the assertion; the equality checks
/// pin the (1,1) sentinel / finite-dimension contract.
final class Audit_Sources_ViewerCore_ImageEditing_ImageDocument_swift_AspectFitFiniteGuardTests: XCTestCase {

    // MARK: - else-branch (degenerate input) crash sites

    func test_aspectFit_nanBoxWidth_returnsSentinel_noTrap() {
        let fit = EditOp.aspectFit(source: CGSize(width: 1000, height: 500),
                                   into: CGSize(width: CGFloat.nan, height: 400))
        XCTAssertEqual(fit.width, 1)
        XCTAssertEqual(fit.height, 1)
    }

    func test_aspectFit_nanBoxHeight_returnsSentinel_noTrap() {
        let fit = EditOp.aspectFit(source: CGSize(width: 1000, height: 500),
                                   into: CGSize(width: 400, height: CGFloat.nan))
        XCTAssertEqual(fit.width, 1)
        XCTAssertEqual(fit.height, 1)
    }

    func test_aspectFit_nanSource_returnsSentinel_noTrap() {
        let fit = EditOp.aspectFit(source: CGSize(width: CGFloat.nan, height: 500),
                                   into: CGSize(width: 400, height: 400))
        XCTAssertEqual(fit.width, 1)
        XCTAssertEqual(fit.height, 1)
    }

    func test_aspectFit_zeroBox_returnsSentinel_noTrap() {
        let fit = EditOp.aspectFit(source: CGSize(width: 1000, height: 500),
                                   into: .zero)
        XCTAssertEqual(fit.width, 1)
        XCTAssertEqual(fit.height, 1)
    }

    func test_aspectFit_negativeBox_returnsSentinel_noTrap() {
        let fit = EditOp.aspectFit(source: CGSize(width: 1000, height: 500),
                                   into: CGSize(width: -10, height: -10))
        XCTAssertEqual(fit.width, 1)
        XCTAssertEqual(fit.height, 1)
    }

    // MARK: - happy-path Inf scale crash site

    func test_aspectFit_infBoxThatPassesPositiveGuard_noTrap() {
        // `.infinity > 0` is *true*, so a pre-fix happy path computed an Inf
        // scale and trapped on `Int((source.width * scale).rounded())`.
        let fit = EditOp.aspectFit(source: CGSize(width: 1000, height: 500),
                                   into: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        XCTAssertEqual(fit.width, 1)
        XCTAssertEqual(fit.height, 1)
    }

    func test_aspectFit_infSourceDimension_noTrap() {
        let fit = EditOp.aspectFit(source: CGSize(width: CGFloat.infinity, height: 500),
                                   into: CGSize(width: 400, height: 400))
        XCTAssertEqual(fit.width, 1)
        XCTAssertEqual(fit.height, 1)
    }

    // MARK: - the documented happy path still holds (no regression)

    func test_aspectFit_canonicalRoundingRule_unchanged() {
        let fit = EditOp.aspectFit(source: CGSize(width: 1000, height: 500),
                                   into: CGSize(width: 400, height: 400))
        XCTAssertEqual(fit.width, 400)
        XCTAssertEqual(fit.height, 200)
    }

    func test_aspectFit_subPixelResultFloorsToOne() {
        // A tiny box must not collapse to 0 — the original floor-at-1 contract.
        let fit = EditOp.aspectFit(source: CGSize(width: 1000, height: 1000),
                                   into: CGSize(width: 1, height: 1))
        XCTAssertEqual(fit.width, 1)
        XCTAssertEqual(fit.height, 1)
    }
}
