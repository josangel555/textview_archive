import CoreGraphics

/// The compositing z-order contract for the side-docked terminal column vs the
/// center content surface (TSK-960, regression of TSK-491).
///
/// WHY THIS EXISTS AS A NAMED, HOST-TESTABLE TYPE
/// ----------------------------------------------
/// `ContentView` lays the side-docked terminal column (`sideTerminalColumn`)
/// and the center content column as plain `HStack` siblings. BOTH host an
/// opaque, layer-backed `NSViewRepresentable` surface — the terminal
/// (`TerminalNSView`) and the content WebView respectively. Per the compositor
/// rule codified in CLAUDE.md / LESSONS (TSK-488), two opaque representables in
/// one container composite by PAINT ORDER: without an explicit z-order, the
/// later-painted surface occludes the earlier one. Depending on the dock edge
/// that surfaces as either the right-docked terminal failing to composite, or
/// the terminal overdrawing the document.
///
/// The fix is to put the terminal column in its OWN compositing layer ordered
/// ABOVE the content surface (`.compositingGroup().zIndex(terminalColumn)` vs
/// `.zIndex(contentColumn)`). The actual on-screen composite is a VM T5 guard
/// (`TerminalTabStripVisualRegressionTests`) — `ImageRenderer` is a documented
/// FALSE GREEN for this class because it never instantiates the opaque AppKit
/// layer. So the host cannot prove the pixels composited; what it CAN pin is
/// the ORDERING DECISION. By driving the `.zIndex(...)` modifiers from these
/// named constants (rather than bare literals scattered across layout
/// branches), `SideDockCompositingTests` fails on the host if anyone flips the
/// order or lets the two layers collide on the same z — catching the logic
/// regression even though the pixel proof is VM-only.
enum SideDockCompositing {
    /// The center content column (opaque WKWebView surface). Base layer.
    static let contentColumnZIndex: Double = 0

    /// The side-docked terminal column (opaque terminal surface). Ordered
    /// strictly ABOVE the content column so neither opaque representable
    /// occludes the other regardless of HStack paint order.
    static let terminalColumnZIndex: Double = 1

    /// The invariant the layout relies on: the terminal column must sit
    /// strictly above the content column. Pinned by the host test; if this is
    /// ever false the right-docked terminal can stop compositing (TSK-960).
    static var terminalIsAboveContent: Bool {
        terminalColumnZIndex > contentColumnZIndex
    }
}
