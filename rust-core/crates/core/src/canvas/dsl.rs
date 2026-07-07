//! Canvas M1.S8 — the authoring DSL parser (TSK-1363; 07-DSL-SPIKE).
//!
//! The agent-facing surface language for SUBTREE AUTHORING — compact, line
//! oriented, id-anchored:
//!
//! ```text
//! frame #hero fill=$color.surface padding=$space.lg gap=8 {
//!   text #title "Hello world" font=$font.h1
//!   image src="shot.png" fit=cover
//! }
//! ```
//!
//! * element line = `<kind> [#id] ["text sugar"] [prop=value …] [{`
//! * values: numbers → `Num`, `$path` → `Token`, `true`/`false` → `Bool`,
//!   quoted or bare words → `Str`
//! * `#name` anchors mint deterministic ids (`nd:name`); omitting it lets the
//!   engine mint
//! * a bare quoted string after the head is sugar for `text="…"`
//!
//! Output is a plan of ordinary [`CanvasOp::Insert`]s (depth-first) — the DSL
//! never bypasses the op layer or the fence; it is a FRONT END to them. The
//! parser validates vocabulary EARLY (unknown kinds/props fail here with
//! teaching messages listing what IS legal — the close-the-loop rule), and
//! the fence re-checks everything at apply.
//!
//! EDIT statements complete the verb set (id-anchored, one per line):
//!
//! ```text
//! set #title text="New copy" color=$color.accent
//! unset #title font
//! move #pic -> #row first
//! remove #hero
//! ```
//!
//! [`render`] projects a live subtree BACK into canonical DSL —
//! `parse(render(doc)) == doc` (round-trip pinned by test). Structural-diff
//! projection EDITING (rewrite-the-block workflows) is the M2 surface (07 §5).

use super::ops::CanvasOp;
use super::props::{PropKey, Value};
use super::registry;
use super::store::{Id, Position, RecordKind};

/// A token-store mutation statement (M4.S4): `token set <path> <value>` /
/// `token alias <path> <target>` / `token rename <old> <new>`. Tokens are
/// DOCUMENT settings (not record state): applied by the doc facade, not the
/// op engine; renames are deprecate-and-alias underneath.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenStatement {
    /// Set a token to a literal CSS value.
    Set {
        /// Token path (`color.accent`).
        path: String,
        /// The CSS value.
        css: String,
    },
    /// Point a token at another token.
    Alias {
        /// Token path being defined.
        path: String,
        /// The token it references.
        target: String,
    },
    /// Rename a token (references follow).
    Rename {
        /// Existing path.
        old: String,
        /// New path.
        new: String,
    },
}

/// Parse fault: line (1-based) + a teaching message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DslError {
    /// 1-based source line of the fault.
    pub line: usize,
    /// A teaching message (what was expected).
    pub message: String,
}

fn err<T>(line: usize, message: impl Into<String>) -> Result<T, DslError> {
    Err(DslError {
        line,
        message: message.into(),
    })
}

/// One lexed token.
#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Word(String),          // frame, cover, true
    Anchor(String),        // #hero
    Quoted(String),        // "hello"
    Prop(String, Box<Tok>), // fill=$color.x, gap=8
    TokenRef(String),      // $color.accent
    Number(f64),           // 8, 0.5, -4
    Open,                  // {
    Close,                 // }
}

/// Lex one line (whitespace-separated with quoted-string awareness).
fn lex_line(line: &str, line_no: usize) -> Result<Vec<Tok>, DslError> {
    let mut toks = Vec::new();
    let mut chars = line.chars().peekable();
    while let Some(&c) = chars.peek() {
        match c {
            c if c.is_whitespace() => {
                chars.next();
            }
            '{' => {
                chars.next();
                toks.push(Tok::Open);
            }
            '}' => {
                chars.next();
                toks.push(Tok::Close);
            }
            '"' => {
                toks.push(Tok::Quoted(lex_string(&mut chars, line_no)?));
            }
            '#' => {
                chars.next();
                let name = lex_word(&mut chars);
                if name.is_empty() {
                    return err(line_no, "'#' must be followed by an id name");
                }
                toks.push(Tok::Anchor(name));
            }
            '/' => {
                // Line comment: `// …` to end of line.
                chars.next();
                if chars.peek() == Some(&'/') {
                    break;
                }
                return err(line_no, "unexpected '/' (comments are '//')");
            }
            _ => {
                let word = lex_word(&mut chars);
                if word.is_empty() {
                    return err(line_no, format!("unexpected character '{c}'"));
                }
                if chars.peek() == Some(&'=') {
                    chars.next();
                    let value = lex_value(&mut chars, line_no)?;
                    toks.push(Tok::Prop(word, Box::new(value)));
                } else {
                    toks.push(Tok::Word(word));
                }
            }
        }
    }
    Ok(toks)
}

fn lex_word(chars: &mut std::iter::Peekable<std::str::Chars>) -> String {
    let mut word = String::new();
    while let Some(&c) = chars.peek() {
        if c.is_alphanumeric() || c == '-' || c == '_' || c == '.' || c == ':' {
            word.push(c);
            chars.next();
        } else {
            break;
        }
    }
    word
}

fn lex_string(
    chars: &mut std::iter::Peekable<std::str::Chars>,
    line_no: usize,
) -> Result<String, DslError> {
    chars.next(); // consume opening quote
    let mut s = String::new();
    loop {
        match chars.next() {
            None => return err(line_no, "unterminated string (missing closing '\"')"),
            Some('"') => return Ok(s),
            Some('\\') => match chars.next() {
                Some('"') => s.push('"'),
                Some('\\') => s.push('\\'),
                Some('n') => s.push('\n'),
                Some('t') => s.push('\t'),
                other => {
                    return err(
                        line_no,
                        format!("unknown escape '\\{}'", other.map_or(String::new(), |c| c.to_string())),
                    )
                }
            },
            Some(c) => s.push(c),
        }
    }
}

