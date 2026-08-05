import SwiftUI
import ViewerCore
import ViewerKit

/// Bottom status bar: file path on the left; document metrics on the
/// right. Mirrors what code editors expose so the user can read state
/// at a glance without right-clicking or opening a menu.
///
/// Fields shown today (light-weight, no I/O on the body path):
///   • File path (abbreviated to ~) — moved here from ModeBar
///   • Language badge (also still shown in ModeBar for emphasis)
///   • Line count
///   • Character count
///   • File size (KB / MB)
///   • Line endings (LF / CRLF)
///   • Encoding (UTF-8 / Latin-1 / UTF-16 LE/BE)
///
/// Deferred (need plumbing or filesystem stat):
///   • Cursor position — requires NSTextView delegate → model
///   • git +/-, last commit, file age — Phase 7 git module
///   • Spaces vs tabs — Phase 8.5 polish
struct StatusBar: View {
    @ObservedObject var model: DocumentModel
    /// Tabs + per-tab caches (incl. live editor buffers). Observed
    /// DIRECTLY — same severed path as the TabBar's dirty-dot — because
    /// an editor save rewrites `tab.state` via `tabCoordinator.replace`,
    /// which fires `tabCoordinator.objectWillChange`, NOT
    /// `DocumentModel`'s; and every editor keystroke mutates
    /// `editorBuffers`. Without this observation the editor-mode metrics
    /// never re-body — they'd stay pinned to the on-disk-at-open values
    /// while the buffer is dirty AND after save. See `currentMetrics` for
    /// the editor-buffer-vs-loaded-TextFile choice.
    @ObservedObject var tabCoordinator: TabCoordinator
    /// Caret/selection channel. Observed DIRECTLY (not via `model`) so the
    /// "Ln X, Col Y" readout updates on caret move WITHOUT republishing
    /// DocumentModel — a caret tick re-bodies only this bar + the source
    /// subtree, never the sidebar / content tree. See `SourceViewChannel`.
    @ObservedObject var sourceView: SourceViewChannel
    /// Hover-description sink (0c). Defaults to the process-wide shared sink
    /// that the `.helpInfo(_:)` modifier feeds — `StatusBar(model:)` keeps
    /// working without a new injection at the (out-of-scope) ContentView root.
    @ObservedObject var helpSink: HelpSink = .shared

    /// Off-main cache for the git-chip menu (TSK-734). The menu reads branches/
    /// worktrees from here; the `git` enumeration runs in `.task(id: root)` below,
    /// NEVER synchronously in the Menu content builder (that crashed via a nested
    /// runloop inside the layout commit).
    @StateObject private var gitChipStore = GitChipStore()

