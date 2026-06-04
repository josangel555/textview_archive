import SwiftUI
import ViewerKit
import ViewerCore

/// UX-A (#224) — the BOTTOM toggle-button group that took the
/// text-attribute controls off the old top attributes bar: **Wrap**,
/// **Special chars** (invisibles), the per-tab **Enable JS** opt-in (for
/// HTML rendered mode), and a UNIFIED **type control** that merges the old
/// "Open As…" viewer dropdown with the syntax-language picker into one
/// "open this file as …" menu.
///
/// Placement: a thin strip directly ABOVE the StatusBar (so the
/// attribute/type controls sit at the bottom of the content column, away
/// from the lens-switching control which moved to the top
/// `ContentToolbar`). Hidden entirely when no file is open.
///
/// Observation: standard narrow `@ObservedObject var model` channel —
/// same as the old ModeBar. Re-bodies on the model republishes that change
/// the current tab / mode / overrides, never per-scroll/caret.
struct BottomAttributesBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack(spacing: model.uiSize(12)) {
            // Text-rendering toggles. These control the NSTextView source /
            // editor rendering, so they're only meaningful for the text
            // lenses — hidden in rendered / preview / hex.
            if showsTextToggles {
                Toggle("Wrap", isOn: $model.sourceWordWrap)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .font(.system(size: model.uiSize(11)))
                    .help("Soft-wrap long lines at the viewport edge")
                    .accessibilityIdentifier("mdv.wrapToggle")
                Toggle("Special chars", isOn: $model.showInvisibleChars)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .font(.system(size: model.uiSize(11)))
                    .help("Show invisible characters (spaces · tabs → returns ¶)")
                    .accessibilityIdentifier("mdv.invisiblesToggle")
            }

            // PER-TAB JavaScript opt-in for raw-HTML rendered mode.
            // SECURITY: JS is DEFAULT-DENY; this is the ONLY way to turn it
            // on, scoped to the current tab. Shown only for `.html` in
            // rendered mode (same gate as before, relocated from the top
            // bar).
            if model.showsHTMLJavaScriptToggle {
                Toggle("Enable JS", isOn: Binding(
                    get: { model.currentHTMLJavaScriptEnabled },
                    set: { model.setHTMLJavaScriptEnabled(
                        $0, forTabID: model.tabs.selected?.id ?? UUID()) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .font(.system(size: model.uiSize(11)))
                .help("Run this HTML file's JavaScript (per-tab; off by "
                      + "default — untrusted HTML runs no scripts). Page "
                      + "scripts are still subject to the strict CSP and "
                      + "sanitizer; remote and file:// loads stay blocked.")
                .accessibilityIdentifier("mdv.htmlJSToggle")
            }

            Spacer(minLength: 8)

            // Unified type control (OpenAs viewer + syntax language). One
            // menu: "open this file as …".
            if let url = model.currentURL {
                TypeControlMenu(model: model, url: url)
            }
        }
        .padding(.horizontal, model.uiSize(10))
        .padding(.vertical, model.uiSize(3))
        .frame(height: model.uiSize(22))
        .background(Palette.windowBackground.opacity(0.45))
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("mdv.bottomAttributesBar")
    }

    /// Wrap / Special-chars apply to the source + editor text lenses (and
    /// the formatted text lens). Mirror the old ModeBar `showsSourceToggles`
    /// gate so they hide in rendered / preview / hex.
    private var showsTextToggles: Bool {
        switch model.currentViewMode {
        case .source, .editor, .formatted: return true
        case .rendered, .preview, .table, .diff, .hex: return false
        }
    }
}

/// UX-A unified type control. Merges the former separate "Open As…" chip
/// (viewer CATEGORY: open a `.db` as CSV, a `.png` as HEX, …) and the
/// language badge (syntax LANGUAGE override) into ONE dropdown so the user
/// has a single "what is this file?" affordance.
///
/// Two sections inside one menu:
///   • **Open as** — the universal viewer list (reuses
///     `model.openAsCategories` + `setCurrentCategoryOverride`, which
///     already persists the per-file override).
///   • **Language** — syntax highlighting override (reuses
///     `setCurrentLanguage`), shown only when a text lens is active (a
///     language override is meaningless for an image / PDF preview).
///
/// The chip LABEL reflects whichever override is more salient: a category
/// override (forced viewer) takes precedence in the label; otherwise the
/// detected/overridden language shows.
private struct TypeControlMenu: View {
    @ObservedObject var model: DocumentModel
    let url: URL

