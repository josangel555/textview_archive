import AppKit
import SwiftUI
import ViewerCore

/// The UNIFIED version-history + diff viewer (TSK-1103) — ONE component that
/// serves BOTH Local History and Git, per the owner's spec:
///
///   - a **version list** (left), newest-first;
///   - click a version → see **that version's full content** OR its **diff vs
///     current** (a toggle), or **the change it introduced** (vs predecessor);
///   - select a **range** (Cmd-click a second version) → see the **cumulative
///     diff** across the range;
///   - **Restore** a selected version into the editor as an UNDOABLE edit.
///
/// Back-end-agnostic: everything flows through a `VersionSource`
/// (`LocalHistoryVersionSource` or `GitVersionSource`) via
/// `UnifiedHistoryViewModel`. The right pane reuses the existing `DiffView` for
/// all diff modes (the renderer was already right — the rethink is the
/// list + selection + back-end binding, not the diff pixels).
///
/// Master-detail (`HSplitView`) like the prior git `FileHistoryView`, but
/// generalized and with the View/Diff toggle + Restore.
struct UnifiedHistoryView: View {
    @ObservedObject var doc: DocumentModel
    @StateObject private var model: UnifiedHistoryViewModel
    /// TSK-1462 — Restore asks for confirmation (it replaces the whole editor
    /// contents; undoable, but a whole-buffer swap shouldn't be one stray click).
    @State private var showRestoreConfirm = false

    /// Called when the user clicks Restore on a selected version. Receives the
    /// version's full content; the host pushes it into the editor buffer as an
    /// undoable edit (NOT a disk write). nil ⇒ no Restore affordance (e.g. when
    /// the viewer is opened for a file with no editor tab).
    private let onRestore: ((String) -> Void)?
    /// I-08: "Merge into Current…" — the host opens the per-hunk picker
    /// (`DocumentModel.beginVersionMergePick`) over this version's content.
    /// nil ⇒ no merge affordance.
    private let onMergePick: ((String) -> Void)?

    init(
        doc: DocumentModel,
        source: VersionSource,
        kind: VersionRef.Kind,
        onRestore: ((String) -> Void)? = nil,
        onMergePick: ((String) -> Void)? = nil
    ) {
        self.doc = doc
        _model = StateObject(wrappedValue: UnifiedHistoryViewModel(source: source, kind: kind))
        self.onRestore = onRestore
        self.onMergePick = onMergePick
    }

    var body: some View {
        HSplitView {
            versionList
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.loadIfNeeded() }
    }

    // MARK: - Left: version list

