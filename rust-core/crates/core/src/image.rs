//! Minimal, dependency-free raster-image header parser — just enough to identify
//! the format and pull pixel dimensions for a preview card / `<img>` sizing.
//! Pure, sans-IO, and panic-free (every byte access is bounds-checked via
//! `slice::get`, so a short or malformed header yields `None`, never a trap).
//!
//! It deliberately reads only the leading header bytes, so it works on the
//! capped preview read the front-ends already do. Format coverage: PNG, GIF,
//! JPEG (baseline + progressive SOFn), BMP, WEBP (VP8 / VP8L / VP8X). SVG is
//! intentionally excluded — it's text/XML, not a raster format.

/// A recognized raster image format.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ImageKind {
    /// PNG (`image/png`).
    Png,
    /// JPEG (`image/jpeg`).
    Jpeg,
    /// GIF (`image/gif`).
    Gif,
    /// BMP (`image/bmp`).
    Bmp,
    /// WEBP (`image/webp`).
    Webp,
}

impl ImageKind {
    /// The MIME type for a `data:<mime>;base64,…` URI / `Content-Type`.
    #[must_use]
    pub fn mime(self) -> &'static str {
        match self {
            ImageKind::Png => "image/png",
            ImageKind::Jpeg => "image/jpeg",
            ImageKind::Gif => "image/gif",
            ImageKind::Bmp => "image/bmp",
            ImageKind::Webp => "image/webp",
        }
    }

    /// A short human label for a preview card (e.g. `"PNG"`).
    #[must_use]
    pub fn label(self) -> &'static str {
        match self {
            ImageKind::Png => "PNG",
            ImageKind::Jpeg => "JPEG",
            ImageKind::Gif => "GIF",
            ImageKind::Bmp => "BMP",
            ImageKind::Webp => "WEBP",
        }
    }
}

/// An identified image: format + pixel dimensions.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct ImageInfo {
    /// The detected format.
    pub kind: ImageKind,
    /// Pixel width.
    pub width: u32,
    /// Pixel height.
    pub height: u32,
}

/// Whether `name` looks like a (raster) image by extension — the front-ends use
/// this to offer the image view mode and to pick a `data:` URI MIME even when
/// the header bytes can't be parsed. Disjoint from the text/csv/diff sets.
#[must_use]
pub fn looks_image(name: &str) -> bool {
    mime_from_name(name).is_some()
}

/// The image MIME for `name` by extension, or `None` if it isn't a known raster
/// image extension. Used for the `data:` URI so display works in the browser
/// even if [`identify`] couldn't read the dimensions.
#[must_use]
pub fn mime_from_name(name: &str) -> Option<&'static str> {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".png") {
        Some("image/png")
    } else if lower.ends_with(".jpg") || lower.ends_with(".jpeg") {
        Some("image/jpeg")
    } else if lower.ends_with(".gif") {
        Some("image/gif")
    } else if lower.ends_with(".bmp") {
        Some("image/bmp")
    } else if lower.ends_with(".webp") {
        Some("image/webp")
    } else {
        None
    }
}

/// Identify `bytes` as an image and read its pixel dimensions from the header.
/// Returns `None` for an unrecognized signature, a header too short to hold the
/// dimensions, or a malformed field.
#[must_use]
pub fn identify(bytes: &[u8]) -> Option<ImageInfo> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        // IHDR is the first chunk: width @16, height @20 (big-endian u32).
        return Some(ImageInfo { kind: ImageKind::Png, width: be_u32(bytes, 16)?, height: be_u32(bytes, 20)? });
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        // Logical Screen Descriptor: width @6, height @8 (little-endian u16).
        return Some(ImageInfo {
            kind: ImageKind::Gif,
            width: u32::from(le_u16(bytes, 6)?),
            height: u32::from(le_u16(bytes, 8)?),
        });
    }
    if bytes.starts_with(b"BM") {
        // BITMAPINFOHEADER: width @18, height @22 (signed LE i32; height may be
        // negative for a top-down DIB — report the magnitude).
        return Some(ImageInfo {
            kind: ImageKind::Bmp,
            width: le_i32(bytes, 18)?.unsigned_abs(),
            height: le_i32(bytes, 22)?.unsigned_abs(),
        });
    }
    if bytes.starts_with(&[0xFF, 0xD8]) {
        return identify_jpeg(bytes);
    }
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        return identify_webp(bytes);
    }
    None
}

