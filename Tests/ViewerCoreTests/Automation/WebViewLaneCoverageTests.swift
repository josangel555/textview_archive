import Testing
import Foundation

/// Guards the webview-lane DRIFT class (TSK-621 / the gated-suite-in-no-lane trap).
///
/// A `#192`-gated UI suite (a `WebViewTestCase` subclass, or any suite whose
/// `setUp` calls `skipUnlessEnabled()`) SELF-SKIPS on the host headless gate and
/// is only ever run when it appears in a VM lane's `--filter` list. A gated suite
/// absent from the lane lists therefore runs NOWHERE — it self-skips on the host
/// AND is never invoked on the VM, so its "green" history means nothing (exactly
/// how TSK-621 shipped a silent regression, and how `SpreadsheetViewHostingTests`
/// sat un-laned after a one-off manual validation).
///
/// This enumerates the gated suites from the test source and asserts each appears
/// in BOTH lane lists:
///   - `scripts/test-in-vm.sh`            (the agent/local VM lane)
///   - `.github/workflows/nightly-vm.yml` (the unattended nightly CI lane)
///
/// Adding a new gated suite without wiring it into both lanes turns this RED — the
/// SOP rule "wiring it into the lane lists IS part of the change", enforced.
struct WebViewLaneCoverageTests {

    /// Repo root via `#filePath` (up 4: Automation → ViewerCoreTests → Tests → root).
    private static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()   // Automation
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// The class name from a `final class X: WebViewTestCase`/`: XCTestCase` line,
    /// or nil if the line isn't such a declaration.
    static func suiteClassName(in line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("class ") || t.hasPrefix("final class ") else { return nil }
        guard t.contains(": WebViewTestCase") || t.contains(": XCTestCase") else { return nil }
        let afterClass = t.replacingOccurrences(of: "final ", with: "").dropFirst("class ".count)
        let name = afterClass.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    /// Class names of `#192`-gated suites under `Tests/ViewerUITests` (top level).
    private static func gatedSuites(_ root: URL) -> Set<String> {
        let dir = root.appendingPathComponent("Tests/ViewerUITests")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var suites = Set<String>()
        for url in files where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard text.contains(": WebViewTestCase") || text.contains("skipUnlessEnabled()")
            else { continue }
            for line in text.split(separator: "\n") {
                if let name = suiteClassName(in: String(line)) { suites.insert(name) }
            }
        }
        return suites
    }

    @Test func everyGatedSuiteIsInBothVMLanes() throws {
        let root = Self.repoRoot()
        let suites = Self.gatedSuites(root)
        // Floor: a broken scan (0 suites) must not pass vacuously.
        #expect(suites.count >= 30,
                "gated-suite scan found only \(suites.count) — the source scan likely broke")

        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/test-in-vm.sh"), encoding: .utf8)
        let nightly = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/nightly-vm.yml"), encoding: .utf8)

        let missingScript = suites.sorted().filter { !script.contains("ViewerUITests.\($0)") }
        let missingNightly = suites.sorted().filter { !nightly.contains("ViewerUITests.\($0)") }

        #expect(missingScript.isEmpty,
                "gated suites missing from scripts/test-in-vm.sh (they run NOWHERE): \(missingScript)")
        #expect(missingNightly.isEmpty,
                "gated suites missing from .github/workflows/nightly-vm.yml: \(missingNightly)")
    }
}
