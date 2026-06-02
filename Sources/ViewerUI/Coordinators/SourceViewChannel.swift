import Foundation
import Combine

/// Narrow observation channel for the HIGH-FREQUENCY source-view view-local
/// state: live scroll offset, caret/selection position, and the scroll-to-line
/// request. These tick on EVERY scroll wheel event and EVERY caret move.
///
/// ## Why this exists (PERF — the republish cascade)
///
/// Before this split, `sourceScrollState` + `sourceSelection` were
/// `@Published` directly on `DocumentModel`. Every view that observes
/// `DocumentModel` via `@ObservedObject` (`ContentView`, `SidebarView` and
/// its every `FileRowView`, `ModeBar`, `TabBar`, …) was therefore re-bodied
/// on every scroll tick and every caret move — fields those views do NOT
/// read. Measured cost: a caret move was ~249× the no-change layout baseline,
/// driven entirely by the whole-sidebar re-body it triggered.
///
/// The fix is the same narrow-observation pattern already used by
/// `FindCoordinator` (find state), `EditorCoordinator` (CM6 editor state),
/// `TabCoordinator` (tabs + per-tab caches) and `PanelLayoutStore` (rails):
/// hang the high-frequency state off a dedicated `ObservableObject` whose
/// `objectWillChange` is NOT forwarded into `DocumentModel.objectWillChange`,
/// and have ONLY the views that actually read it observe it directly
/// (`SourceModeView` — gutter + text + find-minimap — and `StatusBar` — the
/// "Ln X, Col Y" readout). A scroll tick / caret move now re-bodies just that
/// pair, never the sidebar or the content tree.
///
/// `DocumentModel` keeps thin forwarders (`sourceScrollState`,
/// `sourceSelection`, `sourceScrollLineTarget`/`Nonce`, `scrollSource(toLine:)`)
/// so the dozens of existing call sites (Walkthrough, automation host, search
/// results, the editor cursor-mirror closure, …) compile unchanged — they
/// just delegate to this channel.
@MainActor
public final class SourceViewChannel: ObservableObject {

    /// Latest scroll state from the source view, published by
    /// `TextDisplayView.onScrollChange`. Drives the SwiftUI gutter
    /// (`SourceGutterView`) and the find-match minimap's `totalLines`.
    /// Seeded with empty values so the gutter has something to render at
    /// first paint before `viewDidLoad` fires.
    @Published public var sourceScrollState: SourceScrollState = SourceScrollState(
        offsetY: 0, viewportHeight: 0, lineHeight: 16, lineCount: 0, topInset: 10
    )

    /// Caret position published by `TextDisplayView` (and mirrored from the
    /// CM6 editor via `EditorCoordinator.onCursorMirrorToStatusBar`). The
    /// status bar reads this to render "Ln 12, Col 4". Reset to `.zero` on
    /// tab switch.
    @Published public var sourceSelection: SourceSelection = .zero

    /// Scroll the active source view to this 1-based line number on the next
    /// render. The controller debounces by comparing to its last-applied
    /// target. Pair with a bumped `sourceScrollLineNonce` so re-requesting
    /// the same line still fires.
    @Published public var sourceScrollLineTarget: Int? = nil
    @Published public var sourceScrollLineNonce: Int = 0

    public init() {}

    public func scrollSource(toLine line: Int) {
        sourceScrollLineTarget = line
        sourceScrollLineNonce &+= 1
    }
}
