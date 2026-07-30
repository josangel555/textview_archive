//! Markdown→HTML port (TSK-631) — the Rust twin of Swift's `HTMLRenderer`/
//! `HTMLVisitor`, on `pulldown-cmark` (owner-approved TSK-629, default
//! features OFF — we hand-roll the HTML writer to mirror the Swift visitor's
//! emission byte-for-byte over the parity corpus).
//!
//! **Division of labor (the chunk contract).** The core renders STRUCTURE:
//! headings with GitHub-slug ids, paragraphs, lists, blockquotes, GFM
//! tables/strikethrough, inline formatting, the S5/F-06 URL-scheme allowlist,
//! and 5-entity HTML escaping. Host-coupled islands are NOT rendered here —
//! they come back as typed [`Chunk`]s with `<!--mdv-chunk-N-->` sentinels in
//! the html, for the Swift side to enrich and splice:
//! - `raw_html` — raw HTML blocks/inline tags. The SECURITY BARRIER
//!   (`HTMLSanitizer`) stays Swift-side, per the TSK-631 grooming; the core
//!   never emits attacker-controlled raw HTML into `html`.
//! - `code` — fences with a non-empty info string; the host decides
//!   TreeSitter `tok-*` spans vs plain escape. The `<pre><code class=…>`
//!   wrapper IS emitted here; the sentinel sits where the body goes.
//!   (Retires when the TSK-660 highlight port lands.)
//!
//! ` ```mermaid ` fences render their COMPLETE host `<div class="mdv-mermaid">`
//! here via [`crate::mermaid`] (TSK-661) — no chunk round-trip; only the
//! mermaid.js diagram pass stays client-side.
//!
//! Splice rule: each sentinel is replaced VERBATIM by the enrichment of its
//! chunk, located by scanning the ORIGINAL core-emitted html (segment-based,
//! never iterative string replace — a payload that *contains* sentinel text
//! must not hijack a later slot).
//!
//! **Documented divergences from the Swift twin** (A/B corpus avoids them):
//! - parser engines differ (cmark-gfm vs pulldown-cmark) — corner-case
//!   *parses* can differ; the corpus sticks to the common interpretation;
//! - no PARSE-03 nesting guards / truncation marker: pulldown is an
//!   iterative pull parser and this writer is event-driven, so the
//!   C-stack-overflow class the Swift guards exist for is structurally
//!   absent (deep nesting renders fully instead of truncating);
//! - `<ol>` start numbers are ignored (the Swift visitor does the same).

use pulldown_cmark::{
    CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd,
};
use serde::{Deserialize, Serialize};

/// One host-enrichment island extracted from the document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    /// `"raw_html"` | `"mermaid"` | `"code"`.
    pub kind: ChunkKind,
    /// Fence info string for `Code` chunks; empty otherwise.
    pub lang: String,
    /// The raw payload (un-escaped source text / raw HTML).
    pub payload: String,
}

/// What the host must do with a chunk's payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkKind {
    /// Sanitize (HTMLSanitizer) and splice.
    RawHtml,
    /// Highlight (or plain-escape) the fence body and splice.
    Code,
    /// A diagram-source fence (dot/graphviz/plantuml/puml): the host splices
    /// its labeled `<figure class="mdv-diagram">` block via its
    /// DiagramRegistry. Emitted WITHOUT a structural `<pre><code>` wrapper —
    /// the figure IS the block (Stage-B, TSK-649/TSK-713: parity with the
    /// deleted Swift visitor's diagram routing).
    Diagram,
}

impl ChunkKind {
    /// Wire tag.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            ChunkKind::RawHtml => "raw_html",
            ChunkKind::Code => "code",
            ChunkKind::Diagram => "diagram",
        }
    }
}

/// Fence info strings the host's DiagramRegistry routes as diagram-source
/// blocks (mermaid is NOT here — it renders its full host div in core).
fn is_diagram_fence(info: &str) -> bool {
    info.eq_ignore_ascii_case("dot")
        || info.eq_ignore_ascii_case("graphviz")
        || info.eq_ignore_ascii_case("plantuml")
        || info.eq_ignore_ascii_case("puml")
}

/// Rendered output: structural html + the enrichment chunks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderOutput {
    /// HTML with `<!--mdv-chunk-N-->` sentinels where chunks splice in.
    pub html: String,
    /// Chunks, in document order (chunk N owns sentinel N).
    pub chunks: Vec<Chunk>,
}

/// The sentinel marking where chunk `n` splices in.
#[must_use]
pub fn sentinel(n: usize) -> String {
    format!("<!--mdv-chunk-{n}-->")
}

/// Inline (`$…$`) vs block (`$$…$$`) math rendering.
#[derive(Clone, Copy, PartialEq, Eq)]
enum MathDisplay {
    Inline,
    Block,
}

/// LaTeX → MathML via pulldown-latex (owner-approved 2026-07-29).
///
/// TOTAL: invalid TeX must never take the render down — the whole document
/// still renders, with the failed expression shown as its escaped source in
/// a `<code class="mdv-math-error">` so the author can see what to fix.
/// The MathML itself is engine output over escaped input, not author markup,
/// so it bypasses the sanitizer the same way other structural output does.
fn render_mathml(tex: &str, display: MathDisplay) -> String {
    let storage = pulldown_latex::Storage::new();
    let parser = pulldown_latex::Parser::new(tex, &storage);
    let config = pulldown_latex::RenderConfig {
        display_mode: match display {
            MathDisplay::Inline => pulldown_latex::config::DisplayMode::Inline,
            MathDisplay::Block => pulldown_latex::config::DisplayMode::Block,
        },
        ..Default::default()
    };
    let mut out = String::new();
    match pulldown_latex::mathml::push_mathml(&mut out, parser, config) {
        Ok(()) => out,
        Err(_) => format!(
            "<code class=\"mdv-math-error\" title=\"invalid LaTeX\">{}</code>",
            escape(tex)
        ),
    }
}

