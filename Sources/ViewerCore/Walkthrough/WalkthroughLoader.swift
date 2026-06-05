import Foundation

/// Decodes + validates a `WalkthroughScript` from on-disk JSON.
///
/// The loader is the security boundary for file-drop transport: a
/// script that arrives in the inbox is untrusted (anyone with write
/// access to the drop dir can drop one). The validations here are the
/// only thing standing between a malicious script and the verb dispatch
/// — keep them strict. Specifically:
///
///   - `..` traversal: any step path that resolves outside the
///     effective fence is rejected. Without this, `openFile` could read
///     `/etc/passwd`.
///   - Duplicate step ids: the engine indexes by id (`jumpTo`); a dup
///     would make the index ambiguous.
///   - Schema discriminator: enforced by `Codable` on the type already,
///     but surfaced as a structured error here.
///
/// **Trusted-root vs self-declared `rootHint` (S3 hardening).** The
/// script's own `rootHint` is attacker-controlled — it travels inside
/// the same untrusted JSON. Validating step paths against `rootHint`
/// alone is no containment at all: a malicious script just declares
/// `rootHint: "/"` and every absolute path passes. The untrusted
/// boundary (file-drop transport) must therefore inject a `trustedRoot`
/// it derived itself (frontmost window's working dir / configured
/// drop dir). When `trustedRoot` is supplied it is the authoritative
/// fence: every step path is validated against it, and the script's
/// `rootHint` is additionally required to resolve *inside* it
/// (intersection — a script may narrow to a subdir, never widen out).
///
/// The loader returns a `Result`, never throws. Rationale: every call
/// site needs to branch on success/failure to write to `accepted/` or
/// `rejected/` (design §4.1), so a structured error is the right shape.
public enum WalkthroughLoader {

