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
        .file(path: "/Users/me/a b/notes.md", line: 12),
        .file(path: "relative/no-line.txt", line: nil),
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
        #expect(ElementRef.file(path: "a.md", line: nil).serialized == "mdv://file/a.md")
        #expect(ElementRef.file(path: "a.md", line: 3).serialized == "mdv://file/a.md?line=3")
        #expect(ElementRef.tab(id: "t1").serialized == "mdv://tab/t1")
    }

    @Test func encodingKeepsParseSafeAndIdsReadable() {
        // mdv.* ids stay human-readable (dots/alnum unescaped).
        #expect(ElementRef.ax(identifier: "mdv.hex.search.field").serialized
                == "mdv://ax/mdv.hex.search.field")
        // A path with spaces + slashes encodes so the '/'-split can't be fooled.
        let ref = ElementRef.file(path: "/a/b c/d.md", line: nil)
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
        #expect(ElementRef.file(path: "a", line: nil).axQuery == nil)
    }

    @Test func fileLineQueryParses() {
        let ref = ElementRef(parsing: "mdv://file/x.md?line=42")
        #expect(ref == .file(path: "x.md", line: 42))
        // A non-line query is ignored, not fatal.
        #expect(ElementRef(parsing: "mdv://file/x.md?foo=bar") == .file(path: "x.md", line: nil))
    }
}
