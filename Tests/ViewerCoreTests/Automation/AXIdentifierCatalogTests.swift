import Foundation
import Testing
@testable import ViewerCore

/// TSK-1254 slice 4 — drift guard for the agent-drivable addressing contract.
/// Every id in `AXIdentifierCatalog.critical` must still appear as a literal in
/// the ViewerUI source: renaming or deleting a critical control then silently
/// un-addresses it for the AX driver / element-ref tooling, so this goes RED.
/// (Sibling of `ScriptVerbCatalogTests` for the verb surface.)
struct AXIdentifierCatalogTests {

    /// Concatenated `Sources/ViewerUI` Swift source, located relative to this
    /// test file (#filePath → up 4 → repo root). Nil only if the source tree
    /// isn't present (e.g. an installed-bundle run, where this target won't run).
    private static func viewerUISource() -> String? {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()   // Automation
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let dir = repoRoot.appendingPathComponent("Sources/ViewerUI")
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        var blob = ""
        for case let url as URL in walker where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                blob += text
                blob += "\n"
            }
        }
        return blob.isEmpty ? nil : blob
    }

    // MARK: - The drift guard (the teeth)

    @Test func everyCriticalIdExistsInViewerUISource() {
        guard let source = Self.viewerUISource() else {
            Issue.record("Sources/ViewerUI not reachable from #filePath — path derivation broke")
            return
        }
        // Collect every quoted `"mdv.…"` literal in the source in ONE linear pass,
        // then check each catalogued id by O(1) set membership. The prior form
        // ran `source.contains("\"\(id)\"")` once PER id over a multi-MB blob —
        // O(ids × source) — which made this the slowest test in the suite (~2s,
        // the parallel long-pole). The set form is semantically identical (id
        // present as a complete quoted literal) and keeps the same teeth: a
        // renamed/removed id is absent from the set → the #expect fires. (TSK-836.)
        let present = Self.quotedMdvLiterals(in: source)
        for entry in AXIdentifierCatalog.critical {
            #expect(present.contains(entry.id),
                    """
                    catalogued AX id \(entry.id) (surface: \(entry.surface)) is NOT present \
                    in Sources/ViewerUI — the control was renamed/removed, breaking the \
                    agent-drivable addressing contract. Restore the id or update \
                    AXIdentifierCatalog.critical deliberately.
                    """)
        }
    }

    /// Every `"mdv.…"` quoted string literal in `source`, captured WITHOUT the
    /// surrounding quotes — one linear regex pass, the set the drift guard checks
    /// catalogued ids against (replacing one `contains` scan per id). Matches the
    /// prior `source.contains("\"\(id)\"")` semantics: an id counts only when it
    /// appears as a COMPLETE quoted literal, so `"mdv.foo"` never satisfies a
    /// lookup for the prefix `mdv.fo`, and a bare (unquoted) mention can't mask a
    /// removed control.
    static func quotedMdvLiterals(in source: String) -> Set<String> {
        let pattern = #""(mdv\.[^"\\]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        var out: Set<String> = []
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            out.insert(ns.substring(with: m.range(at: 1)))
        }
        return out
    }

    // MARK: - Self-consistency (pure)

    @Test func idsAreUnique() {
        let ids = AXIdentifierCatalog.critical.map(\.id)
        #expect(ids.count == Set(ids).count, "duplicate id in AXIdentifierCatalog.critical")
    }

    @Test func everyIdIsNamespacedAndNonEmpty() {
        for entry in AXIdentifierCatalog.critical {
            #expect(entry.id.hasPrefix("mdv."), "\(entry.id) must be in the mdv.* namespace")
            #expect(!entry.summary.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(entry.id) has an empty summary")
        }
    }

    /// Pins the teeth of the `quotedMdvLiterals` scan that backs the drift guard:
    /// only COMPLETE quoted literals count — a bare (commented/unquoted) mention,
    /// a prefix of a present literal, and an absent id all stay out of the set, so
    /// the guard can't be fooled into a false pass.
    @Test func quotedMdvLiteralsMatchesQuotedFormOnly() {
        let src = #"""
        let a = "mdv.present.one"
        view.accessibilityIdentifier("mdv.present.two")
        // bare, not a string literal: mdv.bare.unquoted
        let longer = "mdv.present.two.suffix"
        """#
        let found = Self.quotedMdvLiterals(in: src)
        #expect(found.contains("mdv.present.one"))
        #expect(found.contains("mdv.present.two"))
        #expect(found.contains("mdv.present.two.suffix"))
        // A bare (unquoted) occurrence does NOT count — a comment mention must not
        // mask a removed control.
        #expect(!found.contains("mdv.bare.unquoted"))
        // A prefix of a present literal is NOT itself present (quoted-exact).
        #expect(!found.contains("mdv.present"))
        #expect(!found.contains("mdv.absent"))
    }

    @Test func idsSetMatchesCritical() {
        #expect(AXIdentifierCatalog.ids == Set(AXIdentifierCatalog.critical.map(\.id)))
    }

    @Test func entryLookupRoundTrips() {
        for entry in AXIdentifierCatalog.critical {
            #expect(AXIdentifierCatalog.entry(entry.id)?.id == entry.id)
        }
        #expect(AXIdentifierCatalog.entry("mdv.definitely-not-a-control") == nil)
    }

    @Test func groupedCoversEveryEntryExactlyOnce() {
        let grouped = AXIdentifierCatalog.grouped()
        let flattened = grouped.flatMap { $0.entries }
        #expect(flattened.count == AXIdentifierCatalog.critical.count)
        #expect(Set(flattened.map(\.id)) == AXIdentifierCatalog.ids)
        // Surfaces emitted in sorted order.
        let surfaces = grouped.map { $0.surface }
        #expect(surfaces == surfaces.sorted())
    }
}
