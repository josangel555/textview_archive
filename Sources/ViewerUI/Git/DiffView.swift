import AppKit
import SwiftUI
import ViewerCore

/// Renders a unified diff as a per-file, per-hunk colored view with
/// old/new line numbers. Replaces the "open the .diff as plain text"
/// fallback for git-generated diffs (Status row, commit show, stash show).
///
/// Side-by-side mode is a future polish — v1 is unified.
struct DiffView: View {
    let text: String
    @ObservedObject var doc: DocumentModel

    /// Optional review session (§6.2). When `nil` (the default — both
    /// existing call sites), `DiffView` renders EXACTLY as before: read-only
    /// diff, no gutter affordance, no comment threads. When non-nil, the
    /// diff becomes review-aware: comment threads render under their anchored
    /// lines and a hover gutter opens the composer. Every review affordance
    /// is gated on `reviewSession != nil`, so the read-only path is provably
    /// unchanged (pinned by `DiffViewReviewTests`).
    var reviewSession: ReviewSession? = nil

    /// `DiffParser.parse` is O(diff size) and allocates a fresh
    /// `[UnifiedDiff.File]` tree per call. As a computed property
    /// it re-ran on every body re-eval (zoom change, hover, etc.) —
    /// on a multi-thousand-line commit diff that's the dominant
    /// cost. @State + .onChange recomputes only when `text` changes.
    @State private var files: [UnifiedDiff.File] = []

    // TSK-597 — find-in-diff. The match set + current index are pure
    // DiffFind output; the view renders tints and scrolls to the
    // current match. Recomputed when the query or the parsed tree
    // changes.
    @State private var findQuery: String = ""
    @State private var findMatches: [DiffFind.Match] = []
    @State private var findIndex: Int?

    init(text: String, doc: DocumentModel, reviewSession: ReviewSession? = nil) {
        self.text = text
        self.doc = doc
        self.reviewSession = reviewSession
    }

    /// Test seam: seed the parsed files directly so layout tests can render
    /// the populated branch without depending on `.onAppear` firing in a
    /// window-free/ImageRenderer context. Behavior is otherwise identical.
    internal init(
        text: String, doc: DocumentModel, reviewSession: ReviewSession?,
        initialFiles: [UnifiedDiff.File]
    ) {
        self.text = text
        self.doc = doc
        self.reviewSession = reviewSession
        self._files = State(initialValue: initialFiles)
    }

