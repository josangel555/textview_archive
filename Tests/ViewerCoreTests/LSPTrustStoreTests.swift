import Foundation
import Testing
@testable import ViewerCore

/// TSK-1129 (security) — the persisted one-time trust store for workspace-local
/// LSP server binaries. Pins: grant/revoke, persistence across instances (the
/// "one-time" survives a relaunch), the spawn decision (workspace-local untrusted
/// → needsTrust; trusted/outside → allow), canonical-path keying, and the
/// entry cap. Pairs with LSPBinaryTrustTests (the pure decision core).
struct LSPTrustStoreTests {

    /// A throwaway store over a fresh temp file + a fake workspace with a
    /// repo-local binary and an external one.
    private func fixture() throws -> (store: LSPTrustStore, ws: URL, local: URL, external: URL, storeURL: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-lsptrust-\(UUID().uuidString)", isDirectory: true)
        let ws = tmp.appendingPathComponent("ws", isDirectory: true)
        let binDir = ws.appendingPathComponent("node_modules/.bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let local = binDir.appendingPathComponent("evil-lsp")
        try Data("#!/bin/sh\n".utf8).write(to: local)
        let extDir = tmp.appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let external = extDir.appendingPathComponent("sourcekit-lsp")
        try Data("#!/bin/sh\n".utf8).write(to: external)
        let storeURL = tmp.appendingPathComponent("trusted.json")
        return (LSPTrustStore(storeURL: storeURL), ws, local, external, storeURL)
    }

    @Test func workspaceLocalUntrustedNeedsTrust_externalAllowed() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.ws.deletingLastPathComponent()) }
        #expect(f.store.decision(binary: f.local, workspaceRoot: f.ws) == .needsTrust)
        #expect(f.store.decision(binary: f.external, workspaceRoot: f.ws) == .allow)
    }

    @Test func grantFlipsDecisionToAllow() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.ws.deletingLastPathComponent()) }
        #expect(!f.store.isTrusted(f.local))
        #expect(f.store.grant(f.local))
        #expect(f.store.isTrusted(f.local))
        #expect(f.store.decision(binary: f.local, workspaceRoot: f.ws) == .allow)
    }

    @Test func revokeFlipsBack() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.ws.deletingLastPathComponent()) }
        f.store.grant(f.local)
        #expect(f.store.revoke(f.local))
        #expect(!f.store.isTrusted(f.local))
        #expect(f.store.decision(binary: f.local, workspaceRoot: f.ws) == .needsTrust)
    }

    /// The "one-time" requirement: a grant persists, so a FRESH store over the
    /// same file still trusts the binary (survives a relaunch).
    @Test func grantPersistsAcrossInstances() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.ws.deletingLastPathComponent()) }
        f.store.grant(f.local)
        let reborn = LSPTrustStore(storeURL: f.storeURL)
        #expect(reborn.isTrusted(f.local))
        #expect(reborn.decision(binary: f.local, workspaceRoot: f.ws) == .allow)
    }

    @Test func missingStoreFileIsEmptyNotCrash() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-lsptrust-missing-\(UUID().uuidString).json")
        let store = LSPTrustStore(storeURL: url)
        #expect(store.trustedPaths.isEmpty)
    }

    @Test func entryCapIsEnforced() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-lsptrust-cap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LSPTrustStore(storeURL: url, maxEntries: 2)
        #expect(store.grant(URL(fileURLWithPath: "/a/x")))
        #expect(store.grant(URL(fileURLWithPath: "/a/y")))
        #expect(!store.grant(URL(fileURLWithPath: "/a/z")))   // cap hit
        // An already-trusted path still reports trusted even at the cap.
        #expect(store.grant(URL(fileURLWithPath: "/a/x")))
    }
}
