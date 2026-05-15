import XCTest
@testable import ViewerKit

/// Smoke tests for the new media-category detection so a future
/// rename or extension-drop is caught.
final class FileCategoryMediaTests: XCTestCase {

    private func cat(_ name: String) -> FileCategory {
        FileTypeDetector.category(for: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testImageExtensionsDetected() {
        XCTAssertEqual(cat("photo.png"),  .image)
        XCTAssertEqual(cat("photo.jpg"),  .image)
        XCTAssertEqual(cat("photo.jpeg"), .image)
        XCTAssertEqual(cat("photo.gif"),  .image)
        XCTAssertEqual(cat("photo.heic"), .image)
        XCTAssertEqual(cat("photo.tiff"), .image)
        XCTAssertEqual(cat("photo.webp"), .image)
        XCTAssertEqual(cat("icon.icns"),  .image)
        XCTAssertEqual(cat("logo.svg"),   .image)
    }

    func testAudioExtensionsDetected() {
        XCTAssertEqual(cat("track.mp3"),  .audio)
        XCTAssertEqual(cat("track.m4a"),  .audio)
        XCTAssertEqual(cat("track.wav"),  .audio)
        XCTAssertEqual(cat("track.flac"), .audio)
        XCTAssertEqual(cat("track.aiff"), .audio)
    }

    func testVideoExtensionsDetected() {
        XCTAssertEqual(cat("clip.mp4"),  .video)
        XCTAssertEqual(cat("clip.mov"),  .video)
        XCTAssertEqual(cat("clip.mkv"),  .video)
        XCTAssertEqual(cat("clip.webm"), .video)
    }

    func testPDFDetected() {
        XCTAssertEqual(cat("doc.pdf"), .pdf)
    }

    func testSQLiteDetected() {
        XCTAssertEqual(cat("data.sqlite"),  .sqlite)
        XCTAssertEqual(cat("data.sqlite3"), .sqlite)
        XCTAssertEqual(cat("data.db"),      .sqlite)
        XCTAssertEqual(cat("data.db3"),     .sqlite)
    }

    func testMarkdownStillDetected() {
        // Make sure adding media types didn't accidentally redirect
        // markdown / code / plaintext.
        XCTAssertEqual(cat("readme.md"),    .markdown)
        XCTAssertEqual(cat("script.swift"), .code)
        XCTAssertEqual(cat("note.txt"),     .plainText)
    }

    func testUppercaseExtensionsAlsoMatch() {
        XCTAssertEqual(cat("PHOTO.PNG"), .image)
        XCTAssertEqual(cat("CLIP.MP4"),  .video)
    }
}
