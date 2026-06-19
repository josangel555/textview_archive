import AppKit
import SwiftUI
import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Pins the treemap tile-color mapping (TSK-506): a scanned
/// `FolderSizeEntry` resolves to the SAME shared `IconCategory` palette
/// the file's sidebar chip uses, so a `.swift` tile is "code"-blue and a
/// directory uses the folder palette. This is the view's only pure-logic
/// branch — the rect/label painting is `Canvas` (VM-only) — so locking the
/// color contract here catches a classification regression on the host
/// gate even though the pixels are validated in the VM.
///
/// `Color.adaptive` wraps a fresh dynamic `NSColor` provider per call, so
/// two `Color`s are never `==` even with identical RGB. We therefore
/// compare RESOLVED sRGB components under a fixed appearance.
final class FolderTreemapPaletteTests: XCTestCase {

    /// Resolve a SwiftUI `Color` to (r,g,b,a) in the light (aqua)
    /// appearance — stable across independently-constructed adaptives.
    private func rgba(_ color: Color) -> [CGFloat] {
        var out: [CGFloat] = [0, 0, 0, 0]
        let aqua = NSAppearance(named: .aqua)!
        aqua.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            out = [ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent]
        }
        return out
    }

    private func assertSameColor(
        _ a: Color, _ b: Color, file: StaticString = #filePath, line: UInt = #line
    ) {
        let ra = rgba(a), rb = rgba(b)
        for i in 0..<4 {
            XCTAssertEqual(ra[i], rb[i], accuracy: 0.001,
                           "channel \(i) differs", file: file, line: line)
        }
    }

    private func category(forFile name: String) -> IconCategory {
        let kind = FileIconClassifier.icon(
            for: URL(fileURLWithPath: name), isDirectory: false)
        switch kind {
        case .chip(_, let c), .glyph(_, let c): return c
        case .folder: return .generic   // unreachable for a file
        }
    }

    func test_codeFile_usesCodeCategoryPalette() {
        let entry = FolderSizeEntry(
            name: "Main.swift", byteSize: 100, isDirectory: false, fileCount: 1)
        assertSameColor(
            FolderTreemapView.palette(for: entry).background,
            IconCategory.code.palette.background)
        // And the mapping agrees with the classifier's own category.
        XCTAssertEqual(category(forFile: "Main.swift"), .code)
    }

    func test_docFile_usesDocCategoryPalette() {
        let entry = FolderSizeEntry(
            name: "README.md", byteSize: 100, isDirectory: false, fileCount: 1)
        assertSameColor(
            FolderTreemapView.palette(for: entry).foreground,
            category(forFile: "README.md").palette.foreground)
    }

    func test_directory_usesFolderPalette() {
        let entry = FolderSizeEntry(
            name: "Sources", byteSize: 5000, isDirectory: true, fileCount: 12)
        // Default (collapsed) folder palette — must be a folder palette,
        // not a file-category one.
        assertSameColor(
            FolderTreemapView.palette(for: entry).background,
            FolderState.collapsed.palette.background)
    }

    func test_distinctFileTypes_getDistinctColors() {
        let swift = rgba(FolderTreemapView.palette(for: FolderSizeEntry(
            name: "a.swift", byteSize: 1, isDirectory: false, fileCount: 1)).background)
        let css = rgba(FolderTreemapView.palette(for: FolderSizeEntry(
            name: "a.css", byteSize: 1, isDirectory: false, fileCount: 1)).background)
        // code (blue) vs style (teal) must not collapse to the same tint.
        XCTAssertNotEqual(swift, css)
    }
}
