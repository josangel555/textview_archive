import XCTest
@testable import ViewerCore

/// Coverage for the `.dot`/Graphviz parser model core (TSK-290 phase 1).
/// Exercises the documented common subset; the layout/render is a separate
/// (VM/dep) phase, so these pin only the parsed STRUCTURE.
final class DotGraphTests: XCTestCase {

    func test_simpleDigraph_directedNameNodesEdge() {
        let g = DotGraphParser.parse("digraph G { a -> b }")
        XCTAssertEqual(g?.isDirected, true)
        XCTAssertEqual(g?.name, "G")
        XCTAssertEqual(g?.nodes, ["a", "b"])
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b")])
    }

    func test_undirectedGraph_notDirected() {
        let g = DotGraphParser.parse("graph { a -- b }")
        XCTAssertEqual(g?.isDirected, false)
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b")])
    }

    func test_edgeChain_expandsToConsecutivePairs() {
        let g = DotGraphParser.parse("digraph { a -> b -> c }")
        XCTAssertEqual(g?.nodes, ["a", "b", "c"])
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b"),
                                  DotEdge(from: "b", to: "c")])
    }

    func test_nodeStatements_withAttrList_skipsAttrsRecordsNode() {
        let g = DotGraphParser.parse("""
        digraph {
          a [color=red, shape=box];
          b;
          a -> b [label="x"];
        }
        """)
        XCTAssertEqual(g?.nodes, ["a", "b"])
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b")])
    }

    func test_quotedIdsWithSpaces() {
        let g = DotGraphParser.parse(#"digraph { "hello world" -> "x y" }"#)
        XCTAssertEqual(g?.nodes, ["hello world", "x y"])
        XCTAssertEqual(g?.edges, [DotEdge(from: "hello world", to: "x y")])
    }

    func test_comments_lineHashBlock_stripped_butNotInsideQuotes() {
        let g = DotGraphParser.parse("""
        // line comment
        digraph {            # hash comment
          a -> b   /* block
                      comment */ ;
          "n#1" -> "n//2"    // a label containing comment-like chars survives
        }
        """)
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b"),
                                  DotEdge(from: "n#1", to: "n//2")])
        XCTAssertTrue(g?.nodes.contains("n#1") == true)
        XCTAssertTrue(g?.nodes.contains("n//2") == true)
    }

    func test_defaultAttrKeywords_areNotNodes() {
        let g = DotGraphParser.parse("""
        digraph {
          node [shape=circle];
          edge [color=blue];
          graph [rankdir=LR];
          rankdir = LR;
          a -> b;
        }
        """)
        // Only the real nodes a/b — never `node`/`edge`/`graph`/`rankdir`/`LR`.
        XCTAssertEqual(g?.nodes, ["a", "b"])
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b")])
    }

    func test_subgraph_isFlattened() {
        let g = DotGraphParser.parse("""
        digraph {
          subgraph cluster_0 { a -> b }
          c -> a
        }
        """)
        XCTAssertEqual(g?.nodes, ["a", "b", "c"])
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b"),
                                  DotEdge(from: "c", to: "a")])
    }

    func test_nodeOrder_isFirstSeen_andDeduped() {
        let g = DotGraphParser.parse("digraph { b -> a; a -> b; c }")
        XCTAssertEqual(g?.nodes, ["b", "a", "c"], "first-seen order, no duplicates")
        XCTAssertEqual(g?.edges.count, 2)
    }

    func test_leadingDashNumeralId_isNotAnEdgeOp() {
        let g = DotGraphParser.parse("digraph { a -> -3 }")
        XCTAssertEqual(g?.nodes, ["a", "-3"])
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "-3")])
    }

    func test_strictPrefix_accepted() {
        let g = DotGraphParser.parse("strict digraph { a -> b }")
        XCTAssertEqual(g?.isDirected, true)
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b")])
    }

    func test_emptyGraph_noNodesOrEdges() {
        let g = DotGraphParser.parse("digraph {}")
        XCTAssertEqual(g?.isDirected, true)
        XCTAssertEqual(g?.nodes, [])
        XCTAssertEqual(g?.edges, [])
    }

    func test_nonDotInput_returnsNil() {
        XCTAssertNil(DotGraphParser.parse("just some plain text\nno graph here"))
        XCTAssertNil(DotGraphParser.parse("{ a -> b }"))   // no graph/digraph keyword
        XCTAssertNil(DotGraphParser.parse(""))
    }

    func test_htmlLikeLabel_isSkipped_notMisparsed() {
        // `<...>` HTML label must not leak `<`/`>`/tag text as nodes.
        let g = DotGraphParser.parse(#"digraph { a [label=<<b>hi</b>>]; a -> b }"#)
        XCTAssertEqual(g?.nodes, ["a", "b"])
        XCTAssertEqual(g?.edges, [DotEdge(from: "a", to: "b")])
    }
}
