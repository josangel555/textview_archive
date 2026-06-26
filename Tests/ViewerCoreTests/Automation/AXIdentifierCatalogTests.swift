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
        for entry in AXIdentifierCatalog.critical {
            #expect(source.contains("\"\(entry.id)\""),
                    """
                    catalogued AX id \(entry.id) (surface: \(entry.surface)) is NOT present \
                    in Sources/ViewerUI — the control was renamed/removed, breaking the \
                    agent-drivable addressing contract. Restore the id or update \
                    AXIdentifierCatalog.critical deliberately.
                    """)
        }
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
