import Foundation

// Plugin manifest — the **smallest** subset of the v2 design (§4) that
// supports v1 today. v1 ships two contribution paths end-to-end:
//
//   1. `sidebar_section` Tier A — static list bound to a host-supplied
//      data source. Used by the bundled `RowCounterPlugin`.
//   2. `sidebar_section` Tier B — rows produced by an out-of-process
//      subprocess, dispatched through `PluginSubprocessHost`. Used by
//      third-party Tier B plugins. The provider carries `bin` (path
//      relative to the plugin folder) plus optional `args`.
//
// Other contribution shapes from the design (view modes, themes,
// formatters, etc.) are intentionally NOT modelled here — leaving the
// type surface narrow keeps the manifest validator honest. When we
// extend, we add new `Contribution` cases and re-run the schema
// fixtures.

/// On-disk schema for `plugin.json`. Decoded directly by `JSONDecoder`.
/// Unknown contribution `type`s decode into `.unknown`, so a forward-
/// compat manifest from a newer host doesn't fail the whole plugin —
/// it just registers fewer contributions and surfaces in the load
/// report (see `PluginRegistry.LoadReport`).
public struct PluginManifest: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let author: Author
    public let homepage: String?
    public let license: String?

    /// Host-version compatibility constraint. v1 parses these as
    /// opaque strings — full semver matching is a v1.1 follow-up
    /// (design §4.2). Behaviour: log mismatch, but still load.
    public let hostVersion: String
    public let manifestVersion: Int

    public let capabilities: [Capability]
    public let contributes: [Contribution]

    public struct Author: Decodable, Sendable, Equatable {
        public let name: String
        public let url: String?
        public let email: String?
    }

    /// v1 capability subset. The full design (§5.1) defines ~18.
    /// Adding here is cheap; we only enumerate the ones we actually
    /// gate on. `shellExec` is required for any Tier B contribution
    /// because that's the capability that authorises spawning a
    /// subprocess at all.
    public enum Capability: String, Decodable, Sendable, Equatable {
        case uiSidebar = "ui.sidebar"
        case shellExec = "shell.exec"
        // Forward-compat: unknown capability strings decode to
        // `.unknown` rather than throwing, so a future-host manifest
        // doesn't poison loading of compatible siblings.
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Capability(rawValue: raw) ?? .unknown
        }
    }

    public enum Contribution: Decodable, Sendable, Equatable {
        case sidebarSection(SidebarSectionContribution)
        case unknown(type: String)

        private enum CodingKeys: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "sidebar_section":
                self = .sidebarSection(try SidebarSectionContribution(from: decoder))
            default:
                // Don't throw — record and skip. Lets a multi-
                // contribution plugin partially register on a host
                // that doesn't know every type yet.
                self = .unknown(type: type)
            }
        }

        /// Which capabilities this contribution requires. Used by the
        /// registry to reject contributions whose required cap isn't
        /// in the manifest's declared `capabilities`.
        var requiredCapabilities: Set<Capability> {
            switch self {
            case .sidebarSection(let s):
                var req: Set<Capability> = [.uiSidebar]
                // Tier B/C provider implies `shell.exec` / `webview.run`
                // permissions. v1 ships Tier B only; Tier C is parsed
                // and rejected as not-supported (§3.3).
                if case .b = s.provider { req.insert(.shellExec) }
                return req
            case .unknown:
                return []
            }
        }
    }

    /// §2.1 sidebar-section contribution. v1 supports Tier A (static
    /// data, host-owned source) and Tier B (subprocess-owned rows).
    public struct SidebarSectionContribution: Decodable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let icon: String?
        public let order: Int?
        public let collapsedByDefault: Bool?
        public let provider: Provider

        /// Provider is a tagged union over `tier`. Tier A carries no
        /// extra fields (host owns the data). Tier B carries the
        /// path of the binary inside the plugin folder plus optional
        /// args. Tier C parses-and-rejects with a warning.
        public enum Provider: Decodable, Sendable, Equatable {
            case a
            case b(bin: String, args: [String], timeoutMs: Int?)
            case c
            case unknown(tier: String)

            private enum CodingKeys: String, CodingKey {
                case tier, bin, args, timeoutMs
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let tier = try c.decode(String.self, forKey: .tier)
                switch tier {
                case "A":
                    self = .a
                case "B":
                    // Tier B *must* declare a `bin`. We surface a
                    // missing `bin` as a decode error rather than
                    // silently accepting and crashing at spawn time.
                    let bin = try c.decode(String.self, forKey: .bin)
                    let args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
                    let timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs)
                    self = .b(bin: bin, args: args, timeoutMs: timeoutMs)
                case "C":
                    self = .c
                default:
                    self = .unknown(tier: tier)
                }
            }

            /// Human-readable label for log + warning messages. Not
            /// public API; only the registry and audit log read it.
            var tierLabel: String {
                switch self {
                case .a: return "A"
                case .b: return "B"
                case .c: return "C"
                case .unknown(let t): return t
                }
            }
        }
    }
}
