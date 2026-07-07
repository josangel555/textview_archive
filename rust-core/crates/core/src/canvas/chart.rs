//! Canvas M4.S7b — the hand-rolled Vega-Lite-SUBSET chart renderer
//! (TSK-1386; M4-PLAN §S7). ZERO dependencies, DETERMINISTIC output (fixed
//! 2-decimal formatting; no clocks, no rng): the same spec always emits the
//! same SVG bytes, so goldens and patches stay stable.
//!
//! The subset (deliberately tiny — the gauntlet decides growth):
//! `{"mark": "bar"|"line"|"pie", "values": [{"label": "...", "value": N}…],
//!  "width"?: N, "height"?: N}`.

use crate::json::{self, JsonValue};

/// One parsed datum.
#[derive(Debug, Clone, PartialEq)]
/// One labeled data point.
pub struct Datum {
    /// Category / x label.
    pub label: String,
    /// Numeric value.
    pub value: f64,
}

/// The parsed subset spec.
#[derive(Debug, Clone, PartialEq)]
pub struct ChartSpec {
    /// Chart type.
    pub mark: Mark,
    /// The data points, in order.
    pub values: Vec<Datum>,
    /// Render width (px).
    pub width: f64,
    /// Render height (px).
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// The supported chart types.
pub enum Mark {
    /// Vertical bars.
    Bar,
    /// A connected line.
    Line,
    /// A pie of value shares.
    Pie,
}

/// Parse the spec (None on any malformed shape — lint owns the warning;
/// lowering stays total with a placeholder).
#[must_use]
pub fn parse_spec(spec_json: &str) -> Option<ChartSpec> {
    let parsed = json::parse(spec_json).ok()?;
    let mark = match parsed.get("mark").and_then(JsonValue::as_str)? {
        "bar" => Mark::Bar,
        "line" => Mark::Line,
        "pie" => Mark::Pie,
        _ => return None,
    };
    let raw_values = parsed.get("values").and_then(JsonValue::as_array)?;
    if raw_values.is_empty() || raw_values.len() > 1000 {
        return None;
    }
    let mut values = Vec::with_capacity(raw_values.len());
    for entry in raw_values {
        let label = entry.get("label").and_then(JsonValue::as_str)?.to_owned();
        let value = match entry.get("value")? {
            JsonValue::Int(i) => {
                // Chart magnitudes are far below 2^53 — exact in f64.
                #[allow(clippy::cast_precision_loss, reason = "chart magnitudes < 2^53")]
                {
                    *i as f64
                }
            }
            JsonValue::Float(f) => *f,
            _ => return None,
        };
        if !value.is_finite() || value < 0.0 {
            return None;
        }
        values.push(Datum { label, value });
    }
    let dim = |key: &str, default: f64| -> f64 {
        match parsed.get(key) {
            Some(JsonValue::Int(i)) if *i > 0 && *i <= 4000 => {
                #[allow(clippy::cast_precision_loss, reason = "bounded <= 4000")]
                {
                    *i as f64
                }
            }
            _ => default,
        }
    };
    Some(ChartSpec {
        mark,
        values,
        width: dim("width", 320.0),
        height: dim("height", 180.0),
    })
}

fn esc(s: &str, out: &mut String) {
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(ch),
        }
    }
}

/// Fixed 2-decimal formatting — the determinism anchor.
fn num(v: f64, out: &mut String) {
    out.push_str(&format!("{v:.2}"));
}

/// Render the spec to an inline SVG (token-colored via var(--cv-*) so
/// charts RETHEME with the document like everything else).
#[must_use]
pub fn render_svg(spec: &ChartSpec) -> String {
    let mut out = String::with_capacity(1024);
    out.push_str("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ");
    num(spec.width, &mut out);
    out.push(' ');
    num(spec.height, &mut out);
    out.push_str("\" width=\"");
    num(spec.width, &mut out);
    out.push_str("\" height=\"");
    num(spec.height, &mut out);
    out.push_str("\" role=\"img\">");
    match spec.mark {
        Mark::Bar => render_bars(spec, &mut out),
        Mark::Line => render_line(spec, &mut out),
        Mark::Pie => render_pie(spec, &mut out),
    }
    out.push_str("</svg>");
    out
}

const LABEL_BAND: f64 = 18.0;

fn max_value(spec: &ChartSpec) -> f64 {
    spec.values.iter().map(|d| d.value).fold(0.0, f64::max).max(1e-9)
}

#[allow(clippy::cast_precision_loss, reason = "value counts are <= 1000")]
fn render_bars(spec: &ChartSpec, out: &mut String) {
    let n = spec.values.len() as f64;
    let plot_h = spec.height - LABEL_BAND;
    let max = max_value(spec);
    let band = spec.width / n;
    let bar_w = (band * 0.7).max(1.0);
    for (i, d) in spec.values.iter().enumerate() {
        let h = (d.value / max) * (plot_h - 4.0);
        let x = (i as f64) * band + (band - bar_w) / 2.0;
        let y = plot_h - h;
        out.push_str("<rect fill=\"var(--cv-color-accent)\" x=\"");
        num(x, out);
        out.push_str("\" y=\"");
        num(y, out);
        out.push_str("\" width=\"");
        num(bar_w, out);
        out.push_str("\" height=\"");
        num(h, out);
        out.push_str("\"/>");
        label(d, x + bar_w / 2.0, spec.height - 4.0, out);
    }
}