fn lex_value(
    chars: &mut std::iter::Peekable<std::str::Chars>,
    line_no: usize,
) -> Result<Tok, DslError> {
    match chars.peek() {
        Some('"') => Ok(Tok::Quoted(lex_string(chars, line_no)?)),
        Some('$') => {
            chars.next();
            let path = lex_word(chars);
            if path.is_empty() {
                return err(line_no, "'$' must be followed by a token path (e.g. $color.accent)");
            }
            Ok(Tok::TokenRef(path))
        }
        Some(&c) if c.is_ascii_digit() || c == '-' => {
            let word = lex_word(chars);
            word.parse::<f64>().map(Tok::Number).or_else(|_| {
                err(line_no, format!("'{word}' is not a number"))
            })
        }
        // `#name` as a prop VALUE resolves to the node id nd:name (M5.S6 —
        // linkTo=#artboard; the DSL anchor convention for id-valued props).
        Some('#') => {
            chars.next();
            let name = lex_word(chars);
            if name.is_empty() {
                return err(line_no, "'#' must be followed by a node name (e.g. #artboard)");
            }
            Ok(Tok::Word(format!("nd:{name}")))
        }
        Some(_) => {
            let word = lex_word(chars);
            if word.is_empty() {
                return err(line_no, "missing value after '='");
            }
            Ok(Tok::Word(word))
        }
        None => err(line_no, "missing value after '='"),
    }
}

fn value_of(tok: Tok, line_no: usize) -> Result<Value, DslError> {
    Ok(match tok {
        Tok::Quoted(s) => Value::Str(s),
        Tok::TokenRef(p) => Value::Token(p),
        Tok::Number(n) => Value::Num(n),
        Tok::Word(w) => match w.as_str() {
            "true" => Value::Bool(true),
            "false" => Value::Bool(false),
            _ => Value::Str(w),
        },
        _ => return err(line_no, "unsupported value form"),
    })
}

fn parse_kind(word: &str, line_no: usize) -> Result<RecordKind, DslError> {
    Ok(match word {
        "frame" => RecordKind::Frame,
        "text" => RecordKind::Text,
        "image" => RecordKind::Image,
        "shape" => RecordKind::Shape,
        "component" => RecordKind::Component,
        "embed" => RecordKind::Embed,
        "hole" => RecordKind::Hole,
        "table" => RecordKind::Table,
        "code" => RecordKind::Code,
        "chart" => RecordKind::Chart,
        "diagram" => RecordKind::Diagram,
        other => {
            return err(
                line_no,
                format!(
                    "unknown element '{other}' — elements are: frame, text, image, \
                     shape, component, embed, hole, table, code, chart, diagram"
                ),
            )
        }
    })
}

/// Parse a DSL fragment into an insert plan under `parent`. Depth-first,
/// document order; `#name` anchors become `nd:name` ids (duplicates within
/// the fragment are errors); anchorless elements let the engine mint.
pub fn parse_fragment(source: &str, parent: &Id) -> Result<Vec<CanvasOp>, DslError> {
    let (ops, tokens) = parse_fragment_full(source, parent)?;
    if !tokens.is_empty() {
        return err(
            1,
            "token statements need the document context — send them through \
             canvas_apply (they ride apply_dsl), not this ops-only entry",
        );
    }
    Ok(ops)
}

