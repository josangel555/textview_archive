import Foundation
import ViewerKit

public struct Tab: Sendable, Identifiable {
    /// How the tab's loaded copy relates to the file on disk. Orthogonal
    /// to `isDirty` (which is about the *editor buffer* vs. the loaded
    /// copy): a tab can be both edited-by-you AND changed-on-disk.
    ///
    /// This is the per-tab generalization of `EditorBuffer.hasExternalEdit`
    /// (which only covered the active editor tab). Computed by the watcher /
    /// a stat sweep against the `(mtime, size)` baseline the loaded
    /// `TextFile` already carries. Consumed by the status-bar "Modified" red
    /// chip and (later) a tab red-dot.
    ///
    /// IMPORTANT: introducing this is a SIGNAL only — it does NOT change the
    /// watcher's current auto-reload behavior. Any "flag instead of reload"
    /// is a future opt-in pref defaulting to today's behavior.
    public enum DiskState: String, Sendable, Equatable {
        /// Loaded copy matches disk (or we can't prove otherwise).
        case fresh
        /// The on-disk file changed since we loaded it.
        case staleVsDisk
        /// The on-disk file no longer exists (deleted / moved away).
        case deleted

        /// Whether the tab strip should surface a red disk-change dot for
        /// this state (TSK-371). `.fresh` shows nothing; both change states
        /// do. Pure so the TabBar reads it off the cheap `Tab` snapshot and
        /// it stays unit-testable without a view.
        public var showsTabDot: Bool { self != .fresh }

        /// HelpInfo bubble title for the tab dot (`nil` when no dot).
        public var tabDotHelpTitle: String? {
            switch self {
            case .fresh:       return nil
            case .staleVsDisk: return "Changed on disk"
            case .deleted:     return "Deleted on disk"
            }
        }

        /// Longer HelpInfo / status-bar description for the tab dot
        /// (`nil` when no dot).
        public var tabDotHelpDescription: String? {
            switch self {
            case .fresh:       return nil
            case .staleVsDisk: return "The file changed in the filesystem since it was loaded"
            case .deleted:     return "The file no longer exists in the filesystem"
            }
        }
    }

    public let id: UUID
    public var url: URL?
    public var state: DocumentState
    public var viewMode: ViewMode
    /// True when the editor buffer for this tab has unsaved changes.
    /// Mirrored from `DocumentModel.editorBuffer(forTabID:).isDirty`
    /// so the TabBar can read it via the cheap, Equatable `Tab`
    /// snapshot rather than reaching into the model on every diff.
    /// Updated by `DocumentModel.updateEditorText` and cleared by
    /// `saveActiveEditor`.
    public var isDirty: Bool
    /// Disk-vs-loaded staleness signal (see `DiskState`). Default `.fresh`;
    /// updated by the watcher / stat sweep, reset to `.fresh` on reload.
    public var diskState: DiskState
    /// Per-tab "Open As…" category override (WAVE 2b item 6). When set,
    /// it overrides extension/UTI auto-detection — both for HOW the file
    /// was loaded (`DocumentController.open(forcedCategory:)`) and for
    /// WHICH viewer renders it (`ContentView` reads this first). `nil` =
    /// auto-detect. Additive-optional; persisted as a raw string in
    /// `TabSnapshot.categoryOverride` with a downgrade guard.
    public var categoryOverride: FileCategory?

    /// Last-known 1-based top visible source line for this tab (UX-K, #231).
    /// Persisted per-file as `TabSnapshot.scrollTopLine` so reopening a file
    /// restores the user's scroll position.
    ///
    /// HOT-PATH NOTE: captured LAZILY at focus-loss / close / snapshot
    /// boundaries (`DocumentModel.captureScrollForActiveTab`), NEVER on the
    /// per-scroll-tick path — the live offset lives on the narrow
    /// `SourceViewChannel.sourceScrollState`, which deliberately does not
    /// republish `DocumentModel`. EXCLUDED from `Tab`'s Equatable so writing
    /// it can't churn the SwiftUI tab-strip diff: it's persistence-only
    /// metadata, not display state.
    public var scrollTopLine: Int?

    /// TSK-1041: last-known RENDERED-markdown WKWebView scroll offset
    /// (`window.scrollY`) for this tab. The rendered preview is a separate
    /// scroll channel from the source/editor `scrollTopLine` (no source-line
    /// mapping exists for reflowed HTML), so it's persisted per-file as
    /// `TabSnapshot.renderedScrollY` and restored by seeding
    /// `DocumentModel.renderedScrollByURL`.
    ///
    /// HOT-PATH NOTE: same discipline as `scrollTopLine` — captured LAZILY at
    /// focus-loss / close / snapshot boundaries (`DocumentModel.captureScroll`),
    /// NEVER per scroll tick. EXCLUDED from `Tab`'s Equatable: persistence-only
    /// metadata, not tab-strip display state.
    public var renderedScrollY: Double?

