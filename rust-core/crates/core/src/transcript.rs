//! Claude transcript (JSONL) projection (TSK-632) — the Rust twin of Swift's
//! `ClaudeLogParser` (+ the `SystemRecords` redaction barrier). Built on the
//! hand-rolled [`crate::json`] subset (owner decision 2026-06-11: no
//! `serde_json`).
//!
//! Semantics mirrored from the Swift parser, byte for byte where observable:
//! - tolerant framing: blank lines, lines over the line-byte cap, lines that
//!   fail JSON parse, and non-object documents are SKIPPED, never fatal (a
//!   torn tail line during live append must not fail the file);
//! - record projection: `uuid`/`id` fallback, `message.content` as a plain
//!   string (user/assistant) or a block array (`text` / `thinking` /
//!   `tool_use` / `tool_result`); a block array containing any non-object
//!   element yields NO events for that record (the Swift `as? [[String:Any]]`
//!   cast fails wholesale);
//! - resource caps (S6/S7): per-line byte cap and total-event ceiling;
//! - the TSK-245 redaction barrier: `signature` / `headers` values are
//!   replaced with `[REDACTED]` wherever they nest; an image block's
//!   oversized `source` (string or `{data: …}` form) collapses to a byte-count
//!   placeholder. Surfacing consumers MUST parse with `redacting: true`.
//!
//! Documented divergences from the Swift twin (A/B corpus avoids them):
//! - a record with neither `uuid` nor `id` gets a deterministic `line-<n>`
//!   id, not a random UUID (the core reads no randomness, by lint);
//! - `tool_use.input` preserves key order (Swift dictionaries do not);
//!   nested array/object values render through a compact serializer with
//!   `JSONSerialization`-style escaping, but multi-key nested OBJECT order
//!   is Swift-nondeterministic, so parity holds only per-key;
//! - timestamps normalize to epoch MILLISECONDS (the `withFractionalSeconds`
//!   precision Foundation parses) rather than a `Date`.

use crate::json::{self, JsonValue};
use serde::{Deserialize, Serialize};

/// Largest single JSONL line considered (Swift `maxLineBytes` default, 4 MB).
pub const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;
/// Hard ceiling on events from one parse (Swift `maxEvents` default).
pub const MAX_EVENTS: usize = 200_000;

/// Keys whose values are stripped wholesale (opaque secrets — extended-
/// thinking signature blobs, HTTP response headers / set-cookie carriers).
pub const REDACTED_KEYS: [&str; 2] = ["signature", "headers"];
/// Replacement token written in place of a redacted value.
pub const REDACTION_TOKEN: &str = "[REDACTED]";
/// Max retained `image.source` bytes before collapse to a placeholder.
pub const MAX_IMAGE_SOURCE_BYTES: usize = 256;

/// One projected transcript event.
#[derive(Debug, Clone, PartialEq)]
pub struct TranscriptEvent {
    /// Record `uuid`/`id`, the tool-use id for `ToolUse`, or `line-<n>`.
    pub id: String,
    /// Epoch milliseconds, when the record carries a parsable timestamp
    /// (RFC 3339 string with optional fractional seconds, or a number of
    /// epoch seconds).
    pub timestamp_ms: Option<i64>,
    /// The event payload.
    pub kind: EventKind,
}

/// The five event kinds the Swift `ClaudeEvent.Kind` enum projects.
#[derive(Debug, Clone, PartialEq)]
pub enum EventKind {
    /// A user text message.
    UserMessage {
        /// Message text.
        text: String,
    },
    /// An assistant text message.
    AssistantMessage {
        /// Message text.
        text: String,
    },
    /// An extended-thinking block.
    Thinking {
        /// Thinking text (the `thinking` field, falling back to `text`).
        text: String,
    },
    /// A tool invocation.
    ToolUse {
        /// Tool-use id (block `id`, falling back to the record id).
        id: String,
        /// Tool name (`"tool"` when absent).
        name: String,
        /// Stringified input map, key order preserved, duplicate keys
        /// last-wins.
        input: Vec<(String, String)>,
    },
    /// A tool result.
    ToolResult {
        /// The originating tool-use id (`""` when absent).
        tool_use_id: String,
        /// Result text (string content, or text blocks joined with `\n`).
        summary: String,
    },
}

/// Parse a JSONL transcript with the default caps. `redacting: true` routes
/// every decoded record through the TSK-245 barrier first — the mode every
/// surfacing consumer must use.
#[must_use]
pub fn parse(text: &str, redacting: bool) -> Vec<TranscriptEvent> {
    parse_with(text, redacting, MAX_LINE_BYTES, MAX_EVENTS)
}