/// The full parse: element/edit ops AND token statements (M4.S4).
pub fn parse_fragment_full(
    source: &str,
    parent: &Id,
) -> Result<(Vec<CanvasOp>, Vec<TokenStatement>), DslError> {
    let mut token_statements: Vec<TokenStatement> = Vec::new();
    let mut ops: Vec<CanvasOp> = Vec::new();
    // Parent stack: (id-or-placeholder, line). Anchorless containers cannot
    // be parents (children need an addressable parent id) — teaching error.
    let mut stack: Vec<Id> = vec![parent.clone()];
    let mut seen_anchors: Vec<String> = Vec::new();

    let lines: Vec<&str> = source.lines().collect();
    let mut idx = 0;
    while let Some(raw_line) = lines.get(idx).copied() {
        let line_no = idx + 1;
        idx += 1;
        let toks = lex_line(raw_line, line_no)?;
        if toks.is_empty() {
            continue;
        }
        // A bare `}` closes the current container.
        if toks == vec![Tok::Close] {
            if stack.len() == 1 {
                return err(line_no, "unmatched '}'");
            }
            stack.pop();
            continue;
        }

        let mut iter = toks.into_iter().peekable();
        let head = match iter.next() {
            Some(Tok::Word(w)) => w,
            other => {
                return err(
                    line_no,
                    format!("expected an element or statement at line start, got {other:?}"),
                )
            }
        };

        // Edit statements (set/unset/move/remove) — id-anchored, single line.
        if matches!(head.as_str(), "set" | "unset" | "move" | "remove") {
            ops.push(parse_statement(&head, &mut iter, line_no)?);
            if iter.next().is_some() {
                return err(line_no, format!("trailing input after '{head}' statement"));
            }
            continue;
        }

        // `token set|alias|rename …` — document-setting statements (M4.S4).
        if head == "token" {
            let statement = parse_token_statement(&mut iter, line_no)?;
            if iter.next().is_some() {
                return err(line_no, "trailing input after token statement");
            }
            token_statements.push(statement);
            continue;
        }

        // `each data="[…]" [where=field] {` — AUTHOR-TIME repetition
        // (M4.S8, the B3 tier): the block's lines expand PER DATUM at parse
        // time with {{i}} (index) and {{item.<field>}} substituted; `where`
        // filters on a truthy field. The doc stores the EXPANDED records —
        // no runtime JS (02 §7).
        if head == "each" {
            let mut data_json: Option<String> = None;
            let mut where_field: Option<String> = None;
            let mut opens = false;
            for tok in iter.by_ref() {
                match tok {
                    Tok::Prop(name, value) => match name.as_str() {
                        "data" => {
                            if let Tok::Quoted(s) = *value {
                                data_json = Some(s);
                            } else {
                                return err(line_no, "each: data must be a quoted JSON array");
                            }
                        }
                        "where" => {
                            if let Tok::Word(w) = *value {
                                where_field = Some(w);
                            } else {
                                return err(line_no, "each: where takes a field name");
                            }
                        }
                        other => return err(line_no, format!("each: unknown arg '{other}'")),
                    },
                    Tok::Open => {
                        opens = true;
                        break;
                    }
                    other => return err(line_no, format!("unexpected {other:?} in each")),
                }
            }
            if !opens {
                return err(line_no, "each needs a '{' block");
            }
            let Some(json) = data_json else {
                return err(line_no, "each needs data=\"[…]\" (a JSON array of objects)");
            };
            // Scan the block (brace balance over following lines).
            let mut depth = 1usize;
            let mut end = idx;
            while let Some(scan_line) = lines.get(end) {
                let trimmed = scan_line.trim();
                if trimmed.ends_with('{') {
                    depth += 1;
                } else if trimmed == "}" {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                end += 1;
            }
            if depth != 0 {
                return err(line_no, "each block is missing its closing '}'");
            }
            let template = lines
                .get(idx..end)
                .unwrap_or_default()
                .join("\n");
            idx = end + 1; // consume the block + its close

            let data = parse_each_data(&json)
                .ok_or_else(|| DslError {
                    line: line_no,
                    message: "each data must be a JSON array of flat objects \
                              (1..=500 items)"
                        .to_owned(),
                })?;
            let Some(current_parent) = stack.last().cloned() else {
                return err(line_no, "internal: empty parent stack");
            };
            for (i, datum) in data.iter().enumerate() {
                if let Some(field) = &where_field
                    && !datum_truthy(datum, field)
                {
                    continue;
                }
                let substituted = substitute(&template, i, datum);
                let (sub_ops, sub_tokens) =
                    parse_fragment_full(&substituted, &current_parent).map_err(|e| DslError {
                        line: line_no,
                        message: format!(
                            "each item {i}: line {} of the template: {}",
                            e.line, e.message
                        ),
                    })?;
                if !sub_tokens.is_empty() {
                    return err(line_no, "token statements cannot live inside each blocks");
                }
                ops.extend(sub_ops);
            }
            continue;
        }

        // `component #name {` — a DEFINITION block (M4.S3): children parse
        // under the cmp:name root; instances reference it via `use`.
        if head == "component" {
            let Some(Tok::Anchor(name)) = iter.next() else {
                return err(line_no, "component needs a '#name' anchor");
            };
            let Some(Tok::Open) = iter.next() else {
                return err(line_no, "component definitions need a '{' block");
            };
            if iter.next().is_some() {
                return err(line_no, "'{' must end the component line");
            }
            let full = format!("cmp:{name}");
            let def_id = Id::parse(&full)
                .map_err(|e| DslError { line: line_no, message: format!("bad component name: {e:?}") })?;
            ops.push(CanvasOp::DefineComponent { id: def_id.clone() });
            stack.push(def_id);
            continue;
        }

        // `use #def #inst [props] [override text #anchor "…"]…` — an
        // INSTANCE (single line; sugar over Insert{kind: component}).
        if head == "use" {
            let Some(Tok::Anchor(def_name)) = iter.next() else {
                return err(line_no, "use needs the definition's '#name' first");
            };
            let Some(Tok::Anchor(inst_name)) = iter.next() else {
                return err(line_no, "use needs an instance '#name' second");
            };
            if seen_anchors.contains(&inst_name) {
                return err(line_no, format!("duplicate anchor '#{inst_name}' in this fragment"));
            }
            seen_anchors.push(inst_name.clone());
            let inst_id = Id::parse(&format!("nd:{inst_name}"))
                .map_err(|e| DslError { line: line_no, message: format!("bad anchor: {e:?}") })?;
            let mut props: Vec<(PropKey, Value)> = Vec::new();
            let Some(ref_key) = PropKey::by_name("ref") else {
                return err(line_no, "internal: no ref key");
            };
            props.push((ref_key, Value::Str(format!("cmp:{def_name}"))));
            let mut overrides: Vec<(String, String)> = Vec::new();
            while let Some(tok) = iter.next() {
                match tok {
                    Tok::Prop(name, value) => {
                        let Some(k) = PropKey::by_name(&name) else {
                            return err(line_no, format!("unknown prop '{name}'"));
                        };
                        props.push((k, value_of(*value, line_no)?));
                    }
                    Tok::Word(w) if w == "override" => {
                        // `override text #anchor "replacement"`
                        match (iter.next(), iter.next(), iter.next()) {
                            (
                                Some(Tok::Word(kind)),
                                Some(Tok::Anchor(anchor)),
                                Some(Tok::Quoted(text)),
                            ) if kind == "text" => {
                                overrides.push((format!("nd:{anchor}"), text));
                            }
                            _ => {
                                return err(
                                    line_no,
                                    "override syntax: override text #anchor \"replacement\"",
                                )
                            }
                        }
                    }
                    other => return err(line_no, format!("unexpected {other:?} in use")),
                }
            }
            if !overrides.is_empty() {
                let Some(ok) = PropKey::by_name("overrides") else {
                    return err(line_no, "internal: no overrides key");
                };
                let mut json = String::from("{");
                for (i, (anchor, text)) in overrides.iter().enumerate() {
                    if i > 0 {
                        json.push(',');
                    }
                    json.push('"');
                    json.push_str(anchor);
                    json.push_str("\":\"");
                    for ch in text.chars() {
                        match ch {
                            '"' => json.push_str("\\\""),
                            '\\' => json.push_str("\\\\"),
                            '\n' => json.push_str("\\n"),
                            c => json.push(c),
                        }
                    }
                    json.push('"');
                }
                json.push('}');
                props.push((ok, Value::Str(json)));
            }
            let Some(current_parent) = stack.last().cloned() else {
                return err(line_no, "internal: empty parent stack");
            };
            ops.push(CanvasOp::Insert {
                id: Some(inst_id),
                kind: RecordKind::Component,
                parent: current_parent,
                pos: Position::Last,
                props,
            });
            continue;
        }

        let kind = parse_kind(&head, line_no)?;

        // Optional #anchor.
        let mut id: Option<Id> = None;
        if matches!(iter.peek(), Some(Tok::Anchor(_))) {
            let Some(Tok::Anchor(name)) = iter.next() else {
                return err(line_no, "internal: anchor peek/next mismatch");
            };
            if seen_anchors.contains(&name) {
                return err(line_no, format!("duplicate anchor '#{name}' in this fragment"));
            }
            seen_anchors.push(name.clone());
            let full = format!("nd:{name}");
            match Id::parse(&full) {
                Ok(parsed) => id = Some(parsed),
                Err(e) => return err(line_no, format!("bad anchor '#{name}': {e:?}")),
            }
        }

        // Optional text sugar + props.
        let mut props: Vec<(PropKey, Value)> = Vec::new();
        let mut opens_children = false;
        while let Some(tok) = iter.next() {
            match tok {
                Tok::Quoted(s) => {
                    let Some(text_key) = PropKey::by_name("text") else {
                        return err(line_no, "internal: no text key");
                    };
                    if props.iter().any(|(k, _)| *k == text_key) {
                        return err(line_no, "text given twice (sugar + text=)");
                    }
                    props.push((text_key, Value::Str(s)));
                }
                Tok::Prop(name, value) => {
                    let Some(key) = PropKey::by_name(&name) else {
                        let allowed = registry::allowed_names(kind).join(", ");
                        return err(
                            line_no,
                            format!("unknown prop '{name}' — props for {head}: {allowed}"),
                        );
                    };
                    if registry::check_allowed(kind, key).is_err() {
                        let allowed = registry::allowed_names(kind).join(", ");
                        return err(
                            line_no,
                            format!("'{name}' is not allowed on {head} — props: {allowed}"),
                        );
                    }
                    props.push((key, value_of(*value, line_no)?));
                }
                Tok::Open => {
                    if iter.peek().is_some() {
                        return err(line_no, "'{' must end its line");
                    }
                    opens_children = true;
                }
                Tok::Close => return err(line_no, "'}' must be alone on its line"),
                other => {
                    return err(line_no, format!("unexpected {other:?} in element line"))
                }
            }
        }

        let Some(current_parent) = stack.last().cloned() else {
            return err(line_no, "internal: empty parent stack");
        };

        if opens_children {
            if !kind.can_parent() {
                return err(line_no, format!("'{head}' cannot contain children"));
            }
            let Some(own_id) = &id else {
                return err(
                    line_no,
                    "a container with children needs a '#name' anchor (children must \
                     address their parent)",
                );
            };
            stack.push(own_id.clone());
        }

        ops.push(CanvasOp::Insert {
            id,
            kind,
            parent: current_parent,
            pos: Position::Last,
            props,
        });
        // NOTE: ops for children reference the pushed parent — order is
        // depth-first by construction, so inserts always find their parent.
    }

    if stack.len() != 1 {
        return err(source.lines().count(), "unclosed '{' (missing '}')");
    }
    Ok((ops, token_statements))
}

/// each data: a JSON array (1..=500) of FLAT objects.
fn parse_each_data(json: &str) -> Option<Vec<Vec<(String, String)>>> {
    let crate::json::JsonValue::Array(items) = crate::json::parse(json).ok()? else {
        return None;
    };
    if items.is_empty() || items.len() > 500 {
        return None;
    }
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let crate::json::JsonValue::Object(pairs) = item else { return None };
        let mut fields = Vec::with_capacity(pairs.len());
        for (k, v) in pairs {
            let display = match v {
                crate::json::JsonValue::Str(s) => s,
                crate::json::JsonValue::Int(n) => n.to_string(),
                crate::json::JsonValue::Float(f) => f.to_string(),
                crate::json::JsonValue::Bool(b) => b.to_string(),
                _ => return None, // flat objects only
            };
            fields.push((k, display));
        }
        out.push(fields);
    }
    Some(out)
}