    /// Hot-exit (TSK-718): the unsaved editor-buffer text for this tab, captured
    /// so a relaunch can restore in-flight edits the user never saved (like
    /// VS Code's hot exit). Persisted per-file as `TabSnapshot.unsavedText`;
    /// `nil` when the buffer is clean (no unsaved edits to restore).
    ///
    /// HOT-PATH NOTE: captured LAZILY at the autosave / detach / quit snapshot
    /// boundary (`DocumentModel.captureUnsavedTextForAllTabs`), NEVER per
    /// keystroke. EXCLUDED from `Tab`'s Equatable (same rationale as
    /// `scrollTopLine`): it's persistence-only metadata, not tab-strip display
    /// state — comparing it would churn the SwiftUI diff on every capture.
    public var unsavedText: String?

    /// TSK-1025 hot-exit clobber guard: the file's `(mtime, size)` baseline the
    /// `unsavedText` edits were made FROM, captured at the hot-exit snapshot
    /// boundary. On restore the buffer's saved-fingerprint is seeded from this
    /// (NOT the fresh-from-disk read), so the external-edit conflict path fires
    /// if the file changed while the app was closed. Persistence-only metadata
    /// (EXCLUDED from `Tab`'s Equatable, like `unsavedText`); nil for a clean
    /// tab or a pre-TSK-1025 snapshot.
    public var unsavedBaseMTime: Date?
    public var unsavedBaseSize: Int?

    /// Hex hot-exit (2026-08-01): the unsaved HEX-editor bytes for this tab
    /// (base64), captured at the same snapshot boundary as `unsavedText` so
    /// hex edits survive a session switch / relaunch — they used to be the
    /// one buffer class the hot-exit machinery dropped. Same hot-path rules:
    /// stamped lazily, persistence-only, EXCLUDED from `Tab`'s Equatable.
    public var unsavedHexBase64: String?

    /// TSK-1303: the in-progress image-editor edit state (tonal/geometry ops +
    /// vector overlay) for an image tab, captured so it survives a SESSION
    /// switch — the view-local `ImageEditorViewModel` otherwise loses it when the
    /// tab/VM is recreated on switch-back (the SAME session-switch drain class as
    /// `scrollTopLine` / `renderedScrollY` / `unsavedText`). Persisted per file as
    /// `TabSnapshot.imageEditState`; `nil` for a non-image or unedited tab.
    ///
    /// HOT-PATH NOTE: stamped LAZILY at the session-switch snapshot boundary
    /// (`DocumentModel.captureImageEditStateForAllTabs`), NEVER on the per-edit
    /// path — the live state lives on the URL-keyed `imageEditStateByURL` channel.
    /// EXCLUDED from `Tab`'s Equatable (like the scroll / hot-exit fields): it's
    /// persistence-only metadata, so writing it must not churn the tab-strip diff.
    public var imageEditState: ImageEditState?

    /// True for an ephemeral "preview" tab (VSCode-style): single-click /
    /// arrow-nav in the sidebar reuses the one preview slot instead of
    /// spawning a tab per file; an explicit commit (double-click / Enter /
    /// edit) promotes it to permanent via `TabsState.promoteTab` (TSK-306,
    /// TSK-272 — see `docs/PREVIEW_TAB_DESIGN.md`). In-memory only: NOT
    /// carried by `TabSnapshot`, so a relaunch rehydrates tabs as permanent
    /// (the "promote on save" persistence rule, for free). INCLUDED in
    /// `Equatable` so the tab strip re-renders the preview affordance on
    /// promote.
    public var isPreview: Bool