    /// Decode + validate.
    ///
    /// Containment fence precedence:
    ///   1. `trustedRoot` (caller-injected, NOT from the script) when
    ///      non-nil — the authoritative fence. Step paths are validated
    ///      against it, and `script.rootHint` must resolve inside it.
    ///   2. Otherwise `script.rootHint` if present — legacy/internal
    ///      callers (engine reload after edit, tests, scripts authored
    ///      against a known dev root) that trust the script's own root.
    ///   3. Otherwise no path-escape check (absolute paths accepted).
    ///
    /// **Important boundary distinction (S1.4 / S3):** this overload
    /// defaults to `requireRootHint: false` and `trustedRoot: nil`
    /// because internal callers may legitimately accept absolute-only
    /// paths against the script's own root. The file-drop transport —
    /// the *untrusted* boundary — must call with `requireRootHint: true`
    /// AND a non-nil `trustedRoot` so a script can neither omit
    /// `rootHint` nor self-declare an over-broad one (`"/"`, `/Users`)
    /// to land `openFile` / `addBookmark` on arbitrary absolute paths.
    public static func load(
        data: Data,
        decoder: JSONDecoder? = nil,
        requireRootHint: Bool = false,
        trustedRoot: String? = nil
    ) -> Result<WalkthroughScript, WalkthroughLoadError> {
        let d = decoder ?? Self.defaultDecoder()
        let script: WalkthroughScript
        do {
            script = try d.decode(WalkthroughScript.self, from: data)
        } catch let err as UnsupportedSchemaError {
            // Distinct from a malformed-JSON failure: the script is
            // well-formed but declares a schema version this binary
            // doesn't know. Surface it structurally so callers can show
            // an "update the app" message instead of a parse error.
            return .failure(.unsupportedSchema(
                version: err.version, supported: err.supported
            ))
        } catch let err as DecodingError {
            return .failure(.decodingFailed(describe(err)))
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
        if requireRootHint && script.rootHint == nil {
            return .failure(.missingRootHint)
        }
        if let err = validate(script, trustedRoot: trustedRoot) {
            return .failure(err)
        }
        return .success(script)
    }

    public static func load(
        fileAt url: URL,
        decoder: JSONDecoder? = nil,
        requireRootHint: Bool = false,
        trustedRoot: String? = nil
    ) -> Result<WalkthroughScript, WalkthroughLoadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.ioFailed(error.localizedDescription))
        }
        return load(
            data: data,
            decoder: decoder,
            requireRootHint: requireRootHint,
            trustedRoot: trustedRoot
        )
    }

    // MARK: - Validation

    /// Returns the first validation error, or nil if the script is
    /// clean. Single-error-per-load is deliberate: the file-drop
    /// transport surfaces the rejection in a sibling `.error.txt`, and
    /// stacking errors confuses authors more than one focused message.
    ///
    /// `trustedRoot`, when supplied, is the caller-derived fence (NOT
    /// from the script) and takes precedence over the script's own
    /// `rootHint` per the type docstring.
    static func validate(
        _ script: WalkthroughScript,
        trustedRoot: String? = nil
    ) -> WalkthroughLoadError? {

        // 1. Step ids must be unique. The engine indexes by id for
        //    jumpTo + guardOn resolution; a dup makes the resolution
        //    ambiguous and a future `guardOn` lookup would match the
        //    wrong step.
        var seen: Set<String> = []
        seen.reserveCapacity(script.steps.count)
        for step in script.steps {
            if !seen.insert(step.id).inserted {
                return .duplicateStepID(step.id)
            }
        }

        // 2. Establish the authoritative containment fence.
        //
        //    `trustedRoot` (caller-injected, derived OUTSIDE the script)
        //    wins when present: the script's own `rootHint` is part of
        //    the untrusted JSON, so trusting it for the fence is no
        //    containment at all (an attacker sets `rootHint: "/"` and
        //    every absolute path passes). When `trustedRoot` is nil we
        //    fall back to `rootHint` for legacy/internal callers that
        //    deliberately trust the script's own root; when both are nil
        //    the check is skipped (absolute paths accepted by choice).
        let fence: URL
        let fencePath: String
        if let trustedRoot {
            let t = canonicalRoot(trustedRoot)
            fence = t.url
            fencePath = t.path

            // Intersect: the script may NARROW to a subdirectory of the
            // trusted root, but never widen out of it. Reject a
            // `rootHint` that resolves outside the trusted fence so a
            // script can't claim a broader root than the caller granted.
            if let rootHint = script.rootHint {
                let r = canonicalRoot(rootHint)
                if r.path != fencePath && !r.path.hasPrefix(fencePath + "/") {
                    return .rootHintOutsideTrustedRoot(
                        rootHint: rootHint, trustedRoot: trustedRoot
                    )
                }
            }
        } else if let rootHint = script.rootHint {
            let r = canonicalRoot(rootHint)
            fence = r.url
            fencePath = r.path
        } else {
            return nil
        }

        // 3. Path-escape check against the established fence. Every
        //    action payload that carries a `path` field (string,
        //    optional or not) must resolve inside it.
        for step in script.steps {
            for action in step.actions {
                for path in pathsIn(action) {
                    if let bad = pathEscape(path, root: fence, rootPath: fencePath) {
                        return .pathEscape(stepID: step.id, path: bad)
                    }
                }
            }
        }

        return nil
    }

    /// Canonicalize a root directory path into the (URL, path) pair the
    /// escape check compares against.
    ///
    /// `isDirectory: true` keeps a trailing slash on the URL so
    /// `URL(fileURLWithPath: relative, relativeTo: root)` resolves
    /// against `root` as a base **directory** rather than its parent.
    /// Without this, root `/tmp/repo` would resolve `src/A.swift` to
    /// `/tmp/src/A.swift` (one level up) and legit scripts would falsely
    /// fail. `resolvingSymlinksInPath` handles macOS's `/tmp` →
    /// `/private/tmp` indirection so the comparison doesn't
    /// false-positive when the resolved file path is canonical.
    private static func canonicalRoot(_ path: String) -> (url: URL, path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return (url, url.path)
    }

    /// Extract every `path` string an action references. We collect on
    /// the variant level so adding a verb forces a compile-time match
    /// here, not a silent skip.
    private static func pathsIn(_ action: Action) -> [String] {
        switch action {
        case .openFile(let p):        return [p.path]
        case .revealLine(let p):      return [p.path].compactMap { $0 }
        case .highlightRange(let p):  return [p.path].compactMap { $0 }
        case .flash(let p):           return [p.path].compactMap { $0 }
        case .showPopover(let p):
            if case .line(let path?, _) = p.anchor { return [path] }
            return []
        case .setView(let p):         return [p.path].compactMap { $0 }
        case .splitFile(let p):       return [p.path] + [p.alongside].compactMap { $0 }
        case .runDiff(let p):         return [p.path].compactMap { $0 }
        case .awaitUser:              return []
        case .addBookmark(let p):     return [p.path]
        case .revealInSidebar(let p): return [p.path]
        case .openGitPanel:           return []
        case .narrateOnly:            return []
        }
    }

    /// Returns the offending path if `path` (relative to `root` if not
    /// absolute) resolves outside `root`. Uses path-prefix comparison
    /// on the **standardized** path, which collapses `..` so a sneaky
    /// `foo/../../outside` is caught.
    private static func pathEscape(
        _ path: String, root: URL, rootPath: String
    ) -> String? {
        // Build the resolved absolute path by hand rather than via
        // `URL(fileURLWithPath:relativeTo:)`. Foundation's URL behavior
        // for relativeTo + standardizedFileURL diverged between
        // Swift 6.1 (treats the base as a file, drops its last
        // component) and 6.3 (preserves it as a directory). The VM
        // build canary runs 6.1.2 so the URL-based approach silently
        // resolved `src/A.swift` against `/tmp/repo` to `/tmp/src/A.swift`
        // and rejected legitimate paths.
        let absolutePath: String
        if path.hasPrefix("/") {
            absolutePath = path
        } else {
            // appendingPathComponent on a String preserves rootPath's
            // intent as a directory regardless of Foundation version.
            absolutePath = (rootPath as NSString).appendingPathComponent(path)
        }
        let resolved = URL(fileURLWithPath: absolutePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let p = resolved.path
        // Match either the root itself or any descendant. Trailing
        // slash check guards against `/tmp/foo` matching `/tmp/foobar`.
        if p == rootPath { return nil }
        if p.hasPrefix(rootPath + "/") { return nil }
        return path
    }

    // MARK: - Helpers

    public static func defaultDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func describe(_ err: DecodingError) -> String {
        switch err {
        case .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx),
             .keyNotFound(_, let ctx),
             .dataCorrupted(let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty
                ? ctx.debugDescription
                : "\(path): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: err)
        }
    }
}