fn datum_truthy(datum: &[(String, String)], field: &str) -> bool {
    datum
        .iter()
        .find(|(k, _)| k == field)
        .is_some_and(|(_, v)| !v.is_empty() && v != "false" && v != "0")
}

/// Substitute `{{i}}` and `{{item.<field>}}` in the template text (raw text
/// pass BEFORE lexing, so quoted strings substitute naturally).
fn substitute(template: &str, index: usize, datum: &[(String, String)]) -> String {
    let mut out = template.replace("{{i}}", &index.to_string());
    for (field, value) in datum {
        out = out.replace(&format!("{{{{item.{field}}}}}"), value);
    }
    out
}

fn parse_token_statement(iter: &mut TokIter, line_no: usize) -> Result<TokenStatement, DslError> {
    let verb = match iter.next() {
        Some(Tok::Word(w)) => w,
        other => return err(line_no, format!("token needs set/alias/rename, got {other:?}")),
    };
    let word = |iter: &mut TokIter, what: &str| -> Result<String, DslError> {
        match iter.next() {
            Some(Tok::Word(w)) => Ok(w),
            Some(Tok::Quoted(s)) => Ok(s),
            // CSS hex colors lex as anchors (#123456) — re-prefix them.
            Some(Tok::Anchor(a)) => Ok(format!("#{a}")),
            other => err(line_no, format!("token {verb}: expected {what}, got {other:?}")),
        }
    };
    match verb.as_str() {
        "set" => {
            let path = word(iter, "a token path")?;
            let css = word(iter, "a css value (quote multi-word values)")?;
            Ok(TokenStatement::Set { path, css })
        }
        "alias" => Ok(TokenStatement::Alias {
            path: word(iter, "a token path")?,
            target: word(iter, "a target path")?,
        }),
        "rename" => Ok(TokenStatement::Rename {
            old: word(iter, "the old path")?,
            new: word(iter, "the new path")?,
        }),
        other => err(
            line_no,
            format!("unknown token verb '{other}' — token set|alias|rename"),
        ),
    }
}

type TokIter = std::iter::Peekable<std::vec::IntoIter<Tok>>;

fn need_anchor(iter: &mut TokIter, what: &str, line_no: usize) -> Result<Id, DslError> {
    match iter.next() {
        Some(Tok::Anchor(name)) => {
            let full = format!("nd:{name}");
            Id::parse(&full).map_or_else(
                |e| err(line_no, format!("bad anchor '#{name}': {e:?}")),
                Ok,
            )
        }
        other => err(line_no, format!("{what} needs a '#id' anchor, got {other:?}")),
    }
}