    /// I-19 (owner 2026-08-11): this tab is in the SPLIT-EDITING layout —
    /// the editor lens with a live rendered preview of the SAME file
    /// beside it, INSIDE the tab's content area. PER-TAB state (each tab
    /// keeps its own arrangement across switches; the old model rode the
    /// window-scoped `splitURL` pane, so switching tabs stranded the
    /// preview on the previous file). Persisted via
    /// `TabSnapshot.splitEditing`. INCLUDED in Equatable — it drives the
    /// content layout, so the view diff must see it flip.
    public var isSplitEditing: Bool

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        state: DocumentState = .empty,
        viewMode: ViewMode = .rendered,
        isDirty: Bool = false,
        diskState: DiskState = .fresh,
        categoryOverride: FileCategory? = nil,
        scrollTopLine: Int? = nil,
        renderedScrollY: Double? = nil,
        unsavedText: String? = nil,
        unsavedBaseMTime: Date? = nil,
        unsavedBaseSize: Int? = nil,
        imageEditState: ImageEditState? = nil,
        isPreview: Bool = false,
        isSplitEditing: Bool = false
    ) {
        self.id = id
        self.url = url
        self.state = state
        self.viewMode = viewMode
        self.isDirty = isDirty
        self.diskState = diskState
        self.categoryOverride = categoryOverride
        self.scrollTopLine = scrollTopLine
        self.renderedScrollY = renderedScrollY
        self.unsavedText = unsavedText
        self.unsavedBaseMTime = unsavedBaseMTime
        self.unsavedBaseSize = unsavedBaseSize
        self.imageEditState = imageEditState
        self.isPreview = isPreview
        self.isSplitEditing = isSplitEditing
    }

    /// Pure staleness classification, reusing the same mtime-OR-size
    /// mismatch logic as `EditorBuffer.hasExternalEdit`. `currentExists`
    /// false → `.deleted`. A mismatch on either dimension → `.staleVsDisk`.
    /// Otherwise (proven match, or can't-tell) → `.fresh` — a display
    /// signal must not false-positive into "stale" when it can't prove a
    /// change, mirroring `hasExternalEdit`'s conservative `false`.
    public static func classifyDiskState(
        baselineMTime: Date?, baselineSize: Int?,
        currentMTime: Date?, currentSize: Int?,
        currentExists: Bool
    ) -> DiskState {
        guard currentExists else { return .deleted }
        if let b = baselineMTime, let c = currentMTime, b != c { return .staleVsDisk }
        if let b = baselineSize, let c = currentSize, b != c { return .staleVsDisk }
        return .fresh
    }

    /// What to display in the tab strip.
    public var title: String {
        switch state {
        case .loaded(let f):      return f.url.lastPathComponent
        case .binary(let b):      return b.url.lastPathComponent
        case .error(let f):       return f.url.lastPathComponent
        case .preview(let u, _):  return u.lastPathComponent
        case .loading(let u):     return u.lastPathComponent
        case .hostedView(_, let t): return t
        case .empty:              return url?.lastPathComponent ?? "Untitled"
        }
    }

    /// True when this tab has never been pointed at a file.
    public var isBlank: Bool {
        if url == nil, case .empty = state { return true }
        return false
    }
}

/// Equatable on identity + cheap discriminators only — explicitly NOT
/// on `state` (which contains `TextFile.contents`, a full file String).
/// Synthesized Equatable would O(N) compare every open file's bytes
/// on every SwiftUI `ForEach` diff over `tabs`. Identity-based equality
/// is what SwiftUI actually needs for diffing — content equality
/// matters only when something explicitly compares two `Tab`s
/// expecting deep semantic equality, which nothing does.
extension Tab: Equatable {
    public static func == (lhs: Tab, rhs: Tab) -> Bool {
        guard lhs.id == rhs.id else { return false }
        guard lhs.url == rhs.url else { return false }
        guard lhs.viewMode == rhs.viewMode else { return false }
        guard lhs.isDirty == rhs.isDirty else { return false }
        guard lhs.diskState == rhs.diskState else { return false }
        guard lhs.categoryOverride == rhs.categoryOverride else { return false }
        guard lhs.isPreview == rhs.isPreview else { return false }
        guard lhs.isSplitEditing == rhs.isSplitEditing else { return false }
        // `scrollTopLine` is intentionally NOT compared (UX-K, #231): it's
        // persistence-only scroll metadata captured at focus-loss/close
        // boundaries. Comparing it would make a scroll capture re-trigger
        // tab-strip diffs — the exact hot-path republish we avoid. The same
        // applies to `renderedScrollY` (TSK-1041 rendered-scroll persistence)
        // and `unsavedText` (TSK-718 hot exit) — captured at the snapshot
        // boundary, persistence-only, not display state.
        // Compare state by case-only, not by payload. Payload changes
        // are reflected by other model state (e.g. loadState, watcher
        // reload nonce); state-payload-equality isn't a property
        // anything in the app actually requires.
        switch (lhs.state, rhs.state) {
        case (.empty, .empty),
             (.loaded, .loaded),
             (.binary, .binary),
             (.error, .error):
            return true
        case (.loading(let lu), .loading(let ru)):
            // S3-D: explicit case so two adjacent .loading tabs with
            // the same URL compare equal. Without this they fell into
            // `default → false` and SwiftUI did redundant diff work
            // on every tick.
            return lu == ru
        case (.preview(let lu, let lc), .preview(let ru, let rc)):
            return lu == ru && lc == rc
        case (.hostedView(let lid, let lt), .hostedView(let rid, let rt)):
            return lid == rid && lt == rt
        default:
            return false
        }
    }
}
