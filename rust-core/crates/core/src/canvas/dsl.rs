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
//! Projection read-back and id-anchored structural diff editing are the M2
//! surface (07 §5); S8 is the parser.

use super::ops::CanvasOp;
use super::props::{PropKey, Value};
use super::registry;
use super::store::{Id, Position, RecordKind};

/// Parse fault: line (1-based) + a teaching message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DslError {
    pub line: usize,
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
        other => {
            return err(
                line_no,
                format!(
                    "unknown element '{other}' — elements are: frame, text, image, \
                     shape, component, embed, hole"
                ),
            )
        }
    })
}

/// Parse a DSL fragment into an insert plan under `parent`. Depth-first,
/// document order; `#name` anchors become `nd:name` ids (duplicates within
/// the fragment are errors); anchorless elements let the engine mint.
pub fn parse_fragment(source: &str, parent: &Id) -> Result<Vec<CanvasOp>, DslError> {
    let mut ops: Vec<CanvasOp> = Vec::new();
    // Parent stack: (id-or-placeholder, line). Anchorless containers cannot
    // be parents (children need an addressable parent id) — teaching error.
    let mut stack: Vec<Id> = vec![parent.clone()];
    let mut seen_anchors: Vec<String> = Vec::new();

    for (idx, raw_line) in source.lines().enumerate() {
        let line_no = idx + 1;
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
                    format!("expected an element name at line start, got {other:?}"),
                )
            }
        };
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
    Ok(ops)
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
    fn store_is_untouched_by_parse_alone() {
        let (d, pg) = page();
        let before = d.store.fingerprint();
        let _ = parse_fragment(HERO, &pg).expect("parse");
        assert_eq!(d.store.fingerprint(), before, "parsing is pure");
        let _ = Store::new(); // silence unused-import lint paths in cfg(test)
    }
}