    var body: some View {
        Group {
            if files.isEmpty {
                empty
            } else {
                // TSK-593: a two-axis ScrollView CENTERS content smaller than
                // the viewport. Propose at least the viewport size to the
                // stack and anchor it topLeading so short/narrow diffs pin to
                // the top-left like every other panel; oversized diffs still
                // scroll both axes unchanged.
                VStack(spacing: 0) {
                    findBar
                    GeometryReader { geo in
                        ScrollViewReader { proxy in
                            ScrollView([.horizontal, .vertical]) {
                                scrollBody(viewport: geo.size)
                            }
                            .onChange(of: findIndex) { _, idx in
                                if let idx, findMatches.indices.contains(idx) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        proxy.scrollTo(findMatches[idx], anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { files = RustDiffAdapter.parse(text) }
        .onChange(of: text) { _, newText in files = RustDiffAdapter.parse(newText) }
        .onChange(of: findQuery) { _, q in recomputeFind(query: q) }
        .onChange(of: files) { _, _ in recomputeFind(query: findQuery) }
    }

    // MARK: - Find-in-diff (TSK-597)

    private func recomputeFind(query: String) {
        findMatches = DiffFind.matches(in: files, query: query)
        // A fresh/changed search jumps to the first match (or none).
        findIndex = DiffFind.next(after: nil, count: findMatches.count)
    }

    private var findBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: doc.uiSize(9)))
                .foregroundStyle(.secondary)
            TextField("Find in diff", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: doc.uiSize(11)))
                .accessibilityIdentifier("mdv.diff.findField")
            if !findQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(findMatches.isEmpty
                     ? "0 matches"
                     : "\((findIndex ?? 0) + 1) of \(findMatches.count)")
                    .font(.system(size: doc.uiSize(9), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mdv.diff.findCount")
                Button(action: {
                    findIndex = DiffFind.previous(before: findIndex, count: findMatches.count)
                }) {
                    Image(systemName: "chevron.up").font(.system(size: doc.uiSize(9)))
                }
                .buttonStyle(.plain)
                .disabled(findMatches.isEmpty)
                .accessibilityIdentifier("mdv.diff.findPrev")
                Button(action: {
                    findIndex = DiffFind.next(after: findIndex, count: findMatches.count)
                }) {
                    Image(systemName: "chevron.down").font(.system(size: doc.uiSize(9)))
                }
                .buttonStyle(.plain)
                .disabled(findMatches.isEmpty)
                .accessibilityIdentifier("mdv.diff.findNext")
                Button(action: { findQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: doc.uiSize(10)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mdv.diff.findClear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Palette.windowBackground.opacity(0.3))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Per-row find state, O(1) via the match set.
    private var findMatchSet: Set<DiffFind.Match> { Set(findMatches) }

    private var currentFindMatch: DiffFind.Match? {
        guard let findIndex, findMatches.indices.contains(findIndex) else { return nil }
        return findMatches[findIndex]
    }

    /// The scroll content: file blocks expanded to AT LEAST the viewport,
    /// anchored topLeading (TSK-593). Internal so the headless layout test
    /// can render this exact tree with ImageRenderer — ScrollView itself is
    /// opaque to every headless oracle (renders nothing), so the alignment
    /// contract is pinned here, one level below it.
    internal func scrollBody(viewport: CGSize) -> some View {
        LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
            ForEach(Array(files.enumerated()), id: \.offset) { fi, file in
                fileBlock(file, fileIndex: fi)
            }
        }
        .padding(.vertical, 8)
        .frame(minWidth: viewport.width,
               minHeight: viewport.height,
               alignment: .topLeading)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("No diff content.")
                .font(.system(size: doc.uiSize(13)))
                .foregroundStyle(.secondary)
            Text("The file may be unchanged, untracked, or binary.")
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fileBlock(_ file: UnifiedDiff.File, fileIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)
            if file.isBinary {
                Text("Binary file — no textual diff.")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if file.hunks.isEmpty {
                Text("(no hunks)")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { hi, hunk in
                    hunkBlock(hunk, filePath: filePath(of: file),
                              fileIndex: fileIndex, hunkIndex: hi)
                }
            }
        }
        .background(Palette.textBackground,
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.horizontal, 8)
        // TSK-594: guaranteed multi-line copy regardless of SwiftUI text-
        // selection limits — the file block offers its whole unified-diff
        // text; hunkBlock offers the per-hunk variant.
        .contextMenu {
            Button("Copy File Diff") {
                Self.copyToPasteboard(file.clipboardText)
            }
        }
    }

    private func fileHeader(_ file: UnifiedDiff.File) -> some View {
        HStack(spacing: 8) {
            statusBadge(file)
            if file.isRename {
                Text(file.oldPath)
                    .font(.system(size: doc.uiSize(12), design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(file.newPath)
                    .font(.system(size: doc.uiSize(12), design: .monospaced))
                    .foregroundStyle(.primary)
            } else {
                Text(file.newPath.isEmpty ? file.oldPath : file.newPath)
                    .font(.system(size: doc.uiSize(12), weight: .semibold,
                                  design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Spacer()
            Text(stats(file))
                .font(.system(size: doc.uiSize(10), design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.secondary)
    }

    private func statusBadge(_ file: UnifiedDiff.File) -> some View {
        let (label, color): (String, Color) = {
            if file.isNew     { return ("A", .green) }
            if file.isDeleted { return ("D", .red) }
            if file.isRename  { return ("R", .blue) }
            return ("M", .yellow)
        }()
        return Text(label)
            .font(.system(size: doc.uiSize(10), weight: .bold,
                          design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }

    private func stats(_ file: UnifiedDiff.File) -> String {
        // Single source of truth: the host-tested UnifiedDiff.File.lineStats
        // (TSK-514). Identical "+a −r" output; was an untested inline counter.
        let s = file.lineStats
        if s.added == 0 && s.removed == 0 { return "" }
        return "+\(s.added) −\(s.removed)"
    }

    @ViewBuilder
    private func hunkBlock(_ hunk: UnifiedDiff.Hunk, filePath: String,
                           fileIndex: Int, hunkIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header banner — like "@@ -10,3 +12,5 @@ func foo()"
            HStack(spacing: 6) {
                Text(hunkCoords(hunk))
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !hunk.header.isEmpty {
                    Text(hunk.header)
                        .font(.system(size: doc.uiSize(10), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.06))

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { li, line in
                lineRow(line, coordinate: DiffFind.Match(
                    file: fileIndex, hunk: hunkIndex, line: li))
                // Review affordances — entirely gated on a session being
                // present. The nil (read-only) path renders only `lineRow`.
                if reviewSession != nil {
                    reviewAffordances(for: line, hunk: hunk, filePath: filePath)
                }
            }
        }
        .contextMenu {
            Button("Copy Hunk") {
                Self.copyToPasteboard(hunk.clipboardText)
            }
        }
    }

    /// Pasteboard write behind the Copy Hunk / Copy File Diff menu items.
    /// Injectable pasteboard so tests exercise the exact closure the menu
    /// invokes without touching the user's general pasteboard.
    internal static func copyToPasteboard(
        _ text: String, pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// New-path is what `ReviewComment.filePath` is keyed on (post-change
    /// path); fall back to old path for pure deletions.
    private func filePath(of file: UnifiedDiff.File) -> String {
        file.newPath.isEmpty ? file.oldPath : file.newPath
    }

    /// Comment threads anchored to this line, plus the inline composer when
    /// the user has opened it on this line. Only invoked when
    /// `reviewSession != nil`.
    @ViewBuilder
    private func reviewAffordances(
        for line: UnifiedDiff.Line, hunk: UnifiedDiff.Hunk, filePath: String
    ) -> some View {
        if let session = reviewSession {
            let lineNo = line.newLineNo ?? line.oldLineNo
            // Threads whose anchor start lands on this line.
            let topLevel = session.review.comments.filter {
                $0.parentId == nil && $0.filePath == filePath
                && lineNo != nil && $0.anchor.startLine == lineNo
            }
            ForEach(topLevel) { parent in
                CommentThreadView(
                    doc: doc,
                    parent: parent,
                    replies: session.review.comments
                        .filter { $0.parentId == parent.id }
                        .sorted { $0.createdAt < $1.createdAt },
                    anchorState: session.anchorStates[parent.id] ?? .unknown,
                    onResolveToggle: { session.setResolved(id: parent.id, !parent.resolved) },
                    onReply: { /* VM-owed: opens reply composer */ },
                    onEdit: { /* VM-owed: opens edit composer */ },
                    onDelete: { session.delete(id: parent.id) }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private func hunkCoords(_ h: UnifiedDiff.Hunk) -> String {
        "@@ -\(h.oldStart),\(h.oldCount) +\(h.newStart),\(h.newCount) @@"
    }

    private func lineRow(_ line: UnifiedDiff.Line,
                         coordinate: DiffFind.Match) -> some View {
        HStack(spacing: 0) {
            lineNoCell(line.oldLineNo)
            lineNoCell(line.newLineNo)
            // Gutter +/- column
            Text(prefix(for: line.kind))
                .font(.system(size: doc.uiSize(11), design: .monospaced))
                .foregroundStyle(prefixColor(line.kind))
                .frame(width: 14, alignment: .center)
            // Content. Selectable in place (TSK-594) — per-Text on older
            // macOS; the guaranteed multi-line path is the right-click
            // Copy Hunk / Copy File Diff on the enclosing blocks.
            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(size: doc.uiSize(11), design: .monospaced))
                .foregroundStyle(contentColor(line.kind))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .frame(minHeight: 17)
        .background(rowBackground(line.kind))
        // TSK-597: match tints layer OVER the +/- row color so both read
        // at once; the current match is the stronger tint. The id makes
        // the row a scrollTo target for next/prev.
        .overlay(
            (findMatchSet.contains(coordinate)
                ? (coordinate == currentFindMatch
                    ? Color.orange.opacity(0.28)
                    : Color.yellow.opacity(0.18))
                : Color.clear)
                // Tint only — never swallow the row's text-selection
                // clicks (TSK-594).
                .allowsHitTesting(false)
        )
        .id(coordinate)
    }

    private func lineNoCell(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: doc.uiSize(10), design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private func prefix(for kind: UnifiedDiff.Line.Kind) -> String {
        switch kind {
        case .context:    return " "
        case .added:      return "+"
        case .removed:    return "-"
        case .noNewline:  return "\\"
        }
    }

    private func prefixColor(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added:    return .green
        case .removed:  return .red
        case .context:  return .secondary
        case .noNewline: return Color.secondary.opacity(0.6)
        }
    }

    private func contentColor(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added, .removed: return .primary
        case .context:         return .secondary
        case .noNewline:       return Color.secondary.opacity(0.6)
        }
    }

    private func rowBackground(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added:    return Color.green.opacity(0.10)
        case .removed:  return Color.red.opacity(0.10)
        default:        return .clear
        }
    }
}
