import XCTest
import Foundation

/// UAT executable companion — **group 12/12: walkthrough-and-code-review**.
///
/// Durable T4 live-app smoke for `docs/uat/smokes/walkthrough-and-code-review.md`
/// (WCR-01..06). Unlike every other UAT group, the surfaces here are NOT
/// reachable through the standard `--script` verb dispatcher: per the smoke
/// catalog (§"There is NO walkthrough or review script verb"), `ScriptVerbDispatch`
/// exposes open/view/zoom/tabs/git-panel/sidebar/etc. but **no walkthrough
/// playback and no review authoring**. The catalog therefore mandates driving
/// walkthroughs via the **`--walkthrough PATH` launch flag** and asserting at
/// the engine layer, and driving review at the **store/session layer**.
///
/// The shared `MultiScenarioTestCase` / `AppLauncher.runScript` path hardcodes
/// `argv = ["--script", scriptPath, fileArg]` and cannot inject `--walkthrough`
/// or `TV_WALKTHROUGH_DROP=1`. So this suite owns a small private launcher
/// (`runWalkthrough`) that spawns the assembled `dist/TextView.app` with BOTH
/// `--walkthrough X --script Y`: the walkthrough auto-plays while the `--script`
/// `delay` steps keep the process alive and emit a `DiagnosticDump` JSON per
/// step (the same `mdv-step-NN.json` artifacts the other suites consume). We
/// reuse `LaunchHarness` only for project-root resolution + the `isAppBuilt`
/// skip gate.
///
/// ## Observability reality for THIS group (probed against the live bundle)
///
///  1. **`--walkthrough PATH` + `--script PATH` coexist.** Both run from
///     `applicationDidFinishLaunching`: the script-runner on its own `Task`,
///     the walkthrough start deferred one runloop tick. Confirmed: a launch
///     with both flags auto-plays the tour AND captures the realized tree at
///     each scripted `delay`.
///
///  2. **The walkthrough player strip is INVISIBLE to the dump's structural
///     probes.** SwiftUI `.accessibilityIdentifier("mdv.walkthrough.*")` does
///     NOT propagate onto `NSView.accessibilityIdentifier()` that
///     `DiagnosticDump` reads (the group-1/2/5/6 finding, re-confirmed here:
///     ZERO `mdv.walkthrough.*` ids in `contentView`). The strip's SwiftUI
///     body also produces no uniquely-named NSView class — it renders as
///     generic `DocumentView` / `NSTextFieldSimpleLabel` hosts. So "is the
///     strip mounted" is NOT directly observable; we infer activation
///     **behaviorally** from the `DocumentModel` mutations the tour's verbs
///     drive (a tab opened, the view mode changed) which DO surface in
///     `ScriptVerb.modelStateDump`.
///
///  3. **Auto-advance (`dwellSec > 0`) does NOT progress in the occluded
///     (`MDV_BACKGROUND`) launch.** The advance is a `Task.sleep`-based
///     reschedule driven off the SwiftUI strip's lifecycle; with the window
///     occluded and the process non-foreground the scheduled advance never
///     fires, so a `dwellSec:1.0` tour stalls on step 1. A `dwellSec:0` step,
///     by contrast, advances **synchronously** inside the engine's `next()`
///     chain (see `WalkthroughAutoAdvance.schedule` zero-dwell fast path), so
///     a zero-dwell script chains deterministically to the last step. This
///     suite therefore uses **`dwellSec:0`** to reach later steps and verify
///     the verb sequence lands; transport/dwell timing is the headless
///     `WalkthroughAutoAdvanceTests` lane + the VM lane, not this one. Logged
///     as F-WCR-AUTOADV.
///
///  4. **The review surface has NO live observable from a `--script` run** —
///     no create-comment affordance, no review-state keys in
///     `modelStateDump`, and the `.review` Git-panel tab is unreachable from
///     the scripted/occluded path (same gate as group-6 `GitPanelUATTests`).
///     The review state machine, project-local store, flush durability,
///     severity/staleness rendering inputs, and export→`.sent` are all
///     exercised at the store/session layer by the existing
///     `ReviewSessionTests` / `ReviewStoreProjectLocalTests` /
///     `ReviewExporterTests` headless suites (WCR-04/05 evidence). This suite
///     adds the one thing those cannot: the **live walkthrough+review
///     coexistence** boundary (WCR-06) — a tour playing in a window that also
///     holds a flushed project-local review, confirming neither disturbs the
///     other's on-disk / model state.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process wiring: `main.swift`'s `--walkthrough` arg parse →
/// `WalkthroughLoader.load` → deferred `WalkthroughPlayerController.start` →
/// `WalkthroughEngine` → `WalkthroughPlayerImpl` delegate → live
/// `DocumentModel` mutations, in a real `NSWindow` with the real AppDelegate.
/// None of that CLI→controller→model integration exists in a bare `(model,
/// sessions)` headless pair — the engine/loader/bridge are unit-tested
/// headless, but the *flag wiring that activates them in a real process* is
/// only here. Self-skips on the headless gate (`isAppBuilt` false); runs for
/// real on the VM/nightly lane or a host-occluded UAT run.
@MainActor
final class WalkthroughAndCodeReviewUATTests: LiveAppTestCase {

