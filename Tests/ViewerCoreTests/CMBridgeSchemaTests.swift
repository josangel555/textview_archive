import XCTest
@testable import ViewerCore

/// TSK-1507 s3 — `schemas/cm-bridge.json` is the SINGLE SOURCE for the CM6
/// bridge's outbound message contract. These pins scan BOTH implementations
/// against it, so a message added or renamed on either side without a schema
/// update goes RED:
///   - the Swift encoder (`CMProtocol.encodeOutbound`'s `dict["type"]` tags
///     + payload-key assignments),
///   - the JS dispatcher (`codemirror.html`'s `switch (msg.type)` cases).
/// Source-scan style per the walkthrough-gate precedent (#filePath-relative).
final class CMBridgeSchemaTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func loadSchema() throws -> [String: [String]] {
        let url = repoRoot().appendingPathComponent("schemas/cm-bridge.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let outbound = obj?["outbound"] as? [String: [String]] else {
            throw XCTSkip("schema unreadable")
        }
        return outbound
    }

    /// Parse the Swift encoder's message tags + payload keys.
    private func swiftEncoderCatalog() throws -> [String: Set<String>] {
        let src = try String(
            contentsOf: repoRoot()
                .appendingPathComponent("Sources/ViewerCore/CodeMirrorBridge.swift"),
            encoding: .utf8)
        // The signature recurs (encodeOutboundJSON wraps the encoder) —
        // scan AFTER THE FIRST occurrence, i.e. the encoder body itself.
        let parts = src.components(
            separatedBy: "_ msg: CMOutboundMessage, peerVersion: Int")
        guard parts.count >= 2 else { return [:] }
        let tail = parts[1]
        var catalog: [String: Set<String>] = [:]
        var current: String?
        for raw in tail.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"),
                  // Anywhere in the line: optional keys assign inside
                  // one-line `if let x { dict["k"] = x }` bodies.
                  let start = line.range(of: "dict[\"") else { continue }
            let afterOpen = line[start.upperBound...]
            guard let keyClose = afterOpen.range(of: "\"]") else { continue }
            let key = String(afterOpen[..<keyClose.lowerBound])
            let assignment = String(afterOpen[keyClose.upperBound...])
            if key == "type" {
                // dict["type"] = "setText"
                guard let open = assignment.range(of: "= \"") else { continue }
                let rest = assignment[open.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { continue }
                let tag = String(rest[..<close])
                current = tag
                catalog[tag, default: []].formUnion([])
            } else if key != "v", let cur = current {
                catalog[cur, default: []].insert(key)
            }
        }
        return catalog
    }

    func test_swiftEncoder_matchesTheSchema() throws {
        let schema = try loadSchema()
        var catalog = try swiftEncoderCatalog()
        XCTAssertFalse(catalog.isEmpty, "encoder scan must find the catalog")
        // The one recorded exception: scrollToLine rides a raw dispatch (the
        // schema's $rawDispatchDebt note) — no typed encoder case yet.
        catalog["scrollToLine"] = ["line"]
        XCTAssertEqual(Set(catalog.keys), Set(schema.keys),
                       "message set drift — update schemas/cm-bridge.json in the same change")
        for (name, keys) in catalog {
            XCTAssertEqual(keys, Set(schema[name] ?? []),
                           "payload keys drift for '\(name)'")
        }
    }

    func test_jsDispatcher_handlesEverySchemaMessage() throws {
        let schema = try loadSchema()
        let html = try String(
            contentsOf: repoRoot()
                .appendingPathComponent("Sources/ViewerUI/Resources/codemirror/codemirror.html"),
            encoding: .utf8)
        guard let dispatch = html.components(separatedBy: "switch (msg.type)").last?
            .components(separatedBy: "default:").first else {
            return XCTFail("dispatcher block not found")
        }
        var jsCases = Set<String>()
        for m in dispatch.matches(of: /case "(\w+)"/) {
            jsCases.insert(String(m.1))
        }
        XCTAssertEqual(jsCases, Set(schema.keys),
                       "JS dispatcher drift — a message exists on one side only; "
                       + "update schemas/cm-bridge.json + both peers together")
    }
}
