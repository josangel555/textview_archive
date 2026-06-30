import XCTest
import AppKit
import SwiftUI
import AVKit
@testable import ViewerUI

/// TSK-1308 — render-validation that audio survives a session/tab switch (user bug: "switching
/// session stops music"). The fix moved player ownership to an app-level
/// AudioPlaybackController.shared (host-tested: reuse-same-URL / replace-on-change / outlives the
/// view). This proves the VIEW half: hosting AudioPlayerHost binds the AVPlayerView to the shared
/// controller's player (so the controller registers the URL), and that player SURVIVES tearing the
/// host down — exactly the session-switch scenario.
///
/// `#192`-gated (VM GUI lane — SwiftUI realizes the representable + calls makeNSView there).
@MainActor
final class AudioPlayerHostIntegrationTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_audioHost_bindsToPersistentController_andSurvivesTeardown_TSK1308() async throws {
        // A unique URL (need not exist — AVPlayer is lazy and player(for:) just creates it).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsk1308-\(UUID().uuidString).mp3")

        let host = NSHostingView(rootView: AudioPlayerHost(url: url))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 90)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        // Hosting → makeNSView → AudioPlaybackController.shared.player(for: url) → the controller
        // registers the URL + holds the player. If the view owned its OWN player (the bug), the
        // shared controller would not reflect this URL.
        XCTAssertEqual(AudioPlaybackController.shared.currentURL, url,
            "the audio view must bind to the app-level persistent controller (TSK-1308)")
        XCTAssertNotNil(AudioPlaybackController.shared.activePlayer,
            "the persistent controller must hold the active player")
        let playerBefore = AudioPlaybackController.shared.activePlayer

        // Tear the host down (simulate the session/tab switch that used to deallocate the player).
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()

        // The player SURVIVES — the whole point of the fix.
        XCTAssertEqual(AudioPlaybackController.shared.currentURL, url,
            "the registered URL must survive view teardown (the session-switch fix)")
        XCTAssertNotNil(AudioPlaybackController.shared.activePlayer,
            "the player must still be alive after the view is gone (music keeps playing)")
        XCTAssertTrue(AudioPlaybackController.shared.activePlayer === playerBefore,
            "the SAME player instance must survive (no yank/replace on teardown)")
    }
}