/// Parse one edit statement (`set`/`unset`/`move`/`remove`).
fn parse_statement(
    head: &str,
    iter: &mut TokIter,
    line_no: usize,
) -> Result<CanvasOp, DslError> {
    match head {
        "remove" => Ok(CanvasOp::Remove {
            id: need_anchor(iter, "remove", line_no)?,
        }),
        "set" => {
            let id = need_anchor(iter, "set", line_no)?;
            let mut set: Vec<(PropKey, Value)> = Vec::new();
            for tok in iter.by_ref() {
                match tok {
                    Tok::Prop(name, value) => {
                        let Some(key) = PropKey::by_name(&name) else {
                            return err(line_no, format!("unknown prop '{name}'"));
                        };
                        set.push((key, value_of(*value, line_no)?));
                    }
                    Tok::Quoted(s) => {
                        let Some(key) = PropKey::by_name("text") else {
                            return err(line_no, "internal: no text key");
                        };
                        set.push((key, Value::Str(s)));
                    }
                    other => return err(line_no, format!("unexpected {other:?} in set")),
                }
            }
            if set.is_empty() {
                return err(line_no, "set needs at least one prop=value");
            }
            Ok(CanvasOp::Update { id, set, unset: vec![] })
        }
        "unset" => {
            let id = need_anchor(iter, "unset", line_no)?;
            let mut unset: Vec<PropKey> = Vec::new();
            for tok in iter.by_ref() {
                match tok {
                    Tok::Word(name) => {
                        let Some(key) = PropKey::by_name(&name) else {
                            return err(line_no, format!("unknown prop '{name}'"));
                        };
                        unset.push(key);
                    }
                    other => return err(line_no, format!("unexpected {other:?} in unset")),
                }
            }
            if unset.is_empty() {
                return err(line_no, "unset needs at least one prop name");
            }
            Ok(CanvasOp::Update { id, set: vec![], unset })
        }
        "move" => {
            let id = need_anchor(iter, "move", line_no)?;
            match iter.next() {
                Some(Tok::Word(arrow)) if arrow == "->" || arrow == "to" => {}
                // `->` lexes as unexpected char; accept `to` as the word form.
                other => {
                    return err(
                        line_no,
                        format!("move syntax: move #id to #parent [first|before #x|after #x], got {other:?}"),
                    )
                }
            }
            let parent = need_anchor(iter, "move target", line_no)?;
            let pos = match iter.next() {
                None => Position::Last,
                Some(Tok::Word(w)) => match w.as_str() {
                    "first" => Position::First,
                    "last" => Position::Last,
                    "before" => Position::Before(need_anchor(iter, "before", line_no)?),
                    "after" => Position::After(need_anchor(iter, "after", line_no)?),
                    other => return err(line_no, format!("unknown position '{other}'")),
                },
                other => return err(line_no, format!("unexpected {other:?} in move")),
            };
            Ok(CanvasOp::Move { id, parent, pos })
        }
        _ => err(line_no, "internal: unknown statement"),
    }
}

// MARK: - projection (render)

fn render_value(v: &Value, out: &mut String) {
    match v {
        Value::Str(s) => {
            out.push('"');
            for ch in s.chars() {
                match ch {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\t' => out.push_str("\\t"),
                    c => out.push(c),
                }
            }
            out.push('"');
        }
        Value::Num(n) => out.push_str(&format!("{n}")),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Token(p) => {
            out.push('$');
            out.push_str(p);
        }
    }
}

fn render_node(store: &super::store::Store, id: &Id, depth: usize, out: &mut String) {
    let Some(rec) = store.get(id) else { return };
    // Component instances project as `use` (M4.S3).
    if rec.kind == RecordKind::Component {
        render_use(store, id, rec, depth, out);
        return;
    }
    let Some(kind_word) = dsl_kind_word(rec.kind) else { return };
    for _ in 0..depth {
        out.push_str("  ");
    }
    out.push_str(kind_word);
    // Anchors render only for nd:-prefixed ids (the DSL's mintable space).
    if let Some(name) = id.as_str().strip_prefix("nd:") {
        out.push_str(" #");
        out.push_str(name);
    }
    let text_key = PropKey::by_name("text");
    // Text sugar first.
    if let Some(k) = text_key
        && let Some(Value::Str(s)) = rec.props.get(k)
    {
        out.push(' ');
        render_value(&Value::Str(s.clone()), out);
    }
    for (key, value) in rec.props.iter() {
        if text_key == Some(key) {
            continue; // already rendered as sugar
        }
        let Some(name) = key.name() else { continue };
        out.push(' ');
        out.push_str(name);
        out.push('=');
        render_value(value, out);
    }
    let kids = store.children(id);
    if kids.is_empty() {
        out.push('\n');
    } else {
        out.push_str(" {\n");
        for kid in kids {
            render_node(store, &kid, depth + 1, out);
        }
        for _ in 0..depth {
            out.push_str("  ");
        }
        out.push_str("}\n");
    }
}

fn dsl_kind_word(kind: RecordKind) -> Option<&'static str> {
    Some(match kind {
        RecordKind::Frame => "frame",
        RecordKind::Text => "text",
        RecordKind::Image => "image",
        RecordKind::Shape => "shape",
        RecordKind::Component => "component",
        RecordKind::Embed => "embed",
        RecordKind::Hole => "hole",
        RecordKind::Table => "table",
        RecordKind::Code => "code",
        RecordKind::Chart => "chart",
        RecordKind::Diagram => "diagram",
        RecordKind::Page => return None, // pages are containers of fragments, not elements
    })
}

/// Project ONE node (and its subtree) into canonical DSL — the `#anchor`
/// slice `canvas_read` serves (M2.S4).
#[must_use]
pub fn render_subtree(store: &super::store::Store, id: &Id) -> String {
    let mut out = String::new();
    render_node(store, id, 0, &mut out);
    out
}

fn render_use(
    store: &super::store::Store,
    id: &Id,
    rec: &super::store::Record,
    depth: usize,
    out: &mut String,
) {
    let _ = store;
    for _ in 0..depth {
        out.push_str("  ");
    }
    out.push_str("use");
    let ref_key = PropKey::by_name("ref");
    let ov_key = PropKey::by_name("overrides");
    if let Some(Value::Str(target)) = ref_key.and_then(|k| rec.props.get(k)) {
        out.push_str(" #");
        out.push_str(target.strip_prefix("cmp:").unwrap_or(target));
    }
    if let Some(name) = id.as_str().strip_prefix("nd:") {
        out.push_str(" #");
        out.push_str(name);
    }
    for (key, value) in rec.props.iter() {
        if ref_key == Some(key) || ov_key == Some(key) {
            continue;
        }
        let Some(name) = key.name() else { continue };
        out.push(' ');
        out.push_str(name);
        out.push('=');
        render_value(value, out);
    }
    if let Some(Value::Str(json)) = ov_key.and_then(|k| rec.props.get(k))
        && let Ok(crate::json::JsonValue::Object(pairs)) = crate::json::parse(json)
    {
        let mut sorted = pairs;
        sorted.sort_by(|a, b| a.0.cmp(&b.0));
        for (anchor, text) in sorted {
            if let crate::json::JsonValue::Str(s) = text {
                out.push_str(" override text #");
                out.push_str(anchor.strip_prefix("nd:").unwrap_or(&anchor));
                out.push(' ');
                render_value(&Value::Str(s), out);
            }
        }
    }
    out.push('\n');
}

