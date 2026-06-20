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

    /// Called when the user clicks Restore on a selected version. Receives the
    /// version's full content; the host pushes it into the editor buffer as an
    /// undoable edit (NOT a disk write). nil ⇒ no Restore affordance (e.g. when
    /// the viewer is opened for a file with no editor tab).
    private let onRestore: ((String) -> Void)?

    init(
        doc: DocumentModel,
        source: VersionSource,
        kind: VersionRef.Kind,
        onRestore: ((String) -> Void)? = nil
    ) {
        self.doc = doc
        _model = StateObject(wrappedValue: UnifiedHistoryViewModel(source: source, kind: kind))
        self.onRestore = onRestore
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
                centeredPlaceholder(model.sourceKind == .localHistory
                    ? "No saved versions yet.\nVersions are recorded when you save edits."
                    : "No history for this file.")
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
                    DiffView(text: text, doc: doc)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                if let text = model.restoreCandidateContent() {
                    onRestore(text)
                }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .font(.system(size: doc.uiSize(11)))
            }
            .buttonStyle(.borderless)
            .help("Replace the current editor contents with this version (undoable — not saved until you save)")
            .accessibilityIdentifier("mdv.history.restore")
        }
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
