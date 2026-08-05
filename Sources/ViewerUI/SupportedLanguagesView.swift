import SwiftUI
import ViewerCore
import ViewerKit

/// Help ▸ Supported Languages (owner 2026-08-05 — moved OUT of Settings:
/// a reference list, not a preference). The syntax-highlighting languages the
/// app supports, with the file extensions that trigger each; both the
/// read-only Source view (TreeSitter) and the CM6 editor highlight this set
/// (TSK-790 discoverability).
struct SupportedLanguagesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Source View and the editor both highlight these languages, detected by file extension:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(HighlightLanguage.supportedForDisplay, id: \.self) { lang in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(lang.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 140, alignment: .leading)
                        Text(lang.fileExtensions.map { ".\($0)" }.joined(separator: "  "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The id predates the move (Settings ▸ Syntax Highlighting) — kept
        // stable for AX drivers; the catalog documents the new home.
        .accessibilityIdentifier("mdv.settings.languages")
    }
}

extension DocumentModel {
    /// Help ▸ Supported Languages — hosted reference window.
    public func showSupportedLanguages() {
        _ = openHostedView(title: "Supported Languages",
                           rootView: SupportedLanguagesView())
    }
}