/// Render markdown to the structural html + chunks (see module docs).
#[must_use]
pub fn render(text: &str) -> RenderOutput {
    // SMART_PUNCTUATION: swift-markdown's default parse curls quotes and
    // converts dashes/ellipses (the A/B suite caught straight-vs-curly
    // divergence) — both engines implement cmark's smart rules.
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_SMART_PUNCTUATION
        // `$…$` inline / `$$…$$` display math → MathML (owner 2026-07-29).
        // The writer MUST handle the two math events whenever this bit is on
        // — an enabled option with a discarding writer arm silently EATS the
        // author's math (the pre-2026-07-29 near-miss: the arms existed as
        // `=> {}`).
        | Options::ENABLE_MATH
        // Recognize a leading YAML (`---`) / TOML (`+++`) frontmatter block as a
        // MetadataBlock so it's SUPPRESSED (see `in_metadata`) instead of rendering
        // as an `<hr>` + a giant setext `<h2>` of the raw key/values — the ugly
        // default for every Jekyll/Hugo/Obsidian doc.
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
        | Options::ENABLE_PLUSES_DELIMITED_METADATA_BLOCKS;
    let mut w = Writer::default();
    for event in Parser::new_ext(text, options) {
        w.event(event);
    }
    RenderOutput { html: w.finish(), chunks: w.chunks }
}

/// Containers that need state while open.
enum Container {
    /// A list item: `para_open` = a synthesized `<p>` is currently open
    /// (the Swift AST always wraps item inlines in a Paragraph; pulldown
    /// emits tight-item inlines bare, so we synthesize to match).
    Item { para_open: bool },
    /// Any other block container.
    Other,
}

#[derive(Default)]
struct Writer {
    /// Output buffers: `bufs[0]` is the document; headings/images push
    /// capture buffers.
    bufs: Vec<String>,
    /// Plain-text capture buffers (heading slug text, image alt text).
    plain: Vec<String>,
    /// While inside an image: html emission is suppressed (alt is plain
    /// text only).
    image_depth: u32,
    /// Open block containers (for tight-item `<p>` synthesis).
    containers: Vec<Container>,
    /// Slug de-dupe: slug → times-issued-so-far. A HashMap keeps `unique_slug`
    /// O(1) per heading (the old Vec linear-scan made it O(N²) over a document's
    /// headings, TSK-984). Never iterated, so there's no ordering dependency.
    used_slugs: std::collections::HashMap<String, u32>,
    /// Code-fence capture (info string) while inside a code block.
    fence: Option<String>,
    /// Raw HTML block capture while inside an `HtmlBlock`.
    html_block: Option<String>,
    /// Inside `<thead>` — table cells emit `<th>` instead of `<td>`.
    in_table_head: bool,
    /// Inside a frontmatter MetadataBlock — suppress ALL inner events (the yaml
    /// text must not render or feed slugs/plain-text).
    in_metadata: bool,
    chunks: Vec<Chunk>,
}

impl Writer {
    fn finish(&mut self) -> String {
        self.bufs.drain(..).next().unwrap_or_default()
    }

    fn out(&mut self, s: &str) {
        if self.image_depth > 0 {
            return; // image alt context: html suppressed
        }
        if self.bufs.is_empty() {
            self.bufs.push(String::new());
        }
        if let Some(top) = self.bufs.last_mut() {
            top.push_str(s);
        }
    }

    /// Record plain text into every active capture (heading slugs include
    /// nested image alt text, so captures nest additively).
    fn plain_text(&mut self, s: &str) {
        for buf in &mut self.plain {
            buf.push_str(s);
        }
    }

    /// An inline is about to be emitted directly inside a list item with no
    /// open block: synthesize the `<p>` the Swift AST shape implies.
    fn synth_para_if_needed(&mut self) {
        if let Some(Container::Item { para_open: para_open @ false }) =
            self.containers.last_mut()
        {
            *para_open = true;
            self.out("<p>");
        }
    }

    /// A block is opening (or the item is closing): close any synthesized
    /// `<p>` first.
    fn close_synth_para(&mut self) {
        if let Some(Container::Item { para_open: para_open @ true }) =
            self.containers.last_mut()
        {
            *para_open = false;
            self.out("</p>\n");
        }
    }

    fn push_chunk(&mut self, kind: ChunkKind, lang: &str, payload: String) {
        let n = self.chunks.len();
        self.chunks.push(Chunk { kind, lang: lang.to_owned(), payload });
        self.out(&sentinel(n));
    }

