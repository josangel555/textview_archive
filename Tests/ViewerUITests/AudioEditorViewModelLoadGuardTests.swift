import XCTest
@testable import ViewerUI

/// TSK-993: `AudioEditorViewModel.load()` must not double-decode when called
/// re-entrantly (e.g. onAppear firing twice). `beginDecodeIfIdle()` is the
/// guard — only one decode runs at a time; a second concurrent call is a no-op.
@MainActor
final class AudioEditorViewModelLoadGuardTests: XCTestCase {

    func test_load_reentrancyGuard_blocksConcurrentDecode() {
        let vm = AudioEditorViewModel(url: URL(fileURLWithPath: "/nonexistent.wav"))
        XCTAssertTrue(vm.beginDecodeIfIdle(), "idle → claims the decode slot")
        XCTAssertFalse(vm.beginDecodeIfIdle(), "in-flight → blocked (no duplicate decode)")
        vm.endDecode()
        XCTAssertTrue(vm.beginDecodeIfIdle(), "after endDecode → the slot is free again")
    }
}