/// [`parse`] with explicit caps (tests; pathological-input control).
#[must_use]
pub fn parse_with(
    text: &str,
    redacting: bool,
    max_line_bytes: usize,
    max_events: usize,
) -> Vec<TranscriptEvent> {
    let mut events: Vec<TranscriptEvent> = Vec::new();
    let mut candidate_lines = 0usize;
    for (idx, line) in text.split('\n').enumerate() {
        // Mirror the Swift scan: empty and over-cap lines are skipped, and
        // both the candidate-line count and the event count are bounded.
        if line.is_empty() || line.len() > max_line_bytes {
            continue;
        }
        candidate_lines = candidate_lines.saturating_add(1);
        if candidate_lines > max_events || events.len() >= max_events {
            break;
        }
        let Ok(doc) = json::parse(line) else { continue };
        let JsonValue::Object(_) = doc else { continue };
        let record = if redacting { redact(&doc) } else { doc };
        events.extend(parse_record(&record, idx.saturating_add(1)));
    }
    events.truncate(max_events);
    events
}

// ---------------------------------------------------------------------------
// Redaction barrier (TSK-245 / claude-dir.md §8.9)
// ---------------------------------------------------------------------------

/// Recursively redact a decoded record: structurally identical, secrets
/// removed. Key-name driven (not path-driven) so it survives the loose,
/// version-drifting record shapes.
#[must_use]
pub fn redact(value: &JsonValue) -> JsonValue {
    match value {
        JsonValue::Object(pairs) => {
            let is_image_block =
                value.get("type").and_then(JsonValue::as_str) == Some("image");
            JsonValue::Object(
                pairs
                    .iter()
                    .map(|(k, v)| {
                        if REDACTED_KEYS.contains(&k.as_str()) {
                            (k.clone(), JsonValue::Str(REDACTION_TOKEN.to_owned()))
                        } else if is_image_block && k == "source" {
                            (k.clone(), redact_image_source(v))
                        } else {
                            (k.clone(), redact(v))
                        }
                    })
                    .collect(),
            )
        }
        JsonValue::Array(items) => JsonValue::Array(items.iter().map(redact).collect()),
        other => other.clone(),
    }
}

/// Collapse a large image source to a placeholder; keep tiny refs intact (a
/// short `source` may be a URL/ref rather than an inline blob).
fn redact_image_source(value: &JsonValue) -> JsonValue {
    match value {
        JsonValue::Str(s) if s.len() > MAX_IMAGE_SOURCE_BYTES => {
            JsonValue::Str(format!("[image source omitted: {} bytes]", s.len()))
        }
        JsonValue::Object(pairs) => JsonValue::Object(
            pairs
                .iter()
                .map(|(k, v)| match v {
                    JsonValue::Str(data) if k == "data" && data.len() > MAX_IMAGE_SOURCE_BYTES => (
                        k.clone(),
                        JsonValue::Str(format!("[image data omitted: {} bytes]", data.len())),
                    ),
                    _ => (k.clone(), v.clone()),
                })
                .collect(),
        ),
        other => other.clone(),
    }
}

// ---------------------------------------------------------------------------
// Record projection
// ---------------------------------------------------------------------------