    fn event(&mut self, event: Event<'_>) {
        // Frontmatter: swallow every event between MetadataBlock start and end
        // (no html, no slug/plain-text capture) so the block is fully hidden.
        if self.in_metadata {
            if matches!(event, Event::End(TagEnd::MetadataBlock(_))) {
                self.in_metadata = false;
            }
            return;
        }
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(t) => {
                // Inside a fence the capture buffer collects RAW text.
                if self.fence.is_some() {
                    if let Some(buf) = self.bufs.last_mut() {
                        buf.push_str(&t);
                    }
                    return;
                }
                self.synth_para_if_needed();
                self.plain_text(&t);
                self.out(&escape(&t));
            }
            Event::Code(c) => {
                self.synth_para_if_needed();
                self.plain_text(&c);
                self.out(&format!("<code>{}</code>", escape(&c)));
            }
            Event::Html(h) => {
                if let Some(block) = &mut self.html_block {
                    block.push_str(&h);
                } else {
                    // Defensive: block html outside an HtmlBlock wrapper.
                    self.push_chunk(ChunkKind::RawHtml, "", h.into_string());
                }
            }
            Event::InlineHtml(h) => {
                self.synth_para_if_needed();
                self.push_chunk(ChunkKind::RawHtml, "", h.into_string());
            }
            Event::SoftBreak => {
                self.synth_para_if_needed();
                self.plain_text(" ");
                self.out("\n");
            }
            Event::HardBreak => {
                self.synth_para_if_needed();
                self.plain_text(" ");
                self.out("<br/>\n");
            }
            Event::Rule => self.out("<hr/>\n"),
            // GFM task list: emit a disabled checkbox at the marker, INSIDE the
            // item's synthesized <p> so it precedes the text (TSK-903). This is
            // trusted structural output (not author raw-HTML), so it bypasses
            // the sanitizer. The Swift visitor mirrors this byte-for-byte
            // (HTMLVisitor.visitListItem) — the A/B parity suite pins it.
            Event::TaskListMarker(checked) => {
                self.synth_para_if_needed();
                self.out(if checked {
                    "<input type=\"checkbox\" disabled checked/> "
                } else {
                    "<input type=\"checkbox\" disabled/> "
                });
            }
            // Math (owner-approved 2026-07-29): `$…$` / `$$…$$` render to
            // MathML in the BACKEND via pulldown-latex — WebKit renders
            // MathML Core natively, so no JS enters the WebContent process
            // and math survives the script-free export path. Inline math is
            // inline content (synthesize the paragraph like Text does);
            // display math is block-level.
            Event::InlineMath(tex) => {
                self.synth_para_if_needed();
                let mathml = render_mathml(&tex, MathDisplay::Inline);
                self.out(&mathml);
            }
            Event::DisplayMath(tex) => {
                self.close_synth_para();
                let mathml = render_mathml(&tex, MathDisplay::Block);
                self.out(&mathml);
                self.out("\n");
            }
            // Unreachable without their Options bits; ignore defensively.
            Event::FootnoteReference(_) => {}
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => {
                self.close_synth_para();
                self.containers.push(Container::Other);
                self.out("<p>");
            }
            Tag::Heading { .. } => {
                self.close_synth_para();
                self.containers.push(Container::Other);
                // Capture inner html + plain text for the slug.
                self.bufs.push(String::new());
                self.plain.push(String::new());
            }
            Tag::BlockQuote(_) => {
                self.close_synth_para();
                self.containers.push(Container::Other);
                self.out("<blockquote>\n");
            }
            Tag::List(ordered) => {
                self.close_synth_para();
                self.containers.push(Container::Other);
                // The Swift visitor ignores ordered-list start numbers.
                self.out(if ordered.is_some() { "<ol>\n" } else { "<ul>\n" });
            }
            Tag::Item => {
                self.containers.push(Container::Item { para_open: false });
                self.out("<li>");
            }
            Tag::CodeBlock(kind) => {
                self.close_synth_para();
                self.containers.push(Container::Other);
                let info = match kind {
                    CodeBlockKind::Fenced(info) => info.into_string(),
                    CodeBlockKind::Indented => String::new(),
                };
                self.fence = Some(info);
                self.bufs.push(String::new()); // raw fence-body capture
            }
            Tag::HtmlBlock => {
                self.close_synth_para();
                self.containers.push(Container::Other);
                self.html_block = Some(String::new());
            }
            Tag::Table(_) => {
                self.close_synth_para();
                self.containers.push(Container::Other);
                self.out("<table>\n");
            }
            Tag::TableHead => {
                self.containers.push(Container::Other);
                self.in_table_head = true;
                self.out("<thead><tr>");
            }
            Tag::TableRow => {
                self.containers.push(Container::Other);
                self.out("<tr>");
            }
            Tag::TableCell => {
                self.containers.push(Container::Other);
                self.out(if self.in_table_head { "<th>" } else { "<td>" });
            }
            Tag::Emphasis => {
                self.synth_para_if_needed();
                self.out("<em>");
            }
            Tag::Strong => {
                self.synth_para_if_needed();
                self.out("<strong>");
            }
            Tag::Strikethrough => {
                self.synth_para_if_needed();
                self.out("<del>");
            }
            Tag::Link { dest_url, title, .. } => {
                self.synth_para_if_needed();
                let href = safe_url(&dest_url, UrlContext::Link);
                let title_attr = if title.is_empty() {
                    String::new()
                } else {
                    format!(" title=\"{}\"", escape(&title))
                };
                self.out(&format!("<a href=\"{}\"{}>", escape(&href), title_attr));
            }
            Tag::Image { dest_url, .. } => {
                self.synth_para_if_needed();
                // Emit the opening now (suppression starts after), capture
                // alt text from the inline children, close at End(Image).
                let src = safe_url(&dest_url, UrlContext::Image);
                self.out(&format!("<img src=\"{}\" alt=\"", escape(&src)));
                self.image_depth = self.image_depth.saturating_add(1);
                self.plain.push(String::new());
            }
            // Frontmatter block: enter suppression (the event loop swallows the
            // inner events + the matching End until it clears this).
            Tag::MetadataBlock(_) => self.in_metadata = true,
            // Unreachable without their Options bits; treat as transparent.
            Tag::FootnoteDefinition(_)
            | Tag::DefinitionList
            | Tag::DefinitionListTitle
            | Tag::DefinitionListDefinition
            | Tag::Superscript
            | Tag::Subscript => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => {
                self.containers.pop();
                self.out("</p>\n");
            }
            TagEnd::Heading(level) => {
                self.containers.pop();
                let inner = self.bufs.pop().unwrap_or_default();
                let text = self.plain.pop().unwrap_or_default();
                let slug = self.unique_slug(&text);
                let n = heading_level(level);
                self.out(&format!("<h{n} id=\"{slug}\">{inner}</h{n}>\n"));
            }
            TagEnd::BlockQuote(_) => {
                self.containers.pop();
                self.out("</blockquote>\n");
            }
            TagEnd::List(ordered) => {
                self.containers.pop();
                self.out(if ordered { "</ol>\n" } else { "</ul>\n" });
            }
            TagEnd::Item => {
                self.close_synth_para();
                self.containers.pop();
                self.out("</li>\n");
            }
            TagEnd::CodeBlock => {
                self.containers.pop();
                let code = self.bufs.pop().unwrap_or_default();
                let info = self.fence.take().unwrap_or_default();
                if info.is_empty() {
                    self.out(&format!("<pre><code>{}</code></pre>\n", escape(&code)));
                } else if info.eq_ignore_ascii_case("mermaid") {
                    // TSK-661: the full host div renders in core — no chunk.
                    let host = crate::mermaid::render_host(&code);
                    self.out(&host);
                } else if is_diagram_fence(&info) {
                    // Diagram-source fences splice as a whole labeled figure
                    // host-side — no structural wrapper here (TSK-713 parity
                    // with the deleted Swift visitor's diagram routing).
                    self.push_chunk(ChunkKind::Diagram, &info, code);
                } else {
                    self.out(&format!("<pre><code class=\"language-{}\">", escape(&info)));
                    self.push_chunk(ChunkKind::Code, &info, code);
                    self.out("</code></pre>\n");
                }
            }
            TagEnd::HtmlBlock => {
                self.containers.pop();
                if let Some(raw) = self.html_block.take() {
                    self.push_chunk(ChunkKind::RawHtml, "", raw);
                }
            }
            TagEnd::Table => {
                self.containers.pop();
                self.out("</tbody></table>\n");
            }
            TagEnd::TableHead => {
                self.containers.pop();
                self.in_table_head = false;
                self.out("</tr></thead>\n<tbody>\n");
            }
            TagEnd::TableRow => {
                self.containers.pop();
                self.out("</tr>\n");
            }
            TagEnd::TableCell => {
                self.containers.pop();
                self.out(if self.in_table_head { "</th>" } else { "</td>" });
            }
            TagEnd::Emphasis => self.out("</em>"),
            TagEnd::Strong => self.out("</strong>"),
            TagEnd::Strikethrough => self.out("</del>"),
            TagEnd::Link => self.out("</a>"),
            TagEnd::Image => {
                self.image_depth = self.image_depth.saturating_sub(1);
                let alt = self.plain.pop().unwrap_or_default();
                self.out(&format!("{}\"/>", escape(&alt)));
            }
            TagEnd::FootnoteDefinition
            | TagEnd::DefinitionList
            | TagEnd::DefinitionListTitle
            | TagEnd::DefinitionListDefinition
            | TagEnd::MetadataBlock(_)
            | TagEnd::Superscript
            | TagEnd::Subscript => {}
        }
    }

    /// GitHub-flavored slug, de-duped within the document — the exact
    /// `HTMLVisitor.uniqueSlug` algorithm.
    fn unique_slug(&mut self, text: &str) -> String {
        let mut slug = String::with_capacity(text.len());
        let mut last_was_dash = true;
        for ch in text.chars() {
            if ch.is_alphanumeric() {
                for lower in ch.to_lowercase() {
                    slug.push(lower);
                }
                last_was_dash = false;
            } else if !last_was_dash {
                slug.push('-');
                last_was_dash = true;
            }
        }
        while slug.ends_with('-') {
            slug.pop();
        }
        if slug.is_empty() {
            slug = "section".to_owned();
        }
        if let Some(n) = self.used_slugs.get_mut(&slug) {
            *n = n.saturating_add(1);
            return format!("{slug}-{n}");
        }
        self.used_slugs.insert(slug.clone(), 0);
        slug
    }
}