/// Project every cmp:* DEFINITION as a `component #name { … }` block
/// (id-sorted; the doc-level projection emits these before page content so
/// `use` lines always reference an already-defined component on re-parse).
#[must_use]
pub fn render_definitions(store: &super::store::Store) -> String {
    let mut out = String::new();
    let mut roots: Vec<&Id> = store
        .ids()
        .filter(|i| i.as_str().starts_with("cmp:"))
        .collect();
    roots.sort();
    for def in roots {
        out.push_str("component #");
        out.push_str(def.as_str().strip_prefix("cmp:").unwrap_or(def.as_str()));
        out.push_str(" {\n");
        for kid in store.children(def) {
            render_node(store, &kid, 1, &mut out);
        }
        out.push_str("}\n");
    }
    out
}

/// Project the children of `parent` into canonical DSL. Round-trip law:
/// applying `parse_fragment(render(store, parent), parent)` to an empty
/// parent rebuilds the identical subtree (anchors preserved for nd: ids).
#[must_use]
pub fn render(store: &super::store::Store, parent: &Id) -> String {
    let mut out = String::new();
    for kid in store.children(parent) {
        render_node(store, &kid, 0, &mut out);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::ops::DocState;
    use crate::canvas::store::Store;

    fn page() -> (DocState, Id) {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store
            .insert_root(pg.clone(), RecordKind::Page)
            .expect("root");
        (d, pg)
    }

    const HERO: &str = r#"
frame #hero fill=$color.surface padding=$space.lg gap=8 {
  text #title "Hello \"Canvas\"" font=$font.h1
  image #pic src="shot.png" fit=cover opacity=0.9
  // a comment line
  frame #row direction=row {
    text "anchorless child"
  }
}
"#;

    #[test]
    fn fragment_parses_applies_and_builds_the_subtree() {
        let (mut d, pg) = page();
        let ops = parse_fragment(HERO, &pg).expect("parse");
        assert_eq!(ops.len(), 5);
        let applied = d.apply(0, &ops).expect("apply through the real fence");
        assert_eq!(applied.minted.len(), 1, "the anchorless text minted");
        // Structure: hero under page; title/pic/row under hero.
        let hero = Id::parse("nd:hero").expect("id");
        let kids = d.store.children(&hero);
        assert_eq!(kids.len(), 3);
        assert_eq!(kids[0].as_str(), "nd:title");
        // Values landed typed.
        let title = d.store.get(&Id::parse("nd:title").expect("id")).expect("rec");
        let text = PropKey::by_name("text").and_then(|k| title.props.get(k)).cloned();
        assert_eq!(text, Some(Value::Str("Hello \"Canvas\"".to_owned())));
        let hero_rec = d.store.get(&hero).expect("rec");
        let fill = PropKey::by_name("fill").and_then(|k| hero_rec.props.get(k)).cloned();
        assert_eq!(fill, Some(Value::Token("color.surface".to_owned())));
        let pic = d.store.get(&Id::parse("nd:pic").expect("id")).expect("rec");
        let op = PropKey::by_name("opacity").and_then(|k| pic.props.get(k)).cloned();
        assert_eq!(op, Some(Value::Num(0.9)));
        let fit = PropKey::by_name("fit").and_then(|k| pic.props.get(k)).cloned();
        assert_eq!(fit, Some(Value::Str("cover".to_owned())), "bare word = string");
    }

    #[test]
    fn teaching_errors_name_the_legal_vocabulary() {
        let (_, pg) = page();
        let e = parse_fragment("wormhole #x", &pg).expect_err("kind");
        assert!(e.message.contains("frame, text, image"), "lists elements: {e:?}");
        let e = parse_fragment("text #t bling=3", &pg).expect_err("prop");
        assert!(e.message.contains("props for text"), "names the kind: {e:?}");
        assert!(e.message.contains("text"), "lists legal props: {e:?}");
        let e = parse_fragment("frame #f src=\"x\"", &pg).expect_err("wrong kind");
        assert!(e.message.contains("not allowed on frame"), "{e:?}");
        assert_eq!(e.line, 1);
    }

    #[test]
    fn structural_errors_are_line_anchored() {
        let (_, pg) = page();
        let e = parse_fragment("frame #a {\n  text \"x\"\n", &pg).expect_err("unclosed");
        assert!(e.message.contains("unclosed"), "{e:?}");
        let e = parse_fragment("}", &pg).expect_err("unmatched");
        assert_eq!(e.line, 1);
        let e = parse_fragment("frame #a\nframe #a", &pg).expect_err("dup");
        assert_eq!(e.line, 2);
        assert!(e.message.contains("duplicate anchor"), "{e:?}");
        let e = parse_fragment("frame {\n  text \"x\"\n}", &pg).expect_err("anchorless parent");
        assert!(e.message.contains("needs a '#name' anchor"), "{e:?}");
        let e = parse_fragment("text #t \"a\" \"b\"", &pg).expect_err("double text");
        assert!(e.message.contains("text given twice"), "{e:?}");
        let e = parse_fragment("text #t text=", &pg).expect_err("missing value");
        assert!(e.message.contains("missing value"), "{e:?}");
        let e = parse_fragment("text #t \"unterminated", &pg).expect_err("string");
        assert!(e.message.contains("unterminated"), "{e:?}");
    }

    #[test]
    fn the_dsl_never_bypasses_the_fence() {
        // The parser catches vocabulary; the FENCE still owns semantics —
        // e.g. a value-range violation flows through apply and is rejected
        // there, proving the DSL is a front end, not a side door.
        let (mut d, pg) = page();
        let ops = parse_fragment("shape #s opacity=7", &pg).expect("parses (range is semantic)");
        let e = d.apply(0, &ops).expect_err("fence rejects");
        let _ = e; // typed ApplyError::Fence — pinned by ops tests
        assert!(d.store.get(&Id::parse("nd:s").expect("id")).is_none());
    }

    #[test]
    fn edit_statements_parse_into_the_op_vocabulary() {
        let (mut d, pg) = page();
        d.apply(0, &parse_fragment(HERO, &pg).expect("seed")).expect("seed apply");
        let edits = r#"
set #title "New copy" color=$color.accent
unset #title font
move #pic to #row first
remove #hero
"#;
        let ops = parse_fragment(edits, &pg).expect("parse edits");
        assert_eq!(ops.len(), 4);
        assert!(matches!(&ops[0], CanvasOp::Update { set, unset, .. }
            if set.len() == 2 && unset.is_empty()));
        assert!(matches!(&ops[1], CanvasOp::Update { set, unset, .. }
            if set.is_empty() && unset.len() == 1));
        assert!(matches!(&ops[2], CanvasOp::Move { pos: Position::First, .. }));
        assert!(matches!(&ops[3], CanvasOp::Remove { .. }));
        // They apply for real (move #pic under #row, then remove the tree).
        let rev = d.rev();
        d.apply(rev, &ops[..3]).expect("edits apply");
        let row_kids = d.store.children(&Id::parse("nd:row").expect("id"));
        assert_eq!(row_kids.first().map(|k| k.as_str().to_owned()), Some("nd:pic".to_owned()));
        // Statement errors teach.
        let e = parse_fragment("set #title", &pg).expect_err("empty set");
        assert!(e.message.contains("at least one"), "{e:?}");
        let e = parse_fragment("move #a #b", &pg).expect_err("no arrow");
        assert!(e.message.contains("move syntax"), "{e:?}");
    }

    #[test]