fn parse_record(obj: &JsonValue, line_no: usize) -> Vec<TranscriptEvent> {
    let id = obj
        .get("uuid")
        .and_then(JsonValue::as_str)
        .or_else(|| obj.get("id").and_then(JsonValue::as_str))
        .map_or_else(|| format!("line-{line_no}"), str::to_owned);
    let timestamp_ms = obj.get("timestamp").and_then(parse_timestamp_ms);
    let record_type = obj.get("type").and_then(JsonValue::as_str).unwrap_or("");
    let Some(message @ JsonValue::Object(_)) = obj.get("message") else {
        return Vec::new();
    };
    let role = message
        .get("role")
        .and_then(JsonValue::as_str)
        .unwrap_or(record_type);

    // content may be a plain string …
    if let Some(JsonValue::Str(content)) = message.get("content") {
        let kind = match role {
            "user" => EventKind::UserMessage { text: content.clone() },
            "assistant" => EventKind::AssistantMessage { text: content.clone() },
            _ => return Vec::new(),
        };
        return vec![TranscriptEvent { id, timestamp_ms, kind }];
    }

    // … or an array of blocks. ANY non-object element fails the whole cast
    // (Swift `as? [[String: Any]]` semantics) — no events from this record.
    let Some(blocks) = message.get("content").and_then(JsonValue::as_array) else {
        return Vec::new();
    };
    if blocks.iter().any(|b| !matches!(b, JsonValue::Object(_))) {
        return Vec::new();
    }

    let mut out = Vec::new();
    for block in blocks {
        let block_type = block.get("type").and_then(JsonValue::as_str).unwrap_or("");
        match block_type {
            "text" => {
                let text = block
                    .get("text")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_owned();
                let kind = if role == "user" {
                    EventKind::UserMessage { text }
                } else {
                    EventKind::AssistantMessage { text }
                };
                out.push(TranscriptEvent { id: id.clone(), timestamp_ms, kind });
            }
            "thinking" => {
                // CRIT-7 parity: both `thinking` and `text` payload fields
                // are observed in the wild — accept either.
                let text = block
                    .get("thinking")
                    .and_then(JsonValue::as_str)
                    .or_else(|| block.get("text").and_then(JsonValue::as_str))
                    .unwrap_or("")
                    .to_owned();
                out.push(TranscriptEvent {
                    id: id.clone(),
                    timestamp_ms,
                    kind: EventKind::Thinking { text },
                });
            }
            "tool_use" => {
                let tool_id = block
                    .get("id")
                    .and_then(JsonValue::as_str)
                    .map_or_else(|| id.clone(), str::to_owned);
                let name = block
                    .get("name")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("tool")
                    .to_owned();
                let input = stringify_input(block.get("input"));
                out.push(TranscriptEvent {
                    id: tool_id.clone(),
                    timestamp_ms,
                    kind: EventKind::ToolUse { id: tool_id, name, input },
                });
            }
            "tool_result" => {
                let tool_use_id = block
                    .get("tool_use_id")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_owned();
                let summary = summarize_tool_result(block.get("content"));
                out.push(TranscriptEvent {
                    id: id.clone(),
                    timestamp_ms,
                    kind: EventKind::ToolResult { tool_use_id, summary },
                });
            }
            _ => {}
        }
    }
    out
}

/// `input` object → display map. Key order preserved; a duplicated key keeps
/// only its LAST value (Swift-dictionary semantics).
fn stringify_input(raw: Option<&JsonValue>) -> Vec<(String, String)> {
    let Some(JsonValue::Object(pairs)) = raw else {
        return Vec::new();
    };
    let mut out: Vec<(String, String)> = Vec::with_capacity(pairs.len());
    for (k, v) in pairs {
        let rendered = match v {
            JsonValue::Str(s) => s.clone(),
            JsonValue::Int(n) => n.to_string(),
            // Swift's `v as? Int` SUCCEEDS for a JSON boolean (CFBoolean
            // bridges to 1/0 before the Bool branch is reached) — pinned by
            // the A/B suite against the shipping parser, fixture AND real
            // transcripts. "true"/"false" here would diverge.
            JsonValue::Bool(b) => if *b { "1" } else { "0" }.to_owned(),
            JsonValue::Float(f) => format_double(*f),
            JsonValue::Null => "<null>".to_owned(),
            nested @ (JsonValue::Array(_) | JsonValue::Object(_)) => to_compact_json(nested),
        };
        if let Some(slot) = out.iter_mut().find(|(key, _)| key == k) {
            slot.1 = rendered;
        } else {
            out.push((k.clone(), rendered));
        }
    }
    out
}