/// JPEG: walk the marker segments until a Start-Of-Frame (SOF0..SOF15, excluding
/// the non-dimension markers C4/C8/CC) and read height @+5, width @+7 (BE u16).
fn identify_jpeg(bytes: &[u8]) -> Option<ImageInfo> {
    let mut i = 2usize; // past the SOI (FF D8)
    loop {
        // Resync to the next marker prefix (0xFF). JPEG allows fill bytes.
        if bytes.get(i)? != &0xFF {
            i = i.checked_add(1)?;
            continue;
        }
        let marker = *bytes.get(i.checked_add(1)?)?;
        // Standalone markers with no length payload: SOI/EOI, RSTn, TEM.
        if marker == 0xD8 || marker == 0xD9 || (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            i = i.checked_add(2)?;
            continue;
        }
        let seg_len = usize::from(be_u16(bytes, i.checked_add(2)?)?);
        let is_sof = matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC);
        if is_sof {
            let height = u32::from(be_u16(bytes, i.checked_add(5)?)?);
            let width = u32::from(be_u16(bytes, i.checked_add(7)?)?);
            return Some(ImageInfo { kind: ImageKind::Jpeg, width, height });
        }
        // Advance past this segment (the 2 marker bytes + the length-prefixed
        // payload, where seg_len counts its own 2 length bytes).
        i = i.checked_add(2)?.checked_add(seg_len)?;
    }
}

/// WEBP: a RIFF container whose first chunk fourcc selects the codec, each with
/// its own dimension encoding.
fn identify_webp(bytes: &[u8]) -> Option<ImageInfo> {
    match bytes.get(12..16)? {
        b"VP8 " => {
            // Lossy keyframe: 14-bit LE width @26, height @28 (top 2 bits are
            // the horizontal/vertical scale, masked off).
            let width = u32::from(le_u16(bytes, 26)? & 0x3FFF);
            let height = u32::from(le_u16(bytes, 28)? & 0x3FFF);
            Some(ImageInfo { kind: ImageKind::Webp, width, height })
        }
        b"VP8L" => {
            // Lossless: after the 0x2F signature @20, 14 bits (width-1) then 14
            // bits (height-1) packed little-endian across bytes 21..25.
            let b0 = u32::from(*bytes.get(21)?);
            let b1 = u32::from(*bytes.get(22)?);
            let b2 = u32::from(*bytes.get(23)?);
            let b3 = u32::from(*bytes.get(24)?);
            let bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
            Some(ImageInfo {
                kind: ImageKind::Webp,
                width: (bits & 0x3FFF) + 1,
                height: ((bits >> 14) & 0x3FFF) + 1,
            })
        }
        b"VP8X" => {
            // Extended: canvas (width-1) @24, (height-1) @27 as 24-bit LE.
            Some(ImageInfo {
                kind: ImageKind::Webp,
                width: le_u24(bytes, 24)? + 1,
                height: le_u24(bytes, 27)? + 1,
            })
        }
        _ => None,
    }
}

fn be_u16(b: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes(b.get(at..at.checked_add(2)?)?.try_into().ok()?))
}

fn be_u32(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(at..at.checked_add(4)?)?.try_into().ok()?))
}

fn le_u16(b: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(b.get(at..at.checked_add(2)?)?.try_into().ok()?))
}

fn le_i32(b: &[u8], at: usize) -> Option<i32> {
    Some(i32::from_le_bytes(b.get(at..at.checked_add(4)?)?.try_into().ok()?))
}

