import Foundation
import ViewerKit

/// Walkthrough script — the JSON payload an external agent (typically
/// Claude Code via MCP) sends to TextView to drive a guided tour.
///
/// Engine + UI integration come in follow-up commits per
/// `docs/WALKTHROUGH_DESIGN_v2.md`. This file ships the types only so
/// they can be reviewed independently and reused by the loader before
/// the player is wired up.
public struct WalkthroughScript: Codable, Sendable, Equatable {

    /// Schema discriminator. Reject loads where this doesn't match the
    /// known set so additive evolution is possible without silent drift.
    public let schema: SchemaVersion

    /// Stable identifier. Used for resume + completion log + targeting
    /// `walkthrough.append` / `replaceFrom` semantics (future).
    public let id: String

    public let title: String
    public let subtitle: String?

    /// Free-text. Convention: `claude:opus-4.7`, `human:jos`, etc.
    public let author: String?

    public let createdAt: Date?
    public let estimatedDurationSec: Int?

    /// Absolute path that all relative `path` fields on steps resolve
    /// against. If nil, every step path must be absolute. The loader
    /// rejects steps whose resolved path escapes `rootHint` via `..`.
    public let rootHint: String?

    public let defaultTargets: DefaultTargets?

    public let steps: [Step]

    public enum SchemaVersion: String, Codable, Sendable {
        case v1 = "textview.walkthrough/v1"
    }

    public init(
        schema: SchemaVersion = .v1,
        id: String,
        title: String,
        subtitle: String? = nil,
        author: String? = nil,
        createdAt: Date? = nil,
        estimatedDurationSec: Int? = nil,
        rootHint: String? = nil,
        defaultTargets: DefaultTargets? = nil,
        steps: [Step]
    ) {
        self.schema = schema; self.id = id; self.title = title
        self.subtitle = subtitle; self.author = author
        self.createdAt = createdAt
        self.estimatedDurationSec = estimatedDurationSec
        self.rootHint = rootHint; self.defaultTargets = defaultTargets
        self.steps = steps
    }
}

public struct DefaultTargets: Codable, Sendable, Equatable {
    public var editor: EditorTarget?
    public var popover: PopoverTarget?

    public init(editor: EditorTarget? = nil, popover: PopoverTarget? = nil) {
        self.editor = editor; self.popover = popover
    }
}

public enum EditorTarget: String, Codable, Sendable {
    case main, split
}

public enum PopoverTarget: String, Codable, Sendable {
    case anchorToEditor, anchorToSidebar, floating
}

/// A single step is narration + a list of actions. Most steps have
/// one action; multi-action steps (e.g. highlight + callout) execute
/// in declared order.
public struct Step: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let narration: String?
    public let speakerLabel: String?
    public let dwellSec: Double?
    public let actions: [Action]

    public init(
        id: String, narration: String? = nil,
        speakerLabel: String? = nil, dwellSec: Double? = nil,
        actions: [Action] = []
    ) {
        self.id = id; self.narration = narration
        self.speakerLabel = speakerLabel; self.dwellSec = dwellSec
        self.actions = actions
    }
}

/// Tagged-union of every verb the engine accepts. Codable keyed on
/// `kind` (a String literal). Unknown kinds reject the whole script
/// at load time — additive evolution declares a new schema version.
public enum Action: Codable, Sendable, Equatable {
    case openFile(OpenFilePayload)
    case revealLine(RevealLinePayload)
    case highlightRange(HighlightRangePayload)
    case showPopover(ShowPopoverPayload)
    case setView(SetViewPayload)
    case splitFile(SplitFilePayload)
    case runDiff(RunDiffPayload)
    case awaitUser(AwaitUserPayload)
    case addBookmark(AddBookmarkPayload)
    case revealInSidebar(RevealInSidebarPayload)
    case openGitPanel(OpenGitPanelPayload)
    case narrateOnly

    enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "openFile":
            self = .openFile(try OpenFilePayload(from: decoder))
        case "revealLine":
            self = .revealLine(try RevealLinePayload(from: decoder))
        case "highlightRange":
            self = .highlightRange(try HighlightRangePayload(from: decoder))
        case "showPopover":
            self = .showPopover(try ShowPopoverPayload(from: decoder))
        case "setView":
            self = .setView(try SetViewPayload(from: decoder))
        case "splitFile":
            self = .splitFile(try SplitFilePayload(from: decoder))
        case "runDiff":
            self = .runDiff(try RunDiffPayload(from: decoder))
        case "awaitUser":
            self = .awaitUser(try AwaitUserPayload(from: decoder))
        case "addBookmark":
            self = .addBookmark(try AddBookmarkPayload(from: decoder))
        case "revealInSidebar":
            self = .revealInSidebar(try RevealInSidebarPayload(from: decoder))
        case "openGitPanel":
            self = .openGitPanel(try OpenGitPanelPayload(from: decoder))
        case "narrateOnly":
            self = .narrateOnly
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown walkthrough action kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openFile(let p):
            try c.encode("openFile", forKey: .kind); try p.encode(to: encoder)
        case .revealLine(let p):
            try c.encode("revealLine", forKey: .kind); try p.encode(to: encoder)
        case .highlightRange(let p):
            try c.encode("highlightRange", forKey: .kind); try p.encode(to: encoder)
        case .showPopover(let p):
            try c.encode("showPopover", forKey: .kind); try p.encode(to: encoder)
        case .setView(let p):
            try c.encode("setView", forKey: .kind); try p.encode(to: encoder)
        case .splitFile(let p):
            try c.encode("splitFile", forKey: .kind); try p.encode(to: encoder)
        case .runDiff(let p):
            try c.encode("runDiff", forKey: .kind); try p.encode(to: encoder)
        case .awaitUser(let p):
            try c.encode("awaitUser", forKey: .kind); try p.encode(to: encoder)
        case .addBookmark(let p):
            try c.encode("addBookmark", forKey: .kind); try p.encode(to: encoder)
        case .revealInSidebar(let p):
            try c.encode("revealInSidebar", forKey: .kind); try p.encode(to: encoder)
        case .openGitPanel(let p):
            try c.encode("openGitPanel", forKey: .kind); try p.encode(to: encoder)
        case .narrateOnly:
            try c.encode("narrateOnly", forKey: .kind)
        }
    }
}

// MARK: - Action payloads
//
// Each payload is Codable + Sendable. Keep the surface narrow — the
// engine reads these and translates to existing DocumentModel
// request-nonce calls. Don't add free-form `[String: Any]` bags.

public struct OpenFilePayload: Codable, Sendable, Equatable {
    public let path: String
    public let target: EditorTarget?    // nil = use defaultTargets.editor
}

public struct RevealLinePayload: Codable, Sendable, Equatable {
    public let path: String?            // nil = current file
    public let line: Int                // 1-based
}

public struct HighlightRangePayload: Codable, Sendable, Equatable {
    public let path: String?
    public let startLine: Int
    public let endLine: Int
    public let style: HighlightStyle?   // nil = .focus
}

public enum HighlightStyle: String, Codable, Sendable {
    case focus, warn, info, agent
}

public struct ShowPopoverPayload: Codable, Sendable, Equatable {
    public let body: String             // markdown allowed
    public let anchor: PopoverAnchor
    public let style: PopoverTarget?
}

public enum PopoverAnchor: Codable, Sendable, Equatable {
    case line(path: String?, line: Int)
    case editor
    case sidebar(section: SidebarSection)
    case gitTab(tab: GitTab)
    case window                          // free-floating
}

/// Sidebar section names the walkthrough engine can anchor against.
/// Closed enum (not free-form string) so an unknown section name
/// rejects the script at load time instead of silently no-op'ing.
public enum SidebarSection: String, Codable, Sendable, Equatable {
    case files, bookmarks, search, git, claude, recentChanges
}

/// Git panel tabs the walkthrough engine can anchor against.
/// Matches the names declared in GitPanelView's tab enum.
public enum GitTab: String, Codable, Sendable, Equatable {
    case status, log, stash, trees, remotes
}

public struct SetViewPayload: Codable, Sendable, Equatable {
    /// `ViewMode` (defined in ViewerKit). Typed enum so an unknown
    /// mode rejects at load time rather than reaching the dispatcher.
    public let mode: ViewMode
    public let path: String?
}

public struct SplitFilePayload: Codable, Sendable, Equatable {
    public let path: String
    public let alongside: String?       // path currently in main, nil = current
}

public struct RunDiffPayload: Codable, Sendable, Equatable {
    public let sha: String?
    public let path: String?
    public let target: EditorTarget?
}

public struct AwaitUserPayload: Codable, Sendable, Equatable {
    public let prompt: String
    public let placeholder: String?
    public let pills: [String]?         // suggested replies
}

public struct AddBookmarkPayload: Codable, Sendable, Equatable {
    public let path: String
    public let line: Int?               // nil = file-level bookmark
}

public struct RevealInSidebarPayload: Codable, Sendable, Equatable {
    public let path: String
}

public struct OpenGitPanelPayload: Codable, Sendable, Equatable {
    public let tab: GitTab
}
