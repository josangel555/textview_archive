//! Mermaid host-div generation (TSK-661) — the Rust twin of Swift's
//! `MermaidSourceParser` + `HTMLVisitor.renderMermaidHost`. Pure string
//! work: directive parsing (`%% @id`, `%% @step N`), the steps JSON
//! manifest, the 8-hex-char SHA-256 source hash, and the
//! `<div class="mdv-mermaid">` host element the JS shim consumes. The
//! mermaid.js DIAGRAM rendering stays client-side in the WKWebView — this
//! module only produces the static HTML.
//!
//! Parity contract (byte-equal with the Swift twin, pinned by the A/B
//! suite): attribute order `class, data-mdv-id, data-mdv-src-hash,
//! data-mdv-steps (only when steps exist), data-mdv-src`; the steps JSON is
//! compact with sorted keys (`[{"line":N,"step":M}]`); the hash is the
//! first 4 bytes of SHA-256(source) in lowercase hex (it keys the shim's
//! theme-flip re-render cache, so it must NEVER drift). SHA-256 is
//! hand-rolled (FIPS 180-4, ~100 lines — no crypto dep under the
//! 1000-line rule), verified against the standard test vectors.

use crate::markdown::escape;

/// One `%% @step N` annotation: the step number and the 0-based line index
/// of the directive itself (the JS shim binds it to the next visible line).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StepAnnotation {
    /// 1-based step number.
    pub step: i64,
    /// 0-based line index of the directive line.
    pub line: usize,
}

/// Parsed directive set of one mermaid source.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Parsed {
    /// Explicit `%% @id <slug>` (LAST occurrence wins, like the Swift loop).
    pub id: Option<String>,
    /// Step annotations in document order.
    pub steps: Vec<StepAnnotation>,
}

/// Trim the Swift `.whitespaces` set (space/tab; the corpus is ASCII —
/// fence bodies never carry the exotic Zs spaces in practice).
fn trim_ws(s: &str) -> &str {
    s.trim_matches([' ', '\t'])
}

/// Parse `%% @id` / `%% @step N` directives (mermaid strips `%%` comment
/// lines, so they are syntactically transparent to the runtime).
#[must_use]
pub fn parse(source: &str) -> Parsed {
    let mut out = Parsed::default();
    for (i, raw) in source.split('\n').enumerate() {
        let line = trim_ws(raw);
        let Some(body) = line.strip_prefix("%%") else { continue };
        let body = trim_ws(body);
        if let Some(after) = body.strip_prefix("@step") {
            // "@stepN"/"@steplabel" are malformed, not directives — the
            // marker must be followed by whitespace (or end of line).
            if !(after.is_empty() || after.starts_with(' ') || after.starts_with('\t')) {
                continue;
            }
            if let Ok(n) = trim_ws(after).parse::<i64>()
                && n >= 1
            {
                out.steps.push(StepAnnotation { step: n, line: i });
            }
        } else if let Some(after) = body.strip_prefix("@id") {
            if !(after.is_empty() || after.starts_with(' ') || after.starts_with('\t')) {
                continue;
            }
            let rest = trim_ws(after);
            if !rest.is_empty() {
                out.id = Some(rest.to_owned());
            }
        }
    }
    out
}

/// Compact steps JSON with sorted keys — byte-equal to Swift's
/// `JSONEncoder` + `.sortedKeys` output: `[{"line":3,"step":1},…]`.
#[must_use]
pub fn encode_steps(steps: &[StepAnnotation]) -> String {
    let mut out = String::from("[");
    for (i, s) in steps.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!("{{\"line\":{},\"step\":{}}}", s.line, s.step));
    }
    out.push(']');
    out
}

