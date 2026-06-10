import XCTest
import SwiftUI
@testable import ViewerCore
@testable import ViewerUI

/// TSK-595 — the selected Git Log row must RENDER a visible accent
/// fill, not just track selection state (the original bug: diff shown,
/// no strong selected state). The row label is a pure-SwiftUI tree (no
/// representable), so ImageRenderer is a faithful oracle for this
/// claim — the TSK-488 false-green class (representable occlusion /
/// cacheDisplay) does not apply. The label is rendered EXTRACTED
/// because in situ it sits inside a ScrollView, which is opaque to
/// every headless render oracle (the TSK-593 discovery).
@MainActor
final class GitLogRowLabelTests: XCTestCase {

    private func makeCommit() -> GitClient.GraphCommit {
        GitClient.GraphCommit(
            sha: "abc1234", parents: ["def5678"], author: "t",
            timestamp: 1_700_000_000, subject: "test subject", refs: [],
            filesChanged: 1, insertions: 2, deletions: 1)
    }

    private func render(selected: Bool) -> NSImage? {
        let label = GitLogRowLabel(
            commit: makeCommit(),
            layoutRow: nil,
            maxLane: 0,
            isHead: false,
            branchRefs: [],
            authorLine: "t · 1 file · +2 −1",
            isSelected: selected,
            uiSize: { $0 })
            .frame(width: 360, height: 60)
        let renderer = ImageRenderer(content: label)
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Mean per-channel difference between the two renders — the
    /// selected row must differ VISIBLY (an accent fill across the row),
    /// not by a rounding error.
    func test_selectedRow_rendersVisibleAccentFill() throws {
        let plain = try XCTUnwrap(render(selected: false), "unselected render")
        let selected = try XCTUnwrap(render(selected: true), "selected render")

        func bitmap(_ img: NSImage) throws -> NSBitmapImageRep {
            let data = try XCTUnwrap(img.tiffRepresentation)
            return try XCTUnwrap(NSBitmapImageRep(data: data))
        }
        let a = try bitmap(plain)
        let b = try bitmap(selected)
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh)

        var changed = 0
        var sampled = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                guard let ca = a.colorAt(x: x, y: y),
                      let cb = b.colorAt(x: x, y: y) else { continue }
                sampled += 1
                let dr = abs(ca.redComponent - cb.redComponent)
                let dg = abs(ca.greenComponent - cb.greenComponent)
                let db = abs(ca.blueComponent - cb.blueComponent)
                let da = abs(ca.alphaComponent - cb.alphaComponent)
                if dr + dg + db + da > 0.05 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(sampled, 100, "renders must produce real pixels")
        // The fill covers the whole row behind the text — well over a
        // third of sampled pixels must differ. A dropped .background
        // makes the two renders identical (changed == 0) → red.
        XCTAssertGreaterThan(
            Double(changed) / Double(sampled), 0.3,
            "selected row must render a row-wide visible fill; "
            + "changed=\(changed)/\(sampled)")
    }
}
