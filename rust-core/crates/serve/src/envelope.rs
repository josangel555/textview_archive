//! The protocol-v1 envelope (`docs/REMOTE_PROTOCOL.md` §3) — a HAND-ROLLED
//! MessagePack codec at the byte level. Hand-rolled because the envelope
//! needs the `bin` family for the opaque body (rmp-serde would need
//! `serde_bytes`, a new dep) and because unknown-key TOLERANCE is a wire
//! contract, not a serde afterthought. Small by design: one fixmap, fixstr
//! keys, uint/str/bin values.

/// Frame type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    /// Request: correlation id, method, body bytes (unframed msgpack doc),
    /// and an optional `aux` bulk side-channel (key `"a"`). `aux` mirrors the
    /// dispatch `aux` argument the core uses for frame-cap-exempt bulk inputs
    /// (the text to indent-detect, the buffer to hex-search/render — TSK-580
    /// §"Aux side-channel"). It is OMITTED from the wire when empty, so every
    /// existing `req`-only method's bytes stay byte-identical; a peer that
    /// never sends `aux` is unaffected (unknown-key tolerance covers the
    /// reverse direction).
    Request { id: u64, method: String, body: Vec<u8>, aux: Vec<u8> },
    /// Response: correlation id, body XOR error.
    Response { id: u64, body: Option<Vec<u8>>, error: Option<WireError> },
    /// Event: subscription id, sequence, kind, body.
    Event { sub: u64, seq: u64, kind: String, body: Vec<u8> },
}

/// In-band error: code + human text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireError {
    pub code: String,
    pub text: String,
}

/// Decode failure (malformed envelope — the connection should close).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvelopeError(pub String);

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

fn push_fixstr(out: &mut Vec<u8>, s: &str) {
    // Envelope keys/kinds/methods are short; fixstr (≤31) covers keys, and
    // str8 covers any longer method/kind/code strings.
    let bytes = s.as_bytes();
    if bytes.len() <= 31 {
        out.push(0xa0 | u8::try_from(bytes.len()).unwrap_or(31));
    } else {
        out.push(0xd9);
        out.push(u8::try_from(bytes.len().min(255)).unwrap_or(255));
    }
    out.extend_from_slice(bytes.get(..bytes.len().min(255)).unwrap_or_default());
}

#[allow(clippy::cast_possible_truncation,
        reason = "TSK-575: the `v as u8` is guarded by `v < 0x80` — fits u8")]
fn push_uint(out: &mut Vec<u8>, v: u64) {
    if v < 0x80 {
        out.push(v as u8);
    } else {
        out.push(0xcf);
        out.extend_from_slice(&v.to_be_bytes());
    }
}

