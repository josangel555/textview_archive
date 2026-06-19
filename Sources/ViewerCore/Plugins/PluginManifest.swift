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
        // TSK-754: gate for `menu_item` contributions. A plugin that
        // contributes app-menu items must declare `ui.menu`, the same
        // way a sidebar contributor declares `ui.sidebar`.
        case uiMenu = "ui.menu"
        case shellExec = "shell.exec"
        // TSK-782: gate for the `openURL` (Tier "U") action — the
        // foundation for office/web integrations (Docs, Wiki, Code
        // Review, CodeSearch). A contribution that opens an external
        // service URL in the browser must declare `web.open`, the same
        // way a subprocess contribution declares `shell.exec`. It is a
        // distinct (lower) privilege than `shell.exec`: it can only hand
        // a host-validated https/http URL to the system browser, never
        // spawn a process or read the filesystem.
        case webOpen = "web.open"
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
        case menuItem(MenuItemContribution)
        case unknown(type: String)

        private enum CodingKeys: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "sidebar_section":
                self = .sidebarSection(try SidebarSectionContribution(from: decoder))
            case "menu_item":
                self = .menuItem(try MenuItemContribution(from: decoder))
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
                // TSK-375: a Tier A section whose static rows carry a Tier B
                // (subprocess) action ALSO needs `shell.exec` — clicking the
                // button spawns a process, the same gate as a Tier B provider.
                if case .a(let rows) = s.provider {
                    for row in rows {
                        if case .b = row.action { req.insert(.shellExec); break }
                    }
                }
                return req
            case .menuItem(let m):
                var req: Set<Capability> = [.uiMenu]
                // A subprocess-backed item (Tier B) additionally needs
                // `shell.exec` — same gate as a Tier B sidebar section.
                if case .b = m.action { req.insert(.shellExec) }
                // An open-external-URL item (Tier U) needs `web.open`.
                if case .openURL = m.action { req.insert(.webOpen) }
                return req
            case .unknown:
                return []
            }
        }
    }

    /// §2.x menu-item contribution (TSK-754). A plugin contributes one
    /// command into the app's "Plugins" top-level menu, optionally
    /// nested under a named submenu. v1 supports two action tiers,
    /// mirroring `SidebarSectionContribution`:
    ///
    ///   - **Tier A** — a "noop" item. The contribution is declarative
    ///     only; selecting it does nothing host-side (used as a label
    ///     or for forward-compat declarations). No subprocess.
    ///   - **Tier B** — selecting the item spawns the plugin's `bin`
    ///     with a `runCommand` envelope, dispatched through the same
    ///     `PluginSubprocessHost` the sidebar uses. The provider carries
    ///     `bin` (path relative to the plugin folder), optional `args`,
    ///     and an optional `timeoutMs`.
    ///   - **Tier U** (TSK-782) — selecting the item opens an external
    ///     service URL in the user's browser. The action carries a
    ///     `urlTemplate` that interpolates the current host context
    ///     (`{path}`, `{filename}`, `{selection}`, `{query}`, `{line}`),
    ///     expanded + validated by `PluginURLTemplate`. This is the
    ///     foundation for office/web integrations (Docs, Wiki, Code
    ///     Review, CodeSearch, code browsers) — no subprocess, no code
    ///     execution, just a host-validated https/http URL handed to the
    ///     system browser. Gated by the `web.open` capability.
    ///
    /// Tier C (WebView) is parsed-and-rejected like the sidebar's.
    public struct MenuItemContribution: Decodable, Sendable, Equatable {
        public let id: String
        public let title: String
        /// Optional submenu name. When present the item nests under a
        /// submenu of that name inside the Plugins menu; when absent the
        /// item sits at the top level of the Plugins menu.
        public let submenu: String?
        public let order: Int?
        public let action: Action

        public init(
            id: String,
            title: String,
            submenu: String? = nil,
            order: Int? = nil,
            action: Action
        ) {
            self.id = id
            self.title = title
            self.submenu = submenu
            self.order = order
            self.action = action
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, submenu, order, action
        }

        /// The behaviour bound to the menu item. A tagged union over
        /// `tier`, mirroring the sidebar provider so plugin authors only
        /// learn one shape.
        public enum Action: Decodable, Sendable, Equatable {
            case a
            case b(bin: String, args: [String], timeoutMs: Int?)
            /// Tier U (TSK-782) — open an external service URL. Carries
            /// the raw template; expansion + scheme validation happen at
            /// invocation time via `PluginURLTemplate`. The template is
            /// kept verbatim here (not pre-expanded) because the host
            /// context (focused file, selection, query) is only known
            /// when the user selects the item, not at manifest decode.
            case openURL(urlTemplate: String)
            case c
            case unknown(tier: String)

            private enum CodingKeys: String, CodingKey {
                case tier, bin, args, timeoutMs, urlTemplate
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let tier = try c.decode(String.self, forKey: .tier)
                switch tier {
                case "A":
                    self = .a
                case "B":
                    // Tier B *must* declare a `bin` — surface a missing
                    // one as a decode error rather than crashing at
                    // invocation time (same contract as the sidebar).
                    let bin = try c.decode(String.self, forKey: .bin)
                    let args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
                    let timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs)
                    self = .b(bin: bin, args: args, timeoutMs: timeoutMs)
                case "U":
                    // Tier U *must* declare a `urlTemplate`. A missing one
                    // is a decode error (same fail-at-load contract as
                    // Tier B's `bin`) rather than a silently inert item.
                    let template = try c.decode(String.self, forKey: .urlTemplate)
                    self = .openURL(urlTemplate: template)
                case "C":
                    self = .c
                default:
                    self = .unknown(tier: tier)
                }
            }

            /// Human-readable label for log + warning messages.
            var tierLabel: String {
                switch self {
                case .a: return "A"
                case .b: return "B"
                case .openURL: return "U"
                case .c: return "C"
                case .unknown(let t): return t
                }
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

        /// One static row of a Tier A section, declared verbatim in
        /// plugin.json (`{"id": "...", "label": "...", "detail": "..."}`).
        ///
        /// A row may carry an optional `action` (TSK-375) — the "button/
        /// widget" surface. An actionable row renders an inline button the
        /// user can click (e.g. a "Copy as Crux URL" row). The action is a
        /// tagged union over `tier`, mirroring `MenuItemContribution.Action`
        /// so plugin authors learn one action shape across every extension
        /// point. Absent `action` ⇒ a plain text row (the pre-375 shape).
        public struct StaticRow: Decodable, Sendable, Equatable {
            public let id: String
            public let label: String
            public let detail: String?
            /// Optional inline action. `nil` ⇒ a plain (inert) text row.
            public let action: RowAction?

            public init(
                id: String,
                label: String,
                detail: String? = nil,
                action: RowAction? = nil
            ) {
                self.id = id
                self.label = label
                self.detail = detail
                self.action = action
            }

            private enum CodingKeys: String, CodingKey {
                case id, label, detail, action
            }
        }

        /// The behaviour bound to an actionable sidebar row (TSK-375). A
        /// tagged union over `tier`, mirroring `MenuItemContribution.Action`
        /// exactly:
        ///
        ///   - **Tier A** — declarative-only. The row renders a button, but
        ///     selecting it does nothing host-side (forward-compat label).
        ///     No subprocess.
        ///   - **Tier B** — clicking the button spawns the plugin's `bin`
        ///     with a `runCommand` envelope, dispatched through the same
        ///     `PluginSubprocessHost` the sidebar/menu use. Carries `bin`
        ///     (path relative to the plugin folder), optional `args`, and an
        ///     optional `timeoutMs`.
        ///
        /// Tier C (WebView) is parsed-and-rejected like the others.
        public enum RowAction: Decodable, Sendable, Equatable {
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
                    // Tier B *must* declare a `bin` — surface a missing one
                    // as a decode error (same contract as the menu item).
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

            /// Human-readable label for log + warning messages.
            var tierLabel: String {
                switch self {
                case .a: return "A"
                case .b: return "B"
                case .c: return "C"
                case .unknown(let t): return t
                }
            }
        }

        /// Provider is a tagged union over `tier`. Tier A carries its
        /// rows STATICALLY in the manifest (`rows`, optional — absent
        /// means an empty section; no subprocess is ever spawned).
        /// Tier B carries the path of the binary inside the plugin
        /// folder plus optional args. Tier C parses-and-rejects with
        /// a warning.
        public enum Provider: Decodable, Sendable, Equatable {
            case a(rows: [StaticRow])
            case b(bin: String, args: [String], timeoutMs: Int?)
            case c
            case unknown(tier: String)

            private enum CodingKeys: String, CodingKey {
                case tier, bin, args, timeoutMs, rows
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let tier = try c.decode(String.self, forKey: .tier)
                switch tier {
                case "A":
                    // Static-bind (TSK-469): rows come straight from the
                    // manifest. Absent `rows` decodes as an empty section —
                    // the old placeholder row is gone.
                    let rows = try c.decodeIfPresent([StaticRow].self, forKey: .rows) ?? []
                    self = .a(rows: rows)
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