fn summarize_tool_result(raw: Option<&JsonValue>) -> String {
    match raw {
        Some(JsonValue::Str(s)) => s.clone(),
        Some(JsonValue::Array(items)) => {
            // Swift `as? [[String: Any]]`: every element must be a dict.
            if items.iter().any(|b| !matches!(b, JsonValue::Object(_))) {
                return String::new();
            }
            items
                .iter()
                .filter_map(|b| b.get("text").and_then(JsonValue::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        }
        _ => String::new(),
    }
}

// ---------------------------------------------------------------------------
// Timestamps — RFC 3339 (the ISO8601DateFormatter internet-date-time subset)
// ---------------------------------------------------------------------------

fn parse_timestamp_ms(v: &JsonValue) -> Option<i64> {
    match v {
        JsonValue::Str(s) => rfc3339_to_epoch_ms(s),
        JsonValue::Int(seconds) => seconds.checked_mul(1000),
        JsonValue::Float(seconds) => {
            let ms = (seconds * 1000.0).round();
            // Reject non-finite and out-of-i64 (the f64 bound is exact).
            (ms.is_finite() && (-9.0e18..=9.0e18).contains(&ms)).then_some(ms as i64)
        }
        _ => None,
    }
}

/// `YYYY-MM-DDTHH:MM:SS(.fff…)?(Z|±HH:MM)` → epoch ms. Anything else → `None`
/// (Foundation parity: `withInternetDateTime` requires the offset). Fractions
/// keep millisecond precision (`withFractionalSeconds`).
fn rfc3339_to_epoch_ms(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    let digit = |i: usize| -> Option<i64> {
        b.get(i)
            .filter(|c| c.is_ascii_digit())
            .map(|c| i64::from(c.saturating_sub(b'0')))
    };
    let num2 = |i: usize| Some(digit(i)?.saturating_mul(10).saturating_add(digit(i.saturating_add(1))?));
    let sep = |i: usize, expect: &[u8]| b.get(i).is_some_and(|c| expect.contains(c));

    if b.len() < 20
        || !sep(4, b"-")
        || !sep(7, b"-")
        || !sep(10, b"Tt")
        || !sep(13, b":")
        || !sep(16, b":")
    {
        return None;
    }
    let year = digit(0)?
        .saturating_mul(1000)
        .saturating_add(digit(1)?.saturating_mul(100))
        .saturating_add(digit(2)?.saturating_mul(10))
        .saturating_add(digit(3)?);
    let month = num2(5)?;
    let day = num2(8)?;
    let hour = num2(11)?;
    let minute = num2(14)?;
    let second = num2(17)?;
    if !(1..=12).contains(&month)
        || day < 1
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }

    // Optional fraction: keep the first 3 digits as milliseconds.
    let mut i = 19usize;
    let mut frac_ms = 0i64;
    if sep(i, b".") {
        i = i.saturating_add(1);
        let mut digits = 0usize;
        while let Some(d) = digit(i) {
            if digits < 3 {
                frac_ms = frac_ms.saturating_mul(10).saturating_add(d);
                digits = digits.saturating_add(1);
            }
            i = i.saturating_add(1);
        }
        if digits == 0 {
            return None; // a bare '.' is not a fraction
        }
        while digits < 3 {
            frac_ms = frac_ms.saturating_mul(10);
            digits = digits.saturating_add(1);
        }
    }

    // Offset: 'Z' or ±HH:MM, and it must end the string.
    let offset_secs: i64 = match b.get(i) {
        Some(b'Z' | b'z') => {
            if i.saturating_add(1) != b.len() {
                return None;
            }
            0
        }
        Some(sign @ (b'+' | b'-')) => {
            let oh = num2(i.saturating_add(1))?;
            if !sep(i.saturating_add(3), b":") {
                return None;
            }
            let om = num2(i.saturating_add(4))?;
            if i.saturating_add(6) != b.len() || oh > 23 || om > 59 {
                return None;
            }
            let magnitude = oh.saturating_mul(3600).saturating_add(om.saturating_mul(60));
            if *sign == b'+' { magnitude } else { -magnitude }
        }
        _ => return None,
    };

    let days = days_from_civil(year, month, day);
    let secs = days
        .saturating_mul(86_400)
        .saturating_add(hour.saturating_mul(3600))
        .saturating_add(minute.saturating_mul(60))
        .saturating_add(second)
        .saturating_sub(offset_secs);
    Some(secs.saturating_mul(1000).saturating_add(frac_ms))
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
                29
            } else {
                28
            }
        }
        _ => 0,
    }
}

/// Howard Hinnant's `days_from_civil` — proleptic-Gregorian days since the
/// 1970-01-01 epoch. Exact over the 4-digit-year range this parser admits.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = (m + 9) % 12; // March = 0
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

// ---------------------------------------------------------------------------
// Compact JSON rendering (nested `input` values)
// ---------------------------------------------------------------------------

/// Compact serialization of a nested value, matching `JSONSerialization`'s
/// observable output: no whitespace, `/` escaped as `\/`, control chars as
/// `\uXXXX`, non-ASCII passed through raw.
fn to_compact_json(value: &JsonValue) -> String {
    let mut out = String::new();
    write_compact(value, &mut out);
    out
}

fn write_compact(value: &JsonValue, out: &mut String) {
    match value {
        JsonValue::Null => out.push_str("null"),
        JsonValue::Bool(true) => out.push_str("true"),
        JsonValue::Bool(false) => out.push_str("false"),
        JsonValue::Int(n) => out.push_str(&n.to_string()),
        JsonValue::Float(f) => out.push_str(&format_double(*f)),
        JsonValue::Str(s) => write_json_string(s, out),
        JsonValue::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_compact(item, out);
            }
            out.push(']');
        }
        JsonValue::Object(pairs) => {
            out.push('{');
            for (i, (k, v)) in pairs.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json_string(k, out);
                out.push(':');
                write_compact(v, out);
            }
            out.push('}');
        }
    }
}