// MARK: - Errors

public enum WalkthroughLoadError: Error, Equatable, Sendable {
    /// JSON parse or schema-discriminator mismatch. The inner string is
    /// a human-readable diagnostic (codable coding-path + reason).
    case decodingFailed(String)
    /// The script is well-formed JSON but declares a `schema` version
    /// this binary doesn't support (e.g. an older app handed a newer
    /// script). Distinct from `decodingFailed` so the UI can tell the
    /// user to update the app rather than reporting a parse error.
    case unsupportedSchema(version: String, supported: [String])
    /// Two steps share the same id; engine indexing would be ambiguous.
    case duplicateStepID(String)
    /// An action references a path that resolves outside `rootHint`.
    case pathEscape(stepID: String, path: String)
    /// File-system read failed (transport layer error, surfaced here so
    /// the loader's call sites only see one error type).
    case ioFailed(String)
    /// Loader was invoked with `requireRootHint: true` (the untrusted
    /// file-drop boundary) but the script omitted `rootHint`. Without
    /// a rootHint the path-escape check is a no-op and `openFile` can
    /// reach arbitrary absolute paths — refuse outright.
    case missingRootHint
    /// A `trustedRoot` was injected by the caller (the untrusted
    /// file-drop boundary) but the script's self-declared `rootHint`
    /// resolves OUTSIDE it. The script may narrow to a subdirectory of
    /// the trusted root, never widen beyond it — otherwise a malicious
    /// script could claim `rootHint: "/"` and defeat containment.
    case rootHintOutsideTrustedRoot(rootHint: String, trustedRoot: String)
}
