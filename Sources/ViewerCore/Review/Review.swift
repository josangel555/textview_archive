import Foundation

// MARK: - Review

/// One review session — what the user is reviewing, the comments
/// they've left, and where it is in its lifecycle. Persisted as a
/// single JSON file at
/// `~/Library/Application Support/MarkdownViewer/Reviews/<id>.json`.
///
/// Pure persistence type — no SwiftUI / AppKit imports. The
/// observable runtime container (`ReviewSession`) lives in the
/// UI layer and wraps this struct.
public struct Review: Codable, Equatable, Sendable, Identifiable {

    /// Schema version. Bump on any breaking change; never silently drift.
    public static let currentSchema: Int = 1

    public let id: String                 // ULID-shaped, see ReviewID
    public let schemaVersion: Int
    public let createdAt: Date
    public var updatedAt: Date

    /// Free-text title. Defaults to a derived one
    /// ("Review of feat/hex-editor", "Review of b09f773…").
    public var title: String
    public var description: String?       // markdown, optional

    /// What's being reviewed. The scope is immutable for the life of
    /// the review — changing it would invalidate every line anchor.
    public let scope: ReviewScope

    /// Repo root the scope resolves against. Absolute path on disk.
    public let repoRoot: String

    /// Git context captured at review creation time. Used to detect
    /// "the diff has moved under me" on reload.
    public let baseSha: String?           // base side
    public let headSha: String?           // head side (working tree → nil)

    public var state: ReviewState

    /// Comments, ordered by `createdAt`. We don't index by file/line
    /// in the on-disk shape — keep it flat, sort on read.
    public var comments: [ReviewComment]

    /// Author identity. v1: pulled from `git config user.name / user.email`
    /// at creation, then frozen. Single-author for v1.
    public let author: ReviewAuthor

    /// Export log. Append-only. Useful for "did I already send this?" UI.
    public var exports: [ReviewExportRecord]

    public init(
        id: String,
        schemaVersion: Int = Review.currentSchema,
        createdAt: Date,
        updatedAt: Date,
        title: String,
        description: String? = nil,
        scope: ReviewScope,
        repoRoot: String,
        baseSha: String?,
        headSha: String?,
        state: ReviewState = .draft,
        comments: [ReviewComment] = [],
        author: ReviewAuthor,
        exports: [ReviewExportRecord] = []
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.description = description
        self.scope = scope
        self.repoRoot = repoRoot
        self.baseSha = baseSha
        self.headSha = headSha
        self.state = state
        self.comments = comments
        self.author = author
        self.exports = exports
    }
}

// MARK: - ReviewState

public enum ReviewState: String, Codable, Sendable, CaseIterable {
    case draft       // freshly created, no comments yet OR still authoring
    case inReview    // has ≥1 comment, not yet exported
    case complete    // user marked it done locally
    case sent        // exported to clipboard / file / Claude Code

    /// State-machine guard. See §8 of CODE_REVIEW_DESIGN.md.
    ///
    /// Allowed transitions:
    /// ```
    /// draft    → inReview     (auto, on first comment)
    /// draft    → complete     (manual; rare — empty review marked done)
    /// inReview → complete     (manual)
    /// inReview → sent         (export skipping "complete")
    /// complete → sent         (export)
    /// complete → inReview     (reopen)
    /// sent     → inReview     (reopen for edits)
    /// ```
    /// Same-state transitions are allowed (idempotent).
    public func canTransition(to next: ReviewState) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.draft,    .inReview),
             (.draft,    .complete),
             (.inReview, .complete),
             (.inReview, .sent),
             (.complete, .sent),
             (.complete, .inReview),
             (.sent,     .inReview):
            return true
        default:
            return false
        }
    }
}

// MARK: - ReviewScope

/// What's being reviewed. Tagged union — exactly one case applies.
///
/// On-disk shape uses an explicit `kind` discriminator so the JSON is
/// readable and forward-compatible. We hand-roll Codable rather than
/// relying on Swift's synthesized enum coding (which buries the
/// discriminator in a nested `_0` key) — the persistence file is
/// meant to be inspected in TextView itself.
public enum ReviewScope: Codable, Equatable, Sendable {
    /// `git diff` of working tree against HEAD (or a named ref).
    case workingTree(base: String)        // base = "HEAD" typically

    /// A single commit: `git show <sha>`.
    case commit(sha: String)

    /// A range: `git diff <from>..<to>`.
    case range(from: String, to: String)

    /// A branch against its merge-base with another branch.
    case branch(branch: String, base: String)

    private enum CodingKeys: String, CodingKey {
        case kind, base, sha, from, to, branch
    }

