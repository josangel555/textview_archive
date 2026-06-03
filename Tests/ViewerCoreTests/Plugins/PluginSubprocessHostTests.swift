import XCTest
@testable import ViewerCore

/// These tests actually spawn subprocesses — they're slow-ish (10s of
/// ms per case) but exercise the real `Process` boundary we care
/// about. Host-only (no UI involved), so they're safe on the host
/// per CLAUDE.md.
final class PluginSubprocessHostTests: XCTestCase {

    private var pluginDir: URL!
    private var auditURL: URL!
    private var host: PluginSubprocessHost!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory
        pluginDir = tmp.appendingPathComponent("MDVPluginHostTest-\(UUID().uuidString)")
        auditURL = tmp.appendingPathComponent("MDVAudit-\(UUID().uuidString).log")
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        host = PluginSubprocessHost(auditURLOverride: auditURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: pluginDir)
        try? FileManager.default.removeItem(at: auditURL)
        super.tearDown()
    }

    /// Drop a shell script into the plugin dir at `name`, make it
    /// executable, return its relative path (what manifest.bin holds).
    @discardableResult
    private func writeScript(_ name: String, body: String) throws -> String {
        let url = pluginDir.appendingPathComponent(name)
        try body.data(using: .utf8)!.write(to: url)
        // 0o755 — owner+group+other read+execute, owner write.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path
        )
        return name
    }

    func test_happy_path_returns_rows() throws {
        let bin = try writeScript("bin.sh", body: """
        #!/bin/sh
        # Ignore stdin; emit a fixed JSON response.
        cat >/dev/null
        echo '{"rows":[{"id":"a","label":"Alpha","detail":"1"},{"id":"b","label":"Beta","detail":null}]}'
        """)
        let result = host.call(
            pluginID: "test.ok", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        if case .ok(let resp) = result.outcome {
            XCTAssertEqual(resp.rows?.count, 2)
            XCTAssertEqual(resp.rows?[0].label, "Alpha")
            XCTAssertNil(resp.rows?[1].detail)
        } else {
            XCTFail("expected .ok, got \(result.outcome)")
        }
    }

    func test_plugin_receives_envelope_on_stdin() throws {
        // Round-trip the envelope through `jq` would be nice, but we
        // can't assume jq is on the test box. Use a script that copies
        // stdin into the response's `detail` field. We have to escape
        // newlines for JSON validity, so we use base64.
        let bin = try writeScript("echo.sh", body: """
        #!/bin/sh
        IN=$(cat | base64)
        printf '{"rows":[{"id":"in","label":"input","detail":"%s"}]}' "$IN"
        """)
        let result = host.call(
            pluginID: "test.echo", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows",
                           invocationID: "INV-1",
                           args: ["foo": "bar"])
        )
        guard case .ok(let resp) = result.outcome,
              let detail = resp.rows?.first?.detail,
              let decoded = Data(base64Encoded: detail.replacingOccurrences(of: "\n", with: "")) else {
            return XCTFail("expected ok with base64 detail, got \(result.outcome)")
        }
        let text = String(data: decoded, encoding: .utf8) ?? ""
        // Envelope must include the kind, invocationID, and args.
        XCTAssertTrue(text.contains("\"kind\":\"listRows\""))
        XCTAssertTrue(text.contains("\"invocationID\":\"INV-1\""))
        XCTAssertTrue(text.contains("\"foo\":\"bar\""))
        XCTAssertTrue(text.contains("\"version\":1"))
    }

    func test_timeout_kills_runaway() throws {
        let bin = try writeScript("hang.sh", body: """
        #!/bin/sh
        cat >/dev/null
        sleep 10
        echo '{"rows":[]}'
        """)
        let started = Date()
        let result = host.call(
            pluginID: "test.hang", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 200,
            request: .init(kind: "listRows")
        )
        // Should return well under the 10s sleep — within ~500ms incl
        // the SIGTERM grace period.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        if case .timedOut = result.outcome {} else {
            XCTFail("expected .timedOut, got \(result.outcome)")
        }
    }

    func test_stdout_cap_truncates_runaway_output() throws {
        // Stream way more than 1 MB. The cap should trip; outcome
        // is `.stdoutOverflow` regardless of what the script eventually
        // does.
        let bin = try writeScript("flood.sh", body: """
        #!/bin/sh
        cat >/dev/null
        # 2 MB of zeros; the host's cap is 1 MB.
        dd if=/dev/zero bs=1024 count=2048 2>/dev/null
        """)
        let result = host.call(
            pluginID: "test.flood", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        if case .stdoutOverflow = result.outcome {} else {
            XCTFail("expected .stdoutOverflow, got \(result.outcome)")
        }
    }

    func test_nonzero_exit_surfaces_stderr_tail() throws {
        let bin = try writeScript("fail.sh", body: """
        #!/bin/sh
        cat >/dev/null
        echo "kaboom: nope" >&2
        exit 7
        """)
        let result = host.call(
            pluginID: "test.fail", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        if case .nonZeroExit(let code, let tail) = result.outcome {
            XCTAssertEqual(code, 7)
            XCTAssertTrue(tail.contains("kaboom"))
        } else {
            XCTFail("expected .nonZeroExit, got \(result.outcome)")
        }
    }

    func test_garbage_stdout_is_decode_failure() throws {
        let bin = try writeScript("garbage.sh", body: """
        #!/bin/sh
        cat >/dev/null
        echo "this is not JSON"
        """)
        let result = host.call(
            pluginID: "test.garbage", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        if case .decodeFailed = result.outcome {} else {
            XCTFail("expected .decodeFailed, got \(result.outcome)")
        }
    }

    func test_missing_bin_returns_spawnFailed() {
        let result = host.call(
            pluginID: "test.nope", pluginFolder: pluginDir,
            bin: "does-not-exist.sh", args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        if case .spawnFailed(let msg) = result.outcome {
            XCTAssertTrue(msg.contains("not found"))
        } else {
            XCTFail("expected .spawnFailed, got \(result.outcome)")
        }
    }

    func test_path_traversal_in_bin_rejected() {
        let result = host.call(
            pluginID: "test.traverse", pluginFolder: pluginDir,
            bin: "../../etc/passwd", args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        if case .spawnFailed(let msg) = result.outcome {
            XCTAssertTrue(msg.contains(".."))
        } else {
            XCTFail("expected .spawnFailed for path traversal")
        }
    }

    // MARK: - SEC-007: symlink escape

    /// A `bin` whose path is clean (no `..`) but is a symlink that, when
    /// resolved, escapes the plugin folder must be rejected. This is the
    /// case the old string-level check missed.
    func test_symlink_bin_escaping_folder_rejected() throws {
        // Create a real executable OUTSIDE the plugin folder, then plant
        // a symlink to it inside. The symlink's literal path has no "..".
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let realBin = outsideDir.appendingPathComponent("evil.sh")
        try "#!/bin/sh\necho '{\"rows\":[]}'\n".data(using: .utf8)!.write(to: realBin)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: realBin.path
        )
        let link = pluginDir.appendingPathComponent("tool.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realBin)

        let result = host.call(
            pluginID: "test.symlink", pluginFolder: pluginDir,
            bin: "tool.sh", args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        if case .spawnFailed(let msg) = result.outcome {
            XCTAssertTrue(msg.lowercased().contains("escape"),
                          "expected an escape message, got: \(msg)")
        } else {
            XCTFail("expected .spawnFailed for symlink escape, got \(result.outcome)")
        }
    }

    /// A symlink that stays INSIDE the plugin folder is fine — we resolve
    /// it and confirm containment, then spawn it normally.
    func test_symlink_bin_staying_inside_folder_allowed() throws {
        let realBin = pluginDir.appendingPathComponent("real.sh")
        try "#!/bin/sh\ncat >/dev/null\necho '{\"rows\":[]}'\n".data(using: .utf8)!.write(to: realBin)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: realBin.path
        )
        let link = pluginDir.appendingPathComponent("alias.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realBin)

        let result = host.call(
            pluginID: "test.symlink.ok", pluginFolder: pluginDir,
            bin: "alias.sh", args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        if case .ok = result.outcome {} else {
            XCTFail("expected .ok for in-folder symlink, got \(result.outcome)")
        }
    }

    func test_path_containment_helper_rejects_sibling_prefix() {
        // /a/plugins must NOT contain /a/plugins-evil (prefix-without-slash trap).
        XCTAssertFalse(PluginSubprocessHost.path("/a/plugins-evil/x",
                                                 isContainedIn: "/a/plugins"))
        XCTAssertTrue(PluginSubprocessHost.path("/a/plugins/x",
                                                isContainedIn: "/a/plugins"))
        XCTAssertTrue(PluginSubprocessHost.path("/a/plugins",
                                                isContainedIn: "/a/plugins"))
    }

    // MARK: - OBS-3: audit log file mode

    func test_audit_log_is_owner_only_0600() throws {
        let bin = try writeScript("ok.sh", body: """
        #!/bin/sh
        cat >/dev/null
        echo '{"rows":[]}'
        """)
        _ = host.call(
            pluginID: "test.perms", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: auditURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perms, 0o600, "audit log must be owner-only (0600)")
    }

    /// A pre-existing 0o644 log (left by an older build) is tightened to
    /// 0o600 on the next write.
    func test_audit_log_preexisting_0644_is_chmod_to_0600() throws {
        // Seed a loose-perms log file first.
        FileManager.default.createFile(
            atPath: auditURL.path, contents: Data(),
            attributes: [.posixPermissions: NSNumber(value: 0o644)]
        )
        let bin = try writeScript("ok.sh", body: """
        #!/bin/sh
        cat >/dev/null
        echo '{"rows":[]}'
        """)
        _ = host.call(
            pluginID: "test.chmod", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: auditURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perms, 0o600, "pre-existing 0644 log must be tightened to 0600")
    }

    // MARK: - OBS-6: stable, byte-free error descriptors

    /// A decode failure must NOT echo the plugin's stdout bytes into the
    /// audit log's `error` field; it records a stable DecodingError
    /// descriptor instead.
    func test_decode_failure_audit_error_is_byte_free() throws {
        // Emit a JSON value of the wrong SHAPE (rows must be an array of
        // objects; here it's a string) so we get a typeMismatch with a
        // distinctive secret token the raw error would have quoted.
        let secret = "SUPERSECRET-PLUGIN-PAYLOAD-9001"
        let bin = try writeScript("badshape.sh", body: """
        #!/bin/sh
        cat >/dev/null
        printf '{"rows":"%s"}' "\(secret)"
        """)
        let result = host.call(
            pluginID: "test.decode", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        guard case .decodeFailed(let msg) = result.outcome else {
            return XCTFail("expected .decodeFailed, got \(result.outcome)")
        }
        XCTAssertFalse(msg.contains(secret),
                       "decode error must not embed plugin bytes: \(msg)")
        // And the audit line must be byte-free too.
        let log = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertFalse(log.contains(secret),
                       "audit log must not embed plugin bytes")
        XCTAssertTrue(log.contains("decode_failed"))
    }

    func test_stableDecodeErrorDescriptor_typeMismatch_keypath() {
        struct Shape: Decodable { let rows: [Int] }
        // rows present but a string, not [Int] → typeMismatch at rows.
        let bad = Data(#"{"rows":"nope"}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Shape.self, from: bad)
            XCTFail("expected decode to throw")
        } catch {
            let desc = PluginSubprocessHost.stableDecodeErrorDescriptor(error)
            XCTAssertTrue(desc.hasPrefix("typeMismatch"), "got: \(desc)")
            XCTAssertTrue(desc.contains("rows"), "keypath should mention rows: \(desc)")
            XCTAssertFalse(desc.contains("nope"), "must not echo the value: \(desc)")
        }
    }

    func test_stableDecodeErrorDescriptor_keyNotFound() {
        struct Shape: Decodable { let required: Int }
        let bad = Data(#"{}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Shape.self, from: bad)
            XCTFail("expected decode to throw")
        } catch {
            let desc = PluginSubprocessHost.stableDecodeErrorDescriptor(error)
            XCTAssertTrue(desc.hasPrefix("keyNotFound"), "got: \(desc)")
            XCTAssertTrue(desc.contains("required"), "got: \(desc)")
        }
    }

    /// spawnFailed for path-traversal should record a `bin_basename`
    /// field and NOT leak any absolute path beyond the manifest-relative
    /// bin string.
    func test_spawnFailed_audit_records_bin_basename() throws {
        _ = host.call(
            pluginID: "test.spawnaudit", pluginFolder: pluginDir,
            bin: "nested/dir/missing.sh", args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        let log = try String(contentsOf: auditURL, encoding: .utf8)
        let line = log.split(separator: "\n").first.map(String.init) ?? ""
        let obj = try JSONSerialization.jsonObject(
            with: line.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["result"] as? String, "spawn_failed")
        XCTAssertEqual(obj["bin_basename"] as? String, "missing.sh")
        // OBS-6 (F-PMA-OBS6): the spawn_failed `error` descriptor for a
        // missing bin must NOT embed the absolute plugin path. Assert it
        // carries only the manifest-relative bin, never `pluginDir`'s
        // absolute path nor a leading '/'.
        let errorMsg = obj["error"] as? String ?? ""
        XCTAssertEqual(errorMsg, "bin not found: nested/dir/missing.sh",
                       "spawn_failed error leaked an absolute path: \(errorMsg)")
        XCTAssertFalse(errorMsg.contains(pluginDir.path),
                       "error leaked the absolute plugin folder path: \(errorMsg)")
        XCTAssertFalse(errorMsg.contains(": /"),
                       "error embedded an absolute filesystem path: \(errorMsg)")
    }

    /// OBS-6: a present-but-non-executable bin must likewise record a
    /// path-free `error` descriptor (the second preflight branch).
    func test_spawnFailed_nonExecutable_audit_is_path_free() throws {
        // Write a regular, non-executable file inside the plugin folder.
        let nonExec = pluginDir.appendingPathComponent("not-exec.sh")
        try "#!/bin/sh\n".write(to: nonExec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: nonExec.path)
        _ = host.call(
            pluginID: "test.spawnaudit.nonexec", pluginFolder: pluginDir,
            bin: "not-exec.sh", args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        let log = try String(contentsOf: auditURL, encoding: .utf8)
        let line = log.split(separator: "\n").first.map(String.init) ?? ""
        let obj = try JSONSerialization.jsonObject(
            with: line.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["result"] as? String, "spawn_failed")
        XCTAssertEqual(obj["bin_basename"] as? String, "not-exec.sh")
        let errorMsg = obj["error"] as? String ?? ""
        XCTAssertEqual(errorMsg, "bin not executable: not-exec.sh",
                       "spawn_failed error leaked an absolute path: \(errorMsg)")
        XCTAssertFalse(errorMsg.contains(pluginDir.path),
                       "error leaked the absolute plugin folder path: \(errorMsg)")
        XCTAssertFalse(errorMsg.contains(": /"),
                       "error embedded an absolute filesystem path: \(errorMsg)")
    }

    func test_env_is_scrubbed_only_HOME_passes() {
        // Env scrub is static + only reads ProcessInfo. We assert the
        // contract directly rather than starting a subprocess: if HOME
        // is set in the host env (it should be), it appears; nothing
        // else does.
        let scrubbed = PluginSubprocessHost.scrubbedEnvironment()
        XCTAssertEqual(scrubbed.count, scrubbed["HOME"] != nil ? 1 : 0)
        XCTAssertNil(scrubbed["PATH"])
        XCTAssertNil(scrubbed["USER"])
        XCTAssertNil(scrubbed["LANG"])
        XCTAssertNil(scrubbed["TMPDIR"])
    }

    func test_audit_log_contains_jsonl_line_per_call() throws {
        let bin = try writeScript("ok.sh", body: """
        #!/bin/sh
        cat >/dev/null
        echo '{"rows":[]}'
        """)
        _ = host.call(
            pluginID: "test.audit.1", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        _ = host.call(
            pluginID: "test.audit.2", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        let log = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let data = line.data(using: .utf8)!
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertNotNil(obj["ts"])
            XCTAssertEqual(obj["cap"] as? String, "shell.exec")
            XCTAssertEqual(obj["result"] as? String, "ok")
            XCTAssertNotNil(obj["duration_ms"])
            XCTAssertNotNil(obj["invocation"])
        }
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: lines[0].data(using: .utf8)!) as? [String: Any])?["plugin"] as? String,
                       "test.audit.1")
    }

    func test_audit_log_records_failure_outcomes() throws {
        let bin = try writeScript("fail.sh", body: """
        #!/bin/sh
        cat >/dev/null
        exit 3
        """)
        _ = host.call(
            pluginID: "test.audit.fail", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 3000,
            request: .init(kind: "listRows")
        )
        let log = try String(contentsOf: auditURL, encoding: .utf8)
        let line = log.split(separator: "\n").first.map(String.init) ?? ""
        let obj = try JSONSerialization.jsonObject(
            with: line.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["result"] as? String, "nonzero_exit")
        XCTAssertEqual(obj["exit"] as? Int, 3)
    }
}