    private var versionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isLoadingVersions {
                centeredPlaceholder("Loading history…")
            } else if model.versions.isEmpty {
                if model.sourceKind == .localHistory {
                    // TSK-1462 — the shared empty-state component, explaining
                    // when snapshots are taken (on save).
                    VStack {
                        Spacer()
                        HostedEmptyStateView(EmptyStateCatalog.localHistory)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    centeredPlaceholder("No history for this file.")
                }
            } else {
                List(selection: Binding(
                    get: { model.primarySelection },
                    set: { id in
                        if let id, let v = model.versions.first(where: { $0.id == id }) {
                            model.click(version: v, command: false)
                        }
                    }
                )) {
                    ForEach(model.versions) { version in
                        versionRow(version)
                            .tag(version.id)
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("mdv.history.versionList")
            }
        }
        .background(Palette.textBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: model.sourceKind == .localHistory
                      ? "clock.arrow.circlepath" : "arrow.triangle.branch")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.secondary)
                Text(model.displayName)
                    .font(.system(size: doc.uiSize(12), weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(model.versions.count) version\(model.versions.count == 1 ? "" : "s")")
                .font(.system(size: doc.uiSize(10)))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func versionRow(_ version: VersionRef) -> some View {
        let isRangeEndpoint = model.rangeSelection.contains { $0.id == version.id }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(version.shortLabel)
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                if isRangeEndpoint {
                    Image(systemName: "circle.fill")
                        .font(.system(size: doc.uiSize(6)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 4)
                if let ts = version.timestamp {
                    Text(Self.shortDate(ts))
                        .font(.system(size: doc.uiSize(9)))
                        .foregroundStyle(.tertiary)
                }
            }
            // TSK-1462 — size + delta vs the previous save ("2.1 KB (+340 B)").
            if let size = model.sizeAnnotation(for: version) {
                Text(size)
                    .font(.system(size: doc.uiSize(9), design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let subject = version.subject, !subject.isEmpty {
                Text(subject)
                    .font(.system(size: doc.uiSize(12)))
                    .lineLimit(2)
            }
            if let author = version.author, !author.isEmpty {
                Text(author)
                    .font(.system(size: doc.uiSize(10)))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .modifier(CommandClickModifier { command in
            model.click(version: version, command: command)
        })
        .help(model.supportsRangeDiff
              ? "Cmd-click to select a range and see the cumulative diff"
              : version.shortLabel)
    }

    // MARK: - Right: detail pane

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailToolbar
            Divider()
            if model.isLoadingDetail {
                centeredPlaceholder("Loading…")
            } else {
                switch model.detail {
                case .empty:
                    centeredPlaceholder("Select a version.")
                case .content(let text):
                    versionContentView(text)
                case .diff(let text):
                    // TSK-1596: web diff renderer (kill-switch MDV_WEB_DIFF=0).
                    if WebDiffGate.isEnabled() {
                        WebDiffPane(text: text, doc: doc, navAvailable: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        DiffView(text: text, doc: doc)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailToolbar: some View {
        HStack(spacing: 10) {
            switch model.selectionMode {
            case .none:
                Text(model.supportsRangeDiff
                     ? "Select a version — Cmd-click a second to compare a range."
                     : "Select a version.")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.secondary)
            case .single:
                Picker("", selection: Binding(
                    get: { model.singleMode },
                    set: { model.setSingleMode($0) }
                )) {
                    Text("Changes").tag(UnifiedHistoryViewModel.SingleMode.ownChange)
                    Text("View").tag(UnifiedHistoryViewModel.SingleMode.viewVersion)
                    Text("vs Current").tag(UnifiedHistoryViewModel.SingleMode.diffVsCurrent)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .accessibilityIdentifier("mdv.history.modePicker")
                restoreButton
                mergePickButton
                copyVersionButton
            case .range:
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: doc.uiSize(10)))
                        .foregroundStyle(.secondary)
                    Text(model.rangeLabel)
                        .font(.system(size: doc.uiSize(11), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Clear") { model.clearRange() }
                        .font(.system(size: doc.uiSize(10)))
                        .buttonStyle(.borderless)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var restoreButton: some View {
        if let onRestore {
            Button {
                showRestoreConfirm = true
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .font(.system(size: doc.uiSize(11)))
            }
            .buttonStyle(.borderless)
            .help("Replace the current editor contents with this version (undoable — not saved until you save)")
            .accessibilityIdentifier("mdv.history.restore")
            // TSK-1462 — confirm before swapping the whole buffer. The current
            // state is snapshotted to Local History first (backup-before-
            // restore, TSK-1331) and the swap is a normal undoable edit.
            .confirmationDialog(
                "Restore this version?",
                isPresented: $showRestoreConfirm
            ) {
                Button("Restore \(model.primaryVersion?.shortLabel ?? "version")",
                       role: .destructive) {
                    if let text = model.restoreCandidateContent() {
                        onRestore(text)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The editor contents are replaced with this version. You can undo with ⌘Z, and nothing is written to disk until you save.")
            }
        }
    }

    /// I-08: per-hunk merge — brings lines from this version into the current
    /// file WITHOUT replacing it (Restore's job). The host opens the 3-pane
    /// picker; ours = current, theirs = this version.
    @ViewBuilder
    private var mergePickButton: some View {
        if let onMergePick {
            Button {
                if let text = model.restoreCandidateContent() {
                    onMergePick(text)
                }
            } label: {
                Label("Merge into Current…", systemImage: "arrow.triangle.merge")
                    .font(.system(size: doc.uiSize(11)))
            }
            .buttonStyle(.borderless)
            .help("Pick per-change which side to keep — bring lines from this version into the current file without replacing it")
            .accessibilityIdentifier("mdv.history.mergePick")
        }
    }

    /// I-08: one-click copy of the WHOLE version — no text-selection fight
    /// with the diff pane's gutters.
    @ViewBuilder
    private var copyVersionButton: some View {
        Button {
            if let text = model.restoreCandidateContent() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                ToastCenter.shared.post(.info, "Version copied to clipboard")
            }
        } label: {
            Label("Copy Version", systemImage: "doc.on.doc")
                .font(.system(size: doc.uiSize(11)))
        }
        .buttonStyle(.borderless)
        .help("Copy this version's full content to the clipboard")
        .accessibilityIdentifier("mdv.history.copyVersion")
    }

    /// Read-only full-content view for "View this version". A monospaced,
    /// selectable text block in a two-axis scroll — deliberately simple (no
    /// CodeMirror WebView) so it stays a SwiftUI-only surface with no compositor
    /// occlusion concerns and renders the historical bytes verbatim.
    private func versionContentView(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "(empty file)" : text)
                .font(.system(size: DiffTextStyle.bodyFontSize(
                    contentFontSize: doc.contentFontSize, zoom: doc.zoom),
                    design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mdv.history.versionContent")
    }

    // MARK: - Helpers

    private func centeredPlaceholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: doc.uiSize(12)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func shortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}
