import XCTest
@testable import ViewerCore

/// Coverage for the walkthrough versioning contract that
/// `WalkthroughScriptTests` doesn't reach: `UnsupportedSchemaError`'s
/// value semantics + author-facing message, the `SchemaVersion`
/// enumeration the error's `supported` list is derived from, and the
/// `flash` verb's decode behavior relative to the declared schema
/// version (the version gate is at the schema string, NOT per-verb).
final class WalkthroughSchemaErrorTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - SchemaVersion enumeration (drives UnsupportedSchemaError.supported)

    /// `SchemaVersion.allCases` is what the decoder reports in the error's
    /// `supported` array. Pin the raw values + order so the message stays
    /// stable and a new version is a deliberate, test-visible change.
    func test_schemaVersion_rawValuesAndOrder_areStable() {
        XCTAssertEqual(
            WalkthroughScript.SchemaVersion.allCases.map(\.rawValue),
            ["textview.walkthrough/v1", "textview.walkthrough/v2"],
            "newest last; v3 must be appended deliberately"
        )
        XCTAssertEqual(WalkthroughScript.SchemaVersion.v1.rawValue,
                       "textview.walkthrough/v1")
        XCTAssertEqual(WalkthroughScript.SchemaVersion.v2.rawValue,
                       "textview.walkthrough/v2")
    }

    func test_schemaVersion_decodesFromRawValue() throws {
        let v1 = try decoder.decode(WalkthroughScript.SchemaVersion.self,
                                    from: Data("\"textview.walkthrough/v1\"".utf8))
        XCTAssertEqual(v1, .v1)
    }

    // MARK: - UnsupportedSchemaError value semantics

    func test_unsupportedSchemaError_isEquatable() {
        let a = UnsupportedSchemaError(version: "x/v3", supported: ["x/v1", "x/v2"])
        let b = UnsupportedSchemaError(version: "x/v3", supported: ["x/v1", "x/v2"])
        let c = UnsupportedSchemaError(version: "x/v4", supported: ["x/v1", "x/v2"])
        let d = UnsupportedSchemaError(version: "x/v3", supported: ["x/v1"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "differing version must compare unequal")
        XCTAssertNotEqual(a, d, "differing supported set must compare unequal")
    }

    /// The error must round-trip across a concurrency boundary unchanged
    /// (`Sendable`) — it's surfaced from the loader which may run off the
    /// main actor. Compile + runtime proof.
    func test_unsupportedSchemaError_sendableAcrossTask() async {
        let original = UnsupportedSchemaError(
            version: "textview.walkthrough/v9",
            supported: WalkthroughScript.SchemaVersion.allCases.map(\.rawValue))
        let received = await Task { original }.value
        XCTAssertEqual(received, original)
    }

    /// The author-facing `errorDescription` must name BOTH the offending
    /// version and the supported set — the whole point of the structured
    /// error (vs an opaque `dataCorrupted`). Pin the substrings, not the
    /// exact prose, so wording can be tuned without a brittle test.
    func test_unsupportedSchemaError_localizedDescription_namesVersionAndSupported() {
        let err = UnsupportedSchemaError(
            version: "textview.walkthrough/v3",
            supported: ["textview.walkthrough/v1", "textview.walkthrough/v2"])
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("textview.walkthrough/v3"),
                      "message must name the offending version: \(msg)")
        XCTAssertTrue(msg.contains("textview.walkthrough/v1"),
                      "message must list supported versions: \(msg)")
        XCTAssertTrue(msg.contains("textview.walkthrough/v2"), msg)
    }

    /// The error thrown by the decoder carries the live supported set
    /// (derived from `SchemaVersion.allCases`), not a hardcoded literal —
    /// pin that the decoder and the enum can't drift apart.
    func test_decoder_unsupportedSchema_carriesLiveSupportedSet() {
        let json = """
        { "schema": "textview.walkthrough/v99", "id": "x", "title": "T", "steps": [] }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8))
        ) { err in
            guard let e = err as? UnsupportedSchemaError else {
                return XCTFail("expected UnsupportedSchemaError, got \(err)")
            }
            XCTAssertEqual(e.version, "textview.walkthrough/v99")
            XCTAssertEqual(e.supported,
                           WalkthroughScript.SchemaVersion.allCases.map(\.rawValue))
        }
    }

    /// An empty / garbage schema string is still an UnsupportedSchemaError
    /// (not a dataCorrupted) — the discriminator is decoded as a raw String
    /// first, so any non-matching value lands in our structured error.
    func test_emptySchemaString_throwsUnsupportedSchemaError() {
        let json = """
        { "schema": "", "id": "x", "title": "T", "steps": [] }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8))
        ) { err in
            guard let e = err as? UnsupportedSchemaError else {
                return XCTFail("expected UnsupportedSchemaError, got \(err)")
            }
            XCTAssertEqual(e.version, "")
        }
    }

    /// A missing `schema` key is a genuine *malformed* payload, NOT a
    /// version-drift — it must surface as a keyNotFound/dataCorrupted
    /// decoding error, never as UnsupportedSchemaError (which would
    /// mislead an author into "upgrade the app").
    func test_missingSchemaKey_isNotUnsupportedSchemaError() {
        let json = """
        { "id": "x", "title": "T", "steps": [] }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8))
        ) { err in
            XCTAssertNil(err as? UnsupportedSchemaError,
                         "a missing schema key is malformed, not version drift")
        }
    }

    // MARK: - flash verb vs declared schema version
    //
    // `flash` is documented as a v2 verb. But the decoder gates on the
    // SCHEMA STRING (rejecting unknown *versions*), while the Action union
    // accepts any *known verb* regardless of the declared version. So a
    // script that declares v1 yet uses `flash` decodes successfully — the
    // version is an envelope contract, the verb set is enforced by the
    // union. Pin this so the (subtle) layering is intentional + visible,
    // and a future per-verb-version gate is a deliberate change.

    func test_flashVerb_underV1Schema_decodesSuccessfully() throws {
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [
            { "kind": "flash", "startLine": 2, "endLine": 4 }
          ]}]
        }
        """
        let s = try decoder.decode(WalkthroughScript.self, from: Data(json.utf8))
        XCTAssertEqual(s.schema, .v1)
        guard case .flash(let p) = s.steps[0].actions[0] else {
            return XCTFail("expected flash, got \(s.steps[0].actions)")
        }
        XCTAssertEqual(p.startLine, 2)
        XCTAssertEqual(p.endLine, 4)
    }

    /// A `flash` action missing a required field (`endLine`) must fail to
    /// decode — the payload's non-optional fields are enforced.
    func test_flashVerb_missingRequiredField_isRejected() {
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [
            { "kind": "flash", "startLine": 2 }
          ]}]
        }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8)),
            "flash without endLine must fail decode")
    }

    /// `flash` with an unknown `style` enum value rejects — the style is a
    /// closed enum, so a typo'd style name fails rather than silently
    /// dropping to a default.
    func test_flashVerb_unknownStyle_isRejected() {
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [
            { "kind": "flash", "startLine": 1, "endLine": 1, "style": "neon" }
          ]}]
        }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8)),
            "unknown HighlightStyle must reject")
    }

    // MARK: - FlashPayload memberwise-init default-arg parity

    /// The memberwise init's defaults (path/style/durationMs = nil) must
    /// produce a value equal to one decoded from a wire payload that omits
    /// those keys — so authoring in code and authoring in JSON agree.
    func test_flashPayload_memberwiseDefaults_matchWireOmission() throws {
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [
            { "kind": "flash", "startLine": 7, "endLine": 9 }
          ]}]
        }
        """
        let decoded = try decoder.decode(WalkthroughScript.self, from: Data(json.utf8))
        let expected = Action.flash(FlashPayload(startLine: 7, endLine: 9))
        XCTAssertEqual(decoded.steps[0].actions[0], expected)
    }

    // MARK: - All HighlightStyle cases round-trip through flash

    func test_flash_everyHighlightStyle_roundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for style in [HighlightStyle.focus, .warn, .info, .agent] {
            let action = Action.flash(FlashPayload(
                startLine: 1, endLine: 2, style: style, durationMs: 300))
            let script = WalkthroughScript(
                schema: .v2, id: "x", title: "T",
                steps: [Step(id: "s1", actions: [action])])
            let data = try encoder.encode(script)
            let back = try decoder.decode(WalkthroughScript.self, from: data)
            XCTAssertEqual(back.steps[0].actions[0], action,
                           "flash style \(style) did not round-trip")
        }
    }
}