    var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("StatusBar")   // TSK-615 re-eval width probe
        #endif
        HStack(spacing: 12) {
            // UX-C (#225): git chip on the LEFT — `repo · branch` for the
            // focused file's repo. Label is built from `SessionGitInfo`
            // (reads `.git/HEAD` directly — NO subprocess on the body hot
            // path). Branch/worktree enumeration + checkout DO spawn git,
            // but only on click (cold path, inside the Menu content).
            gitChip

            // TSK-679: vim mode indicator (NORMAL/INSERT/VISUAL…). Empty (and
            // absent) when vim mode is off. Bottom-left, the conventional place.
            vimModeChip

            // TSK-1162: macro recording indicator — empty when not recording,
            // shows a red "● Recording Macro" while a macro is being captured.
            MacroRecordingChip(macros: model.macros)

            // TSK-1444: LSP status chip — surfaces the focused file's
            // language-server state (running / idle / failed / not installed)
            // so LSP features stop degrading silently. Own view (own poll
            // tick) → re-bodies only the chip. Hidden for non-LSP files.
            LSPStatusChipView(
                pool: model.lspPool,
                currentURL: model.currentURL,
                fontSize: model.uiSize(10))

            // TSK-933: the footer path is a clickable breadcrumb — each segment
            // reveals that ancestor folder (or the file) in the sidebar. Lowest
            // layout priority so it shrinks before the live metric chips (same
            // reason the single-Text version had `.layoutPriority(-1)`).
            pathBreadcrumb
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(-1)
                .help(model.currentURL?.path ?? "")
                .accessibilityIdentifier("mdv.statusBar.path")

            // 0c: hover-description slot. Shows the longer `description` of
            // whatever element the pointer is over (fed by `.helpInfo`).
            // Empty when nothing is hovered. Truncates so it never pushes the
            // metrics off-screen.
            if let desc = helpSink.hovered?.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: model.uiSize(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .accessibilityIdentifier("mdv.statusBar.helpDescription")
            }

            Spacer(minLength: 8)

            // Trailing block: live metrics first, then the WAVE1 date
            // chips. `ViewThatFits` tries the full layout (metrics +
            // dates) and falls back to metrics-only when the row is too
            // narrow — so the date chips DROP CLEANLY under width
            // pressure instead of clipping the live metrics. Combined
            // with the path's `.layoutPriority(-1)` and the per-chip
            // `.fixedSize()`, the live line/cursor/size/encoding chips
            // are guaranteed to render whole or not at all (never the
            // "Col…" / "50.…" half-truncation the date chips introduced).
            // Memory chip is its OWN view (StatusBarMemoryChip) so its 1.5s
            // sampler tick re-bodies only the chip, never this StatusBar
            // (narrow-observation invariant; ChromeBodyEvalCountTests). Single
            // instance OUTSIDE the ViewThatFits so there's exactly one sampler.
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        metricsGroup
                        dateChips
                    }
                    metricsGroup
                }
                // Spell/autocomplete toggles moved to the BottomAttributesBar
                // beside Wrap/Special-chars (owner 2026-08-05).
                StatusBarMemoryChip(
                    tabContentBytes: currentMetrics?.byteCount,
                    fontSize: model.uiSize(10))
            }
        }
        .padding(.horizontal, model.uiSize(10))
        .padding(.vertical, model.uiSize(4))
        .frame(height: model.uiSize(22))
        .background(Palette.windowBackground.opacity(0.65))
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("mdv.statusBar")
    }

    // MARK: - Git chip (UX-C, #225)

    /// `[repo · branch]` chip for the focused file's repo, rendered as a
    /// `Menu` whose click surface offers branch switch (guarded) +
    /// worktree-open-in-new-window. Hidden entirely when the focused file
    /// isn't inside a git repo. The LABEL costs only `.git/HEAD` filesystem
    /// reads (`SessionGitInfo`) — no `git` subprocess on the body path; the
    /// TSK-933: footer path as a clickable breadcrumb. Each segment reveals its
    /// folder (or the file) in the sidebar via `revealInSidebar`. Falls back to
    /// "—" with no file open.
    @ViewBuilder
    private var pathBreadcrumb: some View {
        if let url = model.currentURL {
            let segs = BreadcrumbPath.segments(
                for: url, home: URL(fileURLWithPath: NSHomeDirectory()))
            HStack(spacing: 2) {
                ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                    if i > 0 {
                        Text("›")
                            .font(.system(size: model.uiSize(10)))
                            .foregroundStyle(.tertiary)
                    }
                    Button(seg.name) { model.revealInSidebar(seg.url) }
                        .buttonStyle(.plain)
                        .pointingCursor()   // I-07
                        .font(.system(size: model.uiSize(11)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // TSK-934: right-click a segment for the file-nav verbs.
                        // Every segment is a folder except the leaf (the file).
                        .contextMenu {
                            breadcrumbSegmentMenu(seg, isDirectory: i < segs.count - 1)
                        }
                }
            }
        } else {
            Text("—")
                .font(.system(size: model.uiSize(11)))
                .foregroundStyle(.secondary)
        }
    }

    /// TSK-934: footer breadcrumb right-click menu — same verbs as the file-nav
    /// context menu. The applicable action SET is the host-tested
    /// `BreadcrumbPath.menuActions`; this just renders each to a Button.
    @ViewBuilder
    private func breadcrumbSegmentMenu(
        _ seg: BreadcrumbPath.Segment, isDirectory: Bool
    ) -> some View {
        ForEach(BreadcrumbPath.menuActions(isDirectory: isDirectory), id: \.self) { action in
            switch action {
            case .revealInSidebar:
                Button("Reveal in Sidebar") { model.revealInSidebar(seg.url) }
            case .openFolder:
                Button("Open Folder") { model.openFolder(seg.url) }
            case .openInDefaultApp:
                Button("Open in Default App") { Finder.openInDefaultApp(seg.url) }
            case .copyPath:
                Button("Copy Path") { Pasteboard.copy(seg.url.path) }
            case .revealInFinder:
                Button("Reveal in Finder") { Finder.reveal(seg.url) }
            case .openInTerminal:
                Button("Open in Terminal") {
                    model.openTerminalInApp(at: seg.url, isDirectory: true)
                }
            }
        }
    }

    /// expensive enumeration is deferred into the lazily-evaluated menu.
    @ViewBuilder
    private var gitChip: some View {
        if let root = model.gitChipRepoRoot,
           let label = SessionGitInfo.footerLabel(for: root) {
            Menu {
                gitChipMenu(root: root)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: model.uiSize(9)))
                    Text(label)
                        .font(.system(size: model.uiSize(10), design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // The chip is informative but droppable under extreme width
            // pressure — still higher priority than the bare path.
            .layoutPriority(0)
            // TSK-734: populate the branch/worktree cache OFF-MAIN when the repo
            // root appears/changes, so the Menu content builder never spawns git
            // on the layout path. Re-runs on root change; cancels when the chip
            // disappears.
            .task(id: root) { await gitChipStore.load(root: root) }
            .helpInfo(title: "Git: \(label)",
                      description: "Click to switch branch or open a worktree")
            .accessibilityIdentifier("mdv.statusBar.git")
            .accessibilityLabel("Git \(label)")
        }
    }

    /// Menu content. CRITICAL (TSK-734): NO `GitClient` / subprocess here —
    /// SwiftUI evaluates `Menu` content during the layout/commit pass, and a
    /// synchronous `git` call there spins a nested runloop inside
    /// `CA::Transaction::commit` → AppKit reentrancy crash. Branches/worktrees
    /// come from `gitChipStore` (populated off-main by the chip's `.task(id:)`).
    /// `current` is a cheap `.git/HEAD` file read (`SessionGitInfo`), not a
    /// subprocess, so it is safe on the body path.
    @ViewBuilder
    private func gitChipMenu(root: URL) -> some View {
        let current = SessionGitInfo.badge(for: root).branch
        let branches = gitChipStore.branches
        let worktrees = gitChipStore.worktrees

        Section("Branches") {
            if branches.isEmpty {
                Text("No local branches").disabled(true)
            }
            ForEach(branches, id: \.self) { branch in
                Button {
                    model.switchBranch(to: branch)
                } label: {
                    if branch == current {
                        Label(branch, systemImage: "checkmark")
                    } else {
                        Text(branch)
                    }
                }
                // Switching to the current branch is a no-op; disable it.
                .disabled(branch == current)
            }
        }

        // Worktrees other than the current checkout — open in a NEW window.
        let others = worktrees.filter { $0.state != .current && $0.state != .prunable }
        if !others.isEmpty {
            Section("Worktrees (open in new window)") {
                ForEach(others, id: \.path) { wt in
                    Button {
                        model.openWorktreeInNewWindow(wt.path)
                    } label: {
                        Text(wt.branch.map { "⎇ \($0)" } ?? wt.path.lastPathComponent)
                    }
                }
            }
        }
    }

    /// Vim mode chip (TSK-679). A compact uppercased badge; TSK-679/L861 colors
    /// it per mode (NORMAL=accent, INSERT=green, VISUAL=orange, REPLACE=red) via
    /// the host-tested `VimModeKind` classifier. Renders only when the editor
    /// reports an active vim mode.
    @ViewBuilder
    private var vimModeChip: some View {
        if !model.editorVimMode.isEmpty {
            let kind = VimModeKind.from(model.editorVimMode)
            Text(model.editorVimMode)
                .font(.system(size: model.uiSize(10), weight: .semibold, design: .monospaced))
                .padding(.horizontal, model.uiSize(6))
                .padding(.vertical, model.uiSize(1))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(kind.color.opacity(0.18))
                )
                .foregroundStyle(kind.color)
                .fixedSize()
                .help("Vim mode")
                .accessibilityIdentifier("mdv.statusBar.vimMode")
        }
    }

    /// Live document metrics (line/cursor, lines, chars, size, indent,
    /// EOL, encoding). These are the HIGH-priority chips — never dropped,
    /// each `.fixedSize()` so it renders whole. The trailing date chips
    /// (`dateChips`) drop ahead of these via `ViewThatFits`.
    @ViewBuilder
    private var metricsGroup: some View {
        if let metrics = currentMetrics {
            HStack(spacing: 12) {
                if model.currentViewMode.hasTextCaret,
                   metrics.lineCount > 0, sourceView.sourceSelection.line > 0 {
                    // Ln/Col only meaningful for the caret-backed text
                    // lenses (Source / Editor). Hidden in Rendered (no
                    // caret in the WKWebView — VM-01), Preview / Hex /
                    // Formatted / Table / Diff (no caret either), for
                    // media previews where everything is 0, and for
                    // large read-only files where the source view
                    // publishes a `line == 0` sentinel (it skips the
                    // O(N) newline-index build that would otherwise
                    // resolve precise line:col).
                    metric("Ln",
                        "\(sourceView.sourceSelection.line)" +
                        ", Col \(sourceView.sourceSelection.column)")
                    // UX-C (#225) edit stats: when there's a non-empty
                    // selection, surface its length (UTF-16 units, matching
                    // `SourceSelection.length`). Caret-only (length 0) hides
                    // the chip so it doesn't read as "Sel 0".
                    if sourceView.sourceSelection.length > 0 {
                        metric("Sel",
                            "\(formatNumber(sourceView.sourceSelection.length)) ch")
                    }
                }
                // Lines/Chars only apply to a text-backed document. For
                // media/binary previews (image/audio/video/PDF/sqlite)
                // they're a meaningless 0 — hide them rather than render
                // "Lines 0 / Chars 0", which reads as an empty 0-line doc
                // (PV-08). Size + category encoding still show.
                if metrics.hasTextMetrics {
                    metric("Lines", "\(metrics.lineCount)")
                    metric("Chars", formatNumber(metrics.charCount))
                }
                metric("Size",  formatBytes(metrics.byteCount))
                if !metrics.indent.isEmpty {
                    metric("Indent", metrics.indent)
                }
                metric("EOL",   metrics.lineEndings)
                metric("Enc",   metrics.encodingShort)
                zoomReadout
            }
            // A11Y-16: collapse the per-metric label/value pairs into
            // a single VoiceOver element so the rotor surfaces one
            // "Lines 42, Chars 1.2k, …" element instead of a dozen
            // fragments. `.combine` concatenates each metric's own
            // accessibility label (set in `metric(_:_:)`).
            .accessibilityElement(children: .combine)
        }
    }

    /// item7/0d: Created / Modified dates. "Modified" turns RED when
    /// the active tab's disk-staleness signal says the on-disk file
    /// changed since we loaded it (consumes Tab.diskState). Dates are
    /// today-relative (time-only when the date is today) and cached so
    /// the body hot path doesn't stat on every re-eval. LOW priority —
    /// the `ViewThatFits` in `body` drops this whole block when the row
    /// is too narrow rather than truncating the live metrics.
    @ViewBuilder
    private var dateChips: some View {
        if let dates = currentFileDates {
            HStack(spacing: 12) {
                if let created = dates.created {
                    metric("Created", Self.formatDate(created))
                }
                if let modified = dates.modified {
                    modifiedMetric(Self.formatDate(modified), stale: isActiveTabStale)
                }
            }
        }
    }

    /// True when the active tab's loaded copy is stale vs disk (or deleted).
    private var isActiveTabStale: Bool {
        switch model.tabs.selected?.diskState {
        case .staleVsDisk, .deleted: return true
        default: return false
        }
    }

    /// "Modified" chip that renders red on staleness. Mirrors `metric(_:_:)`
    /// but with a conditional value color + a "(on disk changed)" a11y hint.
    @ViewBuilder
    private func modifiedMetric(_ value: String, stale: Bool) -> some View {
        HStack(spacing: 3) {
            Text("Modified")
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(stale ? Color.red : Color.secondary)
            Text(value)
                .font(.system(size: model.uiSize(10), design: .monospaced))
                .foregroundStyle(stale ? Color.red : Color.primary)
        }
        // Render whole or not at all — never a half-truncated "Mod… 6:12…".
        // The whole date block is dropped by `ViewThatFits` when too narrow.
        .fixedSize()
        .helpInfo(title: "Modified \(value)",
                  description: stale ? "The file changed on disk since it was loaded" : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale ? "Modified \(value), changed on disk" : "Modified: \(value)")
        .accessibilityIdentifier("mdv.statusBar.modified")
    }

    /// UX-C (#225) dual-zoom readout.
    ///
    /// DESIGN NOTE — labeled-merged, NOT a true split. The app currently
    /// drives BOTH the window chrome (`model.uiSize`) and the rendered /
    /// source document content (`fontSize` / `WKWebView.pageZoom`) from a
    /// single `model.zoom` value — the historical separate `uiScale` knob
    /// was collapsed onto it (see `DocumentModel.uiSize`). So there is no
    /// independent document-zoom value to read today. Rather than fabricate
    /// a second readout that would just mirror the first (misleading), we
    /// surface the ONE value under an explicit "Zoom (UI+Doc)" label whose
    /// tooltip says they're unified. A genuine UI-vs-document zoom split is
    /// out of scope here and belongs to the #228 zoom pass — see TODO.
    ///
    /// TODO(#228): when the zoom pass splits chrome zoom from document
    /// zoom, replace this single readout with two (Window-UI zoom +
    /// Document zoom) reading the two separate model values.
    @ViewBuilder
    private var zoomReadout: some View {
        // Only show when zoom isn't the 1.0 default — at 100% the readout
        // is noise. `uiSize`/document share the value so a single check is
        // exact.
        if abs(model.zoom - 1.0) > 0.001 {
            HStack(spacing: 3) {
                Text("Zoom")
                    .font(.system(size: model.uiSize(10), weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: model.uiSize(10), design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .fixedSize()
            .helpInfo(title: "Zoom \(Int((model.zoom * 100).rounded()))%",
                      description: "Window UI and document content share one zoom "
                + "level today; a separate document zoom is planned (#228).")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zoom \(Int((model.zoom * 100).rounded())) percent, "
                + "window and document")
            .accessibilityIdentifier("mdv.statusBar.zoom")
        }
    }

    @ViewBuilder
    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: model.uiSize(10), design: .monospaced))
                .foregroundStyle(.primary)
        }
        // A status-bar chip must render whole — `.fixedSize()` stops
        // SwiftUI from compressing "Col 1" → "Col…" or "50.0k" → "50.…"
        // under width pressure. The path (lowest layout priority) absorbs
        // the shrink; the trailing date chips drop via `ViewThatFits`.
        .fixedSize()
        .help("\(label): \(value)")
        // One combined element per metric so the parent's
        // `.accessibilityElement(children: .combine)` (A11Y-16) reads
        // "Lines: 42" as a unit rather than two separate fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    /// Lightweight per-render stats from the in-memory TextFile.
    /// `internal` (not `private`) so the host test suite can pin the
    /// computed values against the cache (TSK-971).
    struct Metrics: Equatable {
        let lineCount: Int
        let charCount: Int
        let byteCount: Int
        let lineEndings: String  // LineEndingDetector: "LF" / "CRLF" / "CR" / "Mixed" / "—"
        let encodingShort: String
        let indent: String       // "Tabs" / "Spaces (2)" / "—"
        /// True only for text-backed documents (`.loaded`). Media/binary
        /// previews leave line/char at 0; this flag drives hiding the
        /// Lines/Chars chips for them so they don't read as an empty
        /// 0-line document (PV-08).
        var hasTextMetrics: Bool = true
    }

    /// `body` re-evals every `@Published` mutation (typing, scroll,
    /// selection move). Without memoization, every keystroke re-runs
    /// `lineCount`, `IndentDetector.detect`, `(contents as NSString).length`
    /// across the full file. For a 1 MB source, that's ~5-15 ms of
    /// pure waste per keystroke. Cache keyed by URL + utf8 length so a
    /// file-watcher reload (different length) invalidates automatically.
    private var currentMetrics: Metrics? {
        guard let tab = model.tabs.selected else { return nil }
        switch tab.state {
        case .loaded(let f):
            // In editor mode the on-disk-at-open `TextFile` is stale the
            // moment the user types — the live edits live in the editor
            // buffer, and the post-save bytes land there too (`markSaved`
            // sets `originalText = text`). Read metrics off the buffer so
            // Lines/Chars/Size track the buffer live AND reflect the saved
            // content after a save, instead of freezing at the load-time
            // values. `byteCount` is recomputed from the buffer text in
            // the buffer's own encoding so it matches what a save writes.
            // Falls back to the loaded TextFile in non-editor modes (where
            // the on-disk copy IS the source of truth) and whenever no
            // buffer has been materialized yet.
            if tab.viewMode == .editor,
               let buf = tabCoordinator.editorBuffer(forTabID: tab.id) {
                // TSK-971: read metrics straight off the live buffer text.
                // The byte count is computed via `Self.byteCount` (utf8.count
                // fast path for UTF-8 — no full-buffer `Data` re-encode per
                // keystroke) and the scan is cached on a CONTENT key (not the
                // byte length), so a same-length edit (replace one char) still
                // invalidates correctly and an unchanged re-eval (caret move,
                // scroll, hover) hits the cache instead of rescanning.
                return Self.metrics(
                    forText: buf.text,
                    url: buf.url,
                    encoding: buf.encoding)
            }
            return Self.metrics(for: f)
        case .binary(let b):
            return Metrics(
                lineCount: 0,
                charCount: 0,
                byteCount: b.totalByteCount,
                lineEndings: "—",
                encodingShort: "binary",
                indent: "",
                hasTextMetrics: false
            )
        case .preview(let url, let cat):
            return Metrics(
                lineCount: 0,
                charCount: 0,
                byteCount: Self.cachedFileSize(for: url),
                lineEndings: "—",
                encodingShort: cat.rawValue,
                indent: "",
                hasTextMetrics: false
            )
        case .loading, .empty:
            // Don't blank the bar while a lazily-selected tab reads from disk
            // (`.loading`) — and likewise for the brief `.empty` placeholder a
            // tab can report on switch-in before materialize flips it back to
            // `.loaded`. Without covering `.empty` too, switching between two
            // ALREADY-LOADED tabs flashed the footer blank for a frame
            // (TSK-1120; the TSK-452/1615b98 fix only covered `.loading`).
            // Show at least Size (the path shows separately) so a switch never
            // flashes empty; Lines/Chars/EOL/Enc fill in when `.loaded` lands
            // and the coordinator republishes.
            if let url = tab.url {
                return Self.loadingPlaceholder(for: url)
            }
            return nil
        case .error, .hostedView:
            return nil
        }
    }

    /// Shared placeholder metrics for the transient `.loading` / `.empty` tab
    /// states: Size (from the stat cache) + a "loading…" encoding label, with
    /// `hasTextMetrics` false so the Lines/Chars chips hide until real text
    /// metrics arrive on `.loaded`. Keeps the footer from flashing blank on a
    /// tab switch-in (TSK-452 / TSK-1120). Static + internal for host teeth.
    static func loadingPlaceholder(for url: URL) -> Metrics {
        Metrics(
            lineCount: 0,
            charCount: 0,
            byteCount: cachedFileSize(for: url),
            lineEndings: "—",
            encodingShort: "loading…",
            indent: "",
            hasTextMetrics: false
        )
    }

    /// Cheap byte count of `text` in `encoding`, WITHOUT the full-buffer
    /// `Data` allocation the old `data(using:)?.count` paid on every
    /// keystroke (TSK-971). UTF-8 — the overwhelmingly common buffer
    /// encoding — is `utf8.count`, which is amortized O(1) once Swift has
    /// the UTF-8 view (its native storage) and allocates nothing. ASCII
    /// is exactly that count too. Only the rare non-UTF-8 buffers
    /// (Latin-1 / UTF-16 / …) fall back to a real `data(using:)` encode;
    /// `nil` (encoding can't represent the text) yields `0` rather than a
    /// crash. This is the byte count `EditorWriter.save` will produce
    /// (modulo a 2-byte BOM for explicit-endianness UTF-16, which the
    /// status-bar size readout rounds away).
    static func byteCount(of text: String, encoding: String.Encoding) -> Int {
        switch encoding {
        case .utf8, .ascii:
            return text.utf8.count
        default:
            return text.data(using: encoding)?.count ?? 0
        }
    }

    /// Content-keyed cache entry. The key is `(url, contentHash)` — NOT
    /// `(url, byteCount)`. The old byte-length key was BROKEN two ways
    /// (TSK-971): (a) it required re-encoding the whole buffer to a `Data`
    /// just to get the length, so a heavy alloc ran every keystroke; and
    /// (b) keying on length alone let a same-length edit (swap one char)
    /// return STALE metrics — and conversely never deduplicated the far
    /// more frequent zero-content-change re-evals if they touched length.
    /// Hashing the content (SIMD-fast, no alloc) is cheaper than the
    /// `lineCount`/EOL/indent scans it gates and is content-exact.
    nonisolated(unsafe) private static var metricsCache:
        (url: URL, contentHash: Int, value: Metrics)? = nil
    private static let metricsLock = NSLock()

    #if DEBUG
    /// Test-only counter of how many times the heavy metric scan actually
    /// ran (i.e. cache misses). A repeat call with identical content must
    /// NOT bump this; a real edit must (TSK-971 teeth). DEBUG-only and
    /// guarded by `metricsLock` so it tracks the miss path exactly.
    nonisolated(unsafe) static var metricsScanCount = 0
    static func resetMetricsCache() {
        metricsLock.lock()
        metricsCache = nil
        metricsScanCount = 0
        metricsLock.unlock()
    }
    #endif

    private static func metrics(for f: TextFile) -> Metrics {
        metrics(forText: f.contents, url: f.url, encoding: f.encoding,
                byteCount: f.byteCount)
    }

    /// Compute (or cache-serve) the status-bar metrics for `text`.
    ///
    /// `byteCount` is optional: when the caller already knows the on-disk
    /// byte count (the loaded `TextFile` path) it's passed straight
    /// through; for the live editor buffer it's computed cheaply via
    /// `Self.byteCount` (no `Data` re-encode). The heavy scans
    /// (`lineCount`, `utf16.count`, EOL sample, indent detect) run ONLY
    /// on a content-hash cache miss, so a caret move / scroll / hover that
    /// re-bodies the bar with unchanged text serves from cache, and a real
    /// edit (even a same-length one) recomputes.
    static func metrics(
        forText text: String,
        url: URL,
        encoding: String.Encoding,
        byteCount precomputedBytes: Int? = nil
    ) -> Metrics {
        let contentHash = text.hashValue
        metricsLock.lock()
        if let hit = metricsCache, hit.url == url, hit.contentHash == contentHash {
            metricsLock.unlock()
            return hit.value
        }
        metricsLock.unlock()
        #if DEBUG
        metricsLock.lock(); metricsScanCount += 1; metricsLock.unlock()
        #endif
        let bytes = precomputedBytes ?? Self.byteCount(of: text, encoding: encoding)
        // .utf16.count without NSString bridge — String.UTF16View.count
        // is O(1) on UTF-8 storage post-first-access (Swift caches).
        let m = Metrics(
            lineCount: lineCount(in: text),
            charCount: text.utf16.count,
            byteCount: bytes,
            lineEndings: LineEndingDetector.displayString(in: text, sampleScalars: 4096),
            encodingShort: encodingShort(encoding),
            // Routed through the `.indent` gate (TSK-649 A0): Rust core when
            // on (the shipped default since stage A), Swift IndentDetector
            // otherwise. Cached per (url, contentHash) above, so the detect
            // runs once per file version either way.
            indent: RustIndentAdapter.detect(in: text)
        )
        metricsLock.lock()
        metricsCache = (url, contentHash, m)
        metricsLock.unlock()
        return m
    }

    /// Cache of (url, mtime) → byte size for the preview state. Reads
    /// `attributesOfItem` once per (url, mtime); without this, every
    /// body re-eval did a fresh stat syscall.
    nonisolated(unsafe) private static var previewSizeCache:
        (url: URL, size: Int, sampledAt: TimeInterval)? = nil
    nonisolated(unsafe) private static let previewLock = NSLock()
    private static let previewCacheTTL: TimeInterval = 1.0

    private static func cachedFileSize(for url: URL) -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        previewLock.lock()
        if let hit = previewSizeCache,
           hit.url == url,
           now - hit.sampledAt < previewCacheTTL {
            previewLock.unlock()
            return hit.size
        }
        previewLock.unlock()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        previewLock.lock()
        previewSizeCache = (url, size, now)
        previewLock.unlock()
        return size
    }

    // MARK: - File dates (Created / Modified)

    /// Creation + modification dates for the active tab's file. Cached by
    /// (url, mtime, size) so the body hot path doesn't `stat` on every
    /// re-eval. Reuses the same TTL-window discipline as the preview-size
    /// cache. `nil` for tabs with no file (empty / error / loading).
    private var currentFileDates: (created: Date?, modified: Date?)? {
        guard let tab = model.tabs.selected, let url = tab.url else { return nil }
        switch tab.state {
        case .empty, .error, .loading: return nil
        default: return Self.cachedFileDates(for: url)
        }
    }

    nonisolated(unsafe) private static var datesCache:
        (url: URL, created: Date?, modified: Date?, sampledAt: TimeInterval)? = nil
    nonisolated(unsafe) private static let datesLock = NSLock()
    private static let datesCacheTTL: TimeInterval = 1.0

    private static func cachedFileDates(for url: URL) -> (created: Date?, modified: Date?) {
        let now = Date().timeIntervalSinceReferenceDate
        datesLock.lock()
        if let hit = datesCache, hit.url == url, now - hit.sampledAt < datesCacheTTL {
            datesLock.unlock()
            return (hit.created, hit.modified)
        }
        datesLock.unlock()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = attrs?[.creationDate] as? Date
        let modified = attrs?[.modificationDate] as? Date
        datesLock.lock()
        datesCache = (url, created, modified, now)
        datesLock.unlock()
        return (created, modified)
    }

    /// File created/modified chip: standardized `yyyy-MM-dd HH:mm` (24h)
    /// via the shared ``DisplayDateFormatter``. `now` / `calendar` are kept
    /// for call-site/test compatibility but no longer branch the format.
    static func formatDate(_ date: Date, now: Date = Date(),
                           calendar: Calendar = .current) -> String {
        DisplayDateFormatter.string(from: date)
    }

    private static func lineCount(in s: String) -> Int {
        // Each \n bumps the line count; trailing-newline / empty cases
        // handled so "abc" → 1, "abc\n" → 1, "abc\ndef" → 2.
        if s.isEmpty { return 0 }
        var n = 1
        for c in s.utf8 where c == 0x0A { n += 1 }
        if s.utf8.last == 0x0A { n -= 1 }
        return n
    }

    private static func encodingShort(_ enc: String.Encoding) -> String {
        switch enc {
        case .utf8:             return "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian:    return "UTF-16 BE"
        case .utf16:            return "UTF-16"
        case .isoLatin1:        return "Latin-1"
        case .ascii:            return "ASCII"
        default:                return "?"
        }
    }

    private func formatNumber(_ n: Int) -> String {
        // Compact: 12,345 → "12.3k", 1,234,567 → "1.2M". The status bar
        // can't afford much width for "Chars".
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1_024 { return "\(n) B" }
        if n < 1_024 * 1_024 { return String(format: "%.1f KB", Double(n) / 1_024) }
        return String(format: "%.1f MB", Double(n) / (1_024 * 1_024))
    }
}
