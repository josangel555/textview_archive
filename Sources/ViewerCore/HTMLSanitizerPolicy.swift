import Foundation

/// TSK-1507 s4 — the SINGLE SOURCE of the HTML-sanitizer security policy.
///
/// The native (`HTMLSanitizer`, Swift) and the future WebUI (rust/JS) render
/// paths MUST sanitize identically — a tag the web side keeps that native
/// drops (or vice-versa) is a security hole. So the policy sets live here as
/// the one authority, mirrored to `schemas/html-sanitizer-policy.json` (the
/// wire contract the rust single-sourcing reads), and pinned by
/// `HTMLSanitizerPolicyGuardTests` so a change on either side without the
/// other goes RED. This does NOT port the sanitizer algorithm — only its
/// divergence-dangerous CONSTANTS (the "byte-identical native vs web" surface
/// the ticket names).
public enum HTMLSanitizerPolicy {

    /// Tags whose entire element is dropped (hardened, untrusted path).
    public static let droppedElements: Set<String> = [
        "script", "style", "iframe", "object", "embed",
        "form", "input", "button", "select", "textarea",
        "link", "meta", "base",
    ]

    /// The two tags a LOCAL, user-opted-in ("trusted") document keeps so a
    /// JS-render bundle can paint. `trustedDroppedElements` is
    /// `droppedElements` minus these.
    public static let trustedKeepsElements: Set<String> = ["script", "style"]

    /// The trusted-mode drop set (derived — never diverges from the two above).
    public static var trustedDroppedElements: Set<String> {
        droppedElements.subtracting(trustedKeepsElements)
    }

    /// Attributes whose value is a URL and therefore scheme-checked.
    public static let urlBearingAttributes: Set<String> = [
        "href", "src", "xlink:href", "action",
        "formaction", "background", "poster",
    ]

    /// Schemes neutralized to `about:blank` (compared against the decoded,
    /// lowercased leading scheme token).
    public static let dangerousSchemes: Set<String> = ["javascript", "vbscript"]

    /// The policy as the wire contract shape (sorted arrays for a stable,
    /// diffable serialization the rust side decodes).
    public static func contract() -> [String: [String]] {
        [
            "droppedElements": droppedElements.sorted(),
            "trustedKeepsElements": trustedKeepsElements.sorted(),
            "urlBearingAttributes": urlBearingAttributes.sorted(),
            "dangerousSchemes": dangerousSchemes.sorted(),
        ]
    }
}
