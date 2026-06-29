import XCTest
import AVFoundation
@testable import ViewerUI

/// TSK-1308 — the persistent audio player (survives session/tab-switch teardown).
/// Pins the model contract the AudioPlayerHost binding relies on: the SAME URL reuses
/// the live player (no playback yank on re-mount), a DIFFERENT URL replaces it, and
/// the player is retained by the controller (so it outlives the requesting view).
/// The on-screen "audio keeps playing across the switch" is the owner/VM tail.
@MainActor
final class AudioPlaybackControllerTests: XCTestCase {

    func test_player_reusesForSameURL_replacesForDifferent() {
        let c = AudioPlaybackController()
        let a = URL(fileURLWithPath: "/tmp/mdv-audio-a.m4a")
        let b = URL(fileURLWithPath: "/tmp/mdv-audio-b.m4a")

        let pa1 = c.player(for: a)
        let pa2 = c.player(for: a)
        XCTAssertTrue(pa1 === pa2, "same URL reuses the live player (no re-mount playback yank)")
        XCTAssertEqual(c.currentURL, a)
        XCTAssertTrue(c.activePlayer === pa1, "controller retains the player → it outlives the view")

        let pb = c.player(for: b)
        XCTAssertFalse(pb === pa1, "a different URL replaces the player")
        XCTAssertEqual(c.currentURL, b)
        XCTAssertTrue(c.activePlayer === pb)
    }

    func test_sharedSingleton_isStable() {
        XCTAssertTrue(AudioPlaybackController.shared === AudioPlaybackController.shared)
    }
}
