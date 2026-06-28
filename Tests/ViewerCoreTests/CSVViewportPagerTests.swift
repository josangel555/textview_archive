import Testing
@testable import ViewerCore

/// Host coverage for the CSV viewport-paging window decision (TSK-1139). The
/// scroll → fetch → render wiring is the VM tail; this is the host-validated
/// core — the "which window, refetch or not" math the scroll handler delegates to.
struct CSVViewportPagerTests {

    @Test func noCache_fetchesVisiblePlusBuffer() {
        let pager = CSVViewportPager(bufferRows: 50)
        let p = pager.plan(filteredCount: 10_000, firstVisibleRow: 1000,
                           visibleRowCount: 30, cached: nil)
        #expect(p.needsFetch)
        #expect(p.offset == 950)            // 1000 - 50 buffer
        #expect(p.limit == 130)             // [950, 1029+1+50) = [950, 1080)
    }

    @Test func visibleWithinCache_noFetch() {
        let pager = CSVViewportPager(bufferRows: 50)
        let cached = CSVViewportPager.CachedWindow(offset: 950, count: 130) // [950,1080)
        // Small scroll — still inside the cached span: no refetch.
        let p = pager.plan(filteredCount: 10_000, firstVisibleRow: 1010,
                           visibleRowCount: 30, cached: cached)
        #expect(!p.needsFetch)
        #expect(p.offset == 950)
        #expect(p.limit == 130)
    }

    @Test func visibleEscapesCacheBelow_refetches() {
        let pager = CSVViewportPager(bufferRows: 50)
        let cached = CSVViewportPager.CachedWindow(offset: 950, count: 130) // [950,1080)
        // last = 1089 ≥ cache upper 1080 → escaped → refetch.
        let p = pager.plan(filteredCount: 10_000, firstVisibleRow: 1060,
                           visibleRowCount: 30, cached: cached)
        #expect(p.needsFetch)
        #expect(p.offset == 1010)           // 1060 - 50
    }

    @Test func visibleEscapesCacheAbove_refetches() {
        let pager = CSVViewportPager(bufferRows: 50)
        let cached = CSVViewportPager.CachedWindow(offset: 950, count: 130) // [950,1080)
        // first = 900 < cache offset 950 → escaped → refetch.
        let p = pager.plan(filteredCount: 10_000, firstVisibleRow: 900,
                           visibleRowCount: 30, cached: cached)
        #expect(p.needsFetch)
        #expect(p.offset == 850)
    }

    @Test func clampsAtTop() {
        let pager = CSVViewportPager(bufferRows: 50)
        let p = pager.plan(filteredCount: 10_000, firstVisibleRow: 10,
                           visibleRowCount: 30, cached: nil)
        #expect(p.offset == 0)              // max(0, 10-50) — no negative offset
        #expect(p.needsFetch)
    }

    @Test func clampsAtBottom() {
        let pager = CSVViewportPager(bufferRows: 50)
        let p = pager.plan(filteredCount: 1000, firstVisibleRow: 980,
                           visibleRowCount: 30, cached: nil)
        #expect(p.offset == 930)            // 980 - 50
        #expect(p.offset + p.limit == 1000) // upper clamped to filteredCount
    }

    @Test func clampsFirstVisibleBeyondFilteredSet() {
        // A filter shrank the surviving set below the prior scroll position.
        let pager = CSVViewportPager(bufferRows: 10)
        let p = pager.plan(filteredCount: 100, firstVisibleRow: 5000,
                           visibleRowCount: 30, cached: nil)
        #expect(p.offset == 89)             // firstVisible clamped to 99, -10 buffer
        #expect(p.offset + p.limit == 100)
        #expect(p.needsFetch)
    }

    @Test func zeroBuffer_fetchesExactVisible() {
        let pager = CSVViewportPager(bufferRows: 0)
        let p = pager.plan(filteredCount: 10_000, firstVisibleRow: 1000,
                           visibleRowCount: 30, cached: nil)
        #expect(p.offset == 1000)
        #expect(p.limit == 30)
    }

    @Test func emptyFilteredSet_noFetch() {
        let p = CSVViewportPager().plan(filteredCount: 0, firstVisibleRow: 0,
                                        visibleRowCount: 30, cached: nil)
        #expect(!p.needsFetch)
        #expect(p.limit == 0)
    }

    @Test func noVisibleRows_noFetch() {
        let p = CSVViewportPager().plan(filteredCount: 1000, firstVisibleRow: 0,
                                        visibleRowCount: 0, cached: nil)
        #expect(!p.needsFetch)
        #expect(p.limit == 0)
    }

    @Test func negativeBufferClampedToZero() {
        #expect(CSVViewportPager(bufferRows: -5).bufferRows == 0)
    }
}
