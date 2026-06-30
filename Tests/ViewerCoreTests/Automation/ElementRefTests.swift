import Foundation
import Testing
@testable import ViewerCore

/// TSK-1256 slice 1 — host coverage for the shareable element-reference model:
/// serialize ⇄ parse round-trips, malformed-input rejection (a pasted ref is
/// untrusted), percent-encoding safety (paths/selectors can't break the parse),
/// and the AX-driver bridge.
struct ElementRefTests {

    private static let samples: [ElementRef] = [
        .ax(identifier: "mdv.hexView"),
        .ax(identifier: "mdv.csvFind.field"),
        .webLine(docId: "doc-42", line: 137),
        .webSelector(docId: "doc-42", selector: ".cm-line:nth-child(3) > span.tok-keyword"),
        .file(path: "/Users/me/a b/notes.md", line: 12, endLine: nil),
        .file(path: "relative/no-line.txt", line: nil, endLine: nil),
        .file(path: "span.md", line: 5, endLine: 12),
        .tab(id: "tab-7"),
    ]

    @Test func roundTripsAllVariants() throws {
        for ref in Self.samples {
            let s = ref.serialized
            let back = ElementRef(parsing: s)
            #expect(back == ref, "round-trip failed for \(ref): serialized=\(s) parsed=\(String(describing: back))")
        }
    }

    @Test func serializedFormsAreStable() {
        #expect(ElementRef.ax(identifier: "mdv.hexView").serialized == "mdv://ax/mdv.hexView")
        #expect(ElementRef.webLine(docId: "d1", line: 9).serialized == "mdv://web/d1/line/9")
        #expect(ElementRef.file(path: "a.md", line: nil, endLine: nil).serialized == "mdv://file/a.md")
        #expect(ElementRef.file(path: "a.md", line: 3, endLine: nil).serialized == "mdv://file/a.md?line=3")
        #expect(ElementRef.tab(id: "t1").serialized == "mdv://tab/t1")
    }

