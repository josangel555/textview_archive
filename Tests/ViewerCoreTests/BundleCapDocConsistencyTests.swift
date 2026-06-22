import XCTest

/// TSK-1098 — the bundle-cap numbers drifted between the ENFORCING script and the
/// human docs twice. A one-time correction won't stick, so this guard pins them:
/// `scripts/check-bundle-size.sh` is the source of truth (its `BUDGET_MB` /
/// `EXEC_BUDGET_MB` defaults), and every doc that quotes the caps MUST cite the same
/// numbers. A future script bump that leaves a doc stale fails here, on the host gate.
final class BundleCapDocConsistencyTests: XCTestCase {
    private let docsThatQuoteCaps = ["CLAUDE.md", "scripts/build-app.sh"]

    func test_docs_match_enforced_bundle_caps() throws {
        let root = packageRoot()
        let script = try contents(root, "scripts/check-bundle-size.sh")
        let total = try defaultInt(inLineDefining: "BUDGET_MB", of: script)
        let exec = try defaultInt(inLineDefining: "EXEC_BUDGET_MB", of: script)
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(exec, 0)
        for doc in docsThatQuoteCaps {
            let text = try contents(root, doc)
            XCTAssertTrue(text.contains("\(total) MB"),
                "\(doc) does not cite the enforced TOTAL cap \(total) MB — bundle-cap doc drift (TSK-1098)")
            XCTAssertTrue(text.contains("\(exec) MB"),
                "\(doc) does not cite the enforced EXEC cap \(exec) MB — bundle-cap doc drift (TSK-1098)")
        }
    }

    /// The integer default from a shell line like `BUDGET_MB="${BUDGET_MB:-${1:-80}}"`
    /// or `EXEC_BUDGET_MB="${EXEC_BUDGET_MB:-60}"` — the last `:-<int>` on that line.
    private func defaultInt(inLineDefining name: String, of script: String) throws -> Int {
        guard let line = script.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("\(name)=") }) else {
            throw XCTSkip("no assignment line for \(name) in check-bundle-size.sh")
        }
        let parts = line.components(separatedBy: ":-")
        var lastInt: Int?
        for part in parts.dropFirst() {
            let digits = part.prefix { $0.isNumber }
            if let n = Int(digits) { lastInt = n }
        }
        guard let value = lastInt else {
            throw XCTSkip("could not parse a default int from \(name)'s line")
        }
        return value
    }

    private func contents(_ root: URL, _ rel: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    private func packageRoot() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewerCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // <root>/
    }
}
