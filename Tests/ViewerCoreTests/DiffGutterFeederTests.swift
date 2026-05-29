import XCTest
@testable import ViewerCore

/// Pins the unified-diff → CM6 `setGutterMarkers` payload transform.
///
/// The deterministic, host-runnable kernel that backs the CM6 editor's
/// diff/blame gutter feed. Verifies the wire vocabulary the JS bundle's
/// `applySetGutterMarkers` understands (`"added"|"modified"|"removed"`)
/// and the line-ordering / dedup invariants the CM6 view relies on for
/// its `lastSentGutterMarkers` no-op check.
final class DiffGutterFeederTests: XCTestCase {

    // MARK: - kindString mapping

    func test_kindString_maps_added_modified_deleted_to_wire_vocabulary() {
        // Producer side must use the literal strings the JS bundle's
        // `applySetGutterMarkers` switches on. "removed" (not "deleted")
        // is intentional — see DiffGutterFeeder.Kind.
        XCTAssertEqual(DiffGutterFeeder.kindString(for: .added), "added")
        XCTAssertEqual(DiffGutterFeeder.kindString(for: .modified), "modified")
        XCTAssertEqual(DiffGutterFeeder.kindString(for: .deleted), "removed")
    }

    // MARK: - markers(from: [Int: DiffMark])

    func test_empty_marks_yields_empty_markers() {
        XCTAssertEqual(DiffGutterFeeder.markers(from: [:]), [])
    }

    func test_marks_dict_produces_sorted_markers() {
        // Sort order matters: CodeMirrorEditorView dedupes with
        // Array == on the marker payload. Unstable ordering from the
        // dict iteration would cause spurious re-dispatches.
        let marks: [Int: DiffMark] = [
            7: .modified,
            2: .added,
            14: .deleted,
            1: .added,
        ]
        let out = DiffGutterFeeder.markers(from: marks)
        XCTAssertEqual(out, [
            CMGutterMarker(line: 1, kind: "added"),
            CMGutterMarker(line: 2, kind: "added"),
            CMGutterMarker(line: 7, kind: "modified"),
            CMGutterMarker(line: 14, kind: "removed"),
        ])
    }

    func test_marks_dict_emits_no_tooltip() {
        // Diff bars don't carry hover text — that's a blame feed
        // concern. Producer must leave tooltip nil so the codec
        // omits the field (CMBridgeV2Tests pins that omission).
        let out = DiffGutterFeeder.markers(from: [3: .added])
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].tooltip)
    }

    // MARK: - markers(fromDiff: String) — end-to-end transform

    func test_pure_addition_diff_emits_added_markers() {
        let diff = """
        @@ -0,0 +1,3 @@
        +alpha
        +beta
        +gamma
        """
        XCTAssertEqual(DiffGutterFeeder.markers(fromDiff: diff), [
            CMGutterMarker(line: 1, kind: "added"),
            CMGutterMarker(line: 2, kind: "added"),
            CMGutterMarker(line: 3, kind: "added"),
        ])
    }

    func test_modification_diff_emits_modified_marker_on_new_line() {
        // `-old` + `+new` on adjacent lines collapses to .modified
        // on the new-side line, per DiffHunkParser semantics.
        let diff = """
        @@ -1,3 +1,3 @@
         alpha
        -beta
        +bravo
         gamma
        """
        let out = DiffGutterFeeder.markers(fromDiff: diff)
        XCTAssertEqual(out, [CMGutterMarker(line: 2, kind: "modified")])
    }

    func test_deletion_diff_emits_removed_marker_on_following_line() {
        // A bare `-` (no following `+`) lands on the next existing
        // line in the new file. The marker is "removed" so the JS
        // side renders the thin upward tick.
        let diff = """
        @@ -1,3 +1,2 @@
         alpha
        -beta
         gamma
        """
        let out = DiffGutterFeeder.markers(fromDiff: diff)
        XCTAssertEqual(out, [CMGutterMarker(line: 2, kind: "removed")])
    }

    func test_multi_hunk_diff_keeps_lines_sorted_across_hunks() {
        // The second hunk's lines come after the first numerically;
        // sorted output is required for the dedup invariant.
        let diff = """
        @@ -1,2 +1,2 @@
         a
        -b
        +B
        @@ -10,2 +10,2 @@
         x
        -y
        +Y
        """
        let out = DiffGutterFeeder.markers(fromDiff: diff)
        XCTAssertEqual(out, [
            CMGutterMarker(line: 2, kind: "modified"),
            CMGutterMarker(line: 11, kind: "modified"),
        ])
    }

    func test_mixed_add_modify_delete_in_one_hunk() {
        // Synthetic realistic diff: one addition, one modification,
        // one deletion. Pins the producer end-to-end.
        // New-side line walk:
        //   line 1 = " keep"     (context)
        //   line 2 = "+new line" (paired with -old line → modified)
        //   line 3 = " context"  (context)
        //   line 4 = " tail"     (context, but flagged removed by the
        //                         preceding bare `-removed` deletion)
        //   line 5 = "+tacked-on" (added)
        let diff = """
        @@ -1,5 +1,5 @@
         keep
        -old line
        +new line
         context
        -removed
         tail
        +tacked-on
        """
        let out = DiffGutterFeeder.markers(fromDiff: diff)
        XCTAssertEqual(out, [
            CMGutterMarker(line: 2, kind: "modified"),
            CMGutterMarker(line: 4, kind: "removed"),
            CMGutterMarker(line: 5, kind: "added"),
        ])
    }

    func test_empty_diff_string_yields_empty_payload() {
        // Clean file (no diff against HEAD) → no markers. The Swift
        // side ships an empty array, which the JS bundle treats as
        // "clear all markers for this file".
        XCTAssertEqual(DiffGutterFeeder.markers(fromDiff: ""), [])
    }

    func test_metadata_only_diff_yields_empty_payload() {
        // Binary-file change reports have headers but no hunks.
        // Producer must surface zero markers — not crash, not emit
        // garbage entries for the index/binary lines.
        let diff = """
        diff --git a/blob.bin b/blob.bin
        index abc..def 100644
        Binary files a/blob.bin and b/blob.bin differ
        """
        XCTAssertEqual(DiffGutterFeeder.markers(fromDiff: diff), [])
    }

    // MARK: - Dedup invariant

    func test_two_equal_diffs_produce_equal_marker_arrays() {
        // The CodeMirrorEditorView short-circuits a dispatch when the
        // new marker array == the last-sent one. That depends on this
        // function being a pure deterministic mapping.
        let diff = """
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        """
        let a = DiffGutterFeeder.markers(fromDiff: diff)
        let b = DiffGutterFeeder.markers(fromDiff: diff)
        XCTAssertEqual(a, b)
    }
}