fn render_round_trips_over_the_full_m5_m6_prop_surface() {
        // A deck/grid doc exercising every M5/M6 prop kind + a bool: role,
        // step (num), morphId (str), linkTo (nd:-id), columns (num), a table
        // with headers (bool) + data (str), a token ref. The round-trip law
        // must hold over ALL of them, not just components/overrides.
        let src_dsl = "frame #slide-0 role=slide columns=2 gap=16 {\n\
            \x20 text #title \"Q3\" morphId=logo step=1 color=$color.accent\n\
            \x20 text #nav \"Jump\" linkTo=#slide-0\n\
            \x20 table #grid headers=true data=\"[[\\\"a\\\",\\\"b\\\"]]\"\n\
            }";
        let (mut d, pg) = page();
        d.apply(0, &parse_fragment(src_dsl, &pg).expect("seed")).expect("apply");
        let projected = render(&d.store, &pg);
        // Every M5/M6 prop must survive to the projection.
        assert!(projected.contains("role=\"slide\"") || projected.contains("role=slide"), "{projected}");
        assert!(projected.contains("columns=2"), "grid columns: {projected}");
        assert!(projected.contains("step=1"), "reveal step");
        assert!(projected.contains("morphId=logo") || projected.contains("morphId=\"logo\""), "morph tag");
        assert!(projected.contains("linkTo=nd:slide-0") || projected.contains("linkTo=\"nd:slide-0\""), "link");
        assert!(projected.contains("headers=true"), "bool prop round-trips as bool, not string");
        // The LAW: reparse the projection → reproject → byte-identical.
        let (mut d2, pg2) = page();
        d2.apply(0, &parse_fragment(&projected, &pg2).expect("reparse")).expect("reapply");
        assert_eq!(render(&d2.store, &pg2), projected,
                   "parse(render(doc)) == doc over the full M5/M6 prop surface");
    }

    #[test]
    fn render_round_trips_parse_render_eq_doc() {
        let (mut d, pg) = page();
        d.apply(0, &parse_fragment(HERO, &pg).expect("seed")).expect("seed apply");
        let projected = render(&d.store, &pg);
        assert!(projected.contains("frame #hero"), "{projected}");
        assert!(projected.contains("$color.surface"), "token refs render as $path");
        // Rebuild from the projection on a fresh doc: subtree-identical
        // modulo the one engine-minted id (anchorless in HERO), which renders
        // with its minted anchor and therefore round-trips stably from here.
        let (mut d2, pg2) = page();
        let ops = parse_fragment(&projected, &pg2).expect("reparse");
        d2.apply(0, &ops).expect("reapply");
        let reprojected = render(&d2.store, &pg2);
        assert_eq!(reprojected, projected, "parse(render(doc)) == doc (canonical form)");
        // And the structures agree.
        assert_eq!(
            d2.store.children(&Id::parse("nd:hero").expect("id")).len(),
            d.store.children(&Id::parse("nd:hero").expect("id")).len()
        );
    }

    // MARK: M4.S3 — component forms

    const KIT: &str = r#"