    private enum Kind: String, Codable {
        case workingTree, commit, range, branch
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workingTree(let base):
            try c.encode(Kind.workingTree, forKey: .kind)
            try c.encode(base, forKey: .base)
        case .commit(let sha):
            try c.encode(Kind.commit, forKey: .kind)
            try c.encode(sha, forKey: .sha)
        case .range(let from, let to):
            try c.encode(Kind.range, forKey: .kind)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case .branch(let branch, let base):
            try c.encode(Kind.branch, forKey: .kind)
            try c.encode(branch, forKey: .branch)
            try c.encode(base, forKey: .base)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .workingTree:
            self = .workingTree(base: try c.decode(String.self, forKey: .base))
        case .commit:
            self = .commit(sha: try c.decode(String.self, forKey: .sha))
        case .range:
            self = .range(
                from: try c.decode(String.self, forKey: .from),
                to:   try c.decode(String.self, forKey: .to)
            )
        case .branch:
            self = .branch(
                branch: try c.decode(String.self, forKey: .branch),
                base:   try c.decode(String.self, forKey: .base)
            )
        }
    }
}

// MARK: - ReviewAuthor

public struct ReviewAuthor: Codable, Equatable, Sendable {
    public let name: String               // git config user.name
    public let email: String              // git config user.email

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

// MARK: - ReviewExportRecord

public struct ReviewExportRecord: Codable, Equatable, Sendable {
    public enum Target: String, Codable, Sendable, CaseIterable {
        case clipboard, file, claudeCode
    }
    public let target: Target
    public let at: Date
    public let destination: String?        // file path / "clipboard" / mcp endpoint
    public let commentCount: Int           // sanity: how many comments at export time

    public init(target: Target, at: Date, destination: String?, commentCount: Int) {
        self.target = target
        self.at = at
        self.destination = destination
        self.commentCount = commentCount
    }
}

// MARK: - ReviewID (ULID-style)

/// ULID-style identifier generator. 26 chars, Crockford base32,
/// lexicographically sortable by creation time.
///
/// Layout: 10 chars timestamp (48-bit ms since epoch) + 16 chars
/// random (80-bit). Filename-safe — alphabet is `[0-9A-Z]` minus
/// `I L O U` (Crockford collision avoidance). Matches the
/// production ULID spec closely enough that swapping in a real
/// library later is trivial; the IDs are opaque to callers.
public enum ReviewID {

    /// Crockford base32 alphabet — no I, L, O, U.
    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Generate a new ULID-shaped ID using the current time.
    public static func generate(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        var timePart = encode(ms, length: 10)

        // 80 random bits in two 64-bit pulls (we'll only use 80 of 128 bits).
        // Using arc4random_buf via SystemRandomNumberGenerator — Sendable on macOS.
        var rng = SystemRandomNumberGenerator()
        let hi = UInt64.random(in: 0...UInt64.max, using: &rng)
        let lo = UInt64.random(in: 0...UInt64.max, using: &rng)
        // Encode 80 bits across 16 base32 chars. We pull 5 bits at a time
        // from a 128-bit value where the top 80 bits are random.
        // Pack hi[0..<16] | lo[0..<64] into a sequence of 5-bit nibbles.
        var bits: UInt128State = UInt128State(hi: hi & 0xFFFF, lo: lo)
        var randomChars: [Character] = []
        randomChars.reserveCapacity(16)
        for _ in 0..<16 {
            let nibble = Int(bits.top5())
            randomChars.append(alphabet[nibble])
            bits.shiftLeft5()
        }
        timePart.append(contentsOf: randomChars)
        return String(timePart)
    }

    /// Encode `value` as `length` base32 chars (most-significant first).
    private static func encode(_ value: UInt64, length: Int) -> [Character] {
        var out = [Character](repeating: alphabet[0], count: length)
        var v = value
        for i in stride(from: length - 1, through: 0, by: -1) {
            out[i] = alphabet[Int(v & 0x1F)]
            v >>= 5
        }
        return out
    }

    /// Regex-style assertion helper for tests / validation.
    /// Returns true iff `id` is 26 chars of the ULID alphabet.
    public static func isWellFormed(_ id: String) -> Bool {
        guard id.count == 26 else { return false }
        let set = Set(alphabet)
        return id.allSatisfy { set.contains($0) }
    }
}

/// Internal: a tiny 80-bit shift register packed as (hi:16, lo:64).
/// We pull 5 bits off the top per step. Lives here because we only
/// need it for the random tail of the ULID encoding.
private struct UInt128State {
    var hi: UInt64   // only low 16 bits used
    var lo: UInt64

    /// Returns the top 5 bits of the 80-bit window.
    func top5() -> UInt8 {
        // Top 5 of 80 bits == bits 75..79, which are bits 11..15 of `hi`.
        UInt8((hi >> 11) & 0x1F)
    }

    /// Shift the 80-bit window left by 5 bits.
    mutating func shiftLeft5() {
        // hi[0..16] gets (hi << 5) | (lo >> 59), masked to 16 bits.
        let newHi = ((hi << 5) | (lo >> 59)) & 0xFFFF
        let newLo = lo << 5
        hi = newHi
        lo = newLo
    }
}
