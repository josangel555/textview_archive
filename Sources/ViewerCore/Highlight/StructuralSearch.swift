import Foundation

/// Structural (AST) search — query model + result types.
///
/// Where regex/literal find (`FindEngine`) matches *characters*, structural
/// search matches *syntax*: "every `function_declaration` whose `name` field
/// is captured as `$X`", "every `call_expression` calling `print`". The query
/// is expressed over TreeSitter node KINDS (the grammar's named node types,
/// e.g. `function_declaration`, `class_declaration`, `parameter`) plus the
/// grammar's named FIELDS (`name`, `value`, …), which is far more robust than
/// regex against formatting, comments, and string-literal false positives.
///
/// v1 is intentionally a small, well-defined pattern grammar (a node kind,
/// optional field constraints, optional nested child patterns) — enough to
/// express the canonical "function_declaration with name $X" example and a
/// useful range of "find all <kind> [whose <field> is/captures …]" queries.
/// It deliberately is NOT a full s-expression / Comby-style matcher; the model
/// is shaped so those can be layered on later without breaking this contract.
///
/// All types here are pure value types (`Sendable`), so the model can be built
/// on any thread / actor and shipped into the (CPU-bound) matcher off-actor.
/// The matcher itself lives in `StructuralSearchEngine`.

// MARK: - Field constraints

/// A constraint on one named grammar FIELD of a candidate node.
///
/// A node-kind pattern can carry several of these; ALL must hold for the node
/// to match (AND semantics). Each constraint targets the child reachable via
/// `Node.child(byFieldName:)` — e.g. on a Swift `function_declaration`, the
/// `name` field is the function identifier.
public struct StructuralFieldConstraint: Sendable, Equatable {
    /// The grammar field name (`name`, `value`, `body`, …).
    public let field: String

    /// What we require / extract from that field's node.
    public let predicate: Predicate

    public enum Predicate: Sendable, Equatable {
        /// The field's source text must equal this string exactly.
        /// (`name` of a call == "print".)
        case textEquals(String)

        /// The field's source text must contain this substring.
        case textContains(String)

        /// The field's node kind must be this grammar kind.
        /// (`value` is an `integer_literal`.)
        case kindEquals(String)

        /// No constraint on the field beyond "it must exist"; bind its
        /// source text + range to the given capture name (`$X` → "X").
        /// This is the `function_declaration with name $X` case.
        case capture(name: String)
    }

    public init(field: String, predicate: Predicate) {
        self.field = field
        self.predicate = predicate
    }

    // Ergonomic builders so call sites + tests read like the query grammar.

    /// `field` text equals `text`.
    public static func equals(_ field: String, _ text: String) -> Self {
        .init(field: field, predicate: .textEquals(text))
    }

    /// `field` text contains `text`.
    public static func contains(_ field: String, _ text: String) -> Self {
        .init(field: field, predicate: .textContains(text))
    }

    /// `field`'s node kind equals `kind`.
    public static func kind(_ field: String, is kind: String) -> Self {
        .init(field: field, predicate: .kindEquals(kind))
    }

    /// Bind `field` to capture `$name` (no other constraint).
    public static func capture(_ field: String, as name: String) -> Self {
        .init(field: field, predicate: .capture(name: name))
    }
}

// MARK: - Query

/// A structural query: a single node-kind pattern, optionally constrained by
/// field predicates and nested child patterns.
///
/// Matching is rooted: the engine walks every node of the parsed tree and
/// tests each one against the TOP pattern. A node matches when:
///   1. its grammar kind is in `kinds` (an OR set — `["function_declaration"]`
///      or `["if_statement", "guard_statement"]`), and
///   2. every `fieldConstraints` entry holds against the node's named fields,
///      and
///   3. every `childPatterns` entry matches at least one DESCENDANT of the node
///      (subtree containment — "a function that contains a `return_statement`").
///
/// Captures bound by field constraints (and recursively by child patterns) are
/// merged into the resulting `StructuralMatch.captures`. A capture name bound
/// twice within one match keeps the FIRST binding (outermost / earliest wins).
public struct StructuralQuery: Sendable, Equatable {
    /// Grammar node kinds this pattern accepts (OR). Empty == match any kind
    /// (a wildcard — useful only when child patterns / fields do the work).
    public let kinds: Set<String>

    /// Field-level constraints (AND). All must hold.
    public let fieldConstraints: [StructuralFieldConstraint]

    /// Nested patterns that must each match SOME descendant of the candidate.
    public let childPatterns: [StructuralQuery]

    /// Optional capture for the WHOLE matched node's source text + range,
    /// bound under this name. (`@func`-style root capture.)
    public let captureAs: String?

    public init(
        kinds: Set<String>,
        fieldConstraints: [StructuralFieldConstraint] = [],
        childPatterns: [StructuralQuery] = [],
        captureAs: String? = nil
    ) {
        self.kinds = kinds
        self.fieldConstraints = fieldConstraints
        self.childPatterns = childPatterns
        self.captureAs = captureAs
    }

    /// Convenience: a single-kind pattern.
    public init(
        kind: String,
        fieldConstraints: [StructuralFieldConstraint] = [],
        childPatterns: [StructuralQuery] = [],
        captureAs: String? = nil
    ) {
        self.init(
            kinds: [kind],
            fieldConstraints: fieldConstraints,
            childPatterns: childPatterns,
            captureAs: captureAs
        )
    }
}

// MARK: - Results

/// One captured sub-node within a match: its name (`X` for `$X`), the matched
/// source text, and its position.
///
/// `range` is a UTF-16 `NSRange` — the AppKit / `NSTextView` / SwiftUI text
/// model — so a "jump to / highlight this match" UI consumes it directly. (We
/// parse via SwiftTreeSitter's UTF-16 path, so node positions arrive already in
/// UTF-16 code units; no byte↔unit conversion is needed and a multi-byte/emoji
/// prefix doesn't shift the range. See `StructuralSearchEngine`.)
public struct StructuralCapture: Sendable, Equatable {
    public let name: String
    public let text: String
    public let range: NSRange

    public init(name: String, text: String, range: NSRange) {
        self.name = name
        self.text = text
        self.range = range
    }
}

/// A single structural match: the matched node's range + all captures bound
/// while matching it (root capture + field captures + nested child captures).
public struct StructuralMatch: Sendable, Equatable {
    /// Grammar kind of the matched node (`function_declaration`).
    public let kind: String

    /// UTF-16 `NSRange` of the whole matched node (AppKit unit).
    public let range: NSRange

    /// Captures bound during this match, keyed by capture name.
    public let captures: [String: StructuralCapture]

    public init(
        kind: String,
        range: NSRange,
        captures: [String: StructuralCapture]
    ) {
        self.kind = kind
        self.range = range
        self.captures = captures
    }

    /// Capture lookup by name (`match["X"]`).
    public subscript(_ name: String) -> StructuralCapture? { captures[name] }
}