fn le_u24(b: &[u8], at: usize) -> Option<u32> {
    let s = b.get(at..at.checked_add(3)?)?;
    Some(u32::from(*s.first()?) | (u32::from(*s.get(1)?) << 8) | (u32::from(*s.get(2)?) << 16))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_dimensions() {
        let mut b = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
        b.extend_from_slice(&[0, 0, 0, 13]); // IHDR length
        b.extend_from_slice(b"IHDR");
        b.extend_from_slice(&800u32.to_be_bytes()); // width @16
        b.extend_from_slice(&600u32.to_be_bytes()); // height @20
        let info = identify(&b).expect("png");
        assert_eq!(info, ImageInfo { kind: ImageKind::Png, width: 800, height: 600 });
    }

    #[test]
    fn gif_dimensions() {
        let mut b = Vec::from(*b"GIF89a");
        b.extend_from_slice(&320u16.to_le_bytes()); // width @6
        b.extend_from_slice(&240u16.to_le_bytes()); // height @8
        let info = identify(&b).expect("gif");
        assert_eq!(info, ImageInfo { kind: ImageKind::Gif, width: 320, height: 240 });
    }

    #[test]
    fn bmp_dimensions_top_down_is_absolute() {
        let mut b = vec![0u8; 26];
        b[0] = b'B';
        b[1] = b'M';
        b[18..22].copy_from_slice(&100i32.to_le_bytes()); // width @18
        b[22..26].copy_from_slice(&(-50i32).to_le_bytes()); // top-down height @22
        let info = identify(&b).expect("bmp");
        assert_eq!(info, ImageInfo { kind: ImageKind::Bmp, width: 100, height: 50 });
    }

    #[test]
    fn jpeg_dimensions_skip_app0_to_sof0() {
        // SOI, then an APP0 (JFIF) segment to skip, then SOF0 with dimensions.
        let mut b = vec![0xFF, 0xD8];
        b.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]); // APP0, len=4
        b.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08]); // SOF0, len, precision
        b.extend_from_slice(&1080u16.to_be_bytes()); // height @+5
        b.extend_from_slice(&1920u16.to_be_bytes()); // width @+7
        let info = identify(&b).expect("jpeg");
        assert_eq!(info, ImageInfo { kind: ImageKind::Jpeg, width: 1920, height: 1080 });
    }

    #[test]
    fn webp_vp8x_dimensions() {
        // RIFF[0..4] · size[4..8] · WEBP[8..12] · VP8X[12..16] · chunk size
        // [16..20] · flags+reserved[20..24] · canvas (w-1)@24 · (h-1)@27, both
        // 24-bit LE: 1023 → 1024 wide, 767 → 768 tall.
        let mut b = vec![0u8; 30];
        b[0..4].copy_from_slice(b"RIFF");
        b[8..12].copy_from_slice(b"WEBP");
        b[12..16].copy_from_slice(b"VP8X");
        b[24..27].copy_from_slice(&[0xFF, 0x03, 0x00]); // 1023
        b[27..30].copy_from_slice(&[0xFF, 0x02, 0x00]); // 767
        let info = identify(&b).expect("webp");
        assert_eq!(info, ImageInfo { kind: ImageKind::Webp, width: 1024, height: 768 });
    }

    #[test]
    fn non_image_and_truncated_yield_none() {
        assert_eq!(identify(b"not an image"), None);
        assert_eq!(identify(&[]), None);
        // PNG signature but truncated before IHDR dimensions.
        assert_eq!(identify(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]), None);
    }

    #[test]
    fn mime_and_looks_image_by_extension() {
        assert_eq!(mime_from_name("a.PNG"), Some("image/png"));
        assert_eq!(mime_from_name("a.jpeg"), Some("image/jpeg"));
        assert_eq!(mime_from_name("a.webp"), Some("image/webp"));
        assert_eq!(mime_from_name("a.txt"), None);
        assert!(looks_image("photo.gif"));
        assert!(!looks_image("notes.md"));
        // SVG is text/XML, not a raster image — intentionally not matched.
        assert!(!looks_image("icon.svg"));
    }
}
