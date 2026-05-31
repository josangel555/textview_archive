import Darwin
import XCTest
@testable import ViewerCore

/// Tests for the debug-only diagnostic surface (PRIORITIZED_PLAN item 17):
///   - `PathRedactor` collapses home / tmp prefixes (privacy reducer).
///   - `DiagnosticSnapshot.redactingPaths()` recurses into every nested row.
///   - JSON serialisation is shape-stable and content-free.
///   - `DiagnosticProbes.ownedTempFiles` sweeps only `mdv-*` artifacts and
///     never reads a file body.
///   - `DiagnosticProbes.openFileDescriptors` enumerates real fds, labels
///     types, and resolves vnode paths.
///   - `DiagnosticDumpWriter` writes a redacted 0600 artifact.
///   - `DiagnosticGate` is enabled under DEBUG (the host test build).
final class DiagnosticSnapshotTests: XCTestCase {

    // MARK: - Path redaction

    func testPathRedactorCollapsesHomePrefix() {
        let home = NSHomeDirectory()
        let p = home + "/work/project/secret.swift"
        let r = PathRedactor.redact(p)
        XCTAssertFalse(r.contains(home), "home prefix must be removed: \(r)")
        XCTAssertTrue(r.hasPrefix("<HOME>") || r.hasPrefix("<TMP>"), "got \(r)")
        XCTAssertTrue(r.hasSuffix("/work/project/secret.swift"))
    }

    func testPathRedactorCollapsesTmpPrefix() {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let p = tmp + "/mdv-thing.json"
        let r = PathRedactor.redact(p)
        XCTAssertFalse(r.contains(tmp))
        XCTAssertEqual(r, "<TMP>/mdv-thing.json")
    }

    func testPathRedactorLeavesUnrelatedPathsAlone() {
        let p = "/etc/hosts"
        XCTAssertEqual(PathRedactor.redact(p), "/etc/hosts")
    }

    // MARK: - Snapshot redaction recursion

    func testRedactingPathsRecursesEveryRow() {
        let home = NSHomeDirectory()
        let s = DiagnosticSnapshot(
            pid: 42,
            capturedAtUnixNanos: 1,
            isDebugBuild: true,
            tabs: [DiagnosticTabSummary(
                title: "a.swift", path: home + "/a.swift", stateKind: "loaded",
                viewMode: "source", isDirty: true, diskState: "fresh", byteCount: 10)],
            selectedTabIndex: 0,
            sidebarRootPath: home + "/proj",
            recentsCount: 3,
            bookmarksCount: 1,
            tempFiles: [DiagnosticTempFile(
                path: home + "/.x.mdv-1.tmp", sizeBytes: 5, modifiedUnixNanos: 7)],
            openFDs: [DiagnosticOpenFD(fd: 7, kind: "vnode", path: home + "/open.txt")],
            subprocesses: [DiagnosticSubprocess(
                subsystem: "lsp", label: "swift@" + home + "/proj",
                status: "live", path: home + "/proj")],
            obsBufferedEvents: 2,
            obsTotalEmitted: 2)

        let r = s.redactingPaths()
        XCTAssertFalse(r.tabs[0].path!.contains(home))
        XCTAssertFalse(r.sidebarRootPath!.contains(home))
        XCTAssertFalse(r.tempFiles[0].path.contains(home))
        XCTAssertFalse(r.openFDs[0].path!.contains(home))
        // The embedded path inside the subprocess LABEL is redacted too.
        XCTAssertFalse(r.subprocesses[0].label.contains(home))
        XCTAssertFalse(r.subprocesses[0].path!.contains(home))
        XCTAssertTrue(r.subprocesses[0].label.hasPrefix("swift@"))
        // Non-path facts survive unchanged.
        XCTAssertEqual(r.tabs[0].isDirty, true)
        XCTAssertEqual(r.recentsCount, 3)
    }

    // MARK: - JSON shape

