import Foundation

/// One Markdown lint finding. `rule` is a stable id; `line` is 1-based.
public struct MarkdownLintIssue: Equatable, Sendable {
    public let rule: String
    public let line: Int
    public let message: String
    public init(rule: String, line: Int, message: String) {
        self.rule = rule
        self.line = line
        self.message = message
    }
}

/// A small Markdown quality linter (docs hygiene) — a pure CONSUMER of the
/// focused `MarkdownLinks` / `MarkdownOutline` parsers (not the Rust-ported
/// markdown→HTML engine), so it's migration-safe and fully host-testable.
///
/// Rules (v1):
///  - `image-alt`     — an image with empty alt text (accessibility / fallback).
///  - `heading-skip`  — a heading that jumps more than one level deeper than the
///                      previous (e.g. H1 → H3), which breaks the outline shape.
///  - `dup-anchor`    — two headings that produce the same GitHub anchor slug,
///                      so `#slug` / TOC links become ambiguous.
public enum MarkdownLint {

    public static func lint(_ text: String) -> [MarkdownLintIssue] {
        var issues: [MarkdownLintIssue] = []

        // image-alt
        for link in MarkdownLinks.extract(text)
        where link.isImage && link.text.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(MarkdownLintIssue(
                rule: "image-alt", line: link.line,
                message: "Image has no alt text: \(link.target)"))
        }

        let headings = MarkdownOutline.headings(in: text)

        // heading-skip
        var prevLevel = 0
        for h in headings {
            if prevLevel > 0, h.level > prevLevel + 1 {
                issues.append(MarkdownLintIssue(
                    rule: "heading-skip", line: h.line,
                    message: "Heading jumps from H\(prevLevel) to H\(h.level): \(h.title)"))
            }
            prevLevel = h.level
        }

        // dup-anchor (flag the 2nd+ occurrence of a slug)
        var slugCount: [String: Int] = [:]
        for h in headings {
            let slug = MarkdownTOC.slug(h.title)
            guard !slug.isEmpty else { continue }
            slugCount[slug, default: 0] += 1
            if slugCount[slug]! >= 2 {
                issues.append(MarkdownLintIssue(
                    rule: "dup-anchor", line: h.line,
                    message: "Duplicate heading anchor '#\(slug)': \(h.title)"))
            }
        }

        return issues.sorted { $0.line < $1.line }
    }
}
