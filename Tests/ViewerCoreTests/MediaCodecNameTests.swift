import XCTest
@testable import ViewerCore

/// TSK-348 — the pure FourCC→codec-name mapping behind the file-info "Video
/// codec" / "Audio codec" rows. The AVAsset extraction just hands us the
/// subtype FourCC; this maps it to a friendly name (host-testable).
final class MediaCodecNameTests: XCTestCase {

    private func name(_ tag: String) -> String {
        MediaCodecName.display(fourCC: MediaCodecName.code(tag))
    }

    func test_knownVideoCodecs() {
        XCTAssertEqual(name("avc1"), "H.264")
        XCTAssertEqual(name("hvc1"), "HEVC")
        XCTAssertEqual(name("hev1"), "HEVC")
        XCTAssertEqual(name("vp09"), "VP9")
        XCTAssertEqual(name("av01"), "AV1")
        XCTAssertEqual(name("apcn"), "ProRes")
    }

    func test_knownAudioCodecs() {
        XCTAssertEqual(name("mp4a"), "AAC")
        XCTAssertEqual(name("aac "), "AAC")
        XCTAssertEqual(name(".mp3"), "MP3")
        XCTAssertEqual(name("alac"), "ALAC")
        XCTAssertEqual(name("lpcm"), "Linear PCM")
        XCTAssertEqual(name("opus"), "Opus")
    }

    func test_unknownCodec_fallsBackToTrimmedTag() {
        XCTAssertEqual(name("Qt99"), "Qt99")
        // Trailing-space unknown tag is trimmed (not shown as "xyz ").
        XCTAssertEqual(name("xyz "), "xyz")
    }

    func test_tag_decodesBigEndianFourCC() {
        // 'avc1' = 0x61766331.
        XCTAssertEqual(MediaCodecName.tag(0x6176_6331), "avc1")
        XCTAssertEqual(MediaCodecName.code("avc1"), 0x6176_6331)
    }

    func test_tag_nonPrintableBytesRenderAsQuestionMark() {
        // 0x00000000 → four NULs → "????".
        XCTAssertEqual(MediaCodecName.tag(0), "????")
    }

    func test_code_tag_roundTrip() {
        for t in ["avc1", "mp4a", "hvc1", "vp09", "ac-3"] {
            XCTAssertEqual(MediaCodecName.tag(MediaCodecName.code(t)), t)
        }
    }
}