fn write_json_string(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' => out.push_str("\\/"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// `NSNumber`-description-shaped double rendering: integral finite doubles
/// print without a fraction (`2000.0` → `"2000"`), others via Rust's shortest
/// round-trip formatting (matches Foundation on the common cases).
fn format_double(f: f64) -> String {
    if f.is_finite() && f.fract() == 0.0 && f.abs() < 9.0e15 {
        format!("{}", f as i64)
    } else {
        format!("{f}")
    }
}

// ---------------------------------------------------------------------------
// Wire layer — `ffi_frame_body!` shape.
// ---------------------------------------------------------------------------

/// Borrowed `text` (TSK-561): a whole transcript file crosses per parse.
#[derive(Deserialize)]
struct ParseRequest<'a> {
    #[serde(borrow)]
    text: std::borrow::Cow<'a, str>,
    redacting: bool,
    /// Optional event-count ceiling override (the monitor's detail cap).
    /// Riding the wire matters for remote: the cap must apply SERVER-side
    /// so a capped consumer never ships the full event list.
    #[serde(default)]
    max_events: Option<u32>,
}

#[derive(Serialize)]
struct WireEvent {
    id: String,
    /// Epoch ms; absent timestamp rides as nil.
    timestamp_ms: Option<i64>,
    /// "user" | "assistant" | "thinking" | "tool_use" | "tool_result".
    kind: String,
    /// user/assistant/thinking payload.
    text: Option<String>,
    /// tool_use fields.
    name: Option<String>,
    input: Option<Vec<(String, String)>>,
    /// tool_result fields.
    tool_use_id: Option<String>,
    summary: Option<String>,
}

#[derive(Serialize)]
struct ParseResponse {
    events: Vec<WireEvent>,
}

/// `{text, redacting}` request frame → `{events:[…]}` response frame.
pub fn parse_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    parse_wire_impl(req_frame, None)
}

/// [`parse_wire`] with redaction FORCED ON regardless of the request flag —
/// the remote server routes through this (the TSK-245 barrier as a
/// WIRE-boundary guarantee: nothing unredacted leaves the machine). The
/// in-process FFI keeps caller choice (a local trust domain has legitimate
/// un-redacted consumers, e.g. count-only indexing).
pub fn parse_wire_forced_redaction(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    parse_wire_impl(req_frame, Some(true))
}