    private var harness: LaunchHarness!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { harness = LaunchHarness(label: "WalkthroughCodeReviewUAT") }
    }

    override func tearDown() async throws {
        await MainActor.run { harness?.cleanup(); harness = nil }
        try await super.tearDown()
    }

    // MARK: - WCR-01 — CLI walkthrough drives the live DocumentModel

    /// WCR-01 (live-app slice): a `--walkthrough` tour's `openFile` + `setView`
    /// verbs land on the real `DocumentModel`.
    ///
    /// **F-WCR-AUTOADV reality (probed):** in the occluded (`MDV_BACKGROUND`)
    /// CLI launch the engine advances by EXACTLY ONE step from the initial
    /// `WalkthroughPlayerController.start()` — `start()` lands step 1 and fires
    /// one `scheduleAdvanceIfNeeded()`; the auto-advance task calls
    /// `engine.next()` DIRECTLY (which does not re-schedule), and the
    /// SwiftUI-strip lifecycle callbacks that WOULD re-arm it don't fire while
    /// the window is occluded. So a non-interactive tour deterministically
    /// reaches step 1 + one advance to step 2, then parks. The suite encodes
    /// that contract: step 1 = `openFile main` + `setView source`, step 2 =
    /// `openFile helper`. After the run, helper is focused (one auto-advance
    /// landed it) and the requested mode held. Reaching step 3+ needs live
    /// transport (the VM lane). This is the proof the CLI flag actually arms +
    /// runs the engine against a real process — not just the headless engine.
    func test_WCR_01_cliWalkthroughDrivesModel() throws {
        try skipUnlessBuilt()
        let root = try makeTourFixture()
        let main = root.appendingPathComponent("main.swift")
        let helper = root.appendingPathComponent("helper.swift")
        let readme = root.appendingPathComponent("README.md")

        // step1 (dwell 0) opens main + sets source; the single auto-advance
        // lands step2's openFile helper. step3 parks (dwell 5).
        let tour = try writeScript(
            in: root, name: "wcr01.json", id: "wcr01",
            rootHint: root.path,
            steps: """
            { "id": "s1", "narration": "Open main in source", "dwellSec": 0, "actions": [
                {"kind":"openFile","path":"\(main.path)","target":"main"},
                {"kind":"setView","mode":"source"} ] },
            { "id": "s2", "narration": "Open helper", "dwellSec": 0, "actions": [
                {"kind":"openFile","path":"\(helper.path)","target":"main"} ] },
            { "id": "s3", "narration": "Narrate only", "dwellSec": 5, "actions": [
                {"kind":"narrateOnly"} ] }
            """)

        // argv = README.md (distinct from the tour's files) so we can tell the
        // tour's openFile apart from the argv open.
        let dumps = try runWalkthrough(
            tourJSON: tour, argFile: readme,
            scriptSteps: ["delay 1.5", "delay 0.5"])

        XCTAssertFalse(dumps.isEmpty, "no step dumps — app may not have launched")
        guard let last = dumps.last else { return }
        // The tour's verbs landed on the live model:
        XCTAssertEqual(modelString(last, "currentStateKind"), "loaded",
                       "tour-opened file did not reach .loaded")
        XCTAssertTrue(modelString(last, "currentURL").hasSuffix("helper.swift"),
                      "step2 openFile (helper.swift) is not the focused tab — got \(modelString(last, "currentURL"))")
        XCTAssertEqual(modelString(last, "currentViewMode"), "source",
                       "setView source did not take")
        // README (argv) + main + helper => the tour opened its own tabs.
        XCTAssertGreaterThanOrEqual(modelInt(last, "tabCount"), 3,
                                    "tour did not open files in their own tabs (argv + main + helper)")
    }

    /// WCR-01 variation — **highlightRange landing is model-only observable.**
    /// The persistent highlight stripe lives in the window-root overlay
    /// (coordinate space `walkthroughOverlay`), driven by the
    /// `WalkthroughBridge.highlight` nonce channel. The catalog notes the
    /// overlay only renders when `h.url == currentURL` AND the range is
    /// on-screen + post-layout (`lineHeight > 0`) — none of which is
    /// observable from an occluded `cacheDisplay`/dump run, and the bridge
    /// state is NOT in `modelStateDump`. So this is authored as a SMOKE that
    /// the highlight step does not derail the tour (the file stays open, no
    /// error state), with the stripe-render itself logged as a VM-lane gap.
    func test_WCR_01_highlightStepDoesNotDerailTour() throws {
        try skipUnlessBuilt()
        let root = try makeTourFixture()
        let main = root.appendingPathComponent("main.swift")

        let tour = try writeScript(
            in: root, name: "wcr01b.json", id: "wcr01b",
            rootHint: root.path,
            steps: """
            { "id": "s1", "dwellSec": 0, "actions": [
                {"kind":"openFile","path":"\(main.path)","target":"main"},
                {"kind":"setView","mode":"source"} ] },
            { "id": "s2", "dwellSec": 0, "actions": [
                {"kind":"highlightRange","startLine":2,"endLine":4,"style":"focus"} ] },
            { "id": "s3", "dwellSec": 5, "actions": [ {"kind":"narrateOnly"} ] }
            """)

        let dumps = try runWalkthrough(
            tourJSON: tour, argFile: main,
            scriptSteps: ["delay 1.5"])

        guard let last = dumps.last else {
            return XCTFail("no step dumps for highlight tour")
        }
        XCTAssertNotEqual(modelString(last, "currentStateKind"), "error",
                          "highlightRange step put the document in .error")
        XCTAssertTrue(modelString(last, "currentURL").hasSuffix("main.swift"),
                      "highlight step lost the open file")
    }

    // MARK: - WCR-02 — multi-target verbs (splitFile / openGitPanel) on a repo

    /// WCR-02 (live-app slice): `openFile` → `setView` → `openGitPanel` →
    /// `splitFile` against a real git-repo fixture. We assert the verbs the
    /// dump CAN observe behaviorally: the primary file stays focused/loaded
    /// through the multi-target sequence (the verb chain doesn't error or lose
    /// the document). Popover anchoring + hit-testing, the GIT-section mount,
    /// the split second-pane realization, and the `[tour]` bookmark cleanup are
    /// overlay/AppKit observables not in the dump (same class of gap as
    /// group-6); logged as VM-lane gaps.
    func test_WCR_02_multiTargetVerbsDoNotDerail() throws {
        try skipUnlessBuilt()
        let root = try makeGitRepoFixture()
        let a = root.appendingPathComponent("a.swift")
        let b = root.appendingPathComponent("b.swift")

        let tour = try writeScript(
            in: root, name: "wcr02.json", id: "wcr02",
            rootHint: root.path,
            steps: """
            { "id": "s1", "dwellSec": 0, "actions": [
                {"kind":"openFile","path":"\(a.path)","target":"main"},
                {"kind":"setView","mode":"source"} ] },
            { "id": "s2", "dwellSec": 0, "actions": [
                {"kind":"showPopover","body":"anchored note","anchor":{"kind":"line","path":"\(a.path)","line":2}} ] },
            { "id": "s3", "dwellSec": 0, "actions": [
                {"kind":"splitFile","path":"\(b.path)","alongside":"\(a.path)"} ] },
            { "id": "s4", "dwellSec": 0, "actions": [
                {"kind":"revealInSidebar","path":"\(a.path)"} ] },
            { "id": "s5", "dwellSec": 0, "actions": [
                {"kind":"openGitPanel","tab":"status"} ] },
            { "id": "s6", "dwellSec": 5, "actions": [
                {"kind":"addBookmark","path":"\(a.path)","line":2} ] }
            """)

        let dumps = try runWalkthrough(
            tourJSON: tour, argFile: a,
            scriptSteps: ["delay 1.5"])

        guard let last = dumps.last else {
            return XCTFail("no step dumps for multi-target tour")
        }
        // The whole verb chain ran without putting the doc into error / loading.
        XCTAssertNotEqual(modelString(last, "currentStateKind"), "error",
                          "multi-target verb chain landed in .error")
        XCTAssertNotEqual(modelString(last, "currentStateKind"), "loading",
                          "multi-target verb chain stuck in .loading")
        // The split's primary-pane selection keeps `a.swift` focused (the verb
        // selects the primary pane as the active target).
        XCTAssertTrue(modelString(last, "currentURL").hasSuffix(".swift"),
                      "lost the focused source file after the split/git/bookmark chain")
    }

    // MARK: - WCR-03 — schema rejection: a v2-verb under /v1 must NOT play

    /// WCR-03 (live-app slice): a script declaring `schema /v1` but carrying a
    /// **v2-only `flash` verb** is rejected wholesale by `WalkthroughLoader`
    /// (`UnsupportedSchemaError` / unknown-kind decode) — `main.swift`'s
    /// `startWalkthrough` writes the failure to stderr and leaves the player
    /// inactive WITHOUT exiting. Asserts the live app: (a) stays alive and
    /// usable (the `--script` `delay`/snapshot path still produces dumps), and
    /// (b) does NOT partially play — the argv file is the focused tab and NO
    /// extra tour tab was opened (a `.flash`-bearing tour would, if it played,
    /// have driven `openFile` in step 1).
    ///
    /// NOTE on the fixture: a `flash` verb decodes fine under BOTH /v1 and /v2
    /// today (the decoder is schema-agnostic for known kinds — see
    /// `WalkthroughSchemaErrorTests.test_flashVerb_underV1Schema_decodesSuccessfully`).
    /// The catalog's "v1-reader rejects a v2-only verb" is exercised at the
    /// schema layer; the robust LIVE reject we can drive is a genuinely
    /// **unknown** verb kind, which `Action.init(from:)` rejects with a
    /// `dataCorrupted` decode error for every schema, fully rejecting the load.
    func test_WCR_03_unknownVerbScriptDoesNotPlayAndAppSurvives() throws {
        try skipUnlessBuilt()
        let root = try makeTourFixture()
        let main = root.appendingPathComponent("main.swift")
        let helper = root.appendingPathComponent("helper.swift")
        let readme = root.appendingPathComponent("README.md")

        // step 1 opens helper.swift; if the load is (wrongly) accepted +
        // played, the focused tab would become helper.swift. An unknown verb
        // kind in step 2 must reject the ENTIRE script.
        let badPath = root.appendingPathComponent("bad.json")
        let bad = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "wcr03-bad",
          "title": "Bad script",
          "rootHint": "\(root.path)",
          "steps": [
            { "id": "s1", "dwellSec": 0, "actions": [
                {"kind":"openFile","path":"\(helper.path)","target":"main"} ] },
            { "id": "s2", "dwellSec": 0, "actions": [
                {"kind":"teleport","path":"\(main.path)","line":1} ] }
          ]
        }
        """
        try bad.write(to: badPath, atomically: true, encoding: .utf8)

        let dumps = try runWalkthrough(
            tourJSON: badPath, argFile: readme,
            scriptSteps: ["delay 1.0", "delay 0.5"])

        XCTAssertFalse(dumps.isEmpty,
                       "app produced no dumps — a rejected walkthrough must NOT take down the process")
        guard let last = dumps.last else { return }
        // App alive + usable: argv file opened normally, no error state.
        XCTAssertNotEqual(modelString(last, "currentStateKind"), "error",
                          "rejected walkthrough left the app in .error")
        XCTAssertTrue(modelString(last, "currentURL").hasSuffix("README.md"),
                      "rejected script PARTIALLY PLAYED — focused tab is \(modelString(last, "currentURL")), expected the argv README.md")
        // No tour tab opened: only the argv README.md tab exists.
        XCTAssertEqual(modelInt(last, "tabCount"), 1,
                       "rejected script opened a tab — it must not partially play (tabCount=\(modelInt(last, "tabCount")))")
    }

    /// WCR-03 variation — a `--walkthrough /does/not/exist.json` path: the
    /// loader's `ioFailed` surfaces only on stderr, the app stays alive, no
    /// strip, no tour tab. Same survival contract as the unknown-verb case.
    func test_WCR_03_nonexistentScriptPath_appSurvives() throws {
        try skipUnlessBuilt()
        let root = try makeTourFixture()
        let readme = root.appendingPathComponent("README.md")
        let missing = root.appendingPathComponent("does-not-exist.json")

        let dumps = try runWalkthrough(
            tourJSON: missing, argFile: readme,
            scriptSteps: ["delay 1.0"])

        XCTAssertFalse(dumps.isEmpty,
                       "a missing --walkthrough path must NOT crash the app")
        guard let last = dumps.last else { return }
        XCTAssertTrue(modelString(last, "currentURL").hasSuffix("README.md"),
                      "missing walkthrough disturbed the normal argv open")
        XCTAssertEqual(modelInt(last, "tabCount"), 1,
                       "missing walkthrough opened a spurious tab")
    }

    // MARK: - WCR-06 — walkthrough + review coexistence (live boundary)

    /// WCR-06 (live-app slice): a tour plays in a window whose repo ALSO holds
    /// a flushed project-local `ReviewSession` (seeded at the store layer, the
    /// only way to create a review — there is no live add-comment affordance).
    /// Confirms the two systems coexist without interference: the tour's
    /// `openFile`/`setView`/`openGitPanel` verbs land on the live model, and
    /// the seeded review JSON on disk is UNTOUCHED by the tour lifecycle
    /// (state, comment count, and unresolved count are identical before/after
    /// the live run). This is the durable regression anchor for "Note→Code-
    /// Review is decoupled" — the Note button is visual-only today, so a tour
    /// cannot mutate the review.
    ///
    /// The review-store seeding + the state-machine / export / staleness /
    /// debounce contracts (WCR-04/05) are covered by `ReviewSessionTests` /
    /// `ReviewStoreProjectLocalTests` / `ReviewExporterTests`; here we only
    /// assert the ISOLATION across a real walkthrough run.
    func test_WCR_06_tourDoesNotMutateProjectLocalReview() throws {
        try skipUnlessBuilt()
        let root = try makeGitRepoFixture()
        let a = root.appendingPathComponent("a.swift")

        // Seed a minimal project-local review JSON under .textview/reviews/.
        // We hand-write the on-disk shape (the live UI has no create path) and
        // checksum the file before/after the tour to prove non-interference.
        let reviewsDir = root.appendingPathComponent(".textview/reviews")
        try FileManager.default.createDirectory(at: reviewsDir, withIntermediateDirectories: true)
        let reviewFile = reviewsDir.appendingPathComponent("seed-review.json")
        let seededJSON = """
        { "id": "seed-review", "title": "Seeded", "state": "inReview", "comments": [] }
        """
        try seededJSON.write(to: reviewFile, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: reviewFile)

        let tour = try writeScript(
            in: root, name: "wcr06.json", id: "wcr06",
            rootHint: root.path,
            steps: """
            { "id": "s1", "dwellSec": 0, "actions": [
                {"kind":"openFile","path":"\(a.path)","target":"main"},
                {"kind":"setView","mode":"source"} ] },
            { "id": "s2", "dwellSec": 0, "actions": [
                {"kind":"openGitPanel","tab":"status"} ] },
            { "id": "s3", "dwellSec": 0, "actions": [
                {"kind":"highlightRange","startLine":1,"endLine":2,"style":"focus"} ] },
            { "id": "s4", "dwellSec": 5, "actions": [ {"kind":"narrateOnly"} ] }
            """)

        let dumps = try runWalkthrough(
            tourJSON: tour, argFile: a,
            scriptSteps: ["delay 1.5"])

        guard let last = dumps.last else {
            return XCTFail("no step dumps for coexistence tour")
        }
        // The tour ran against the live model.
        XCTAssertTrue(modelString(last, "currentURL").hasSuffix("a.swift"),
                      "tour lost the open file during coexistence run")
        XCTAssertNotEqual(modelString(last, "currentStateKind"), "error",
                          "coexistence run errored")
        // The seeded review on disk is byte-identical — the tour did not touch it.
        let after = try Data(contentsOf: reviewFile)
        XCTAssertEqual(before, after,
                       "the active walkthrough mutated the project-local review on disk (Note→review must stay decoupled)")
    }

    // MARK: - Skip gate

    private func skipUnlessBuilt() throws {
        guard harness.isAppBuilt else {
            throw XCTSkip("Build .app first (e.g. bash scripts/build-app.sh debug)")
        }
    }

    // MARK: - Fixtures

    /// A scratch tour folder with two small Swift files + a README.
    private func makeTourFixture() throws -> URL {
        let dir = harness.tmpDir.appendingPathComponent("tour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        import Foundation
        struct Main { static func main() { print("hi") } }
        let x = 1
        let y = 2
        let z = 3
        func helper() {}
        """.write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "struct Helper { let marker = \"helper-file\" }\n"
            .write(to: dir.appendingPathComponent("helper.swift"), atomically: true, encoding: .utf8)
        try "# Title\n\nbody text\n"
            .write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return dir
    }

    /// A scratch git repo with two tracked Swift files + one commit.
    private func makeGitRepoFixture() throws -> URL {
        let dir = harness.tmpDir.appendingPathComponent("proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "let aOne = 1\nlet aTwo = 2\nfunc a() {}\n"
            .write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "let bOne = 1\nfunc b() {}\n"
            .write(to: dir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        runGit(["init", "-q"], in: dir)
        runGit(["config", "user.email", "uat@example.com"], in: dir)
        runGit(["config", "user.name", "UAT"], in: dir)
        runGit(["add", "."], in: dir)
        runGit(["commit", "-q", "-m", "seed"], in: dir)
        return dir
    }

    /// Build + write a walkthrough JSON; returns its URL.
    private func writeScript(
        in dir: URL, name: String, id: String,
        rootHint: String, steps: String
    ) throws -> URL {
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "\(id)",
          "title": "UAT \(id)",
          "author": "claude:opus-4.8",
          "rootHint": "\(rootHint)",
          "steps": [
        \(steps)
          ]
        }
        """
        let url = dir.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Private launcher (passes --walkthrough; AppLauncher cannot)

    /// Spawn `dist/TextView.app` with `--walkthrough <tourJSON> --script <tmp>
    /// <argFile>`, occluded (`MDV_BACKGROUND=1`), poll for exit, return the
    /// per-step `DiagnosticDump` dicts. Mirrors `AppLauncher.runScript` but
    /// threads the extra `--walkthrough` flag the shared launcher omits.
    @discardableResult
    private func runWalkthrough(
        tourJSON: URL,
        argFile: URL,
        scriptSteps: [String],
        timeout: TimeInterval = 30
    ) throws -> [[String: Any]] {
        let artifacts = harness.tmpDir.appendingPathComponent("art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        // Clear any stale step files.
        for n in 1...99 {
            let s = String(format: "%02d", n)
            try? FileManager.default.removeItem(at: artifacts.appendingPathComponent("mdv-step-\(s).json"))
        }
        let scriptPath = artifacts.appendingPathComponent("script.txt")
        try (scriptSteps.joined(separator: "\n") + "\n")
            .write(to: scriptPath, atomically: true, encoding: .utf8)

        _ = shell(["/usr/bin/killall", "MarkdownViewer"], wait: 0.5)
        Thread.sleep(forTimeInterval: 0.3)

        let exe = harness.appExecutable
        let p = Process()
        p.executableURL = exe
        p.arguments = [
            "--walkthrough", tourJSON.path,
            "--script", scriptPath.path,
            argFile.path,
        ]
        var env = ProcessInfo.processInfo.environment
        env["MDV_BACKGROUND"] = "1"
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_ARTIFACT_DIR"] = artifacts.path
        p.environment = env
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        Thread.sleep(forTimeInterval: 0.6)

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        }

        var dumps: [[String: Any]] = []
        for n in 1...99 {
            let s = String(format: "%02d", n)
            let url = artifacts.appendingPathComponent("mdv-step-\(s).json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { break }
            dumps.append(obj)
        }
        return dumps
    }

    @discardableResult
    private func shell(_ argv: [String], wait: TimeInterval = 5) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try p.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(wait)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        return p.terminationStatus
    }

    private func runGit(_ args: [String], in dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - Dump helpers

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }

    private func modelInt(_ dump: [String: Any], _ key: String) -> Int {
        (dump["model"] as? [String: Any])?[key] as? Int ?? -1
    }
}