/// Heading level as a number.
fn heading_level(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

// ---------------------------------------------------------------------------
// URL scheme safety — the S5/F-06 allowlist (HTMLVisitor.safeURL port).
// ---------------------------------------------------------------------------

/// Where a URL is being emitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UrlContext {
    /// `<a href>` — http/https/mailto/fragment/relative.
    Link,
    /// `<img src>` — http/https/file/data:image/fragment/relative.
    Image,
}

/// Returns the URL if its scheme is allowlisted, else `"about:blank"`.
/// `javascript:`, `vbscript:`, custom-app schemes, and (for links) `file:`
/// and `data:` are rewritten so malicious markdown can't smuggle them.
#[must_use]
pub fn safe_url(raw: &str, ctx: UrlContext) -> String {
    // WebKit removes ASCII tab/LF/CR from a URL before parsing, so a scheme like
    // "java\tscript:" would slip past the prefix check below and then execute
    // (TSK-1000). Strip those control chars first so we evaluate the scheme the
    // browser will actually see.
    let normalized: String =
        raw.chars().filter(|&c| c != '\t' && c != '\n' && c != '\r').collect();
    let trimmed = normalized.trim();
    if trimmed.is_empty() {
        return "about:blank".to_owned();
    }
    if trimmed.starts_with('#') {
        return trimmed.to_owned();
    }
    let Some(colon) = trimmed.find(':') else {
        return trimmed.to_owned(); // relative path, no scheme
    };
    let prefix_raw = trimmed.get(..colon).unwrap_or_default();
    let is_scheme = !prefix_raw.is_empty()
        && prefix_raw
            .chars()
            .all(|c| c.is_alphanumeric() || c == '+' || c == '-' || c == '.');
    if !is_scheme {
        return trimmed.to_owned(); // e.g. authority-relative "//host/x"
    }
    let prefix = prefix_raw.to_lowercase();
    let allowed: &[&str] = match ctx {
        UrlContext::Link => &["http", "https", "mailto"],
        UrlContext::Image => &["http", "https", "file", "data"],
    };
    if allowed.contains(&prefix.as_str()) {
        if prefix == "data" && ctx == UrlContext::Image {
            // Only image/* data URLs.
            let rest = trimmed.get(colon.saturating_add(1)..).unwrap_or_default();
            if rest.starts_with("image/") {
                return trimmed.to_owned();
            }
            return "about:blank".to_owned();
        }
        return trimmed.to_owned();
    }
    "about:blank".to_owned()
}

