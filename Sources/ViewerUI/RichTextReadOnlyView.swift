import SwiftUI
import ViewerCore

/// Read-only stacked render of the restricted RichText IR (TSK-706 foundation
/// slice). Editing + toolbar are LATER slices; this just walks the closed
/// ``RichTextDocument`` vocabulary and lays each block out vertically so the IR
/// can be eyeballed behind a flag. Pure SwiftUI, no AppKit surface, so there's
/// no compositor-occlusion danger (see CLAUDE.md TSK-488).
///
/// Gated by ``RichTextFeatureFlag/isEnabled`` — off by default; the host build
/// never shows it until a later slice wires an entry point. Render-path visual
/// validation is a VM concern; this slice only ships the model + this skeleton.
public struct RichTextReadOnlyView: View {
    private let document: RichTextDocument

    public init(document: RichTextDocument) {
        self.document = document
    }

    /// Convenience: parse raw Markdown into the restricted IR, then render.
    public init(markdown: String) {
        self.document = RichTextDocument.parse(markdown)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder
    private func blockView(_ block: RichBlock) -> some View {
        switch block {
        case let .heading(level, inlines):
            inlineText(inlines)
                .font(headingFont(level))
                .fontWeight(.semibold)

        case let .paragraph(inlines):
            inlineText(inlines)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}")
                        inlineText(item.inlines)
                    }
                }
            }

        case let .orderedList(start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + idx).")
                        inlineText(item.inlines)
                    }
                }
            }

        case let .blockquote(paras):
            HStack(spacing: 8) {
                Rectangle()
                    .frame(width: 3)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(paras.enumerated()), id: \.offset) { _, para in
                        inlineText(para)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch min(max(level, 1), 3) {
        case 1: return .title
        case 2: return .title2
        default: return .title3
        }
    }

    /// Compose a sequence of restricted inline runs into one styled `Text`.
    private func inlineText(_ inlines: [RichInline]) -> Text {
        inlines.reduce(Text("")) { acc, run in acc + styledText(run) }
    }

    private func styledText(_ inline: RichInline) -> Text {
        switch inline {
        case let .text(t):
            return Text(t)
        case let .bold(children):
            return inlineText(children).bold()
        case let .italic(children):
            return inlineText(children).italic()
        case let .strike(children):
            return inlineText(children).strikethrough()
        case let .code(c):
            return Text(c).font(.system(.body, design: .monospaced))
        case let .link(text, _):
            // Read-only skeleton: render the label underlined/accented; actual
            // navigation is a later slice.
            return inlineText(text).underline().foregroundColor(.accentColor)
        }
    }
}

/// Feature flag for the RichText editor surface. Off by default — the model +
/// read-only skeleton ship dark until later slices wire an entry point and add
/// VM-validated render coverage. Driven via the environment override so tests /
/// later UI can toggle it without persisted state.
public enum RichTextFeatureFlag {
    /// Process-wide enablement. Defaults to the `MDV_RICHTEXT` env var being a
    /// truthy value, so it's opt-in and never surfaces in a normal launch.
    public static var isEnabled: Bool {
        let v = ProcessInfo.processInfo.environment["MDV_RICHTEXT"]?.lowercased()
        return v == "1" || v == "true" || v == "yes"
    }
}