component #card {
  text #card-title "Default title" font=$font.h2
  text #card-body "Default body"
}
frame #page-col gap=8 {
  use #card #hero fill=$color.surface override text #card-title "Hero title"
  use #card #side
}
"#;

    #[test]
    fn component_and_use_parse_apply_and_expand() {
        let (mut d, pg) = page();
        let ops = parse_fragment(KIT, &pg).expect("parse");
        d.apply(0, &ops).expect("apply");
        // The definition exists as a root; instances expand with overrides.
        let tokens = crate::canvas::tokens::TokenStore::default_theme();
        let html = crate::canvas::lower::lower_page(&d.store, &tokens, &pg);
        assert_eq!(html.matches(">Hero title<").count(), 1, "{html}");
        assert_eq!(html.matches(">Default title<").count(), 1);
        assert_eq!(html.matches(">Default body<").count(), 2);
        assert!(html.contains("background:var(--cv-color-surface)"));
    }

    #[test]
    fn component_round_trip_parse_render_eq_doc() {
        let (mut d, pg) = page();
        d.apply(0, &parse_fragment(KIT, &pg).expect("parse")).expect("apply");
        // Doc-level projection: definitions first, then content.
        let projected = {
            let mut out = render_definitions(&d.store);
            out.push_str(&render(&d.store, &pg));
            out
        };
        assert!(projected.starts_with("component #card {"), "{projected}");
        assert!(projected.contains("use #card #hero"));
        assert!(projected.contains("override text #card-title \"Hero title\""));
        // Re-parse on a fresh doc → identical projection (canonical form).
        let (mut d2, pg2) = page();
        d2.apply(0, &parse_fragment(&projected, &pg2).expect("reparse")).expect("reapply");
        let reprojected = {
            let mut out = render_definitions(&d2.store);
            out.push_str(&render(&d2.store, &pg2));
            out
        };
        assert_eq!(reprojected, projected, "parse(render(doc)) == doc over components");
    }

    #[test]
    fn component_teaching_errors() {
        let (_, pg) = page();
        let e = parse_fragment("component card {", &pg).expect_err("anchor");
        assert!(e.message.contains("'#name'"), "{e:?}");
        let e = parse_fragment("component #card", &pg).expect_err("block");
        assert!(e.message.contains("'{' block"), "{e:?}");
        let e = parse_fragment("use #card", &pg).expect_err("inst");
        assert!(e.message.contains("instance '#name'"), "{e:?}");
        let e = parse_fragment("use #card #a override text #t", &pg).expect_err("ov");
        assert!(e.message.contains("override syntax"), "{e:?}");
    }

    // MARK: M4.S8 — each blocks (author-time repetition)

    #[test]
    fn each_expands_per_datum_with_index_and_field_substitution() {
        let (mut d, pg) = page();
        let src_dsl = "frame #list gap=4 {\n\
            each data=\"[{\\\"name\\\":\\\"Ada\\\",\\\"role\\\":\\\"eng\\\"},{\\\"name\\\":\\\"Lin\\\",\\\"role\\\":\\\"design\\\"}]\" {\n\
              text #person-{{i}} \"{{item.name}} — {{item.role}}\"\n\
            }\n\
          }";
        let ops = parse_fragment(src_dsl, &pg).expect("parse");
        d.apply(0, &ops).expect("apply");
        let tokens = crate::canvas::tokens::TokenStore::default_theme();
        let html = crate::canvas::lower::lower_page(&d.store, &tokens, &pg);
        assert!(html.contains(">Ada — eng<"), "{html}");
        assert!(html.contains(">Lin — design<"));
        assert!(html.contains("data-cv-id=\"nd:person-0\""));
        assert!(html.contains("data-cv-id=\"nd:person-1\""));
        // The doc stores EXPANDED records (author-time, no runtime JS).
        let list_id = Id::parse("nd:list").expect("id");
        assert_eq!(d.store.children(&list_id).len(), 2);
    }

    #[test]
    fn each_where_filters_falsy_and_errors_teach() {
        let (mut d, pg) = page();
        let src_dsl = "each data=\"[{\\\"n\\\":\\\"keep\\\",\\\"ok\\\":true},{\\\"n\\\":\\\"drop\\\",\\\"ok\\\":false}]\" where=ok {\n\
          text #kept-{{i}} \"{{item.n}}\"\n\
        }";
        let ops = parse_fragment(src_dsl, &pg).expect("parse");
        d.apply(0, &ops).expect("apply");
        assert_eq!(ops.len(), 1, "the falsy item filtered out");
        // Teaching errors.
        let e = parse_fragment("each {\n}", &pg).expect_err("no data");
        assert!(e.message.contains("needs data"), "{e:?}");
        let e = parse_fragment("each data=\"nope\" {\n}", &pg).expect_err("bad data");
        assert!(e.message.contains("JSON array of flat objects"), "{e:?}");
        let e = parse_fragment("each data=\"[{}]\"", &pg).expect_err("no block");
        assert!(e.message.contains("'{' block"), "{e:?}");
        // Template errors carry BOTH the each line and the template line.
        let bad_template = "each data=\"[{\\\"x\\\":1}]\" {\n  wormhole #w\n}";
        let e = parse_fragment(bad_template, &pg).expect_err("template");
        assert!(e.message.contains("each item 0"), "{e:?}");
        assert!(e.message.contains("unknown element"), "{e:?}");
    }

    #[test]
    fn store_is_untouched_by_parse_alone() {
        let (d, pg) = page();
        let before = d.store.fingerprint();
        let _ = parse_fragment(HERO, &pg).expect("parse");
        assert_eq!(d.store.fingerprint(), before, "parsing is pure");
        let _ = Store::new(); // silence unused-import lint paths in cfg(test)
    }

    // MARK: hardening — DSL parser totality-fuzz (TSK-1402; the TSK-584 lane)

    /// The DSL parser is TOTAL: no arbitrary input panics; every result is
    /// either Ok(ops, tokens) or a typed DslError. Byte-storms + structure-
    /// aware corruptions of a rich valid fragment (every construct the
    /// M1-M6 grammar grew). Deterministic xorshift64* — no rand, no clock.
    #[test]
    fn dsl_parser_is_total_over_byte_storms_and_corruptions() {
        let mut state: u64 = 0xD1B5_4A32_D192_ED03;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        // A valid fragment exercising every construct.
        let valid = "token set base.blue #1a6feb\n            component #card {\n  text #card-t \"T\" color=$color.accent\n}\n            frame #slide role=slide {\n            \x20 text #a \"hi\" step=1 morphId=logo linkTo=#slide\n            \x20 use #card #c1 override text #card-t \"O\"\n            \x20 each data=\"[{\\\"n\\\":\\\"x\\\"}]\" {\n    text #e-{{i}} \"{{item.n}}\"\n  }\n}";
        let pg = Id::page(1);

        for round in 0..2000usize {
            let source: String = if round % 3 == 0 {
                // Pure byte storm (printable-ish + structural chars).
                let len = usize::try_from(next() % 120).unwrap_or(0);
                (0..len)
                    .map(|_| {
                        let pool = b"{}#$=\" \nabc012.-_[]/";
                        pool[usize::try_from(next() % pool.len() as u64).unwrap_or(0)] as char
                    })
                    .collect()
            } else if round % 3 == 1 {
                // Corrupt the valid fragment: delete/duplicate a random line.
                let mut lines: Vec<&str> = valid.lines().collect();
                if !lines.is_empty() {
                    let i = usize::try_from(next() % lines.len() as u64).unwrap_or(0);
                    if next() & 1 == 0 { lines.remove(i); } else { lines.insert(i, lines[i]); }
                }
                lines.join("\n")
            } else {
                // Truncate the valid fragment at a random byte boundary (char-safe).
                let n = usize::try_from(next() % valid.chars().count() as u64).unwrap_or(0);
                valid.chars().take(n).collect()
            };

            // MUST NOT PANIC; MUST be Ok or a typed DslError (line >= 1).
            match parse_fragment_full(&source, &pg) {
                Ok((_ops, _tokens)) => {}
                Err(e) => assert!(e.line >= 1, "typed fault carries a line: {e:?}"),
            }
        }
    }

    /// apply_dsl over fuzzed fragments never panics — typed rejection frames
    /// only (the doc facade's fence + teaching path stays total end to end).
    #[test]
    fn apply_dsl_is_total_over_fuzzed_fragments() {
        let mut state: u64 = 0x2545_F491_4F6C_DD1D;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for round in 0..800usize {
            let len = usize::try_from(next() % 80).unwrap_or(0);
            let source: String = (0..len)
                .map(|_| {
                    let pool = b"{}#$=\" \nframe text tokenuse each step= .0-";
                    pool[usize::try_from(next() % pool.len() as u64).unwrap_or(0)] as char
                })
                .collect();
            let mut doc = crate::canvas::doc::CanvasDoc::new_empty();
            // Never panics; always returns a frame (response or rejection).
            let out = doc.apply_dsl(0, &source);
            assert!(out.is_ok() || out.is_err(), "apply_dsl returned: {round}");
        }
    }
}
