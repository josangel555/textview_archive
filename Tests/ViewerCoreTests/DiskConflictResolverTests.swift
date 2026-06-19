import XCTest
@testable import ViewerCore

/// TSK-768: three-way disk-conflict decision model. Pins the classifier
/// against every (dirty × externalEdit × unknownDiskState) permutation and the
/// three resolution intents' buffer side-effects + the undo-able revert.
final class DiskConflictResolverTests: XCTestCase {

    private func makeURL() -> URL { URL(fileURLWithPath: "/tmp/conflict.txt") }

    // MARK: - classify(dirty:hasExternalEdit:hasUnknownDiskState:)

    func test_classify_cleanProvenUnchanged_inSync() {
        XCTAssertEqual(
            DiskConflictResolver.classify(
                dirty: false, hasExternalEdit: false, hasUnknownDiskState: false),
            .inSync)
    }

    func test_classify_cleanUnknownDiskState_inSync() {
        // No edits to lose, so even an unprovable disk state is harmless.
        XCTAssertEqual(
            DiskConflictResolver.classify(
                dirty: false, hasExternalEdit: false, hasUnknownDiskState: true),
            .inSync)
    }

    func test_classify_cleanExternalEdit_safeAutoReload() {
        XCTAssertEqual(
            DiskConflictResolver.classify(
                dirty: false, hasExternalEdit: true, hasUnknownDiskState: false),
            .externalChangeNoLocalEdits)
    }

    func test_classify_dirtyExternalEdit_conflict() {
        XCTAssertEqual(
            DiskConflictResolver.classify(
                dirty: true, hasExternalEdit: true, hasUnknownDiskState: false),
            .conflict)
    }

    func test_classify_dirtyUnknownDiskState_conflictBeSafe() {
        // Can't prove disk is unchanged AND we have unsaved edits → conflict,
        // so we never silently discard work.
        XCTAssertEqual(
            DiskConflictResolver.classify(
                dirty: true, hasExternalEdit: false, hasUnknownDiskState: true),
            .conflict)
    }

    func test_classify_dirtyProvenUnchanged_inSync() {
        // Dirty buffer but disk proven unchanged: nothing diverged on disk.
        XCTAssertEqual(
            DiskConflictResolver.classify(
                dirty: true, hasExternalEdit: false, hasUnknownDiskState: false),
            .inSync)
    }

    func test_state_flags() {
        XCTAssertFalse(DiskConflictState.inSync.requiresResolution)
        XCTAssertFalse(DiskConflictState.externalChangeNoLocalEdits.requiresResolution)
        XCTAssertTrue(DiskConflictState.conflict.requiresResolution)

        XCTAssertTrue(DiskConflictState.inSync.isSafeToAutoReload)
        XCTAssertTrue(DiskConflictState.externalChangeNoLocalEdits.isSafeToAutoReload)
        XCTAssertFalse(DiskConflictState.conflict.isSafeToAutoReload)
    }

    // MARK: - classify(buffer:currentMTime:currentSize:)

    func test_classify_buffer_cleanMatchingFingerprint_inSync() {
        let buf = EditorBuffer(
            url: makeURL(), original: "abc",
            lastSavedMTime: Date(timeIntervalSince1970: 100), lastSavedSize: 3)
        XCTAssertEqual(
            DiskConflictResolver.classify(
                buffer: buf,
                currentMTime: Date(timeIntervalSince1970: 100), currentSize: 3),
            .inSync)
    }

    func test_classify_buffer_cleanChangedOnDisk_safeAutoReload() {
        let buf = EditorBuffer(
            url: makeURL(), original: "abc",
            lastSavedMTime: Date(timeIntervalSince1970: 100), lastSavedSize: 3)
        XCTAssertEqual(
            DiskConflictResolver.classify(
                buffer: buf,
                currentMTime: Date(timeIntervalSince1970: 200), currentSize: 9),
            .externalChangeNoLocalEdits)
    }

    func test_classify_buffer_dirtyChangedOnDisk_conflict() {
        var buf = EditorBuffer(
            url: makeURL(), original: "abc",
            lastSavedMTime: Date(timeIntervalSince1970: 100), lastSavedSize: 3)
        buf.setText("abc + mine")
        XCTAssertEqual(
            DiskConflictResolver.classify(
                buffer: buf,
                currentMTime: Date(timeIntervalSince1970: 200), currentSize: 9),
            .conflict)
    }

    func test_classify_buffer_dirtyNilFingerprint_conflictBeSafe() {
        // No baseline fingerprint captured (file unreadable at load) → unknown
        // disk state; a dirty buffer escalates that to conflict.
        var buf = EditorBuffer(
            url: makeURL(), original: "abc",
            lastSavedMTime: nil, lastSavedSize: nil)
        buf.setText("abc + mine")
        XCTAssertEqual(
            DiskConflictResolver.classify(buffer: buf, currentMTime: nil, currentSize: nil),
            .conflict)
    }

