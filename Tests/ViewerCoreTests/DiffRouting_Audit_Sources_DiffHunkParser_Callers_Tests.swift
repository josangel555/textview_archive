import XCTest
@testable import ViewerCore

/// TSK-561 routing guard, now post-twin-deletion (TSK-649 Stage B #4). The audit
/// originally found the rust `hunk_marks` engine was DEAD CODE because callers
/// invoked the Swift `DiffHunkParser` directly, bypassing `RustDiffAdapter`. The
/// Swift twins are now DELETED, so the bypass is structurally impossible — only
/// the behavior pin remains: the routed feeder output equals the adapter's marks,
/// i.e. `DiffGutterFeeder.markers(fromDiff:)` goes through `RustDiffAdapter`.
final class DiffRouting_Audit_Sources_DiffHunkParser_Callers_Tests: XCTestCase {

    func test_gutterFeeder_convenience_matchesTheRoutedAdapterMarks() {
        let diff = """
        diff --git a/f.txt b/f.txt
        index 0000000..1111111 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,4 @@
         keep
        -old
        +new
        +added
         tail
        """
        let viaFeeder = DiffGutterFeeder.markers(fromDiff: diff)
        let viaAdapter = DiffGutterFeeder.markers(from: RustDiffAdapter.hunkMarks(diff))
        XCTAssertEqual(viaFeeder, viaAdapter,
                       "markers(fromDiff:) must be exactly the routed adapter result")
        XCTAssertFalse(viaFeeder.isEmpty, "fixture must produce marks — an empty "
                       + "result would make the equality vacuous")
    }
}
