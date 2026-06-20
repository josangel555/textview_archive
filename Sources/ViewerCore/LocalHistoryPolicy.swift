import Foundation

/// The owner-set retention/privacy policy for Local History (TSK-301 seq 4383,
/// 2026-06-13): default-ON, 50 versions/file but CONFIGURABLE, 20MB-per-file
/// size cap, only files edited in-app + TEXT only, EXCLUDE `.env` and other
/// secret-like files. This is the pure, host-testable decision layer the
/// snapshot-on-save hook consults BEFORE calling `LocalHistoryStore.snapshot`.
///
/// SwiftUI-free (ViewerCore) so the UI layer reads one predicate and every rule
/// is unit-tested with teeth. Persisted settings live in `UserDefaults`;
/// env overrides exist for dev / CI / tests.
public enum LocalHistoryPolicy {

    // MARK: - Persisted settings

    /// Master enable. Default ON (owner directive). A future Settings toggle
    /// writes this key.
    public static let enabledKey = "MarkdownViewer.localHistory.enabled"
    /// Per-run override. `MDV_LOCAL_HISTORY=0` forces OFF, `=1` forces ON.
    public static let enabledEnvVar = "MDV_LOCAL_HISTORY"

    /// Configurable per-file version cap (owner: "50 is fine but configurable").
    public static let versionCapKey = "MarkdownViewer.localHistory.versionCap"
    /// Default per-file version cap when the user hasn't set one.
    public static let defaultVersionCap = 50

    /// Per-file/per-snapshot byte cap (owner: "size cap 20MB per file"). Content
    /// larger than this is never snapshotted.
    public static let maxSnapshotBytes = 20 * 1024 * 1024  // 20 MB

    /// Is Local History snapshotting enabled this run? Precedence:
    /// env override → explicit persisted toggle (either way) → default ON.
    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        if let raw = envValue(enabledEnvVar, environment) {
            return raw == "1" || raw.lowercased() == "true"
        }
        if defaults.object(forKey: enabledKey) != nil {
            return defaults.bool(forKey: enabledKey)
        }
        return true   // default ON (owner directive)
    }

    /// The effective per-file version cap. Reads the configurable key; clamps to
    /// a sane floor of 1 (a 0/negative cap would mean "keep nothing", which is
    /// silently useless — treat it as the default instead).
    public static func versionCap(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: versionCapKey) != nil else { return defaultVersionCap }
        let v = defaults.integer(forKey: versionCapKey)
        return v >= 1 ? v : defaultVersionCap
    }

    // MARK: - The snapshot decision

    /// Whether `content` for `path` may be snapshotted, per ALL the owner's
    /// rules. Pure: takes the content + path (+ injectable settings), returns a
    /// reason-bearing verdict so the caller can log WHY a save wasn't recorded.
    ///
    /// Order (cheapest / most-decisive first):
    ///   1. feature disabled         → .disabled
    ///   2. secret-like path (.env…) → .excludedSecret
    ///   3. over the 20MB byte cap   → .tooLarge
    ///   4. not text (NUL bytes)     → .notText
    ///   else                        → .allowed
    public static func decideSnapshot(
        path: String, content: String,
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Decision {
        guard isEnabled(defaults: defaults, environment: environment) else {
            return .disabled
        }
        if isSecretLike(path: path) {
            return .excludedSecret
        }
        if content.utf8.count > maxSnapshotBytes {
            return .tooLarge
        }
        if !isLikelyText(content) {
            return .notText
        }
        return .allowed
    }

    public enum Decision: Equatable, Sendable {
        case allowed
        case disabled
        case excludedSecret
        case tooLarge
        case notText

        public var isAllowed: Bool { self == .allowed }
    }

    // MARK: - Secret / sensitive-file detection

    /// Filenames whose WHOLE leaf (lowercased) is a known secret store.
    static let secretFilenames: Set<String> = [
        ".env", ".npmrc", ".netrc", ".pgpass", ".htpasswd",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
        "credentials", "secrets.yaml", "secrets.yml", "secrets.json",
    ]

    /// Substrings (lowercased) in the leaf that mark a secret-like file:
    /// any `.env*` variant (`.env.local`, `.env.production`), `*.pem`,
    /// `*.key`/`*.keystore`, `*.p12`/`*.pfx`, `*.crt`/`*.cer`, and names
    /// containing "secret"/"credential"/"password".
    public static func isSecretLike(path: String) -> Bool {
        let leaf = (path as NSString).lastPathComponent.lowercased()
        if leaf.isEmpty { return false }
        if secretFilenames.contains(leaf) { return true }
        // Any dotenv variant: ".env", ".env.local", ".env.production.local", …
        if leaf == ".env" || leaf.hasPrefix(".env.") { return true }
        // Secret-bearing extensions.
        let secretExts = [".pem", ".key", ".keystore", ".jks",
                          ".p12", ".pfx", ".crt", ".cer", ".der", ".asc", ".gpg"]
        if secretExts.contains(where: { leaf.hasSuffix($0) }) { return true }
        // Secret-bearing name fragments.
        let secretFragments = ["secret", "credential", "password", "private_key", "apikey", "api_key"]
        if secretFragments.contains(where: { leaf.contains($0) }) { return true }
        return false
    }

    /// Cheap "is this text, not a binary blob" heuristic: reject content
    /// containing a NUL byte (the classic binary marker git itself uses). The
    /// content already arrives as a Swift `String`, so it decoded as UTF-8;
    /// the NUL check rejects e.g. a UTF-16 / binary file that happened to decode.
    /// Empty content is text (a legitimately empty file).
    public static func isLikelyText(_ content: String) -> Bool {
        !content.utf8.contains(0)
    }

    // MARK: - Helpers

    private static func envValue(_ name: String, _ environment: [String: String]?) -> String? {
        if let environment { return environment[name] }
        if let c = getenv(name) { return String(cString: c) }
        return nil
    }
}
