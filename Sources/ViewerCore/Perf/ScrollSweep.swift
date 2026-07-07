import Foundation

/// Pure scroll schedule for the `scroll-sweep` profiling verb (TSK-891,
/// Page-Up/Page-Down jank). Mirrors `ResizeSweep`/`NavSweep`: the profiler
/// needs the view to scroll CONTINUOUSLY in PAGE-SIZED jumps while the trace
/// records — so the whole sweep runs inside one verb and this type owns the
/// schedule (which top-line to jump to at each tick). The AppKit/CM6 side
/// (scroll to the line per tick) is the render tail; the trace itself runs
/// on the VM profiling lane. Pure + host-testable so the schedule is pinned
/// before a measured mitigation lands (owner's measure-don't-guess rule).
public enum ScrollSweep {

    /// The 1-based top LINE to scroll to at tick `i` of `steps`, page-jumping
    /// across a `totalLines` document with a `pageLines`-sized viewport.
    ///
    /// The sweep pages DOWN from the top to the last full page, then pages
    /// back UP — a triangle wave in PAGE units so both Page-Down and Page-Up
    /// (the janky direction) are exercised every cycle. Endpoints are the
    /// first line and the last page-aligned top. Degenerate inputs clamp
    /// (no trap): a document shorter than one page holds at line 1.
    public static func topLine(
        at i: Int, totalLines: Int, pageLines: Int, steps: Int
    ) -> Int {
        let lines = max(1, totalLines)
        let page = max(1, pageLines)
        // Last page-aligned top line (1-based): the top that shows the final
        // page without overscrolling. When the doc is ≤ one page, it's 1.
        let lastTop = max(1, lines - page + 1)
        guard steps >= 1, lastTop > 1 else { return 1 }

        // Number of whole pages between the first and last top.
        let pages = max(1, (lastTop - 1 + page - 1) / page)   // ceil((lastTop-1)/page)
        // Triangle position in [0, 2*pages]; fold to [0, pages].
        let cyc = 2 * pages
        let pos = ((i % cyc) + cyc) % cyc
        let pageIndex = pos <= pages ? pos : cyc - pos
        let top = 1 + pageIndex * page
        return min(top, lastTop)
    }

    /// The full schedule of top lines for a `steps`-tick sweep (tick 0…steps).
    public static func schedule(
        totalLines: Int, pageLines: Int, steps: Int
    ) -> [Int] {
        guard steps >= 1 else { return [1] }
        return (0...steps).map {
            topLine(at: $0, totalLines: totalLines, pageLines: pageLines, steps: steps)
        }
    }
}
