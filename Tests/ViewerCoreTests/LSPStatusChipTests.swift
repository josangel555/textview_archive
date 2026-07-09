import Testing
import Foundation
@testable import ViewerCore

/// TSK-1444 — the pure LSP status-chip classifier + display + UAT parse.
/// The whole state machine that drives the footer chip lives here so a
/// regression fails on the host gate even though the chip's pixels are
/// VM-only.
struct LSPStatusChipTests {

    private let root = URL(fileURLWithPath: "/tmp/proj")

    private func snap(
        language: LSPLanguage,
        root: URL,
        isLive: Bool = false,
        isDead: Bool = false,
        crashCount: Int = 0,
        requestCount: Int = 0,
        lastError: String? = nil
    ) -> LSPPool.StatusSnapshot {
        var status = LSPPool.LSPServerStatus()
        status.crashCount = crashCount
        status.requestCount = requestCount
        status.lastError = lastError
        return LSPPool.StatusSnapshot(
            key: LSPPool.Key(language: language, workspaceRoot: root),
            isLive: isLive, isDead: isDead, status: status)
    }

    // MARK: - classify

    @Test func nilLanguage_hidesChip() {
        #expect(LSPStatusChip.classify(
            language: nil, workspaceRoot: nil,
            binaryAvailable: true, snapshot: []) == nil)
    }

    @Test func liveEntry_isRunning_withRequestSummary() {
        let chip = LSPStatusChip.classify(
            language: .swift, workspaceRoot: root, binaryAvailable: true,
            snapshot: [snap(language: .swift, root: root, isLive: true, requestCount: 3)])
        #expect(chip?.state == .running)
        #expect(chip?.detail == "3 requests")
        #expect(chip?.tint == .ok)
        #expect(chip?.label == "Swift")
    }

    @Test func liveEntry_zeroRequests_hasNilDetail() {
        let chip = LSPStatusChip.classify(
            language: .swift, workspaceRoot: root, binaryAvailable: true,
            snapshot: [snap(language: .swift, root: root, isLive: true, requestCount: 0)])
        #expect(chip?.state == .running)
        #expect(chip?.detail == nil)
    }

    @Test func deadEntry_isFailed_withLastError() {
        let chip = LSPStatusChip.classify(
            language: .python, workspaceRoot: root, binaryAvailable: true,
            snapshot: [snap(language: .python, root: root, isDead: true,
                            lastError: "exited (status 1)")])
        #expect(chip?.state == .failed)
        #expect(chip?.detail == "exited (status 1)")
        #expect(chip?.tint == .error)
    }

    /// A crashed-but-demoted server (cold, will respawn) still reads as
    /// failed so the degradation window is visible — not a misleading "idle".
    @Test func crashedDemotedEntry_isFailed() {
        let chip = LSPStatusChip.classify(
            language: .swift, workspaceRoot: root, binaryAvailable: true,
            snapshot: [snap(language: .swift, root: root, crashCount: 2,
                            lastError: "EOF")])
        #expect(chip?.state == .failed)
        #expect(chip?.detail == "EOF")
    }

    @Test func coldEntry_zeroCrashes_isIdle() {
        let chip = LSPStatusChip.classify(
            language: .swift, workspaceRoot: root, binaryAvailable: true,
            snapshot: [snap(language: .swift, root: root)])  // neither live nor dead, 0 crashes
        #expect(chip?.state == .idle)
        #expect(chip?.tint == .neutral)
    }

    @Test func noEntry_binaryAvailable_isIdle() {
        let chip = LSPStatusChip.classify(
            language: .swift, workspaceRoot: root, binaryAvailable: true, snapshot: [])
        #expect(chip?.state == .idle)
    }

    @Test func noEntry_binaryMissing_isNotInstalled_withHint() {
        let chip = LSPStatusChip.classify(
            language: .python, workspaceRoot: root, binaryAvailable: false, snapshot: [])
        #expect(chip?.state == .notInstalled)
        #expect(chip?.tint == .warning)
        #expect(chip?.detail == LSPLanguage.python.installHint)
        #expect(chip?.detail != nil)
    }

    /// Snapshot entries for OTHER languages must not classify this file's chip.
    @Test func snapshotForOtherLanguage_isIgnored() {
        let chip = LSPStatusChip.classify(
            language: .python, workspaceRoot: root, binaryAvailable: false,
            snapshot: [snap(language: .swift, root: root, isLive: true)])
        #expect(chip?.state == .notInstalled)  // no python entry → falls to availability
    }

    /// With two roots serving the same language, an exact root match wins.
    @Test func exactRootMatch_preferredOverLive() {
        let rootA = URL(fileURLWithPath: "/tmp/a")
        let rootB = URL(fileURLWithPath: "/tmp/b")
        let chip = LSPStatusChip.classify(
            language: .swift, workspaceRoot: rootB, binaryAvailable: true,
            snapshot: [
                snap(language: .swift, root: rootA, isLive: true),
                snap(language: .swift, root: rootB, isDead: true, lastError: "b down"),
            ])
        #expect(chip?.state == .failed)
        #expect(chip?.detail == "b down")
    }

    /// No exact root match → prefer a live entry over a dead one.
    @Test func noExactRoot_prefersLive() {
        let rootA = URL(fileURLWithPath: "/tmp/a")
        let rootB = URL(fileURLWithPath: "/tmp/b")
        let chip = LSPStatusChip.classify(
            language: .swift, workspaceRoot: URL(fileURLWithPath: "/tmp/other"),
            binaryAvailable: true,
            snapshot: [
                snap(language: .swift, root: rootA, isDead: true),
                snap(language: .swift, root: rootB, isLive: true),
            ])
        #expect(chip?.state == .running)
    }

    // MARK: - display mapping

    @Test(arguments: [
        (LSPStatusChip.State.running, "checkmark.circle.fill", LSPStatusChip.Tint.ok),
        (.idle, "circle.dashed", .neutral),
        (.failed, "exclamationmark.triangle.fill", .error),
        (.notInstalled, "xmark.circle", .warning),
    ])
    func symbolAndTint(state: LSPStatusChip.State, symbol: String, tint: LSPStatusChip.Tint) {
        let chip = LSPStatusChip(language: .swift, state: state, detail: nil)
        #expect(chip.symbolName == symbol)
        #expect(chip.tint == tint)
    }

    @Test func accessibilityDescription_carriesFailureDetail() {
        let chip = LSPStatusChip(language: .java, state: .failed, detail: "boom")
        #expect(chip.accessibilityDescription.contains("Java"))
        #expect(chip.accessibilityDescription.contains("failed"))
        #expect(chip.accessibilityDescription.contains("boom"))
    }

    // MARK: - fake() UAT parse hook

    @Test func fake_stateOnly_defaultsToSwift() {
        let chip = LSPStatusChip.fake(fromEnvValue: "running")
        #expect(chip?.language == .swift)
        #expect(chip?.state == .running)
    }

    @Test func fake_stateAndLanguage() {
        let chip = LSPStatusChip.fake(fromEnvValue: "failed:python")
        #expect(chip?.language == .python)
        #expect(chip?.state == .failed)
        #expect(chip?.detail != nil)
    }

    @Test func fake_notInstalled_carriesInstallHint() {
        let chip = LSPStatusChip.fake(fromEnvValue: "notInstalled:typescript")
        #expect(chip?.state == .notInstalled)
        #expect(chip?.detail == LSPLanguage.typescript.installHint)
    }

    @Test func fake_unknownState_isNil() {
        #expect(LSPStatusChip.fake(fromEnvValue: "bogus") == nil)
    }

    @Test func fake_unknownLanguage_fallsBackToSwift() {
        let chip = LSPStatusChip.fake(fromEnvValue: "running:cobol")
        #expect(chip?.language == .swift)
    }
}
