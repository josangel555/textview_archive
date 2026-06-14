import XCTest
@testable import ViewerCore

/// TSK-807 — the Audio tag rows (Title/Artist/Album/Year) for the file-info
/// panel, built from AVMetadata common-key pairs. Pure; host-safe.
final class AudioMetadataRowsTests: XCTestCase {

    private func rows(_ pairs: [(String, String?)]) -> [AudioMetadataRows.Row] {
        AudioMetadataRows.build(common: pairs.map { (key: $0.0, value: $0.1) })
    }

    func test_mapsKnownKeys_inFixedOrder() {
        // Input order is scrambled; output is always Title, Artist, Album, Year.
        let r = rows([("albumName", "Reload"), ("title", "Track"),
                      ("creationDate", "2014"), ("artist", "Tool")])
        XCTAssertEqual(r, [
            AudioMetadataRows.Row("Title", "Track"),
            AudioMetadataRows.Row("Artist", "Tool"),
            AudioMetadataRows.Row("Album", "Reload"),
            AudioMetadataRows.Row("Year", "2014"),
        ])
    }

    func test_omitsEmptyWhitespaceAndNil_andUnknownKeys() {
        let r = rows([("title", "  "), ("artist", nil), ("albumName", "Solid"),
                      ("genre", "Rock"), ("composer", "X")])  // genre/composer unknown
        XCTAssertEqual(r, [AudioMetadataRows.Row("Album", "Solid")],
                       "blank title, nil artist, and unknown keys are dropped")
    }

    func test_creationDate_rendersYearOnly() {
        XCTAssertEqual(rows([("creationDate", "2021-05-01T09:00:00Z")]),
                       [AudioMetadataRows.Row("Year", "2021")])
        XCTAssertEqual(rows([("creationDate", "1999")]),
                       [AudioMetadataRows.Row("Year", "1999")])
        // A non-date value passes through unchanged.
        XCTAssertEqual(rows([("creationDate", "Spring")]),
                       [AudioMetadataRows.Row("Year", "Spring")])
    }

    func test_firstValueWinsForRepeatedKey() {
        XCTAssertEqual(rows([("title", "First"), ("title", "Second")]),
                       [AudioMetadataRows.Row("Title", "First")])
    }

    func test_emptyInput_isEmpty() {
        XCTAssertTrue(rows([]).isEmpty)
    }

    func test_yearOnly_helper() {
        XCTAssertEqual(AudioMetadataRows.yearOnly("2021"), "2021")
        XCTAssertEqual(AudioMetadataRows.yearOnly("2021-05-01"), "2021")
        XCTAssertEqual(AudioMetadataRows.yearOnly("abcd"), "abcd")   // not digits
        XCTAssertEqual(AudioMetadataRows.yearOnly("20"), "20")        // too short
    }
}
