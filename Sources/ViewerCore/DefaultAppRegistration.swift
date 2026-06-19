import CoreServices
import Foundation

/// TSK-356 — "Default anything Viewer".
///
/// The app declares itself a *Viewer* (`CFBundleTypeRole == Viewer`,
/// `LSHandlerRank == Alternate`) for many content types, so it shows up under
/// Finder's "Open With" but is intentionally NOT the system default handler.
/// This type powers an in-app "make TextView the default for these types" flow:
/// it enumerates the registered type groups, reports whether we are currently
/// the default handler for each, and (on the live machine) flips the default
/// via LaunchServices.
///
/// The model is split so the *logic* is host-testable: the LaunchServices calls
/// sit behind `RoleHandlerService`, an injectable seam. Tests drive a fake;
/// production injects `LiveRoleHandlerService` which wraps the LS C API. The
/// catalog itself (`Group.all`) is pure data that mirrors the
/// `CFBundleDocumentTypes` array in `scripts/Info.plist` — keep the two in sync.
public enum DefaultAppRegistration {

    /// Our bundle id. TCC-stable; matches `CFBundleIdentifier` in the bundle.
    /// Resolved live when running inside a bundle so a rebrand can't desync it,
    /// falling back to the known constant for `swift run` / test contexts.
    public static var ourBundleID: String {
        Bundle.main.bundleIdentifier ?? defaultBundleID
    }

    /// The compile-time-known bundle id (kept in lockstep with Info.plist).
    public static let defaultBundleID = "com.markdownviewer.MarkdownViewer"

    /// One row in the "File Associations" UI. Mirrors a single
    /// `CFBundleDocumentTypes` entry: a human label plus the UTIs that entry
    /// claims. A group is "ours" when we are the default handler for EVERY UTI
    /// in `utis` (an all-or-nothing flip keeps the UI honest — "Markdown" reads
    /// default only when both `net.daringfireball.markdown` and
    /// `public.markdown` resolve to us).
    public struct Group: Equatable, Sendable, Identifiable {
        /// Stable identity for SwiftUI `ForEach` / diffing. Derived from the
        /// first UTI, which is unique across groups.
        public var id: String { utis.first ?? name }
        /// Human-readable label shown in Settings (e.g. "Markdown").
        public let name: String
        /// The content-type identifiers (UTIs) this group registers for.
        public let utis: [String]

        public init(name: String, utis: [String]) {
            self.name = name
            self.utis = utis
        }
    }

    /// The registered document-type groups, in display order. Mirrors the four
    /// `CFBundleDocumentTypes` dicts in `scripts/Info.plist`. We expose ONLY the
    /// representative/primary UTIs per group for the "set default" flow — the
    /// full source-code list in Info.plist is large and many of its UTIs are
    /// claimed by Xcode/Apple; offering "make default for everything" on those
    /// would be a footgun. The flip targets the canonical types a user actually
    /// wants TextView to own.
    public static let groups: [Group] = [
        Group(name: "Markdown",
              utis: ["net.daringfireball.markdown", "public.markdown"]),
        Group(name: "Plain Text",
              utis: ["public.plain-text", "public.text"]),
        Group(name: "Source Code",
              utis: ["public.source-code", "public.json",
                     "public.xml", "public.yaml"]),
    ]

    /// Per-group current state, for rendering the Settings rows.
    public struct GroupStatus: Equatable, Sendable, Identifiable {
        public var id: String { group.id }
        public let group: Group
        /// True when TextView is the default handler for EVERY UTI in the group.
        public let isDefault: Bool
        /// True when at least one UTI is ours but not all — a "Partial" state
        /// the UI can surface (e.g. someone set us default for `.md` only).
        public let isPartial: Bool

        public init(group: Group, isDefault: Bool, isPartial: Bool) {
            self.group = group
            self.isDefault = isDefault
            self.isPartial = isPartial
        }
    }

    /// Compute current status for every group via `service`. Pure aggregation —
    /// the I/O is entirely in the injected service, so this is host-testable.
    public static func status(
        using service: RoleHandlerService,
        ourBundleID: String
    ) -> [GroupStatus] {
        groups.map { group in
            let ownedCount = group.utis.reduce(into: 0) { acc, uti in
                if let handler = service.defaultViewerHandler(forContentType: uti),
                   handler.caseInsensitiveCompare(ourBundleID) == .orderedSame {
                    acc += 1
                }
            }
            let all = ownedCount == group.utis.count
            return GroupStatus(
                group: group,
                isDefault: all,
                isPartial: ownedCount > 0 && !all
            )
        }
    }

    /// Outcome of attempting to flip a group's default handler to us.
    public enum SetResult: Equatable, Sendable {
        case success
        /// One or more UTIs failed; carries the OSStatus of the first failure.
        case failed(firstError: Int32)
    }

    /// Make TextView the default *viewer* for every UTI in `group`. Returns
    /// `.success` only when ALL the group's UTIs flipped without error; the
    /// first non-`noErr` status is reported so the UI can surface it.
    @discardableResult
    public static func setDefault(
        for group: Group,
        using service: RoleHandlerService,
        ourBundleID: String
    ) -> SetResult {
        var firstError: Int32?
        for uti in group.utis {
            let status = service.setDefaultViewerHandler(ourBundleID,
                                                         forContentType: uti)
            if status != noErr, firstError == nil {
                firstError = status
            }
        }
        if let err = firstError { return .failed(firstError: err) }
        return .success
    }
}

/// Seam over the LaunchServices default-role-handler C API so the registration
/// logic is testable without touching the live system DB.
public protocol RoleHandlerService: Sendable {
    /// The bundle id of the current default *viewer* handler for `contentType`,
    /// or `nil` if none is registered.
    func defaultViewerHandler(forContentType contentType: String) -> String?
    /// Set `bundleID` as the default *viewer* handler for `contentType`.
    /// Returns the LaunchServices `OSStatus` (`noErr` == success).
    func setDefaultViewerHandler(_ bundleID: String,
                                 forContentType contentType: String) -> Int32
}

/// Production `RoleHandlerService` backed by LaunchServices.
///
/// `LSCopyDefaultRoleHandlerForContentType` / `LSSetDefaultRoleHandlerForContentType`
/// are deprecated-but-functional and remain the ONLY supported way to read/set a
/// default *viewer* (vs editor) handler on macOS — `NSWorkspace.setDefaultApplication`
/// (macOS 12+) operates on URLs and roles but does not expose the viewer-vs-editor
/// distinction we rely on, and there is no non-deprecated content-type variant. We
/// scope the deprecation to this thin wrapper so the rest of the codebase stays clean.
public struct LiveRoleHandlerService: RoleHandlerService {
    public init() {}

    public func defaultViewerHandler(forContentType contentType: String) -> String? {
        guard let handler = LSCopyDefaultRoleHandlerForContentType(
            contentType as CFString, .viewer
        )?.takeRetainedValue() as String? else {
            return nil
        }
        return handler.isEmpty ? nil : handler
    }

    public func setDefaultViewerHandler(
        _ bundleID: String, forContentType contentType: String
    ) -> Int32 {
        LSSetDefaultRoleHandlerForContentType(
            contentType as CFString, .viewer, bundleID as CFString
        )
    }
}