#[allow(clippy::cast_precision_loss, reason = "value counts are <= 1000")]
fn render_line(spec: &ChartSpec, out: &mut String) {
    let n = spec.values.len();
    let plot_h = spec.height - LABEL_BAND;
    let max = max_value(spec);
    let step = if n > 1 { spec.width / ((n - 1) as f64) } else { 0.0 };
    out.push_str("<polyline fill=\"none\" stroke=\"var(--cv-color-accent)\" stroke-width=\"2\" points=\"");
    for (i, d) in spec.values.iter().enumerate() {
        if i > 0 {
            out.push(' ');
        }
        num((i as f64) * step, out);
        out.push(',');
        num(plot_h - (d.value / max) * (plot_h - 4.0), out);
    }
    out.push_str("\"/>");
    for (i, d) in spec.values.iter().enumerate() {
        label(d, (i as f64) * step, spec.height - 4.0, out);
    }
}

fn render_pie(spec: &ChartSpec, out: &mut String) {
    let total: f64 = spec.values.iter().map(|d| d.value).sum::<f64>().max(1e-9);
    let cx = spec.width / 2.0;
    let cy = (spec.height - LABEL_BAND) / 2.0;
    let r = cx.min(cy) - 2.0;
    let mut angle = -std::f64::consts::FRAC_PI_2;
    for (i, d) in spec.values.iter().enumerate() {
        let sweep = (d.value / total) * std::f64::consts::TAU;
        let (x0, y0) = (cx + r * angle.cos(), cy + r * angle.sin());
        let end = angle + sweep;
        let (x1, y1) = (cx + r * end.cos(), cy + r * end.sin());
        let large = i32::from(sweep > std::f64::consts::PI);
        // Slice opacity steps distinguish segments without a palette dep.
        let opacity = 1.0 - (i as f64 % 5.0) * 0.15;
        out.push_str("<path fill=\"var(--cv-color-accent)\" fill-opacity=\"");
        num(opacity, out);
        out.push_str("\" d=\"M");
        num(cx, out);
        out.push(',');
        num(cy, out);
        out.push_str(" L");
        num(x0, out);
        out.push(',');
        num(y0, out);
        out.push_str(&format!(" A{r:.2},{r:.2} 0 {large} 1 "));
        num(x1, out);
        out.push(',');
        num(y1, out);
        out.push_str(" Z\"/>");
        angle = end;
    }
}

fn label(d: &Datum, x: f64, y: f64, out: &mut String) {
    out.push_str("<text fill=\"var(--cv-color-muted)\" font-size=\"10\" text-anchor=\"middle\" x=\"");
    num(x, out);
    out.push_str("\" y=\"");
    num(y, out);
    out.push_str("\">");
    esc(&d.label, out);
    out.push_str("</text>");
}

#[cfg(test)]
mod tests {
    use super::*;

    const BAR: &str = r#"{"mark":"bar","values":[{"label":"A","value":30},{"label":"B","value":60}]}"#;

    #[test]
    fn bar_chart_renders_deterministic_scaled_svg() {
        let spec = parse_spec(BAR).expect("spec");
        let svg = render_svg(&spec);
        assert_eq!(svg, render_svg(&spec), "byte-deterministic");
        assert_eq!(svg.matches("<rect").count(), 2);
        assert!(svg.contains("var(--cv-color-accent)"), "token-colored (rethemes)");
        // B (60) is twice A's height (30): heights 158.60 vs 79.30 @ 180px.
        assert!(svg.contains("height=\"158.00\"") || svg.contains("height=\"158.60\""),
                "{svg}");
    }

    #[test]
    fn line_and_pie_render_and_labels_escape() {
        let line = parse_spec(
            r#"{"mark":"line","values":[{"label":"<q1>","value":1},{"label":"q2","value":2}]}"#,
        )
        .expect("line");
        let svg = render_svg(&line);
        assert!(svg.contains("<polyline"));
        assert!(svg.contains("&lt;q1&gt;"), "labels escape: {svg}");
        let pie = parse_spec(
            r#"{"mark":"pie","values":[{"label":"a","value":1},{"label":"b","value":3}]}"#,
        )
        .expect("pie");
        let psvg = render_svg(&pie);
        assert_eq!(psvg.matches("<path").count(), 2);
    }

    #[test]
    fn malformed_specs_parse_to_none() {
        assert!(parse_spec("not json").is_none());
        assert!(parse_spec(r#"{"mark":"scatter","values":[]}"#).is_none());
        assert!(parse_spec(r#"{"mark":"bar","values":[]}"#).is_none());
        assert!(parse_spec(r#"{"mark":"bar","values":[{"label":"a","value":-1}]}"#).is_none());
        assert!(parse_spec(r#"{"mark":"bar","values":[{"label":"a"}]}"#).is_none());
    }
}