    // MARK: - Baseline capture

    func test_capture_recordsLastSavedBaselineNotLiveText() {
        var buf = EditorBuffer(
            url: makeURL(), original: "ancestor",
            lastSavedMTime: Date(timeIntervalSince1970: 100), lastSavedSize: 8)
        buf.setText("ancestor + my edits")
        let resolver = DiskConflictResolver(capturing: buf)
        XCTAssertEqual(resolver.baselineText, "ancestor",
                       "baseline must be the last-saved text, not the live edit")
        XCTAssertEqual(resolver.localText, "ancestor + my edits")
        XCTAssertEqual(resolver.baselineMTime, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(resolver.baselineSize, 8)
    }

    // MARK: - keepMine

    func test_keepMine_silencesWithoutCollapsingDirt() {
        var buf = EditorBuffer(
            url: makeURL(), original: "ancestor",
            lastSavedMTime: Date(timeIntervalSince1970: 100), lastSavedSize: 8)
        buf.setText("ancestor + mine")
        let resolver = DiskConflictResolver(capturing: buf)

        let diskMTime = Date(timeIntervalSince1970: 200)
        let diskSize = 42
        let out = resolver.applyKeepMine(to: buf, diskMTime: diskMTime, diskSize: diskSize)

        // Edits preserved, still dirty (baseline untouched).
        XCTAssertTrue(out.isDirty)
        XCTAssertEqual(out.text, "ancestor + mine")
        XCTAssertEqual(out.originalText, "ancestor")
        // Fingerprint advanced → the duplicate watcher event for this write
        // is now silent.
        XCTAssertFalse(out.hasExternalEdit(currentMTime: diskMTime, currentSize: diskSize))
    }

    // MARK: - takeDisk

    func test_takeDisk_replacesBufferAndRefingerprints() {
        var buf = EditorBuffer(
            url: makeURL(), original: "ancestor",
            lastSavedMTime: Date(timeIntervalSince1970: 100), lastSavedSize: 8)
        buf.setText("ancestor + mine")
        let resolver = DiskConflictResolver(capturing: buf)

        let diskText = "their external version"
        let diskMTime = Date(timeIntervalSince1970: 300)
        let diskSize = diskText.utf8.count
        let out = resolver.applyTakeDisk(
            to: buf, diskText: diskText, diskMTime: diskMTime, diskSize: diskSize)

        // Buffer now holds disk bytes and is clean.
        XCTAssertEqual(out.text, diskText)
        XCTAssertEqual(out.originalText, diskText)
        XCTAssertFalse(out.isDirty)
        // Re-fingerprinted against disk → no spurious external-edit signal.
        XCTAssertFalse(out.hasExternalEdit(currentMTime: diskMTime, currentSize: diskSize))
        XCTAssertEqual(out.lastSavedMTime, diskMTime)
        XCTAssertEqual(out.lastSavedSize, diskSize)
    }

    // MARK: - revert

    func test_revert_restoresPreConflictBaselineExactly() {
        var buf = EditorBuffer(
            url: makeURL(), original: "the original baseline text",
            lastSavedMTime: Date(timeIntervalSince1970: 100), lastSavedSize: 26)
        buf.setText("the original baseline text + a bunch of unsaved edits")
        // Capture the conflict snapshot BEFORE any further mutation.
        let resolver = DiskConflictResolver(capturing: buf)
        // Simulate the user typing even more after the conflict was captured.
        buf.setText("totally different content now")

        let reverted = resolver.applyRevert(to: buf)
        XCTAssertEqual(reverted.text, "the original baseline text",
                       "revert must restore the captured pre-conflict baseline EXACTLY")
        // Baseline equals originalText → reverting to it makes the buffer clean.
        XCTAssertEqual(reverted.originalText, "the original baseline text")
        XCTAssertFalse(reverted.isDirty)
    }

    func test_revert_isUndoableByReapplyingPriorText() {
        // The revert is a plain text replacement; "undo" = re-applying the
        // text that was present before the revert. Prove the round-trip
        // restores the user's edits byte-for-byte.
        var buf = EditorBuffer(url: makeURL(), original: "base")
        buf.setText("base + edits the user wants back after undo")
        let preRevertText = buf.text
        let resolver = DiskConflictResolver(capturing: buf)

        var reverted = resolver.applyRevert(to: buf)
        XCTAssertEqual(reverted.text, "base")
        // Undo the revert.
        reverted.setText(preRevertText)
        XCTAssertEqual(reverted.text, "base + edits the user wants back after undo")
    }

    func test_intent_rawValues_stable() {
        // Guard against accidental case renames breaking persisted/bridged use.
        XCTAssertEqual(DiskConflictIntent.keepMine.rawValue, "keepMine")
        XCTAssertEqual(DiskConflictIntent.takeDisk.rawValue, "takeDisk")
        XCTAssertEqual(DiskConflictIntent.merge.rawValue, "merge")
    }
}