/// 8-char lowercase-hex prefix of SHA-256(source) — the Swift `shortHash`.
#[must_use]
pub fn short_hash(source: &str) -> String {
    let digest = sha256(source.as_bytes());
    digest
        .iter()
        .take(4)
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Build the `<div class="mdv-mermaid">` host element — byte-equal to
/// `HTMLVisitor.renderMermaidHost`. The raw source is both the visible
/// text-node child (what `mermaid.run` parses) and the `data-mdv-src`
/// attribute (theme-flip re-render restore); deliberately NOT wrapped in
/// `<pre>`/`<code>` (mermaid's tokenizer is whitespace-sensitive).
#[must_use]
pub fn render_host(source: &str) -> String {
    let parsed = parse(source);
    let hash = short_hash(source);
    let id = parsed
        .id
        .unwrap_or_else(|| format!("mdv-mermaid-{hash}"));

    let mut attrs = String::from("class=\"mdv-mermaid\"");
    attrs.push_str(&format!(" data-mdv-id=\"{}\"", escape(&id)));
    attrs.push_str(&format!(" data-mdv-src-hash=\"{hash}\""));
    if !parsed.steps.is_empty() {
        attrs.push_str(&format!(
            " data-mdv-steps=\"{}\"",
            escape(&encode_steps(&parsed.steps))
        ));
    }
    attrs.push_str(&format!(" data-mdv-src=\"{}\"", escape(source)));

    format!("<div {attrs}>{}</div>\n", escape(source))
}

// ---------------------------------------------------------------------------
// SHA-256 (FIPS 180-4) — hand-rolled, no crypto dep (1000-line rule).
// Only used for the 4-byte display hash above; NOT a general crypto API.
// ---------------------------------------------------------------------------

const K: [u32; 64] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4,
    0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe,
    0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f,
    0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da, 0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
    0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc,
    0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
    0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070, 0x19a4_c116,
    0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
    0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7,
    0xc671_78f2,
];

/// SHA-256 digest. Fixed-size-array indexing throughout — every index is
/// compile-time bounded, which the no-panic lint can't see.
#[allow(
    clippy::indexing_slicing,
    reason = "fixed-size arrays; all indices are compile-time bounded constants"
)]
fn sha256(message: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ];

    // Padded message: original + 0x80 + zeros + 64-bit big-endian bit length.
    let bit_len = (message.len() as u64).wrapping_mul(8);
    let mut padded = message.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    for block in padded.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, word) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn sha256_fips_test_vectors() {
        // FIPS 180-4 / NIST CAVP standard vectors — the hash keys the
        // shim's re-render cache, so it must be REAL SHA-256, not merely
        // self-consistent.
        assert_eq!(
            hex(&sha256(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(&sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            hex(&sha256(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        // Multi-block (>64 bytes) exercises the chaining.
        let long = "a".repeat(200);
        assert_eq!(
            hex(&sha256(long.as_bytes())),
            "c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5"
        );
    }

    #[test]
    fn short_hash_is_first_four_bytes_hex() {
        assert_eq!(short_hash(""), "e3b0c442");
        assert_eq!(short_hash("abc"), "ba7816bf");
    }

    #[test]
    fn parse_directives_id_and_steps() {
        let src = "graph TD\n%% @id my-diagram\n%% @step 1\nA-->B\n  %%  @step 2\nB-->C\n%% @stepX bad\n%% @step 0\n%% @step\n";
        let p = parse(src);
        assert_eq!(p.id.as_deref(), Some("my-diagram"));
        assert_eq!(
            p.steps,
            vec![
                StepAnnotation { step: 1, line: 2 },
                StepAnnotation { step: 2, line: 4 },
            ]
        );
        // Later @id wins (Swift assignment semantics).
        let p = parse("%% @id first\n%% @id second\n");
        assert_eq!(p.id.as_deref(), Some("second"));
        // "@idx" is not a directive.
        assert_eq!(parse("%% @idx nope\n").id, None);
    }

    #[test]
    fn encode_steps_matches_swift_sorted_keys_compact_json() {
        assert_eq!(encode_steps(&[]), "[]");
        assert_eq!(
            encode_steps(&[
                StepAnnotation { step: 1, line: 2 },
                StepAnnotation { step: 2, line: 4 }
            ]),
            r#"[{"line":2,"step":1},{"line":4,"step":2}]"#
        );
    }

    #[test]
    fn render_host_shape_attribute_order_and_escaping() {
        let src = "graph TD; A-->B;";
        let hash = short_hash(src);
        let html = render_host(src);
        assert_eq!(
            html,
            format!(
                "<div class=\"mdv-mermaid\" data-mdv-id=\"mdv-mermaid-{hash}\" \
                 data-mdv-src-hash=\"{hash}\" data-mdv-src=\"graph TD; A--&gt;B;\">\
                 graph TD; A--&gt;B;</div>\n"
            )
        );
        // Steps + explicit id: data-mdv-steps appears, id is the directive's.
        let src = "%% @id flow\n%% @step 1\nA-->B";
        let html = render_host(src);
        assert!(html.contains("data-mdv-id=\"flow\""));
        assert!(html.contains(
            "data-mdv-steps=\"[{&quot;line&quot;:1,&quot;step&quot;:1}]\""
        ));
    }
}