    var body: some View {
        Menu {
            openAsSection
            if showsLanguageSection {
                Divider()
                languageSection
            }
        } label: {
            chipLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open this file as a different viewer, or override its "
              + "syntax language.")
        .accessibilityIdentifier("mdv.typeControl")
    }

    // MARK: Label

    @ViewBuilder
    private var chipLabel: some View {
        let overridden = model.hasCategoryOverride || model.hasLanguageOverride
        HStack(spacing: model.uiSize(2)) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: model.uiSize(8)))
            Text(labelText)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: model.uiSize(7), weight: .bold))
        }
        .font(.system(size: model.uiSize(10), weight: .semibold))
        .padding(.horizontal, model.uiSize(6))
        .padding(.vertical, model.uiSize(1))
        .background(
            RoundedRectangle(cornerRadius: model.uiSize(3))
                .fill(overridden
                      ? Color.accentColor.opacity(0.20)
                      : Color.secondary.opacity(0.15))
        )
        .foregroundStyle(overridden ? Color.accentColor : .secondary)
    }

    /// Category override wins the label (it's the bigger hammer); otherwise
    /// the effective language name.
    private var labelText: String {
        if model.hasCategoryOverride, let cat = model.tabs.selected?.categoryOverride {
            return ModeBar.categoryLabel(cat)
        }
        guard let id = model.tabs.selected?.id else { return "Type" }
        return model.effectiveLanguage(forTabID: id, url: url).displayName
    }

    // MARK: Open-as section (viewer category)

    @ViewBuilder
    private var openAsSection: some View {
        Section("Open as") {
            Button(action: { model.setCurrentCategoryOverride(nil) }) {
                HStack {
                    Text("Auto (\(ModeBar.categoryLabel(FileTypeDetector.category(for: url))))")
                    if !model.hasCategoryOverride { Image(systemName: "checkmark") }
                }
            }
            ForEach(model.openAsCategories(for: url), id: \.self) { cat in
                Button(action: { model.setCurrentCategoryOverride(cat) }) {
                    HStack {
                        Text(ModeBar.categoryLabel(cat))
                        if model.tabs.selected?.categoryOverride == cat {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    // MARK: Language section (syntax override)

    /// Language override only applies to the text lenses; for a media /
    /// PDF / SQLite preview there's no syntax to highlight, so the section
    /// is dropped. (The Open-as section still lets the user force such a
    /// file into a text viewer first.)
    private var showsLanguageSection: Bool {
        switch model.currentViewMode {
        case .source, .editor, .formatted, .table, .diff: return true
        case .rendered:
            // Rendered markdown/mermaid has no source-language override
            // surface; raw-HTML rendered likewise. Keep it text-only.
            return false
        case .preview, .hex: return false
        }
    }

    @ViewBuilder
    private var languageSection: some View {
        Section("Language") {
            let auto = HighlightLanguage.detect(from: url)
            Button(action: { model.setCurrentLanguage(auto) }) {
                HStack {
                    Text("Auto (\(auto.displayName))")
                    if !model.hasLanguageOverride { Image(systemName: "checkmark") }
                }
            }
            ForEach(HighlightLanguage.allCases, id: \.self) { lang in
                Button(action: { model.setCurrentLanguage(lang) }) {
                    HStack {
                        Text(lang.displayName)
                        if model.hasLanguageOverride,
                           let id = model.tabs.selected?.id,
                           model.effectiveLanguage(forTabID: id, url: url) == lang {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
}
