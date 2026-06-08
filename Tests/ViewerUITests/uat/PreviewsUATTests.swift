import XCTest
import Foundation
import AppKit
import AVFoundation
import PDFKit
import CoreGraphics

/// UAT executable companion — **group 10/12: previews**
/// (image / audio / video / PDF / SQLite / CSV).
///
/// Durable T4 live-app smoke for `docs/uat/smokes/previews.md`
/// (PV-01..08). Drives the assembled `dist/TextView.app` via the
/// `--script` verb dispatcher (the proven `ViewModeMatrixSmokeTests` /
/// `ViewModesUATTests` path), captures a `DiagnosticDump` JSON per step,
/// and asserts the scripted expectations AND walks the realized NSView
/// tree for wrong-viewer paint / desync / blank panes a model-only
/// assertion would miss.
///
/// ## Realized-tree observability for the preview surfaces
///
/// The preview lenses are SwiftUI structs, so they don't appear by struct
/// name in the dump's `class` field — but every one of them embeds an
/// AppKit NSView the dump CAN see:
///   - image   → `ZoomableImageScrollView` (NSScrollView) + `CenteredImageView`
///   - audio   → `AVPlayerView` (audio: `showsFullScreenToggleButton = false`)
///   - video   → `AVPlayerView` (video: `showsFullScreenToggleButton = true`)
///   - pdf     → `PDFView`
///   - sqlite  → the browser's `NSSplitView` (+ result `NSTableView`/`NSScrollView`)
///   - csv     → a SwiftUI grid (NO distinctive NSView class) — detected by
///               "table mode + no Hex grid + not a media/web view"
///   - hex     → `HexNSTextView` (byte grid)
/// SwiftUI `.accessibilityIdentifier()` does NOT propagate to
/// `NSView.accessibilityIdentifier()` (verified by sibling groups), so the
/// `mdv.*` a11y ids in the catalog are NOT in the dump; we read the
/// authoritative `model` sub-dict + the view CLASS.
///
/// ## What is / isn't script-reachable for THIS group
///
/// Reachable: every preview-category default route + HEX fallback
/// (`open`, `editor-set-mode hex|preview`, `set-open-as`), per-tab mode
/// carry across `select-tab`, the Preview↔HEX round-trip (Bug-B / Bug-C
/// regression sentinels). NOT script-reachable (logged for the MANUAL/VM
/// lane): the in-preview control bars (zoom/pan/sibling chevrons,
/// AVPlayerView transport, PDF page nav), the CSV filter fields
/// (`mdv.csvFilter.*`), the SQLite SQL editor / Run / Cancel, the HEX
/// search field / width picker / click-highlight, and the right-side
/// MetadataPanel — these are SwiftUI controls with no script verb and no
/// model scalar. We exercise everything the verb vocabulary can reach and
/// flag the rest.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process per-(preview type × lens) routing, the
/// mode↔state↔realized-subtree consistency (fd11e61 load-bug + Bug B/C
/// preview-vs-HEX class), and the AVKit/PDFKit/WKWebView-backed surfaces
/// that only a live process mounts. Self-skips on the headless gate
/// (`isAppBuilt` false there); runs for real on the VM/nightly lane or a
/// host-occluded UAT run.
@MainActor
final class PreviewsUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "PreviewsUAT" }
    // AVKit / PDFKit / WKWebView surfaces need mount + first-paint settle
    // time and several scenarios cross multiple files; give generous room.
    override class var defaultScenarioTimeout: TimeInterval { 120 }

    // MARK: - PV-01 — Image preview: default Preview (never HEX), Preview↔HEX round-trip

    /// A fresh image opens in **Preview** (native image scroll view), NOT
    /// HEX (Bug-B sentinel). Force HEX via Open-As, then back to Auto:
    /// the native image returns with NO Hex grid stranded under the Preview
    /// picker (Bug-C sentinel). Also exercises a small image and a corrupt
    /// image (must not crash / .error → stays a non-error preview state).
    func test_PV_01_imagePreviewDefaultAndHexRoundTrip() throws {
        let big = try writePNGFixture("a.png", width: 800, height: 600)
        let small = try writePNGFixture("b.png", width: 16, height: 16)
        let corrupt = try writeCorruptPNG("bad.png")
        // Verb plan (bare `delay` ≈ 300 ms fixed; pad each settle window):
        //   settle x3 -> a.png PREVIEW default (image scroll view), NOT hex
        //   set hex   -> raw byte grid (HexNSTextView)
        //   set-open-as auto -> native image returns, NO Hex stuck (Bug C)
        //   open b.png (small) -> still PREVIEW, no upscale crash
        //   open bad.png       -> corrupt: no crash, no .error, control bar still
        let script = """
        delay
        delay
        delay
        editor-set-mode hex
        delay
        delay
        delay
        set-open-as auto
        delay
        delay
        delay
        delay
        open \(small.path)
        delay
        delay
        delay
        open \(corrupt.path)
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "image-preview-default-hex-roundtrip",
                argFile: big,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let bigDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("a.png") }
                    let smallDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("b.png") }
                    let corruptDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("bad.png") }

                    // Fresh image -> PREVIEW (Bug-B regression guard).
                    if let firstBig = bigDumps.first {
                        assertModel(firstBig, "currentViewMode", equals: "preview", label: "pv01-png-default", file: file, line: line)
                        XCTAssertEqual(modelString(firstBig, "currentStateKind"), "preview",
                            "[pv01] fresh image landed in '\(modelString(firstBig, "currentStateKind"))' state, not .preview (Bug B: fresh image → HEX)", file: file, line: line)
                        assertNoHexView(firstBig, label: "pv01-png-preview", file: file, line: line)
                        assertImagePreviewRendered(firstBig, label: "pv01-image", file: file, line: line)
                    }
                    // Forced HEX -> byte grid, binary state.
                    let pngHex = bigDumps.first { modelString($0, "currentViewMode") == "hex" }
                    XCTAssertNotNil(pngHex, "[pv01] image never reached HEX via Open-As", file: file, line: line)
                    if let ph = pngHex {
                        XCTAssertEqual(modelString(ph, "currentStateKind"), "binary",
                            "[pv01] HEX picker but state != binary", file: file, line: line)
                        assertHexRendered(ph, label: "pv01-png-hex", file: file, line: line)
                    }
                    // Open-As auto -> back to PREVIEW, NO Hex stuck (Bug C).
                    if let lastBig = bigDumps.last, modelString(lastBig, "currentViewMode") == "preview" {
                        XCTAssertEqual(modelString(lastBig, "currentStateKind"), "preview",
                            "[pv01] preview-back but state != preview — Hex stuck under Preview picker (Bug C)", file: file, line: line)
                        assertNoHexView(lastBig, label: "pv01-png-preview-back", file: file, line: line)
                        assertImagePreviewRendered(lastBig, label: "pv01-png-preview-back", file: file, line: line)
                    } else {
                        XCTFail("[pv01] image did not return to Preview after the Open-As→auto round-trip", file: file, line: line)
                    }

                    // Small image -> still PREVIEW (no upscale-past-1:1 crash).
                    XCTAssertFalse(smallDumps.isEmpty, "[pv01] open b.png never committed", file: file, line: line)
                    if let firstSmall = smallDumps.first {
                        assertModel(firstSmall, "currentViewMode", equals: "preview", label: "pv01-small-preview", file: file, line: line)
                        XCTAssertEqual(modelString(firstSmall, "currentStateKind"), "preview",
                            "[pv01] small image not .preview state", file: file, line: line)
                        assertImagePreviewRendered(firstSmall, label: "pv01-small-image", file: file, line: line)
                    }

                    // Corrupt image -> no crash, no .error; routes to a preview
                    // (control bar still shows even if no image drawn).
                    XCTAssertFalse(corruptDumps.isEmpty, "[pv01] open bad.png never committed", file: file, line: line)
                    if let lastCorrupt = corruptDumps.last {
                        assertNotError(lastCorrupt, label: "pv01-corrupt", file: file, line: line)
                        // A corrupt image still routes to .preview (it's still
                        // FileCategory.image) — the preview owns its empty state.
                        XCTAssertNotEqual(modelString(lastCorrupt, "currentStateKind"), "error",
                            "[pv01] corrupt image landed in .error — preview should own its empty state", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv01/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - PV-02 — Audio & video preview: default Preview, AVPlayerView mount, HEX fallback

    /// Audio (`.wav`) and video (`.mp4`) both default to **Preview**
    /// (AVPlayerView), NOT HEX (native-preview-never-HEX sentinel,
    /// `7de0f44`/`08176e9`). Force HEX on the video → byte grid, then back.
    /// The realized tree must mount an `AVPlayerView` for the preview.
    func test_PV_02_audioVideoPreviewAndHexFallback() throws {
        let wav = try writeWAVFixture("tune.wav")
        let mp4 = try writeMP4Fixture("clip.mp4")
        //   settle x3 -> tune.wav PREVIEW (AVPlayerView), NOT hex
        //   open clip.mp4 -> PREVIEW (AVPlayerView), NOT hex
        //   set hex      -> raw byte grid
        //   set-open-as auto -> back to PREVIEW (AVPlayerView), no Hex stuck
        let script = """
        delay
        delay
        delay
        open \(mp4.path)
        delay
        delay
        delay
        editor-set-mode hex
        delay
        delay
        delay
        set-open-as auto
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "audio-video-preview-hex",
                argFile: wav,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let wavDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("tune.wav") }
                    let mp4Dumps = dumps.filter { modelString($0, "currentURL").hasSuffix("clip.mp4") }

                    // Audio -> PREVIEW, AVPlayerView mounted.
                    if let firstWav = wavDumps.first {
                        assertModel(firstWav, "currentViewMode", equals: "preview", label: "pv02-audio-default", file: file, line: line)
                        XCTAssertEqual(modelString(firstWav, "currentStateKind"), "preview",
                            "[pv02] fresh audio not .preview (native-preview→HEX regression)", file: file, line: line)
                        assertNoHexView(firstWav, label: "pv02-audio-preview", file: file, line: line)
                        assertAVPlayerRendered(firstWav, label: "pv02-audio", file: file, line: line)
                    }

                    // Video -> PREVIEW, AVPlayerView mounted (first mp4 dump).
                    XCTAssertFalse(mp4Dumps.isEmpty, "[pv02] open clip.mp4 never committed", file: file, line: line)
                    if let firstMp4 = mp4Dumps.first {
                        assertModel(firstMp4, "currentViewMode", equals: "preview", label: "pv02-video-default", file: file, line: line)
                        XCTAssertEqual(modelString(firstMp4, "currentStateKind"), "preview",
                            "[pv02] fresh video not .preview", file: file, line: line)
                        assertNoHexView(firstMp4, label: "pv02-video-preview", file: file, line: line)
                        assertAVPlayerRendered(firstMp4, label: "pv02-video", file: file, line: line)
                    }

                    // Video forced to HEX -> byte grid, binary.
                    let mp4Hex = mp4Dumps.first { modelString($0, "currentViewMode") == "hex" }
                    XCTAssertNotNil(mp4Hex, "[pv02] video never reached HEX", file: file, line: line)
                    if let mh = mp4Hex {
                        XCTAssertEqual(modelString(mh, "currentStateKind"), "binary",
                            "[pv02] HEX picker but state != binary", file: file, line: line)
                        assertHexRendered(mh, label: "pv02-video-hex", file: file, line: line)
                    }

                    // Open-As auto -> back to PREVIEW (AVPlayerView), no Hex stuck.
                    if let lastMp4 = mp4Dumps.last, modelString(lastMp4, "currentViewMode") == "preview" {
                        XCTAssertEqual(modelString(lastMp4, "currentStateKind"), "preview",
                            "[pv02] video preview-back but state != preview — Hex stuck (Bug C)", file: file, line: line)
                        assertNoHexView(lastMp4, label: "pv02-video-preview-back", file: file, line: line)
                        assertAVPlayerRendered(lastMp4, label: "pv02-video-back", file: file, line: line)
                    } else {
                        XCTFail("[pv02] video did not return to Preview after HEX round-trip", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv02/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - PV-03 — PDF preview: default Preview, PDFView mount, HEX round-trip

    /// A `.pdf` opens in **Preview** (PDFView, continuous mode), NOT HEX.
    /// Open-As → HEX shows the byte grid; back to Auto restores the PDFView
    /// with no leftover Hex grid under the Preview picker.
    func test_PV_03_pdfPreviewAndHexRoundTrip() throws {
        let pdf = try writePDFFixture("doc.pdf", pages: 3)
        //   settle x3 -> doc.pdf PREVIEW (PDFView), NOT hex
        //   set hex   -> byte grid
        //   set-open-as auto -> PDFView returns, no Hex stuck
        let script = """
        delay
        delay
        delay
        editor-set-mode hex
        delay
        delay
        delay
        set-open-as auto
        delay
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "pdf-preview-hex-roundtrip",
                argFile: pdf,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }
                    let pdfDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("doc.pdf") }

                    // Fresh PDF -> PREVIEW (PDFView), NOT hex.
                    if let firstPdf = pdfDumps.first {
                        assertModel(firstPdf, "currentViewMode", equals: "preview", label: "pv03-pdf-default", file: file, line: line)
                        XCTAssertEqual(modelString(firstPdf, "currentStateKind"), "preview",
                            "[pv03] fresh PDF not .preview state", file: file, line: line)
                        assertNoHexView(firstPdf, label: "pv03-pdf-preview", file: file, line: line)
                        assertPDFRendered(firstPdf, label: "pv03-pdf", file: file, line: line)
                    }
                    // Forced HEX -> byte grid.
                    let pdfHex = pdfDumps.first { modelString($0, "currentViewMode") == "hex" }
                    XCTAssertNotNil(pdfHex, "[pv03] PDF never reached HEX", file: file, line: line)
                    if let ph = pdfHex {
                        XCTAssertEqual(modelString(ph, "currentStateKind"), "binary",
                            "[pv03] HEX picker but state != binary", file: file, line: line)
                        assertHexRendered(ph, label: "pv03-pdf-hex", file: file, line: line)
                    }
                    // Open-As auto -> PDFView returns, no Hex stuck.
                    if let lastPdf = pdfDumps.last, modelString(lastPdf, "currentViewMode") == "preview" {
                        XCTAssertEqual(modelString(lastPdf, "currentStateKind"), "preview",
                            "[pv03] PDF preview-back but state != preview — Hex stuck (Bug C)", file: file, line: line)
                        assertNoHexView(lastPdf, label: "pv03-pdf-preview-back", file: file, line: line)
                        assertPDFRendered(lastPdf, label: "pv03-pdf-back", file: file, line: line)
                    } else {
                        XCTFail("[pv03] PDF did not return to Preview after HEX round-trip", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv03/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - PV-04 — SQLite browser: default Preview(sqlite), NSSplitView, fake.db failure

    /// A real `.db` opens in the **SQLite browser** (Preview, NSSplitView),
    /// NOT HEX. A tiny `.db` likewise. A non-database file renamed `.db`
    /// (`fake.db`, actually text) must surface the open-failure path
    /// gracefully (no crash). HEX is the secondary lens and round-trips.
    func test_PV_04_sqliteBrowserDefaultAndOpenFailure() throws {
        let app = try writeSQLiteFixture("app.db")
        let tiny = try writeSQLiteFixture("tiny.db")
        let fake = try harness.writeFile("fake.db", "this is plain text, not a database\nrow,two\n")
        //   settle x3 -> app.db PREVIEW(sqlite) browser, NSSplitView, NOT hex
        //   set hex   -> byte grid (secondary lens)
        //   set-open-as auto -> browser returns
        //   open tiny.db -> PREVIEW(sqlite), NOT hex (tiny-db regression guard)
        //   open fake.db -> open-failure path: no crash
        let script = """
        delay
        delay
        delay
        editor-set-mode hex
        delay
        delay
        delay
        set-open-as auto
        delay
        delay
        delay
        open \(tiny.path)
        delay
        delay
        delay
        open \(fake.path)
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "sqlite-browser-default-failure",
                argFile: app,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let appDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("app.db") }
                    let tinyDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("tiny.db") }
                    let fakeDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("fake.db") }

                    // Real DB -> PREVIEW(sqlite) browser (NSSplitView), NOT hex.
                    if let firstApp = appDumps.first {
                        assertModel(firstApp, "currentViewMode", equals: "preview", label: "pv04-db-default", file: file, line: line)
                        XCTAssertEqual(modelString(firstApp, "currentStateKind"), "preview",
                            "[pv04] sqlite not .preview state (HEX-flip regression)", file: file, line: line)
                        assertNoHexView(firstApp, label: "pv04-db-preview", file: file, line: line)
                        assertSplitBrowserRendered(firstApp, label: "pv04-db-browser", file: file, line: line)
                    }
                    // DB forced to HEX -> byte grid.
                    let dbHex = appDumps.first { modelString($0, "currentViewMode") == "hex" }
                    XCTAssertNotNil(dbHex, "[pv04] sqlite never reached HEX", file: file, line: line)
                    if let dh = dbHex {
                        assertHexRendered(dh, label: "pv04-db-hex", file: file, line: line)
                    }
                    // Open-As auto -> browser returns, no Hex stuck.
                    if let lastApp = appDumps.last, modelString(lastApp, "currentViewMode") == "preview" {
                        XCTAssertEqual(modelString(lastApp, "currentStateKind"), "preview",
                            "[pv04] sqlite preview-back but state != preview — Hex stuck (Bug C)", file: file, line: line)
                        assertNoHexView(lastApp, label: "pv04-db-preview-back", file: file, line: line)
                    } else {
                        XCTFail("[pv04] sqlite did not return to Preview after HEX round-trip", file: file, line: line)
                    }

                    // tiny.db -> PREVIEW(sqlite), NOT hex (sub-ms route, regression guard).
                    XCTAssertFalse(tinyDumps.isEmpty, "[pv04] open tiny.db never committed", file: file, line: line)
                    if let firstTiny = tinyDumps.first {
                        assertModel(firstTiny, "currentViewMode", equals: "preview", label: "pv04-tiny-preview", file: file, line: line)
                        XCTAssertEqual(modelString(firstTiny, "currentStateKind"), "preview",
                            "[pv04] tiny.db flipped to '\(modelString(firstTiny, "currentStateKind"))' not .preview (tiny-db→HEX regression)", file: file, line: line)
                    }

                    // fake.db (text masquerading as .db) -> open-failure path,
                    // no crash. It still ROUTES to .preview(sqlite) by extension;
                    // the browser surfaces "Couldn't open database" internally.
                    // The load-bearing assertion: the app stays alive & not in a
                    // hard .error envelope (the browser owns its own error UI).
                    XCTAssertFalse(fakeDumps.isEmpty, "[pv04] open fake.db never committed", file: file, line: line)
                    if let lastFake = fakeDumps.last {
                        assertNotError(lastFake, label: "pv04-fake", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv04/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - PV-05 — CSV/TSV table: default Table, Table↔Source, Open-As, persistence

    /// CSV opens in **Table** (default). Table↔Source round-trip via the
    /// mode picker. A `.tsv` likewise opens Table. Open-As → code forces the
    /// Source/code lens; auto reverts to Table. The realized tree: Table
    /// mode mounts NO Hex grid and is not a media/web/PDF view.
    func test_PV_05_csvTableModeAndOpenAs() throws {
        var csvBody = "id,name,score,city,active\n"
        for i in 1...60 { csvBody += "\(i),row\(i),\(i * 3),city\(i % 5),\(i % 2 == 0)\n" }
        let csv = try harness.writeFile("data.csv", csvBody)
        var tsvBody = "col_a\tcol_b\tcol_c\n"
        for i in 1...10 { tsvBody += "\(i)\tval\(i)\t\(i * 2)\n" }
        let tsv = try harness.writeFile("tab.tsv", tsvBody)
        //   settle x2 -> data.csv TABLE default, no Hex
        //   set source-> raw CSV NSTextView
        //   set table -> back to grid
        //   set-open-as code -> force code/source lens (CSV default -> source)
        //   set-open-as auto -> revert to Table
        //   open tab.tsv -> TABLE default
        let script = """
        delay
        delay
        editor-set-mode source
        delay
        delay
        editor-set-mode table
        delay
        delay
        set-open-as code
        delay
        delay
        set-open-as auto
        delay
        delay
        open \(tsv.path)
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "csv-table-mode-openas",
                argFile: csv,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let csvDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("data.csv") }
                    let tsvDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("tab.tsv") }

                    // CSV TABLE default (first dump).
                    if let firstCsv = csvDumps.first {
                        assertModel(firstCsv, "currentViewMode", equals: "table", label: "pv05-csv-default", file: file, line: line)
                        assertNoHexView(firstCsv, label: "pv05-csv-table", file: file, line: line)
                        assertTableRendered(firstCsv, label: "pv05-csv-table", file: file, line: line)
                    }
                    // CSV reached Source (raw CSV NSTextView).
                    let csvSource = csvDumps.first { modelString($0, "currentViewMode") == "source" }
                    XCTAssertNotNil(csvSource, "[pv05] CSV never reached Source", file: file, line: line)
                    if let cs = csvSource {
                        assertSourceTextRendered(cs, label: "pv05-csv-source", file: file, line: line)
                    }
                    // Open-As code forced the CSV through the Source/code lens.
                    let csvForcedSource = csvDumps.first {
                        modelString($0, "currentViewMode") == "source"
                    }
                    XCTAssertNotNil(csvForcedSource, "[pv05] Open-As code did not flip CSV to Source", file: file, line: line)
                    // …and Open-As auto reverted to Table (LAST CSV dump is table).
                    if let lastCsv = csvDumps.last {
                        assertModel(lastCsv, "currentViewMode", equals: "table", label: "pv05-csv-openas-auto-table", file: file, line: line)
                    }

                    // TSV -> TABLE default (same as CSV).
                    XCTAssertFalse(tsvDumps.isEmpty, "[pv05] open tab.tsv never committed", file: file, line: line)
                    if let firstTsv = tsvDumps.first {
                        assertModel(firstTsv, "currentViewMode", equals: "table", label: "pv05-tsv-default", file: file, line: line)
                        assertNoHexView(firstTsv, label: "pv05-tsv-table", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv05/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    /// PV-05 edge: header-only `empty.csv` and a `headerless.csv` with
    /// RAGGED rows (some shorter than the header, one with a blank first
    /// cell). Both must open in Table mode without crash / .error / blank.
    func test_PV_05var_emptyAndRaggedCsv() throws {
        let empty = try harness.writeFile("empty.csv", "h1,h2,h3\n")
        let ragged = try harness.writeFile(
            "headerless.csv",
            "a,b,c,d\n1,2\n,blank_first,3,4\n5,6,7,8,9\n")
        let script = """
        delay
        delay
        open \(ragged.path)
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "csv-empty-ragged",
                argFile: empty,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    let emptyDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("empty.csv") }
                    let raggedDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("headerless.csv") }

                    if let firstEmpty = emptyDumps.first {
                        assertModel(firstEmpty, "currentViewMode", equals: "table", label: "pv05var-empty-table", file: file, line: line)
                        assertNotError(firstEmpty, label: "pv05var-empty", file: file, line: line)
                    }
                    XCTAssertFalse(raggedDumps.isEmpty, "[pv05var] open headerless.csv never committed", file: file, line: line)
                    if let lastRagged = raggedDumps.last {
                        assertModel(lastRagged, "currentViewMode", equals: "table", label: "pv05var-ragged-table", file: file, line: line)
                        assertNotError(lastRagged, label: "pv05var-ragged", file: file, line: line)
                        assertNoHexView(lastRagged, label: "pv05var-ragged", file: file, line: line)
                    }
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv05var/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - PV-06 — Default-mode routing per preview category + HEX fallback matrix

    /// The preview-category routing matrix in a SINGLE launch: open one
    /// representative file of each type in turn and assert each lands on the
    /// right default lens (image/audio/video/pdf/sqlite→Preview;
    /// csv→Table; binary/unknown→HEX). This is the consolidated regression
    /// sentinel for "fresh native-preview tab never opens as HEX".
    func test_PV_06_defaultModeRoutingMatrix() throws {
        let png = try writePNGFixture("pic.png", width: 200, height: 120)
        let wav = try writeWAVFixture("song.wav")
        let mp4 = try writeMP4Fixture("movie.mp4")
        let pdf = try writePDFFixture("doc.pdf", pages: 1)
        let db = try writeSQLiteFixture("app.db")
        let csv = try harness.writeFile("data.csv", "a,b,c\n1,2,3\n4,5,6\n")
        let bin = try writeRandomBinary("blob.bin")
        // argv opens pic.png; then open each of the others in turn so each
        // file's FIRST dump captures its default-mode route.
        let script = """
        delay
        delay
        open \(wav.path)
        delay
        delay
        open \(mp4.path)
        delay
        delay
        open \(pdf.path)
        delay
        delay
        open \(db.path)
        delay
        delay
        open \(csv.path)
        delay
        delay
        open \(bin.path)
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "default-mode-routing-matrix",
                argFile: png,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let firstMode: (String) -> String? = { suffix in
                        dumps.first { self.modelString($0, "currentURL").hasSuffix(suffix) }
                            .map { self.modelString($0, "currentViewMode") }
                    }
                    let firstState: (String) -> String? = { suffix in
                        dumps.first { self.modelString($0, "currentURL").hasSuffix(suffix) }
                            .map { self.modelString($0, "currentStateKind") }
                    }

                    // image / audio / video / pdf / sqlite -> Preview.
                    XCTAssertEqual(firstMode("pic.png"), "preview", "[pv06] image default != preview", file: file, line: line)
                    XCTAssertEqual(firstMode("song.wav"), "preview", "[pv06] audio default != preview", file: file, line: line)
                    XCTAssertEqual(firstMode("movie.mp4"), "preview", "[pv06] video default != preview", file: file, line: line)
                    XCTAssertEqual(firstMode("doc.pdf"), "preview", "[pv06] pdf default != preview", file: file, line: line)
                    XCTAssertEqual(firstMode("app.db"), "preview", "[pv06] sqlite default != preview", file: file, line: line)
                    // All five preview categories must be .preview state, NOT binary.
                    for s in ["pic.png", "song.wav", "movie.mp4", "doc.pdf", "app.db"] {
                        XCTAssertEqual(firstState(s), "preview",
                            "[pv06] \(s) state != .preview (native-preview→HEX regression)", file: file, line: line)
                    }
                    // csv -> Table.
                    XCTAssertEqual(firstMode("data.csv"), "table", "[pv06] csv default != table", file: file, line: line)
                    // binary/unknown -> HEX (state binary).
                    XCTAssertEqual(firstMode("blob.bin"), "hex", "[pv06] binary default != hex", file: file, line: line)
                    XCTAssertEqual(firstState("blob.bin"), "binary", "[pv06] binary state != binary", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv06/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - PV-07 — HEX viewer as universal fallback: dump renders, empty file

    /// A binary `data.bin` opens in HEX (byte grid with glyphs). An
    /// `empty.bin` (0 bytes) renders HEX without crash. Then a text
    /// `code.txt` forced to HEX via Open-As mounts the byte grid (the
    /// universal-fallback path) — and back to Auto returns to Source.
    func test_PV_07_hexViewerFallback() throws {
        let bin = try writeKnownBinary("data.bin")
        let empty = try harness.writeFile("empty.bin", "")
        let code = try harness.writeFile("code.txt", "line one\nline two\nMAGIC token here\n")
        //   settle x3 -> data.bin HEX byte grid (glyphs)
        //   open empty.bin -> HEX, 0 bytes, no crash
        //   open code.txt  -> SOURCE default
        //   set hex        -> byte grid (universal fallback on text)
        //   set-open-as auto -> back to SOURCE
        let script = """
        delay
        delay
        delay
        open \(empty.path)
        delay
        delay
        delay
        open \(code.path)
        delay
        delay
        editor-set-mode hex
        delay
        delay
        delay
        set-open-as auto
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "hex-viewer-fallback",
                argFile: bin,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let binDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("data.bin") }
                    let emptyDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("empty.bin") }
                    let codeDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("code.txt") }

                    // Binary -> HEX byte grid with glyphs.
                    if let firstBin = binDumps.first {
                        assertModel(firstBin, "currentViewMode", equals: "hex", label: "pv07-bin-hex", file: file, line: line)
                        XCTAssertEqual(modelString(firstBin, "currentStateKind"), "binary",
                            "[pv07] binary state != binary", file: file, line: line)
                        assertHexRendered(firstBin, label: "pv07-bin-hex", file: file, line: line)
                    }
                    // Empty -> HEX, 0 bytes, no crash / .error.
                    XCTAssertFalse(emptyDumps.isEmpty, "[pv07] open empty.bin never committed", file: file, line: line)
                    if let firstEmpty = emptyDumps.first {
                        assertModel(firstEmpty, "currentViewMode", equals: "hex", label: "pv07-empty-hex", file: file, line: line)
                        assertNotError(firstEmpty, label: "pv07-empty", file: file, line: line)
                    }
                    // code.txt SOURCE default, then forced HEX.
                    let codeSource = codeDumps.first { modelString($0, "currentViewMode") == "source" }
                    XCTAssertNotNil(codeSource, "[pv07] code.txt never opened in Source", file: file, line: line)
                    let codeHex = codeDumps.first { modelString($0, "currentViewMode") == "hex" }
                    XCTAssertNotNil(codeHex, "[pv07] code.txt forced HEX never took", file: file, line: line)
                    if let ch = codeHex {
                        assertHexRendered(ch, label: "pv07-code-hex", file: file, line: line)
                    }
                    // Back to Auto -> SOURCE again (no Hex stuck under source).
                    if let lastCode = codeDumps.last {
                        assertModel(lastCode, "currentViewMode", equals: "source", label: "pv07-code-auto-source", file: file, line: line)
                        XCTAssertNotEqual(modelString(lastCode, "currentStateKind"), "binary",
                            "[pv07] code back-to-auto but state==binary — Hex leaked under source", file: file, line: line)
                        assertNoHexView(lastCode, label: "pv07-code-source-back", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv07/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - PV-08 — Media tab × tab interplay: per-tab mode carry, open-or-reveal (no dup)

    /// Open a media tab and a CSV tab, then re-open the SAME image path: it
    /// must switch to the EXISTING tab (no duplicate). Per-tab modes are
    /// preserved across switches (image=Preview, csv=Table). Confirms the
    /// media tab's currentURL/state stay consistent as the active tab moves.
    func test_PV_08_mediaTabInterplayAndOpenOrReveal() throws {
        let img1 = try writePNGFixture("img1.png", width: 100, height: 80)
        let img2 = try writePNGFixture("img2.png", width: 120, height: 90)
        let csv = try harness.writeFile("rows.csv", "x,y\n1,2\n3,4\n")
        // argv opens img1. Open img2, open csv, then RE-open img1 (should
        // switch to its existing tab, NOT create a 4th). Tab count must stay
        // at 3 after the re-open.
        let script = """
        delay
        delay
        open \(img2.path)
        delay
        delay
        open \(csv.path)
        delay
        delay
        open \(img1.path)
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "media-tab-open-or-reveal",
                argFile: img1,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard let last = dumps.last else { return }

                    // After opening img2, csv, then RE-opening img1, there must
                    // be exactly 3 tabs (open-or-reveal, no duplicate).
                    XCTAssertEqual(intModel(last, "tabCount"), 3,
                        "[pv08] re-opening an already-open image created a duplicate tab (open-or-reveal failed) — tabCount=\(intModel(last, "tabCount"))", file: file, line: line)
                    // The re-opened img1 is now the active tab, back in Preview.
                    assertModel(last, "currentURL", endsWith: "img1.png", label: "pv08-reopen-img1", file: file, line: line)
                    assertModel(last, "currentViewMode", equals: "preview", label: "pv08-img1-preview", file: file, line: line)
                    XCTAssertEqual(modelString(last, "currentStateKind"), "preview",
                        "[pv08] re-opened image not .preview state", file: file, line: line)
                    assertImagePreviewRendered(last, label: "pv08-img1-preview", file: file, line: line)

                    // The csv tab kept Table mode at the point it was active.
                    let csvDump = dumps.last { modelString($0, "currentURL").hasSuffix("rows.csv") }
                    XCTAssertEqual(csvDump.map { modelString($0, "currentViewMode") }, "table",
                        "[pv08] csv tab did not hold Table mode", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "pv08/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - Model assertion helpers (mirror ViewModesUATTests)

    private func model(_ dump: [String: Any]) -> [String: Any] {
        dump["model"] as? [String: Any] ?? [:]
    }
    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        model(dump)[key] as? String ?? ""
    }
    private func intModel(_ dump: [String: Any], _ key: String) -> Int {
        model(dump)[key] as? Int ?? Int.min
    }
    private func boolModel(_ dump: [String: Any], _ key: String) -> Bool {
        model(dump)[key] as? Bool ?? false
    }

    private func assertModel(
        _ dump: [String: Any], _ key: String, equals expected: String,
        label: String, file: StaticString, line: UInt
    ) {
        XCTAssertEqual(modelString(dump, key), expected,
            "[\(label)] model.\(key) mismatch", file: file, line: line)
    }
    private func assertModel(
        _ dump: [String: Any], _ key: String, endsWith suffix: String,
        label: String, file: StaticString, line: UInt
    ) {
        let v = modelString(dump, key)
        XCTAssertTrue(v.hasSuffix(suffix),
            "[\(label)] model.\(key) (\(v.debugDescription)) does not end with \(suffix.debugDescription)",
            file: file, line: line)
    }
    private func assertNotError(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertNotEqual(modelString(dump, "currentStateKind"), "error",
            "[\(label)] document landed in .error state", file: file, line: line)
    }

    // MARK: - Tree-walk helpers (operate on the serialized DiagnosticDump)

    private func allNodes(in dump: [String: Any]) -> [[String: Any]] {
        guard let root = dump["contentView"] as? [String: Any] else { return [] }
        var out: [[String: Any]] = []
        var stack: [[String: Any]] = [root]
        while let node = stack.popLast() {
            out.append(node)
            if let kids = node["subviews"] as? [[String: Any]] {
                stack.append(contentsOf: kids)
            }
        }
        return out
    }
    private func hasViewClass(_ dump: [String: Any], containing needle: String) -> Bool {
        allNodes(in: dump).contains { (($0["class"] as? String) ?? "").contains(needle) }
    }

    /// A node is effectively invisible if it's hidden, alpha≈0, or its CALayer
    /// opacity≈0. NSNumber casts so it works whether the dump was read in-process
    /// (Bool/CGFloat/Float) or round-tripped through JSON (NSNumber). TSK-504.
    private func isInvisibleNode(_ node: [String: Any]) -> Bool {
        if (node["isHidden"] as? NSNumber)?.boolValue == true { return true }
        if let a = (node["alphaValue"] as? NSNumber)?.doubleValue, a <= 0.01 { return true }
        if let layer = node["layer"] as? [String: Any] {
            if (layer["isHidden"] as? NSNumber)?.boolValue == true { return true }
            if let op = (layer["opacity"] as? NSNumber)?.doubleValue, op <= 0.01 { return true }
        }
        return false
    }

    /// Like `hasViewClass`, but only the VISIBLE subtree counts: any subtree
    /// rooted at an invisible node (hidden / alpha≈0 / layer-opacity≈0) is
    /// pruned. This scopes "is an X view mounted" to the ACTIVE pane — the
    /// ContentView ZStack keeps up to `MountedPanesLRU.capacity` retained panes
    /// alive at `.opacity(0)` (ContentView.swift:504), so a backgrounded pane
    /// legitimately still holding e.g. a HexView must NOT count as a leak in the
    /// foreground pane. A genuinely-visible leak is still caught. TSK-504.
    private func hasVisibleViewClass(_ dump: [String: Any], containing needle: String) -> Bool {
        guard let root = dump["contentView"] as? [String: Any] else { return false }
        var stack: [[String: Any]] = [root]
        while let node = stack.popLast() {
            if isInvisibleNode(node) { continue }   // prune the invisible subtree
            if (((node["class"] as? String) ?? "").contains(needle)) { return true }
            if let kids = node["subviews"] as? [[String: Any]] {
                stack.append(contentsOf: kids)
            }
        }
        return false
    }
    private func anyTextViewWithGlyphs(_ dump: [String: Any]) -> Bool {
        allNodes(in: dump).contains { node in
            guard let tv = node["nsTextView"] as? [String: Any] else { return false }
            let glyphs = (tv["numberOfGlyphs"] as? Int) ?? 0
            let contrasts = (tv["contrastsWithBackground"] as? Bool) ?? false
            return glyphs > 0 && contrasts
        }
    }

    private func assertSourceTextRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        assertNoHexView(dump, label: label, file: file, line: line)
        XCTAssertTrue(anyTextViewWithGlyphs(dump),
            "[\(label)] Source mode: no NSTextView with visible glyphs — content blank/stale",
            file: file, line: line)
    }

    /// HEX: a Hex* byte-grid view with visible glyphs.
    private func assertHexRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertTrue(hasViewClass(dump, containing: "Hex"),
            "[\(label)] HEX mode: no Hex* view in tree — byte grid did not mount",
            file: file, line: line)
        XCTAssertTrue(anyTextViewWithGlyphs(dump),
            "[\(label)] HEX mode: byte grid has no visible glyphs — blank",
            file: file, line: line)
    }

    /// The HEX byte grid must be ABSENT (catches Hex leaking under a
    /// non-HEX picker — stale/desynced view, Bug C).
    private func assertNoHexView(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        // Scope to the VISIBLE subtree: a retained inactive pane (opacity:0 in
        // the MountedPanesLRU ZStack) may legitimately still hold a HexView, so
        // a whole-window `hasViewClass("Hex")` over-reports. Only a Hex view in
        // the foreground pane is a real desync. TSK-504.
        XCTAssertFalse(hasVisibleViewClass(dump, containing: "Hex"),
            "[\(label)] a VISIBLE Hex* byte-grid view is mounted under a non-HEX picker — stale/desynced view",
            file: file, line: line)
    }

    /// Image preview: the native image scroll/host/image-view subtree.
    private func assertImagePreviewRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let hasImage = hasViewClass(dump, containing: "ZoomableImageScrollView")
            || hasViewClass(dump, containing: "ImageScrollHost")
            || hasViewClass(dump, containing: "CenteredImageView")
            || hasViewClass(dump, containing: "ImageView")
        XCTAssertTrue(hasImage,
            "[\(label)] Image preview: no image scroll/view subtree mounted",
            file: file, line: line)
        assertNoHexView(dump, label: label, file: file, line: line)
    }

    /// Audio/Video preview: the `AVPlayerView` AppKit subtree.
    private func assertAVPlayerRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertTrue(hasViewClass(dump, containing: "AVPlayerView")
            || hasViewClass(dump, containing: "PlayerView"),
            "[\(label)] Media preview: no AVPlayerView subtree mounted",
            file: file, line: line)
        assertNoHexView(dump, label: label, file: file, line: line)
    }

    /// PDF preview: the `PDFView` AppKit subtree.
    private func assertPDFRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertTrue(hasViewClass(dump, containing: "PDFView"),
            "[\(label)] PDF preview: no PDFView subtree mounted",
            file: file, line: line)
        assertNoHexView(dump, label: label, file: file, line: line)
    }

    /// SQLite browser: the HSplitView-backed `NSSplitView` subtree.
    private func assertSplitBrowserRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertTrue(hasViewClass(dump, containing: "NSSplitView"),
            "[\(label)] SQLite browser: no NSSplitView subtree mounted",
            file: file, line: line)
        assertNoHexView(dump, label: label, file: file, line: line)
    }

    /// CSV Table: not a Hex grid, not a media/web/pdf view, and SOME content
    /// is mounted (a scroll/text subtree). The grid is pure SwiftUI so there
    /// is no distinctive NSView class — the load-bearing checks are the mode
    /// (`table`) at the model layer + the ABSENCE of any wrong-viewer class.
    private func assertTableRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        assertNoHexView(dump, label: label, file: file, line: line)
        XCTAssertFalse(hasViewClass(dump, containing: "AVPlayerView"),
            "[\(label)] Table mode: an AVPlayerView is mounted — wrong viewer", file: file, line: line)
        XCTAssertFalse(hasViewClass(dump, containing: "PDFView"),
            "[\(label)] Table mode: a PDFView is mounted — wrong viewer", file: file, line: line)
        // The grid mounts a hosting/scroll subtree; assert it isn't an empty
        // pane (some subviews present beyond the bare content root).
        let nodes = allNodes(in: dump)
        XCTAssertGreaterThan(nodes.count, 3,
            "[\(label)] Table mode: content pane looks empty (no grid subtree)", file: file, line: line)
    }

    // MARK: - Fixture generators (all in-Swift; no external tooling)

    /// A valid opaque PNG of the given pixel dimensions (real magic bytes →
    /// FileCategory.image → .preview; CGImage-backed so MediaPreviewView
    /// actually decodes + draws it).
    @discardableResult
    private func writePNGFixture(_ name: String, width: Int, height: Int) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("PNG context alloc failed")
        }
        // A simple two-tone fill so it's a real, decodable raster.
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        guard let cg = ctx.makeImage() else { throw XCTSkip("PNG makeImage failed") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("PNG encode failed")
        }
        try data.write(to: url)
        return url
    }

    /// A file with the PNG magic byte prefix but truncated/garbage body —
    /// FileCategory.image by extension+magic, but undecodable (corrupt).
    private func writeCorruptPNG(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        // PNG signature + a few junk bytes; no valid IHDR → decode fails.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33])
        try Data(bytes).write(to: url)
        return url
    }

    /// A valid minimal mono 8 kHz 16-bit PCM WAV (RIFF) — a fraction of a
    /// second of a sine tone. Hand-built header so there's no tool
    /// dependency; AVFoundation decodes it as audio.
    private func writeWAVFixture(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        let sampleRate = 8000
        let durationSamples = sampleRate / 4   // 0.25 s
        var samples = [Int16]()
        samples.reserveCapacity(durationSamples)
        for i in 0..<durationSamples {
            let t = Double(i) / Double(sampleRate)
            let v = sin(2.0 * Double.pi * 440.0 * t)
            samples.append(Int16(v * 12000))
        }
        let dataBytes = samples.withUnsafeBytes { Data($0) }
        let byteRate = sampleRate * 2          // mono, 16-bit
        var out = Data()
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        out.append(Data("RIFF".utf8))
        out.append(le32(UInt32(36 + dataBytes.count)))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(le32(16))                   // fmt chunk size
        out.append(le16(1))                    // PCM
        out.append(le16(1))                    // mono
        out.append(le32(UInt32(sampleRate)))
        out.append(le32(UInt32(byteRate)))
        out.append(le16(2))                    // block align
        out.append(le16(16))                   // bits per sample
        out.append(Data("data".utf8))
        out.append(le32(UInt32(dataBytes.count)))
        out.append(dataBytes)
        try out.write(to: url)
        return url
    }

    /// A valid 1-frame H.264 MP4, written with AVAssetWriter — entirely
    /// in-process, no ffmpeg. Small (a single 16×16 frame) but a real movie
    /// AVFoundation recognizes (FileCategory.video → .preview).
    private func writeMP4Fixture(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let w = 16, h = 16
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw XCTSkip("MP4 writer cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw XCTSkip("MP4 startWriting failed: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb)
        guard let pixelBuffer = pb else { throw XCTSkip("MP4 pixel buffer create failed") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            // Fill the frame with a solid color (ARGB = 0xFF3060A0).
            let count = CVPixelBufferGetBytesPerRow(pixelBuffer) * h
            let p = base.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < count {
                p[i] = 0xFF; p[i+1] = 0x30; p[i+2] = 0x60; p[i+3] = 0xA0
                i += 4
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: .zero)
        input.markAsFinished()

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        guard writer.status == .completed else {
            throw XCTSkip("MP4 finishWriting status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
        }
        return url
    }

    /// A valid multi-page PDF written via PDFKit — real %PDF document with
    /// drawn text, metadata Title/Author (FileCategory.pdf → .preview).
    private func writePDFFixture(_ name: String, pages: Int) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        let doc = PDFDocument()
        for n in 0..<pages {
            let pageRect = CGRect(x: 0, y: 0, width: 200, height: 260)
            let img = NSImage(size: pageRect.size)
            img.lockFocus()
            NSColor.white.setFill()
            pageRect.fill()
            let text = "Page \(n + 1) of \(pages)\nMAGIC preview fixture" as NSString
            text.draw(at: NSPoint(x: 12, y: 200),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                       .foregroundColor: NSColor.black])
            img.unlockFocus()
            if let page = PDFPage(image: img) {
                doc.insert(page, at: n)
            }
        }
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "UAT Preview Doc",
            PDFDocumentAttribute.authorAttribute: "PreviewsUAT",
        ]
        guard doc.write(to: url) else { throw XCTSkip("PDF write failed") }
        return url
    }

    /// Minimal valid empty SQLite v3 database (header + one zeroed page).
    private func writeSQLiteFixture(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        var page = Data(count: 4096)
        let magic = Array("SQLite format 3\u{0}".utf8)
        page.replaceSubrange(0..<magic.count, with: magic)
        page[16] = 0x10; page[17] = 0x00
        page[18] = 1; page[19] = 1
        page[21] = 64; page[22] = 32; page[23] = 32
        page[56] = 0; page[57] = 0; page[58] = 0; page[59] = 1
        try page.write(to: url)
        return url
    }

    /// Random high-bit bytes → unknown binary → HEX-only routing.
    private func writeRandomBinary(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        var bytes = [UInt8]()
        for i in 0..<512 { bytes.append(UInt8((i * 37 + 0x80) & 0xFF)) }
        try Data(bytes).write(to: url)
        return url
    }

    /// Binary with a known `DE AD BE EF` sequence + a `MAGIC` ASCII token,
    /// plus high-bit bytes so it routes to .binary → HEX.
    private func writeKnownBinary(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        var bytes: [UInt8] = []
        bytes.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        bytes.append(contentsOf: Array("MAGIC".utf8))
        for i in 0..<512 { bytes.append(UInt8((i * 53 + 0x90) & 0xFF)) }
        try Data(bytes).write(to: url)
        return url
    }
}