    func testJSONObjectIsContentFreeAndSerialisable() throws {
        let s = DiagnosticSnapshot(
            pid: 1, capturedAtUnixNanos: 99, isDebugBuild: false,
            tabs: [DiagnosticTabSummary(
                title: "t", path: "/p", stateKind: "loaded", viewMode: "source",
                isDirty: false, diskState: "fresh", byteCount: 123)],
            selectedTabIndex: nil, sidebarRootPath: nil,
            recentsCount: 0, bookmarksCount: 0,
            tempFiles: [], openFDs: [], subprocesses: [],
            obsBufferedEvents: 0, obsTotalEmitted: 0)
        let obj = s.jsonObject()
        XCTAssertEqual(obj["schemaVersion"] as? Int, DiagnosticSnapshot.schemaVersion)
        // No "content"/"string"/"bytes-body" key anywhere — sizes only.
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"byteCount\":123"))
        XCTAssertFalse(text.lowercased().contains("contents"))
    }

    // MARK: - Temp-file sweep

    func testOwnedTempFilesMatchesOnlyMdvArtifacts() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let mine = scratch.appendingPathComponent("mdv-diagnostic-snapshot-99.json")
        let mineAtomic = scratch.appendingPathComponent(".doc.txt.mdv-\(UUID().uuidString).tmp")
        let foreign = scratch.appendingPathComponent("someoneelse.tmp")
        try Data("xy".utf8).write(to: mine)
        try Data("z".utf8).write(to: mineAtomic)
        try Data("not ours".utf8).write(to: foreign)

        let found = DiagnosticProbes.ownedTempFiles(in: scratch)
        let names = Set(found.map { ($0.path as NSString).lastPathComponent })
        XCTAssertTrue(names.contains("mdv-diagnostic-snapshot-99.json"))
        XCTAssertTrue(names.contains(mineAtomic.lastPathComponent))
        XCTAssertFalse(names.contains("someoneelse.tmp"))
        // Size fact is reported; content is never read.
        let mineRow = found.first { ($0.path as NSString).lastPathComponent == "mdv-diagnostic-snapshot-99.json" }
        XCTAssertEqual(mineRow?.sizeBytes, 2)
    }

    // MARK: - Open FDs

    func testOpenFileDescriptorsResolvesVnodePath() throws {
        let fm = FileManager.default
        let target = fm.temporaryDirectory
            .appendingPathComponent("mdv-fd-probe-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: target)
        defer { try? fm.removeItem(at: target) }

        let fd = open(target.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        let fds = DiagnosticProbes.openFileDescriptors()
        // Our just-opened fd must appear, typed vnode, with a resolvable path.
        let row = fds.first { $0.fd == fd }
        XCTAssertNotNil(row, "opened fd \(fd) not enumerated")
        XCTAssertEqual(row?.kind, "vnode")
        XCTAssertNotNil(row?.path)
        XCTAssertEqual((row?.path as NSString?)?.lastPathComponent, target.lastPathComponent)

        // stdin/stdout/stderr always present.
        XCTAssertTrue(fds.contains { $0.fd == 0 })
    }

    // MARK: - Dump writer

    func testDumpWriterWrites0600AndRedacts() throws {
        let home = NSHomeDirectory()
        let s = DiagnosticSnapshot(
            pid: 7, capturedAtUnixNanos: 1, isDebugBuild: true,
            tabs: [], selectedTabIndex: nil,
            sidebarRootPath: home + "/secret-project",
            recentsCount: 0, bookmarksCount: 0,
            tempFiles: [], openFDs: [], subprocesses: [],
            obsBufferedEvents: 0, obsTotalEmitted: 0)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-diag-writer-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }

        try DiagnosticDumpWriter.write(s, toPath: out.path, redactPaths: true)

        // Perms are exactly 0600.
        let attrs = try FileManager.default.attributesOfItem(atPath: out.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        // The exported artifact does NOT carry the absolute home path.
        // Parse the JSON rather than substring-match the file text:
        // JSONSerialization escapes `/` as `\/`, so a raw text search for
        // "<HOME>/..." would spuriously miss the (correctly redacted) value.
        let data = try Data(contentsOf: out)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let root = try XCTUnwrap(obj["sidebarRootPath"] as? String)
        XCTAssertFalse(root.contains(home))
        XCTAssertEqual(root, "<HOME>/secret-project")
    }

    func testDumpWriterRespectsRedactFalse() throws {
        let home = NSHomeDirectory()
        let s = DiagnosticSnapshot(
            pid: 7, capturedAtUnixNanos: 1, isDebugBuild: true,
            tabs: [], selectedTabIndex: nil, sidebarRootPath: home + "/p",
            recentsCount: 0, bookmarksCount: 0,
            tempFiles: [], openFDs: [], subprocesses: [],
            obsBufferedEvents: 0, obsTotalEmitted: 0)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-diag-writer-raw-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        try DiagnosticDumpWriter.write(s, toPath: out.path, redactPaths: false)
        let data = try Data(contentsOf: out)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["sidebarRootPath"] as? String, home + "/p")
    }

    // MARK: - Gate

    func testGateEnabledUnderDebug() {
        // The test bundle is a DEBUG build, so the gate is on regardless of
        // the opt-in env var.
        XCTAssertTrue(DiagnosticGate.isEnabled)
        XCTAssertTrue(DiagnosticGate.isDebugBuild)
        XCTAssertFalse(DiagnosticGate.redactPathsInExport) // DEBUG keeps real paths in-window
    }
}