fn parse_wire_impl(
    req_frame: &[u8],
    redacting_override: Option<bool>,
) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: ParseRequest<'_> = crate::wire::decode_frame_borrowed(req_frame)?;
    let redacting = redacting_override.unwrap_or(req.redacting);
    let max_events = req
        .max_events
        .map_or(MAX_EVENTS, |n| (n as usize).min(MAX_EVENTS));
    let events = parse_with(&req.text, redacting, MAX_LINE_BYTES, max_events)
        .into_iter()
        .map(|e| {
            let mut w = WireEvent {
                id: e.id,
                timestamp_ms: e.timestamp_ms,
                kind: String::new(),
                text: None,
                name: None,
                input: None,
                tool_use_id: None,
                summary: None,
            };
            match e.kind {
                EventKind::UserMessage { text } => {
                    w.kind = "user".to_owned();
                    w.text = Some(text);
                }
                EventKind::AssistantMessage { text } => {
                    w.kind = "assistant".to_owned();
                    w.text = Some(text);
                }
                EventKind::Thinking { text } => {
                    w.kind = "thinking".to_owned();
                    w.text = Some(text);
                }
                EventKind::ToolUse { id, name, input } => {
                    w.kind = "tool_use".to_owned();
                    w.id = id;
                    w.name = Some(name);
                    w.input = Some(input);
                }
                EventKind::ToolResult { tool_use_id, summary } => {
                    w.kind = "tool_result".to_owned();
                    w.tool_use_id = Some(tool_use_id);
                    w.summary = Some(summary);
                }
            }
            w
        })
        .collect();
    crate::wire::encode_frame(&ParseResponse { events })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user_line(uuid: &str, text: &str) -> String {
        format!(
            r#"{{"uuid":"{uuid}","type":"user","timestamp":"2026-06-12T03:14:15.926Z","message":{{"role":"user","content":"{text}"}}}}"#
        )
    }

    #[test]
    fn plain_string_content_user_and_assistant() {
        let log = format!(
            "{}\n{}\n",
            user_line("u1", "hi"),
            r#"{"uuid":"a1","type":"assistant","message":{"role":"assistant","content":"yo"}}"#
        );
        let ev = parse(&log, false);
        assert_eq!(ev.len(), 2);
        assert_eq!(ev[0].id, "u1");
        assert_eq!(ev[0].kind, EventKind::UserMessage { text: "hi".into() });
        // 2026-06-12T03:14:15.926Z — pinned epoch ms.
        assert_eq!(ev[0].timestamp_ms, Some(1_781_234_055_926));
        assert_eq!(ev[1].timestamp_ms, None);
        assert_eq!(ev[1].kind, EventKind::AssistantMessage { text: "yo".into() });
    }

    #[test]
    fn block_array_text_thinking_tool_use_tool_result() {
        let log = concat!(
            r#"{"uuid":"e1","type":"assistant","message":{"role":"assistant","content":["#,
            r#"{"type":"text","text":"answer"},"#,
            r#"{"type":"thinking","thinking":"hmm","signature":"SIG"},"#,
            r#"{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls","timeout":5,"verbose":true}},"#,
            r#"{"type":"unknown_block"}"#,
            r#"]}}"#,
            "\n",
            r#"{"uuid":"e2","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"file1"},{"type":"text","text":"file2"}]}]}}"#,
            "\n"
        );
        let ev = parse(log, false);
        assert_eq!(ev.len(), 4, "unknown block skipped, others projected");
        assert_eq!(ev[0].kind, EventKind::AssistantMessage { text: "answer".into() });
        assert_eq!(ev[1].kind, EventKind::Thinking { text: "hmm".into() });
        assert_eq!(
            ev[2].kind,
            EventKind::ToolUse {
                id: "toolu_1".into(),
                name: "Bash".into(),
                input: vec![
                    ("command".into(), "ls".into()),
                    ("timeout".into(), "5".into()),
                    // NSNumber-bridging parity: booleans render "1"/"0".
                    ("verbose".into(), "1".into()),
                ],
            }
        );
        assert_eq!(ev[2].id, "toolu_1", "tool_use event id is the tool id");
        assert_eq!(
            ev[3].kind,
            EventKind::ToolResult { tool_use_id: "toolu_1".into(), summary: "file1\nfile2".into() }
        );
    }

    #[test]
    fn thinking_text_field_fallback_crit7() {
        let log = r#"{"uuid":"t","message":{"role":"assistant","content":[{"type":"thinking","text":"via text"}]}}"#;
        let ev = parse(log, false);
        assert_eq!(ev[0].kind, EventKind::Thinking { text: "via text".into() });
    }

    #[test]
    fn tolerant_framing_skips_torn_blank_and_non_object_lines() {
        let log = format!(
            "\n{}\nnot json at all\n[1,2,3]\n{}",
            user_line("u1", "a"),
            // torn tail line (no trailing newline, truncated JSON)
            r#"{"uuid":"u2","type":"user","message":{"role":"user","con"#
        );
        let ev = parse(&log, false);
        assert_eq!(ev.len(), 1, "only the valid object line projects");
        assert_eq!(ev[0].id, "u1");
    }

    #[test]
    fn record_shapes_that_yield_nothing() {
        // No message envelope; non-user/assistant role with string content;
        // block array poisoned by a non-object element (whole-cast failure).
        let log = concat!(
            r#"{"uuid":"x1","type":"summary","summary":"s"}"#, "\n",
            r#"{"uuid":"x2","type":"system","message":{"role":"system","content":"sys"}}"#, "\n",
            r#"{"uuid":"x3","message":{"role":"assistant","content":[{"type":"text","text":"ok"},"poison"]}}"#, "\n"
        );
        assert!(parse(log, false).is_empty());
    }

    #[test]
    fn missing_ids_get_deterministic_line_ids() {
        let log = "{\"message\":{\"role\":\"user\",\"content\":\"a\"}}\n\n{\"message\":{\"role\":\"user\",\"content\":\"b\"}}\n";
        let ev = parse(log, false);
        // Line numbers are 1-based over ALL lines (blank line still counts).
        assert_eq!(ev[0].id, "line-1");
        assert_eq!(ev[1].id, "line-3");
    }

    #[test]
    fn caps_bound_events_and_line_bytes() {
        let line = user_line("u", "x");
        let log = format!("{0}\n{0}\n{0}\n", line);
        assert_eq!(parse_with(&log, false, MAX_LINE_BYTES, 2).len(), 2);
        // A line over the byte cap is skipped, not truncated.
        let ev = parse_with(&log, false, 10, MAX_EVENTS);
        assert!(ev.is_empty());
    }

    #[test]
    fn timestamps_string_number_and_invalid() {
        let cases = [
            // (timestamp JSON fragment, expected ms)
            (r#""2026-06-12T03:14:15.926Z""#, Some(1_781_234_055_926)),
            (r#""2026-06-12T03:14:15Z""#, Some(1_781_234_055_000)),
            // Offset form: 05:14:15+02:00 == 03:14:15Z.
            (r#""2026-06-12T05:14:15+02:00""#, Some(1_781_234_055_000)),
            (r#""1970-01-01T00:00:00Z""#, Some(0)),
            (r#""1969-12-31T23:59:59Z""#, Some(-1000)),
            (r#"1718150400"#, Some(1_718_150_400_000)),
            (r#"1718150400.5"#, Some(1_718_150_400_500)),
            // Missing offset / garbage / impossible date → None.
            (r#""2026-06-12T03:14:15""#, None),
            (r#""2026-02-30T00:00:00Z""#, None),
            (r#""not a date""#, None),
            (r#"true"#, None),
        ];
        for (frag, want) in cases {
            let log = format!(
                r#"{{"uuid":"u","timestamp":{frag},"message":{{"role":"user","content":"x"}}}}"#
            );
            let ev = parse(&log, false);
            assert_eq!(ev[0].timestamp_ms, want, "timestamp fragment {frag}");
        }
    }

    #[test]
    fn leap_year_february() {
        // 2024-02-29 is real; days_from_civil must not be off-by-one after it.
        let log = r#"{"uuid":"u","timestamp":"2024-02-29T00:00:00Z","message":{"role":"user","content":"x"}}"#;
        assert_eq!(parse(log, false)[0].timestamp_ms, Some(1_709_164_800_000));
        let log = r#"{"uuid":"u","timestamp":"2024-03-01T00:00:00Z","message":{"role":"user","content":"x"}}"#;
        assert_eq!(parse(log, false)[0].timestamp_ms, Some(1_709_251_200_000));
    }

    #[test]
    fn redaction_strips_signature_headers_and_collapses_image_blobs() {
        let big = "A".repeat(MAX_IMAGE_SOURCE_BYTES + 1);
        let log = format!(
            concat!(
                r#"{{"uuid":"r1","message":{{"role":"assistant","content":["#,
                r#"{{"type":"thinking","thinking":"secret-adjacent","signature":"BLOB"}},"#,
                r#"{{"type":"tool_result","tool_use_id":"t","content":[{{"type":"text","text":"ok"}}]}}"#,
                r#"]}},"system":{{"api_error":{{"error":{{"headers":{{"set-cookie":"_cfuvid=secret"}}}}}}}}}}"#,
                "\n",
                r#"{{"uuid":"r2","message":{{"role":"user","content":[{{"type":"image","source":"{big}"}},{{"type":"text","text":"caption"}}]}}}}"#,
                "\n"
            ),
            big = big
        );
        // Un-redacted parse: events carry no secrets anyway (projection drops
        // signature/headers/source) — the barrier matters for consumers that
        // re-serialize records; here we pin the redact() transform directly.
        let doc = json::parse(
            &format!(r#"{{"signature":"S","nested":{{"headers":{{"set-cookie":"v"}}}},"blocks":[{{"type":"image","source":"{big}"}}]}}"#)
        ).unwrap();
        let red = redact(&doc);
        assert_eq!(red.get("signature").and_then(JsonValue::as_str), Some(REDACTION_TOKEN));
        let nested_headers = red
            .get("nested")
            .and_then(|n| n.get("headers"))
            .and_then(JsonValue::as_str);
        assert_eq!(nested_headers, Some(REDACTION_TOKEN), "headers scrubbed wherever nested");
        let source = red
            .get("blocks")
            .and_then(JsonValue::as_array)
            .and_then(|b| b.first())
            .and_then(|b| b.get("source"))
            .and_then(JsonValue::as_str)
            .unwrap();
        assert_eq!(source, format!("[image source omitted: {} bytes]", big.len()));
        // And the redacting parse path still projects events normally.
        let ev = parse(&log, true);
        assert_eq!(ev.len(), 3);
        assert_eq!(ev[0].kind, EventKind::Thinking { text: "secret-adjacent".into() });
    }

    #[test]
    fn redaction_object_form_image_source_drops_data_keeps_metadata() {
        let big = "B".repeat(MAX_IMAGE_SOURCE_BYTES + 10);
        let doc = json::parse(&format!(
            r#"{{"type":"image","source":{{"type":"base64","media_type":"image/png","data":"{big}"}}}}"#
        ))
        .unwrap();
        let red = redact(&doc);
        let source = red.get("source").unwrap();
        assert_eq!(
            source.get("data").and_then(JsonValue::as_str),
            Some(format!("[image data omitted: {} bytes]", big.len()).as_str())
        );
        assert_eq!(source.get("media_type").and_then(JsonValue::as_str), Some("image/png"));
    }

    #[test]
    fn input_stringification_nested_and_duplicates() {
        let log = concat!(
            r#"{"uuid":"i","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"X","input":"#,
            r#"{"args":["a","b"],"nested":{"k":"v/slash"},"pi":1.5,"n":2000.0,"nul":null,"dup":1,"dup":2}"#,
            r#"}]}}"#
        );
        let ev = parse(log, false);
        assert!(matches!(&ev[0].kind, EventKind::ToolUse { .. }), "expected tool_use");
        let EventKind::ToolUse { input, .. } = &ev[0].kind else { return };
        let get = |k: &str| input.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str());
        assert_eq!(get("args"), Some(r#"["a","b"]"#));
        // JSONSerialization escapes '/' as '\/' — the compact repr must too.
        assert_eq!(get("nested"), Some(r#"{"k":"v\/slash"}"#));
        assert_eq!(get("pi"), Some("1.5"));
        assert_eq!(get("n"), Some("2000"), "integral double prints without fraction");
        assert_eq!(get("nul"), Some("<null>"));
        assert_eq!(get("dup"), Some("2"), "duplicate key last-wins");
    }

    #[test]
    fn wire_round_trip() {
        #[derive(Serialize)]
        struct Req<'a> {
            text: &'a str,
            redacting: bool,
        }
        let log = format!("{}\n", user_line("u1", "hello"));
        let frame = crate::wire::encode_frame(&Req { text: &log, redacting: true }).unwrap();
        let resp = parse_wire(&frame).unwrap();

        #[derive(Deserialize)]
        struct Resp {
            events: Vec<REvent>,
        }
        #[derive(Deserialize)]
        struct REvent {
            id: String,
            timestamp_ms: Option<i64>,
            kind: String,
            text: Option<String>,
            name: Option<String>,
            tool_use_id: Option<String>,
        }
        let decoded: Resp = crate::wire::decode_frame(&resp).unwrap();
        assert_eq!(decoded.events.len(), 1);
        let e = &decoded.events[0];
        assert_eq!(e.id, "u1");
        assert_eq!(e.kind, "user");
        assert_eq!(e.text.as_deref(), Some("hello"));
        assert_eq!(e.timestamp_ms, Some(1_781_234_055_926));
        assert!(e.name.is_none());
        assert!(e.tool_use_id.is_none());
        // NOTE: this request omits max_events entirely — #[serde(default)]
        // makes the field additive (old clients keep working).
    }

    #[test]
    fn wire_forced_redaction_ignores_the_request_flag() {
        #[derive(Serialize)]
        struct Req<'a> {
            text: &'a str,
            redacting: bool,
        }
        #[derive(Deserialize)]
        struct Resp {
            events: Vec<REvent>,
        }
        #[derive(Deserialize)]
        struct REvent {
            input: Option<Vec<(String, String)>>,
        }
        let log = concat!(
            r#"{"uuid":"a","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"X","input":{"signature":"SECRET"}}]}}"#,
            "\n"
        );
        // The request EXPLICITLY asks for un-redacted — the forced variant
        // must scrub anyway (the wire-boundary guarantee).
        let frame = crate::wire::encode_frame(&Req { text: log, redacting: false }).unwrap();
        let resp: Resp =
            crate::wire::decode_frame(&parse_wire_forced_redaction(&frame).unwrap()).unwrap();
        let input = resp.events.first().and_then(|e| e.input.clone()).unwrap_or_default();
        assert_eq!(
            input.iter().find(|(k, _)| k == "signature").map(|(_, v)| v.as_str()),
            Some("[REDACTED]"),
            "forced redaction must override redacting:false"
        );
        // And the plain wire fn still honors the flag (local trust domain).
        let resp: Resp = crate::wire::decode_frame(&parse_wire(&frame).unwrap()).unwrap();
        let input = resp.events.first().and_then(|e| e.input.clone()).unwrap_or_default();
        assert_eq!(
            input.iter().find(|(k, _)| k == "signature").map(|(_, v)| v.as_str()),
            Some("SECRET")
        );
    }

    #[test]
    fn wire_max_events_caps_server_side() {
        #[derive(Serialize)]
        struct Req<'a> {
            text: &'a str,
            redacting: bool,
            max_events: Option<u32>,
        }
        #[derive(Deserialize)]
        struct Resp {
            events: Vec<REvent>,
        }
        #[derive(Deserialize)]
        struct REvent {
            id: String,
        }
        let log = format!("{}{}{}", user_line("a", "1"), "\n", user_line("b", "2")) + "\n";
        let frame = crate::wire::encode_frame(&Req {
            text: &log, redacting: false, max_events: Some(1),
        })
        .unwrap();
        let resp: Resp = crate::wire::decode_frame(&parse_wire(&frame).unwrap()).unwrap();
        assert_eq!(resp.events.len(), 1, "cap must apply server-side");
        assert_eq!(resp.events[0].id, "a");
    }
}