fn push_bin(out: &mut Vec<u8>, b: &[u8]) {
    out.push(0xc6); // bin32 unconditionally — simple, and bodies can be big
    out.extend_from_slice(&u32::try_from(b.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(b);
}

/// Encode a frame to envelope bytes (no length prefix — the stream layer
/// adds it).
#[must_use]
pub fn encode(frame: &Frame) -> Vec<u8> {
    let mut out = Vec::with_capacity(64);
    match frame {
        Frame::Request { id, method, body, aux } => {
            // 4 base keys (t/i/m/b); the `a` aux key is added ONLY when
            // non-empty so req-only methods stay byte-identical on the wire.
            let n = 4 + usize::from(!aux.is_empty());
            out.push(0x80 | u8::try_from(n).unwrap_or(5));
            push_fixstr(&mut out, "t");
            push_fixstr(&mut out, "q");
            push_fixstr(&mut out, "i");
            push_uint(&mut out, *id);
            push_fixstr(&mut out, "m");
            push_fixstr(&mut out, method);
            push_fixstr(&mut out, "b");
            push_bin(&mut out, body);
            if !aux.is_empty() {
                push_fixstr(&mut out, "a");
                push_bin(&mut out, aux);
            }
        }
        Frame::Response { id, body, error } => {
            let n = 2 + usize::from(body.is_some()) + usize::from(error.is_some());
            out.push(0x80 | u8::try_from(n).unwrap_or(4));
            push_fixstr(&mut out, "t");
            push_fixstr(&mut out, "r");
            push_fixstr(&mut out, "i");
            push_uint(&mut out, *id);
            if let Some(b) = body {
                push_fixstr(&mut out, "b");
                push_bin(&mut out, b);
            }
            if let Some(e) = error {
                push_fixstr(&mut out, "e");
                out.push(0x82); // fixmap(2)
                push_fixstr(&mut out, "c");
                push_fixstr(&mut out, &e.code);
                push_fixstr(&mut out, "x");
                push_fixstr(&mut out, &e.text);
            }
        }
        Frame::Event { sub, seq, kind, body } => {
            out.push(0x85); // fixmap(5)
            push_fixstr(&mut out, "t");
            push_fixstr(&mut out, "e");
            push_fixstr(&mut out, "s");
            push_uint(&mut out, *sub);
            push_fixstr(&mut out, "n");
            push_uint(&mut out, *seq);
            push_fixstr(&mut out, "k");
            push_fixstr(&mut out, kind);
            push_fixstr(&mut out, "b");
            push_bin(&mut out, body);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Decoding — byte cursor, unknown keys skipped (forward compat).
// ---------------------------------------------------------------------------

struct Cur<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Cur<'a> {
    fn err<T>(&self, m: &str) -> Result<T, EnvelopeError> {
        Err(EnvelopeError(format!("{m} at {}", self.i)))
    }
    fn byte(&mut self) -> Result<u8, EnvelopeError> {
        let Some(&v) = self.b.get(self.i) else {
            return self.err("truncated");
        };
        self.i = self.i.saturating_add(1);
        Ok(v)
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8], EnvelopeError> {
        let end = self.i.saturating_add(n);
        let Some(s) = self.b.get(self.i..end) else {
            return self.err("truncated payload");
        };
        self.i = end;
        Ok(s)
    }
    fn be_u32(&mut self) -> Result<u32, EnvelopeError> {
        let s = self.take(4)?;
        let mut a = [0u8; 4];
        a.copy_from_slice(s);
        Ok(u32::from_be_bytes(a))
    }
    fn be_u64(&mut self) -> Result<u64, EnvelopeError> {
        let s = self.take(8)?;
        let mut a = [0u8; 8];
        a.copy_from_slice(s);
        Ok(u64::from_be_bytes(a))
    }

    fn str_(&mut self) -> Result<String, EnvelopeError> {
        let tag = self.byte()?;
        let len = match tag {
            0xa0..=0xbf => usize::from(tag & 0x1f),
            0xd9 => usize::from(self.byte()?),
            _ => return self.err("expected str"),
        };
        let s = self.take(len)?;
        String::from_utf8(s.to_vec()).map_err(|_| EnvelopeError("bad utf8 str".into()))
    }

    fn uint(&mut self) -> Result<u64, EnvelopeError> {
        let tag = self.byte()?;
        match tag {
            0x00..=0x7f => Ok(u64::from(tag)),
            0xcc => Ok(u64::from(self.byte()?)),
            0xcd => {
                let s = self.take(2)?;
                Ok(u64::from(u16::from_be_bytes([
                    s.first().copied().unwrap_or(0),
                    s.get(1).copied().unwrap_or(0),
                ])))
            }
            0xce => Ok(u64::from(self.be_u32()?)),
            0xcf => self.be_u64(),
            _ => self.err("expected uint"),
        }
    }

    fn bin(&mut self) -> Result<Vec<u8>, EnvelopeError> {
        let tag = self.byte()?;
        let len = match tag {
            0xc4 => usize::from(self.byte()?),
            0xc5 => {
                let s = self.take(2)?;
                usize::from(u16::from_be_bytes([
                    s.first().copied().unwrap_or(0),
                    s.get(1).copied().unwrap_or(0),
                ]))
            }
            0xc6 => self.be_u32()? as usize,
            _ => return self.err("expected bin"),
        };
        Ok(self.take(len)?.to_vec())
    }

    /// Skip one arbitrary value (unknown-key tolerance). Covers the subset
    /// any conforming peer can emit in an envelope.
    fn skip(&mut self) -> Result<(), EnvelopeError> {
        let tag = self.byte()?;
        match tag {
            0x00..=0x7f | 0xc0 | 0xc2 | 0xc3 => Ok(()),
            0xcc => self.take(1).map(|_| ()),
            0xcd => self.take(2).map(|_| ()),
            0xce => self.take(4).map(|_| ()),
            0xcf => self.take(8).map(|_| ()),
            0xa0..=0xbf => self.take(usize::from(tag & 0x1f)).map(|_| ()),
            0xd9 => {
                let n = usize::from(self.byte()?);
                self.take(n).map(|_| ())
            }
            0xc4 => {
                let n = usize::from(self.byte()?);
                self.take(n).map(|_| ())
            }
            0xc6 => {
                let n = self.be_u32()? as usize;
                self.take(n).map(|_| ())
            }
            0x80..=0x8f => {
                for _ in 0..(tag & 0x0f) {
                    self.skip()?;
                    self.skip()?;
                }
                Ok(())
            }
            0x90..=0x9f => {
                for _ in 0..(tag & 0x0f) {
                    self.skip()?;
                }
                Ok(())
            }
            _ => self.err("unskippable tag"),
        }
    }
}

/// Decode envelope bytes into a frame, tolerating unknown keys.
pub fn decode(bytes: &[u8]) -> Result<Frame, EnvelopeError> {
    let mut c = Cur { b: bytes, i: 0 };
    let tag = c.byte()?;
    let pairs = match tag {
        0x80..=0x8f => usize::from(tag & 0x0f),
        _ => return c.err("envelope must be a fixmap"),
    };
    let mut t: Option<String> = None;
    let mut i: Option<u64> = None;
    let mut m: Option<String> = None;
    let mut b: Option<Vec<u8>> = None;
    let mut a: Option<Vec<u8>> = None;
    let mut e: Option<WireError> = None;
    let mut s: Option<u64> = None;
    let mut n: Option<u64> = None;
    let mut k: Option<String> = None;

    for _ in 0..pairs {
        let key = c.str_()?;
        match key.as_str() {
            "t" => t = Some(c.str_()?),
            "i" => i = Some(c.uint()?),
            "m" => m = Some(c.str_()?),
            "b" => b = Some(c.bin()?),
            "a" => a = Some(c.bin()?),
            "s" => s = Some(c.uint()?),
            "n" => n = Some(c.uint()?),
            "k" => k = Some(c.str_()?),
            "e" => {
                let etag = c.byte()?;
                let epairs = match etag {
                    0x80..=0x8f => usize::from(etag & 0x0f),
                    _ => return c.err("error must be a fixmap"),
                };
                let mut code = String::new();
                let mut text = String::new();
                for _ in 0..epairs {
                    let ekey = c.str_()?;
                    match ekey.as_str() {
                        "c" => code = c.str_()?,
                        "x" => text = c.str_()?,
                        _ => c.skip()?,
                    }
                }
                e = Some(WireError { code, text });
            }
            _ => c.skip()?, // forward compat: unknown keys ignored
        }
    }

    match t.as_deref() {
        Some("q") => match (i, m) {
            (Some(id), Some(method)) => Ok(Frame::Request {
                id,
                method,
                body: b.unwrap_or_default(),
                aux: a.unwrap_or_default(),
            }),
            _ => Err(EnvelopeError("request missing i/m".into())),
        },
        Some("r") => match i {
            Some(id) => Ok(Frame::Response { id, body: b, error: e }),
            None => Err(EnvelopeError("response missing i".into())),
        },
        Some("e") => match (s, n, k) {
            (Some(sub), Some(seq), Some(kind)) => Ok(Frame::Event {
                sub,
                seq,
                kind,
                body: b.unwrap_or_default(),
            }),
            _ => Err(EnvelopeError("event missing s/n/k".into())),
        },
        _ => Err(EnvelopeError("missing/unknown frame type".into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_all_frame_types() {
        let frames = [
            Frame::Request { id: 7, method: "find_search".into(), body: vec![1, 2, 3], aux: vec![] },
            // A request carrying an aux side-channel must also round-trip.
            Frame::Request { id: 9, method: "indent_detect".into(), body: vec![4], aux: vec![5, 6, 7] },
            Frame::Response { id: 7, body: Some(vec![9, 9]), error: None },
            Frame::Response {
                id: 8,
                body: None,
                error: Some(WireError { code: "unknown_method".into(), text: "nope".into() }),
            },
            Frame::Event { sub: 3, seq: 41, kind: "changed".into(), body: vec![] },
        ];
        for f in &frames {
            assert_eq!(&decode(&encode(f)).unwrap(), f, "round trip failed for {f:?}");
        }
    }

    #[test]
    fn large_ids_and_bodies_round_trip() {
        let f = Frame::Request {
            id: u64::MAX,
            method: "m".into(),
            body: vec![0xAB; 70_000], // forces bin32 read path
            aux: vec![],
        };
        assert_eq!(decode(&encode(&f)).unwrap(), f);
    }

    #[test]
    fn unknown_keys_are_skipped_forward_compat() {
        // A future peer adds {z: "future", w: 42, v: [1,2], u: {a: 1}}
        // alongside a valid request — decode must succeed.
        let mut bytes = vec![0x88]; // fixmap(8)
        let mut push = |k: &str, emit: &dyn Fn(&mut Vec<u8>)| {
            super::push_fixstr(&mut bytes, k);
            emit(&mut bytes);
        };
        push("t", &|o| super::push_fixstr(o, "q"));
        push("z", &|o| super::push_fixstr(o, "future"));
        push("i", &|o| super::push_uint(o, 5));
        push("w", &|o| super::push_uint(o, 42));
        push("m", &|o| super::push_fixstr(o, "ping"));
        push("v", &|o| {
            o.push(0x92);
            o.push(0x01);
            o.push(0x02);
        });
        push("u", &|o| {
            o.push(0x81);
            super::push_fixstr(o, "a");
            o.push(0x01);
        });
        push("b", &|o| super::push_bin(o, &[7]));
        let f = decode(&bytes).unwrap();
        assert_eq!(
            f,
            Frame::Request { id: 5, method: "ping".into(), body: vec![7], aux: vec![] }
        );
    }

    #[test]
    fn aux_key_is_omitted_when_empty_but_carried_when_present() {
        // The req-only case must NOT spend bytes on an `a` key — a fixmap(4),
        // byte-identical to the pre-aux wire (forward/backward compat).
        let bare = encode(&Frame::Request {
            id: 1,
            method: "find_search".into(),
            body: vec![1, 2, 3],
            aux: vec![],
        });
        assert_eq!(bare.first(), Some(&0x84), "empty aux ⇒ fixmap(4), no `a` key");

        // A non-empty aux promotes the map to fixmap(5) and survives the
        // round-trip with its bytes intact (the indent/hex bulk channel).
        let withaux = Frame::Request {
            id: 2,
            method: "indent_detect".into(),
            body: vec![0x91, 0x32], // {sample_lines: 50}-ish doc
            aux: b"    a\n    b\n".to_vec(),
        };
        let enc = encode(&withaux);
        assert_eq!(enc.first(), Some(&0x85), "non-empty aux ⇒ fixmap(5)");
        assert_eq!(decode(&enc).unwrap(), withaux, "aux round-trips byte-for-byte");
    }

    #[test]
    fn pre_aux_request_without_a_key_decodes_with_empty_aux() {
        // A peer that predates the aux field sends fixmap(4) {t,i,m,b}. It must
        // decode to a request with an EMPTY aux (no key ⇒ default), so an old
        // client talking to a new server is fine.
        let mut bytes = vec![0x84];
        push_fixstr(&mut bytes, "t");
        push_fixstr(&mut bytes, "q");
        push_fixstr(&mut bytes, "i");
        push_uint(&mut bytes, 3);
        push_fixstr(&mut bytes, "m");
        push_fixstr(&mut bytes, "ping");
        push_fixstr(&mut bytes, "b");
        push_bin(&mut bytes, &[]);
        assert_eq!(
            decode(&bytes).unwrap(),
            Frame::Request { id: 3, method: "ping".into(), body: vec![], aux: vec![] }
        );
    }

    #[test]
    fn malformed_envelopes_error_cleanly() {
        assert!(decode(&[]).is_err());
        assert!(decode(&[0x92]).is_err(), "array is not an envelope");
        // Truncated mid-body.
        let good = encode(&Frame::Request { id: 1, method: "x".into(), body: vec![1, 2, 3], aux: vec![] });
        let cut = good.get(..good.len() - 2).unwrap_or_default();
        assert!(decode(cut).is_err());
        // Request missing method.
        let mut bytes = vec![0x82];
        push_fixstr(&mut bytes, "t");
        push_fixstr(&mut bytes, "q");
        push_fixstr(&mut bytes, "i");
        push_uint(&mut bytes, 1);
        assert!(decode(&bytes).is_err());
    }
}