/// HTML-escape the five significant characters (the Swift `htmlEscape` set).
#[must_use]
pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Wire layer — `ffi_frame_body!` shape.
// ---------------------------------------------------------------------------

/// Borrowed `text` (TSK-561): the whole markdown document crosses per render.
#[derive(Deserialize)]
struct RenderRequest<'a> {
    #[serde(borrow)]
    text: std::borrow::Cow<'a, str>,
}

#[derive(Serialize)]
struct WireChunk {
    kind: String,
    lang: String,
    payload: String,
}

#[derive(Serialize)]
struct RenderResponse {
    html: String,
    chunks: Vec<WireChunk>,
}

/// `{text}` request frame → `{html, chunks:[{kind,lang,payload}]}` response
/// frame (see the module docs for the chunk/splice contract).
pub fn render_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: RenderRequest<'_> = crate::wire::decode_frame_borrowed(req_frame)?;
    let out = render(&req.text);
    crate::wire::encode_frame(&RenderResponse {
        html: out.html,
        chunks: out
            .chunks
            .into_iter()
            .map(|c| WireChunk {
                kind: c.kind.as_str().to_owned(),
                lang: c.lang,
                payload: c.payload,
            })
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn html(md: &str) -> String {
        render(md).html
    }

    // Math → MathML (owner-approved pulldown-latex, 2026-07-29). WebKit
    // renders MathML Core natively — no JS, works in export.
    #[test]
    fn inline_math_renders_mathml_inside_the_paragraph() {
        let out = html("Euler: $e^{i\\pi} + 1 = 0$ wow");
        assert!(out.contains("<math"), "inline math must emit MathML: {out}");
        assert!(!out.contains("display=\"block\""), "inline math is inline");
        assert!(out.starts_with("<p>"), "math joins the surrounding paragraph");
        assert!(out.contains("wow"), "trailing prose survives");
    }

    #[test]
    fn display_math_renders_block_mathml() {
        let out = html("before\n\n$$\\frac{a}{b}$$\n\nafter");
        assert!(out.contains("<math"), "display math must emit MathML: {out}");
        assert!(out.contains("display=\"block\""), "display math is block-level");
        assert!(out.contains("<mfrac>"), "the fraction structure survives: {out}");
    }

    /// TOTAL: broken TeX must not take the document down — the rest still
    /// renders and the failed expression shows its escaped source.
    #[test]
    fn invalid_latex_degrades_to_escaped_source_never_panics() {
        let out = html("ok $\\frac{$ ok");
        assert!(out.contains("ok"), "the document still renders: {out}");
        // Either an error node from the engine or our escaped-source
        // fallback — but NEVER a panic, and never raw unescaped TeX.
        assert!(!out.contains("<script"), "no injection path");
    }

    /// A dollar amount in prose must not be eaten as math ("$5 and $10"
    /// is the classic false positive).
    #[test]
    fn dollar_amounts_in_prose_are_not_math() {
        let out = html("costs $5 and $10 total");
        assert!(out.contains("$5"), "prose dollars survive: {out}");
        assert!(!out.contains("<math"), "no math for currency: {out}");
    }

    /// Escaped content INSIDE math must stay escaped (math text carries
    /// author bytes — `<` in TeX must not open a tag).
    #[test]
    fn math_content_is_escaped_not_injected() {
        let out = html("$x <img src=x onerror=alert(1)> y$");
        assert!(!out.contains("<img"), "author bytes inside math never become markup: {out}");
    }

    #[test]
    fn headings_with_slugs_and_dedupe() {
        assert_eq!(html("# Hello World"), "<h1 id=\"hello-world\">Hello World</h1>\n");
        assert_eq!(
            html("## Dup\n\n## Dup"),
            "<h2 id=\"dup\">Dup</h2>\n<h2 id=\"dup-1\">Dup</h2>\n"
        );
        // Formatting inside the heading: slug from plain text, tags kept.
        assert_eq!(
            html("# Hello **Bold** `code`"),
            "<h1 id=\"hello-bold-code\">Hello <strong>Bold</strong> <code>code</code></h1>\n"
        );
        // Symbol-only heading falls back to "section".
        assert_eq!(html("# !!!"), "<h1 id=\"section\">!!!</h1>\n");
    }

    #[test]
    fn slug_dedupe_scales_to_many_duplicates() {
        // TSK-984: many same-title headings dedupe to title, title-1, …,
        // title-(N-1) via an O(1)/heading HashMap lookup (was O(N²) Vec scan).
        let n = 200;
        let md = vec!["# Title"; n].join("\n\n");
        let out = html(&md);
        assert!(out.contains("<h1 id=\"title\">Title</h1>"), "first is the bare slug");
        assert!(out.contains("<h1 id=\"title-1\">Title</h1>"));
        assert!(
            out.contains(&format!("<h1 id=\"title-{}\">Title</h1>", n - 1)),
            "the Nth duplicate gets the -(N-1) suffix"
        );
        // Every heading got a unique id.
        assert_eq!(out.matches("id=\"").count(), n, "all {n} headings have an id");
    }

    #[test]
    fn paragraphs_and_inline_formatting() {
        assert_eq!(
            html("plain *em* **strong** ~~gone~~ `c&d`"),
            "<p>plain <em>em</em> <strong>strong</strong> <del>gone</del> <code>c&amp;d</code></p>\n"
        );
        assert_eq!(html("a\nb"), "<p>a\nb</p>\n"); // softbreak
        assert_eq!(html("a  \nb"), "<p>a<br/>\nb</p>\n"); // hardbreak
    }

    #[test]
    fn tight_list_items_synthesize_paragraphs() {
        // The Swift AST always wraps item inlines in a Paragraph — pulldown
        // emits tight items bare; the writer synthesizes <p> to match.
        assert_eq!(
            html("- a\n- b"),
            "<ul>\n<li><p>a</p>\n</li>\n<li><p>b</p>\n</li>\n</ul>\n"
        );
        // Loose list: real Paragraph events, same output shape.
        assert_eq!(
            html("- a\n\n- b"),
            "<ul>\n<li><p>a</p>\n</li>\n<li><p>b</p>\n</li>\n</ul>\n"
        );
        // Ordered list: start number ignored (Swift parity).
        assert_eq!(
            html("5. x\n6. y"),
            "<ol>\n<li><p>x</p>\n</li>\n<li><p>y</p>\n</li>\n</ol>\n"
        );
        // Nested list inside a tight item: <p> closes before the sublist.
        assert_eq!(
            html("- a\n  - b"),
            "<ul>\n<li><p>a</p>\n<ul>\n<li><p>b</p>\n</li>\n</ul>\n</li>\n</ul>\n"
        );
    }

    #[test]
    fn task_list_renders_disabled_checkboxes() {
        // TSK-903: GFM task items render a disabled checkbox inside the item's
        // <p>; the Swift visitor matches this byte-for-byte (A/B parity).
        assert_eq!(
            html("- [x] done\n- [ ] todo"),
            "<ul>\n<li><p><input type=\"checkbox\" disabled checked/> done</p>\n</li>\n<li><p><input type=\"checkbox\" disabled/> todo</p>\n</li>\n</ul>\n"
        );
    }

    #[test]
    fn blockquote_hr_and_nesting() {
        assert_eq!(html("> quoted"), "<blockquote>\n<p>quoted</p>\n</blockquote>\n");
        assert_eq!(html("---"), "<hr/>\n");
        assert_eq!(
            html("> outer\n>> inner"),
            "<blockquote>\n<p>outer</p>\n<blockquote>\n<p>inner</p>\n</blockquote>\n</blockquote>\n"
        );
    }

    #[test]
    fn tables_match_the_swift_shape() {
        assert_eq!(
            html("| a | b |\n|---|---|\n| 1 | 2 |"),
            "<table>\n<thead><tr><th>a</th><th>b</th></tr></thead>\n<tbody>\n<tr><td>1</td><td>2</td></tr>\n</tbody></table>\n"
        );
    }

    #[test]
    fn links_and_images_with_scheme_allowlist() {
        assert_eq!(
            html("[ok](https://example.com)"),
            "<p><a href=\"https://example.com\">ok</a></p>\n"
        );
        assert_eq!(
            html("[t](https://e.com \"Title\")"),
            "<p><a href=\"https://e.com\" title=\"Title\">t</a></p>\n"
        );
        // javascript: rewritten for links; file: allowed for images only.
        assert_eq!(
            html("[evil](javascript:alert(1))"),
            "<p><a href=\"about:blank\">evil</a></p>\n"
        );
        assert_eq!(
            html("[f](file:///etc/passwd)"),
            "<p><a href=\"about:blank\">f</a></p>\n"
        );
        assert_eq!(
            html("![alt text](file:///tmp/x.png)"),
            "<p><img src=\"file:///tmp/x.png\" alt=\"alt text\"/></p>\n"
        );
        // data: images must be image/*.
        assert_eq!(
            html("![d](data:image/png;base64,AAAA)"),
            "<p><img src=\"data:image/png;base64,AAAA\" alt=\"d\"/></p>\n"
        );
        assert_eq!(
            html("![d](data:text/html;base64,AAAA)"),
            "<p><img src=\"about:blank\" alt=\"d\"/></p>\n"
        );
        // Fragment + relative survive untouched.
        assert_eq!(html("[s](#sec)"), "<p><a href=\"#sec\">s</a></p>\n");
        assert_eq!(html("[r](docs/x.md)"), "<p><a href=\"docs/x.md\">r</a></p>\n");
    }

    #[test]
    fn safe_url_rejects_whitespace_smuggled_javascript() {
        // TSK-1000: WebKit strips ASCII tab/LF/CR, so each of these collapses to
        // "javascript:" in the browser — they must be rewritten to about:blank,
        // not returned verbatim (the pre-fix behaviour, since the embedded control
        // char made the scheme prefix look non-schemey).
        for raw in [
            "java\tscript:alert(1)",
            "java\nscript:alert(1)",
            "java\rscript:alert(1)",
            "javascript\t:alert(1)",
        ] {
            assert_eq!(safe_url(raw, UrlContext::Link), "about:blank",
                       "smuggled scheme {raw:?} must be rejected");
        }
        // A legitimate https URL is unaffected.
        assert_eq!(safe_url("https://example.com", UrlContext::Link), "https://example.com");
    }

    #[test]
    fn image_alt_uses_plain_text_of_children() {
        assert_eq!(
            html("![alt with **bold**](https://e.com/i.png)"),
            "<p><img src=\"https://e.com/i.png\" alt=\"alt with bold\"/></p>\n"
        );
    }

    #[test]
    fn plain_and_indented_code_render_inline_no_chunk() {
        let out = render("```\nlet x = 1 < 2\n```");
        assert_eq!(out.html, "<pre><code>let x = 1 &lt; 2\n</code></pre>\n");
        assert!(out.chunks.is_empty());
        let out = render("    indented\n");
        assert_eq!(out.html, "<pre><code>indented\n</code></pre>\n");
        assert!(out.chunks.is_empty());
    }

    #[test]
    fn language_fences_become_code_chunks() {
        let out = render("```swift\nlet x = 1\n```");
        assert_eq!(
            out.html,
            format!("<pre><code class=\"language-swift\">{}</code></pre>\n", sentinel(0))
        );
        assert_eq!(out.chunks.len(), 1);
        assert_eq!(out.chunks.first().map(|c| c.kind), Some(ChunkKind::Code));
        assert_eq!(out.chunks.first().map(|c| c.lang.as_str()), Some("swift"));
        assert_eq!(out.chunks.first().map(|c| c.payload.as_str()), Some("let x = 1\n"));
    }

    #[test]
    fn mermaid_fences_render_full_host_div_no_chunk() {
        // TSK-661: the host div renders in core (id/hash/steps/src attrs);
        // no chunk crosses to the host for mermaid.
        let out = render("```mermaid\ngraph TD; A-->B;\n```");
        assert!(out.chunks.is_empty(), "mermaid must not produce a chunk");
        assert!(out.html.starts_with("<div class=\"mdv-mermaid\""));
        assert!(out.html.contains("data-mdv-src-hash=\""));
        assert!(out.html.contains("graph TD; A--&gt;B;"));
        assert!(out.html.ends_with("</div>\n"));
        // Case-insensitive intercept, like the Swift visitor.
        let out = render("```Mermaid\nx\n```");
        assert!(out.chunks.is_empty());
        assert!(out.html.starts_with("<div class=\"mdv-mermaid\""));
        // Step annotations surface as the data-mdv-steps manifest.
        let out = render("```mermaid\n%% @step 1\nA-->B\n```");
        assert!(out.html.contains("data-mdv-steps=\""));
    }

    #[test]
    fn raw_html_block_and_inline_become_chunks_never_inline_html() {
        let out = render("<div class=\"x\">\n<script>evil()</script>\n</div>\n\npara");
        // The whole contiguous block is ONE chunk (the sanitizer must see
        // tag pairs together, not line by line).
        assert_eq!(out.chunks.len(), 1);
        assert_eq!(out.chunks.first().map(|c| c.kind), Some(ChunkKind::RawHtml));
        let payload = out.chunks.first().map(|c| c.payload.clone()).unwrap_or_default();
        assert!(payload.contains("<script>"), "raw payload is unsanitized: {payload}");
        assert!(
            !out.html.contains("<script>"),
            "raw html must never leak into the structural html"
        );
        assert!(out.html.contains(&sentinel(0)));

        let out = render("a <b>bold</b> c");
        assert_eq!(out.chunks.len(), 2, "each inline tag is its own chunk");
        assert_eq!(
            out.html,
            format!("<p>a {}bold{} c</p>\n", sentinel(0), sentinel(1))
        );
    }

    #[test]
    fn text_containing_sentinel_lookalike_is_escaped_harmless() {
        let out = render("literal <!--mdv-chunk-0--> in text");
        assert!(out.chunks.is_empty() || out.chunks.len() == 1);
        // Either parsed as inline html (→ chunk, payload carries it) or
        // escaped text — never a bare un-owned sentinel in html that has no
        // chunk behind it beyond chunks.len().
        for n in out.chunks.len()..out.chunks.len().saturating_add(3) {
            assert!(
                !out.html.contains(&sentinel(n)),
                "no orphan sentinel beyond the chunk table"
            );
        }
    }

    #[test]
    fn deep_nesting_renders_without_truncation_or_crash() {
        // PARSE-03 divergence: pulldown is iterative; 6000 '>' levels render
        // fine (the Swift twin refuses input at 5500 to protect cmark's C
        // stack). No truncation marker exists in this output.
        let bombs = ">".repeat(6000) + " x";
        let out = render(&bombs);
        assert!(out.html.starts_with("<blockquote>"));
        assert!(!out.html.contains("truncated"));
    }

    #[test]
    fn yaml_frontmatter_is_hidden() {
        let out = render("---\ntitle: Hello\ntags: [a, b]\n---\n\n# Body\n\ntext");
        assert!(!out.html.contains("title: Hello"), "yaml must not render: {}", out.html);
        assert!(!out.html.contains("<hr"), "--- fences must not become a rule: {}", out.html);
        assert!(out.html.contains("<h1 id=\"body\">Body</h1>"), "body must render: {}", out.html);
    }

    #[test]
    fn toml_frontmatter_is_hidden() {
        let out = render("+++\ntitle = \"X\"\n+++\n\n# Body");
        assert!(!out.html.contains("title = "), "toml must not render: {}", out.html);
        assert!(out.html.contains("Body"));
    }

    #[test]
    fn mid_document_dashes_stay_a_thematic_break() {
        let out = render("# A\n\ntext\n\n---\n\nmore");
        assert!(out.html.contains("<hr"), "mid-doc --- is still a rule: {}", out.html);
    }

    #[test]
    fn wire_round_trip() {
        #[derive(Serialize)]
        struct Req<'a> {
            text: &'a str,
        }
        #[derive(Deserialize)]
        struct Resp {
            html: String,
            chunks: Vec<RChunk>,
        }
        #[derive(Deserialize)]
        struct RChunk {
            kind: String,
            lang: String,
            payload: String,
        }
        let frame = crate::wire::encode_frame(&Req {
            text: "# T\n\n```swift\nlet a = 1\n```",
        })
        .unwrap();
        let resp: Resp = crate::wire::decode_frame(&render_wire(&frame).unwrap()).unwrap();
        assert!(resp.html.starts_with("<h1 id=\"t\">T</h1>\n"));
        assert_eq!(resp.chunks.len(), 1);
        assert_eq!(resp.chunks[0].kind, "code");
        assert_eq!(resp.chunks[0].lang, "swift");
        assert_eq!(resp.chunks[0].payload, "let a = 1\n");
    }

    /// Security fuzz of the untrusted-.md render path (the web viewer renders
    /// attacker-controlled markdown). For random input — including spliced
    /// injection fragments — render() must NEVER panic, and the structural
    /// `out.html` must never carry a raw `<script` tag or a `javascript:` /
    /// `vbscript:` URL scheme in an href/src (raw HTML is sentinel-replaced; link
    /// schemes are rewritten). Merge gate fixed seed; nightly varies
    /// MDV_FUZZ_SEED_BASE. (Raw-HTML CHUNK payloads are sanitized downstream and
    /// are out of scope here — this pins the structural-html guarantee.)
    #[test]
    #[allow(clippy::cast_possible_truncation)] // RNG outputs are modulo-bounded to a small index/len
    fn render_fuzz_structural_html_never_leaks_script_or_js_scheme() {
        let seed_base: u64 = std::env::var("MDV_FUZZ_SEED_BASE")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let alpha: Vec<char> =
            "<>/\\\"'`[]()!#*_-=:;. \n\tabc日 script img a href src onerror alert".chars().collect();
        let fragments = [
            "<script>x</script>",
            "[a](javascript:b)",
            "<a href=\"javascript:c\">t</a>",
            "<img src=\"javascript:d\">",
            "![i](javascript:e)",
            "<SCRIPT>Y</SCRIPT>",
            "[v](vbscript:f)",
            "<iframe src=\"javascript:g\"></iframe>",
        ];
        let mut s: u64 = seed_base.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
        let mut next = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s
        };
        for _ in 0..600 {
            let len = (next() % 120) as usize;
            let mut text: String =
                (0..len).map(|_| alpha[(next() % alpha.len() as u64) as usize]).collect();
            if next() % 2 == 0 {
                text.push_str(fragments[(next() as usize) % fragments.len()]);
            }
            let out = render(&text); // must not panic
            let lower = out.html.to_lowercase();
            assert!(!lower.contains("<script"), "raw <script in out.html for in={text:?}");
            assert!(
                !lower.contains("href=\"javascript:"),
                "javascript: href leaked for in={text:?} out={}",
                out.html
            );
            assert!(
                !lower.contains("src=\"javascript:"),
                "javascript: src leaked for in={text:?} out={}",
                out.html
            );
            assert!(
                !lower.contains("href=\"vbscript:"),
                "vbscript: href leaked for in={text:?} out={}",
                out.html
            );
        }
    }

    // --- Property tests (TSK-585 lane): URL-sanitize + HTML-escape security ---
    use proptest::prelude::*;

    fn url_input_strategy() -> impl Strategy<Value = String> {
        prop_oneof![
            Just("javascript:alert(1)".to_string()),
            Just("java\tscript:alert(1)".to_string()),
            Just("java\nscript:x".to_string()),
            Just("\t\n javascript:x".to_string()),
            Just("JaVaScRiPt:x".to_string()),
            Just("vbscript:msgbox".to_string()),
            Just("vb\tscript:x".to_string()),
            Just("data:text/html,<script>".to_string()),
            Just("data:image/png;base64,AAAA".to_string()),
            Just("DATA:text/html,x".to_string()),
            Just("http://example.com".to_string()),
            Just("#fragment".to_string()),
            Just("/relative".to_string()),
            Just("mailto:a@b".to_string()),
            "[a-zA-Z\t\n\r :/#.,]{0,30}",
        ]
    }

    proptest! {
        /// safe_url NEVER yields an executable-scheme URL (javascript:/vbscript:)
        /// for any input + context — even with the TSK-1000 control-char bypass
        /// or case tricks; a surviving data: URL is only image/* in Image context.
        #[test]
        fn safe_url_never_yields_executable_scheme(
            raw in url_input_strategy(), is_image in any::<bool>(),
        ) {
            let ctx = if is_image { UrlContext::Image } else { UrlContext::Link };
            let out = safe_url(&raw, ctx);
            // Re-normalize the way safe_url + the browser would (strip tab/LF/CR).
            let norm: String = out.chars().filter(|&c| !matches!(c, '\t' | '\n' | '\r')).collect();
            let lower = norm.trim().to_lowercase();
            prop_assert!(!lower.starts_with("javascript:"), "leaked javascript: from {:?}", raw);
            prop_assert!(!lower.starts_with("vbscript:"), "leaked vbscript: from {:?}", raw);
            if lower.starts_with("data:") {
                prop_assert!(ctx == UrlContext::Image && lower.starts_with("data:image/"),
                    "leaked non-image data: URL from {:?}", raw);
            }
        }

        /// escape removes every raw markup char that could open a tag/attribute:
        /// the output contains no <, >, ", or ' (each replaced by its entity).
        #[test]
        fn escape_removes_raw_markup_chars(s in "[<>&\"'a-zA-Z0-9 \t]{0,40}") {
            let out = escape(&s);
            prop_assert!(!out.contains('<'));
            prop_assert!(!out.contains('>'));
            prop_assert!(!out.contains('"'));
            prop_assert!(!out.contains('\''));
        }
    }
}
