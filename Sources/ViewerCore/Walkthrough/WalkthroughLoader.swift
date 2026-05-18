import Foundation

/// Decodes + validates a `WalkthroughScript` from on-disk JSON.
///
/// The loader is the security boundary for file-drop transport: a
/// script that arrives in the inbox is untrusted (anyone with write
/// access to the drop dir can drop one). The validations here are the
/// only thing standing between a malicious script and the verb dispatch
/// — keep them strict. Specifically:
///
///   - `..` traversal: any step path that resolves outside `rootHint`
///     is rejected. Without this, `openFile` could read `/etc/passwd`.
///   - Duplicate step ids: the engine indexes by id (`jumpTo`); a dup
///     would make the index ambiguous.
///   - Schema discriminator: enforced by `Codable` on the type already,
///     but surfaced as a structured error here.
///
/// The loader returns a `Result`, never throws. Rationale: every call
/// site needs to branch on success/failure to write to `accepted/` or
/// `rejected/` (design §4.1), so a structured error is the right shape.
public enum WalkthroughLoader {

    /// Decode + validate. Path-escape checks use `rootHint` if present;
    /// when nil, paths are accepted as-is (the file-drop transport can
    /// fill in `rootHint` from the frontmost window's working dir
    /// before calling `load`).
    public static func load(
        data: Data,
        decoder: JSONDecoder? = nil
    ) -> Result<WalkthroughScript, WalkthroughLoadError> {
        let d = decoder ?? Self.defaultDecoder()
        let script: WalkthroughScript
        do {
            script = try d.decode(WalkthroughScript.self, from: data)
        } catch let err as DecodingError {
            return .failure(.decodingFailed(describe(err)))
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
        if let err = validate(script) {
            return .failure(err)
        }
        return .success(script)
    }

    public static func load(
        fileAt url: URL,
        decoder: JSONDecoder? = nil
    ) -> Result<WalkthroughScript, WalkthroughLoadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.ioFailed(error.localizedDescription))
        }
        return load(data: data, decoder: decoder)
    }

    // MARK: - Validation

    /// Returns the first validation error, or nil if the script is
    /// clean. Single-error-per-load is deliberate: the file-drop
    /// transport surfaces the rejection in a sibling `.error.txt`, and
    /// stacking errors confuses authors more than one focused message.
    static func validate(_ script: WalkthroughScript) -> WalkthroughLoadError? {

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

        // 2. Path-escape check. Every action payload that carries a
        //    `path` field (string, optional or not) must resolve inside
        //    `rootHint`. When `rootHint` is nil we skip — paths are
        //    assumed absolute and the caller has chosen to accept them.
        if let rootHint = script.rootHint {
            let root = URL(fileURLWithPath: rootHint).standardizedFileURL
            let rootPath = root.path
            for step in script.steps {
                for action in step.actions {
                    for path in pathsIn(action) {
                        if let bad = pathEscape(path, root: root, rootPath: rootPath) {
                            return .pathEscape(
                                stepID: step.id, path: bad
                            )
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Extract every `path` string an action references. We collect on
    /// the variant level so adding a verb forces a compile-time match
    /// here, not a silent skip.
    private static func pathsIn(_ action: Action) -> [String] {
        switch action {
        case .openFile(let p):        return [p.path]
        case .revealLine(let p):      return [p.path].compactMap { $0 }
        case .highlightRange(let p):  return [p.path].compactMap { $0 }
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
        let resolved: URL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).standardizedFileURL
            : URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
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
    /// Two steps share the same id; engine indexing would be ambiguous.
    case duplicateStepID(String)
    /// An action references a path that resolves outside `rootHint`.
    case pathEscape(stepID: String, path: String)
    /// File-system read failed (transport layer error, surfaced here so
    /// the loader's call sites only see one error type).
    case ioFailed(String)
}
