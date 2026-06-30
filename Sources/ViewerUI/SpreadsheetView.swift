import SwiftUI
import ViewerCore

/// TSK-1141 (slice 3) — a multi-sheet `.xlsx` tab: a horizontal sheet-tab strip
/// above the existing `CSVTableView` grid. Shown only when the file carries more
/// than one sheet (`TextFile.xlsxSheets`); a single-sheet file renders the bare
/// grid (the caller branches). Switching a tab re-derives the grid's text from the
/// chosen sheet via the host-tested `TextFile.withActiveSheet(_:)` — `file.contents`
/// (and therefore save / find / dirty-tracking) keeps the active sheet's text, so
/// nothing downstream of the String contract changes (see
/// docs/SPREADSHEET_MULTISHEET_DESIGN.md). Both the strip and `CSVTableView` are
/// SwiftUI (no opaque representable), so there's no compositor-occlusion ordering
/// concern here.
struct SpreadsheetView: View {
    let file: TextFile
    let model: DocumentModel
    let tabID: UUID
    @State private var activeSheet = 0

    private var sheetNames: [String] {
        (file.xlsxSheets ?? []).enumerated().map { i, s in
            s.name.isEmpty ? "Sheet \(i + 1)" : s.name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetTabStrip
            Divider()
            CSVTableView(text: file.withActiveSheet(clampedActive).contents,
                         model: model, tabID: tabID)
        }
    }

    /// Guards against an out-of-range index if the workbook changed under us.
    private var clampedActive: Int {
        let count = file.xlsxSheets?.count ?? 0
        guard count > 0 else { return 0 }
        return min(max(activeSheet, 0), count - 1)
    }

    private var sheetTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sheetNames.indices, id: \.self) { i in
                    Button {
                        activeSheet = i
                    } label: {
                        Text(sheetNames[i])
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                i == clampedActive
                                    ? Color(nsColor: .selectedContentBackgroundColor)
                                    : Color(nsColor: .controlBackgroundColor)
                            )
                            .foregroundStyle(i == clampedActive ? Color.white : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(sheetNames[i])
                    .accessibilityIdentifier("mdv.sheetTab.\(i)")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("mdv.sheetTabStrip")
    }
}