    @Test func encodingKeepsParseSafeAndIdsReadable() {
        // mdv.* ids stay human-readable (dots/alnum unescaped).
        #expect(ElementRef.ax(identifier: "mdv.hex.search.field").serialized
                == "mdv://ax/mdv.hex.search.field")
        // A path with spaces + slashes encodes so the '/'-split can't be fooled.
        let ref = ElementRef.file(path: "/a/b c/d.md", line: nil, endLine: nil)
        #expect(!ref.serialized.dropFirst("mdv://file/".count).contains("/"))
        #expect(ElementRef(parsing: ref.serialized) == ref)
    }

    @Test(arguments: [
        "",
        "http://ax/mdv.hexView",          // wrong scheme
        "mdv://",                          // empty
        "mdv://bogus/x",                   // unknown host
        "mdv://ax/",                       // missing id
        "mdv://web/d/line/notanumber",     // bad line
        "mdv://web/d/line/0",              // line must be >= 1
        "mdv://web/d/zzz/v",               // unknown web kind
        "mdv://web/d/sel/",                // empty selector
        "mdv://tab/",                      // missing id
    ])
    func rejectsMalformed(_ bad: String) {
        #expect(ElementRef(parsing: bad) == nil, "should reject \(bad)")
    }

    @Test func axRefBridgesToAXQuery() {
        let q = ElementRef.ax(identifier: "mdv.tab.*").axQuery
        #expect(q?.match == .prefix)
        #expect(q?.matches("mdv.tab.dirtyDot") == true)
        // Non-AX refs have no AX query.
        #expect(ElementRef.webLine(docId: "d", line: 1).axQuery == nil)
        #expect(ElementRef.file(path: "a", line: nil, endLine: nil).axQuery == nil)
    }

    @Test func fileLineQueryParses() {
        let ref = ElementRef(parsing: "mdv://file/x.md?line=42")
        #expect(ref == .file(path: "x.md", line: 42, endLine: nil))
        // A non-line query is ignored, not fatal.
        #expect(ElementRef(parsing: "mdv://file/x.md?foo=bar") == .file(path: "x.md", line: nil, endLine: nil))
    }

    // TSK-942: a file LINE-RANGE reference (a selected span) serializes with both
    // line + endLine, round-trips, and resolves by revealing the START line.
    @Test func fileLineRangeSerializesRoundTripsAndResolvesToStart() {
        let ranged = ElementRef.file(path: "x.md", line: 10, endLine: 20)
        #expect(ranged.serialized == "mdv://file/x.md?line=10&endLine=20")
        #expect(ElementRef(parsing: ranged.serialized) == ranged)
        #expect(ranged.resolution == .openFile(path: "x.md", line: 10))
        // endLine is never emitted without a start line.
        #expect(ElementRef.file(path: "x.md", line: nil, endLine: 9).serialized == "mdv://file/x.md")
    }

    // TSK-1256 slice 2 — the resolver plan: every ref kind maps to exactly one
    // typed ElementResolution, carrying its params; the resolution survives a
    // serialize→parse round-trip (what an agent pastes resolves to the same action).
    @Test func resolutionMapsEveryKind() {
        #expect(ElementRef.ax(identifier: "mdv.hexView").resolution
                == .activateAX(AXQuery("mdv.hexView")))
        #expect(ElementRef.webLine(docId: "d1", line: 9).resolution
                == .gotoWebLine(docId: "d1", line: 9))
        #expect(ElementRef.webSelector(docId: "d1", selector: ".cm-line").resolution
                == .selectWebNode(docId: "d1", selector: ".cm-line"))
        #expect(ElementRef.file(path: "a.md", line: 3, endLine: nil).resolution
                == .openFile(path: "a.md", line: 3))
        #expect(ElementRef.file(path: "a.md", line: nil, endLine: nil).resolution
                == .openFile(path: "a.md", line: nil))
        #expect(ElementRef.tab(id: "t1").resolution == .selectTab(id: "t1"))
    }

    @Test func resolutionSurvivesRoundTrip() {
        for ref in Self.samples {
            let parsed = ElementRef(parsing: ref.serialized)
            #expect(parsed?.resolution == ref.resolution, "resolution drift for \(ref)")
        }
    }

    // TSK-1256 slice 3 — the executor dispatches each ref to exactly one target
    // action with the right params (a regression to the wrong action fails here),
    // and forwards the target's success flag.
    private final class RecordingTarget: ElementRefTarget {
        var calls: [String] = []
        let succeed: Bool
        init(succeed: Bool = true) { self.succeed = succeed }
        func selectTab(id: String) -> Bool { calls.append("selectTab:\(id)"); return succeed }
        func openFile(path: String, line: Int?) -> Bool {
            calls.append("openFile:\(path):\(line.map(String.init) ?? "nil")"); return succeed
        }
        func gotoWebLine(docId: String, line: Int) -> Bool {
            calls.append("gotoWebLine:\(docId):\(line)"); return succeed
        }
        func selectWebNode(docId: String, selector: String) -> Bool {
            calls.append("selectWebNode:\(docId):\(selector)"); return succeed
        }
        func activateAX(_ query: AXQuery) -> Bool { calls.append("activateAX:\(query.stem)"); return succeed }
    }

    @Test func executorDispatchesEachKindToTheRightTargetCall() {
        let t = RecordingTarget()
        ElementRefExecutor.execute(.tab(id: "t1"), on: t)
        ElementRefExecutor.execute(.webLine(docId: "d", line: 5), on: t)
        ElementRefExecutor.execute(.file(path: "a.md", line: 3, endLine: nil), on: t)
        ElementRefExecutor.execute(.file(path: "b.md", line: nil, endLine: nil), on: t)
        ElementRefExecutor.execute(.ax(identifier: "mdv.hexView"), on: t)
        ElementRefExecutor.execute(.webSelector(docId: "d", selector: ".cm-line"), on: t)
        #expect(t.calls == [
            "selectTab:t1",
            "gotoWebLine:d:5",
            "openFile:a.md:3",
            "openFile:b.md:nil",
            "activateAX:mdv.hexView",
            "selectWebNode:d:.cm-line",
        ])
    }

    @Test func executorForwardsTargetSuccessFlag() {
        #expect(ElementRefExecutor.execute(.tab(id: "x"), on: RecordingTarget(succeed: true)) == true)
        #expect(ElementRefExecutor.execute(.tab(id: "x"), on: RecordingTarget(succeed: false)) == false)
    }
}
