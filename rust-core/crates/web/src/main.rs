//! `mdv-web` — a web front-end over `mdvcore-core`.
//!
//! The third of the "one core, three front-ends": the same sans-IO Rust core
//! that backs the SwiftUI app (FFI) and the ratatui TUI also powers this web
//! tier. A hand-rolled, **std-only** HTTP/1.1 server (zero external deps, in
//! the project's minimal-deps spirit) that **server-renders HTML** — no JS
//! framework, no JSON. Feature parity with the TUI: file navigation,
//! text / HEX (`hex::render_all`) / CSV table (`csv::parse`) views, an indent
//! badge (`indent::detect`).
//!
//! **Localhost-only dev tool.** Binds `127.0.0.1` (never exposed on the
//! network), single user, no auth — exactly like the TUI it mirrors, it browses
//! the user's own filesystem. Every file name / path / content byte is
//! HTML-escaped before it reaches the page.
//!
//! Run: `cargo run -p mdvcore-web -- [--port N] [start-dir]` then open the
//! printed `http://127.0.0.1:<port>/`.

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::{fs, thread};

use mdvcore_core::view::{self, ViewBody, ViewMode};

/// Max bytes read into a view (parity with the TUI's preview cap). Per-mode
/// shaping (text/hex/table) lives in the shared `mdvcore_core::view`.
const PREVIEW_CAP: usize = 1024 * 1024;

fn main() -> io::Result<()> {
    let mut port: u16 = 8765;
    let mut start: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        if a == "--port" {
            if let Some(p) = args.next().and_then(|s| s.parse().ok()) {
                port = p;
            }
        } else if !a.starts_with("--") {
            start = Some(PathBuf::from(a));
        }
    }
    let root = start
        .unwrap_or(std::env::current_dir()?)
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from("/"));

    let listener = TcpListener::bind(("127.0.0.1", port))?;
    eprintln!(
        "mdv-web → http://127.0.0.1:{port}/   (serving {}, Ctrl-C to stop)",
        root.display()
    );
    for stream in listener.incoming().flatten() {
        let root = root.clone();
        thread::spawn(move || {
            let _ = handle_conn(stream, &root);
        });
    }
    Ok(())
}

fn handle_conn(mut stream: TcpStream, root: &Path) -> io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut req_line = String::new();
    reader.read_line(&mut req_line)?;
    // Drain (ignore) the remaining request headers.
    loop {
        let mut h = String::new();
        let n = reader.read_line(&mut h)?;
        if n == 0 || h == "\r\n" || h == "\n" {
            break;
        }
    }
    let (status, ctype, body) = route(&req_line, root);
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}

/// Pure routing: request line → (status, content-type, body). Separated from the
/// socket so it's unit-testable.
fn route(req_line: &str, root: &Path) -> (&'static str, &'static str, String) {
    let mut parts = req_line.split_whitespace();
    let _method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let q = parse_query(query);
    const HTML: &str = "text/html; charset=utf-8";
    const TEXT: &str = "text/plain; charset=utf-8";
    match path {
        "/" => ("200 OK", HTML, render_browse(root)),
        "/browse" => {
            let dir = q.get("path").map_or_else(|| root.to_path_buf(), PathBuf::from);
            ("200 OK", HTML, render_browse(&dir))
        }
        "/view" => match q.get("path") {
            Some(p) => (
                "200 OK",
                HTML,
                render_view(Path::new(p), q.get("mode").map(String::as_str)),
            ),
            None => ("400 Bad Request", TEXT, "missing ?path".into()),
        },
        _ => ("404 Not Found", TEXT, "not found".into()),
    }
}

// MARK: - Page rendering

fn render_browse(dir: &Path) -> String {
    page(
        &short(dir),
        &nav_html(dir, None),
        "<p class=\"hint\">Select a file to view its contents.</p>",
    )
}

fn render_view(file: &Path, mode: Option<&str>) -> String {
    let parent = file.parent().unwrap_or(file);
    let name = file_name(file);
    page(
        &name,
        &nav_html(parent, Some(&name)),
        &content_html(file, mode),
    )
}

struct DirEntry {
    name: String,
    is_dir: bool,
}

fn read_entries(dir: &Path) -> Vec<DirEntry> {
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut items: Vec<DirEntry> = rd
        .filter_map(Result::ok)
        .map(|e| DirEntry {
            name: e.file_name().to_string_lossy().into_owned(),
            is_dir: e.file_type().map(|t| t.is_dir()).unwrap_or(false),
        })
        .collect();
    items.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    items
}

fn nav_html(dir: &Path, selected: Option<&str>) -> String {
    let mut s = format!("<div class=\"bar\">{}</div><ul>", esc(&short(dir)));
    if let Some(parent) = dir.parent() {
        s.push_str(&format!(
            "<li class=\"dir\"><a href=\"/browse?path={}\">../</a></li>",
            pct_encode(&parent.to_string_lossy())
        ));
    }
    for e in read_entries(dir) {
        let href = pct_encode(&dir.join(&e.name).to_string_lossy());
        if e.is_dir {
            s.push_str(&format!(
                "<li class=\"dir\"><a href=\"/browse?path={}\">{}/</a></li>",
                href,
                esc(&e.name)
            ));
        } else {
            let cls = if selected == Some(e.name.as_str()) { " class=\"sel\"" } else { "" };
            s.push_str(&format!(
                "<li{}><a href=\"/view?path={}\">{}</a></li>",
                cls,
                href,
                esc(&e.name)
            ));
        }
    }
    s.push_str("</ul>");
    s
}

fn content_html(file: &Path, mode_param: Option<&str>) -> String {
    let (raw, truncated, total) = match read_capped(file, PREVIEW_CAP) {
        Ok(x) => x,
        Err(e) => return format!("<p class=\"hint\">cannot read: {}</p>", esc(&e.to_string())),
    };
    let name = file_name(file);
    let is_tabular = view::looks_tabular(&name);
    let mode = parse_mode(mode_param, is_tabular);
    // The shared core view-model does ALL the shaping (file-type detect, mode
    // set, text/hex/table build, indent badge) — the SAME path the TUI uses.
    let v = view::build(&raw, &name, total, truncated, mode);
    let href = pct_encode(&file.to_string_lossy());

    // Mode switcher from the view's available modes.
    let mut modes = String::from("<div class=\"modes\">");
    for m in &v.available_modes {
        let s = mode_str(*m);
        if *m == v.mode {
            modes.push_str(&format!("<b>{s}</b> "));
        } else {
            modes.push_str(&format!("<a href=\"/view?path={href}&mode={s}\">{s}</a> "));
        }
    }
    modes.push_str("</div>");

    let trunc = if truncated { " · TRUNCATED" } else { "" };
    let bar = format!(
        "<div class=\"bar\">{} · {} · indent: {} · {}{}</div>",
        esc(&name),
        mode_str(v.mode),
        esc(&v.indent),
        human_size(total),
        trunc
    );

    let content = match &v.body {
        ViewBody::Hex(lines) | ViewBody::Text(lines) => format!("<pre>{}</pre>", esc(&lines.join("\n"))),
        ViewBody::Table { header, rows } => table_html(header, rows),
    };
    format!("{modes}{bar}{content}")
}

/// Map the `?mode=` query value to a `ViewMode`, defaulting via the core (and
/// refusing Table for a non-tabular file even if hand-typed in the URL).
fn parse_mode(param: Option<&str>, is_tabular: bool) -> ViewMode {
    match param {
        Some("hex") => ViewMode::Hex,
        Some("text") => ViewMode::Text,
        Some("table") if is_tabular => ViewMode::Table,
        _ => view::default_mode(is_tabular),
    }
}

fn mode_str(m: ViewMode) -> &'static str {
    match m {
        ViewMode::Text => "text",
        ViewMode::Hex => "hex",
        ViewMode::Table => "table",
    }
}

fn table_html(header: &[String], rows: &[Vec<String>]) -> String {
    let mut s = String::from("<table><thead><tr>");
    for h in header {
        s.push_str(&format!("<th>{}</th>", esc(h)));
    }
    s.push_str("</tr></thead><tbody>");
    for row in rows.iter().take(5000) {
        s.push_str("<tr>");
        for c in row {
            s.push_str(&format!("<td>{}</td>", esc(c)));
        }
        s.push_str("</tr>");
    }
    s.push_str("</tbody></table>");
    s
}

fn page(title: &str, nav: &str, main_html: &str) -> String {
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>{t} · mdv-web</title>\
<style>\
*{{box-sizing:border-box}}\
body{{margin:0;font:13px -apple-system,Segoe UI,sans-serif;color:#222;background:#fff}}\
.app{{display:flex;height:100vh}}\
nav{{width:300px;min-width:240px;overflow:auto;border-right:1px solid #ddd;background:#fafafa;padding:8px}}\
nav ul{{list-style:none;margin:0;padding:0}}\
nav li{{padding:2px 4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}\
nav a{{text-decoration:none;color:#1a5fb4}}\
nav .dir a{{color:#0a7;font-weight:600}}\
nav .sel{{background:#1a5fb4;border-radius:4px}} nav .sel a{{color:#fff}}\
main{{flex:1;overflow:auto;padding:12px}}\
.bar{{font:12px ui-monospace,Menlo,monospace;color:#666;margin:6px 0}}\
.modes a,.modes b{{margin-right:10px}}\
pre{{font:12px ui-monospace,Menlo,monospace;white-space:pre;overflow:auto;margin:0}}\
table{{border-collapse:collapse;font:12px ui-monospace,Menlo,monospace}}\
th,td{{border:1px solid #ddd;padding:2px 6px;text-align:left;max-width:320px;overflow:hidden;text-overflow:ellipsis}}\
th{{background:#eef;position:sticky;top:0}}\
.hint{{color:#999}}\
</style></head><body><div class=\"app\"><nav>{nav}</nav><main>{main_html}</main></div></body></html>",
        t = esc(title)
    )
}

// MARK: - Helpers

fn parse_query(query: &str) -> HashMap<String, String> {
    let mut m = HashMap::new();
    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        m.insert(pct_decode(k), pct_decode(v));
    }
    m
}

fn read_capped(path: &Path, cap: usize) -> io::Result<(Vec<u8>, bool, usize)> {
    use std::io::Read;
    let file = fs::File::open(path)?;
    let mut buf = Vec::new();
    file.take(cap as u64 + 1).read_to_end(&mut buf)?;
    let truncated = buf.len() > cap;
    if truncated {
        buf.truncate(cap);
    }
    let total = fs::metadata(path).map(|m| m.len() as usize).unwrap_or(buf.len());
    Ok((buf, truncated, total))
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string())
}

fn human_size(bytes: usize) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}

fn short(path: &Path) -> String {
    let s = path.display().to_string();
    if let Some(home) = std::env::var_os("HOME") {
        let home = home.to_string_lossy();
        if let Some(rest) = s.strip_prefix(home.as_ref()) {
            return format!("~{rest}");
        }
    }
    s
}

/// HTML-escape — every file name / path / content byte passes through here so
/// viewing an `.html` file (or a crafted filename) can't inject markup.
fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => o.push_str("&amp;"),
            '<' => o.push_str("&lt;"),
            '>' => o.push_str("&gt;"),
            '"' => o.push_str("&quot;"),
            '\'' => o.push_str("&#39;"),
            _ => o.push(c),
        }
    }
    o
}

fn pct_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(b as char);
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn pct_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => match (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                (Some(h), Some(l)) => {
                    out.push(h * 16 + l);
                    i += 3;
                }
                _ => {
                    out.push(b'%');
                    i += 1;
                }
            },
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::net::TcpStream;

    fn fixture() -> PathBuf {
        // Unique per call (pid + atomic counter) so parallel tests never share
        // — and thus never `remove_dir_all` each other's fixture mid-run.
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "mdv-web-test-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join("hello.txt"), b"hello <world>\nsecond line\n").unwrap();
        fs::write(dir.join("people.csv"), b"name,age\nAlice,30\nBob,25\n").unwrap();
        fs::write(dir.join("data.bin"), [0x00u8, 0x41, 0xff]).unwrap();
        dir
    }

    #[test]
    fn browse_lists_entries_with_links() {
        let dir = fixture();
        let html = render_browse(&dir);
        assert!(html.contains("hello.txt"), "{html}");
        assert!(html.contains("/browse?path="), "dir link present");
        assert!(html.contains("/view?path="), "file link present");
        assert!(html.contains("sub/"), "subdir shown");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_text_is_escaped() {
        let dir = fixture();
        let html = render_view(&dir.join("hello.txt"), Some("text"));
        assert!(html.contains("hello &lt;world&gt;"), "content HTML-escaped:\n{html}");
        assert!(html.contains("indent:"), "indent badge present");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_hex_uses_core() {
        let dir = fixture();
        let html = render_view(&dir.join("data.bin"), Some("hex"));
        assert!(html.contains("00000000"), "hex offset from core:\n{html}");
        assert!(html.contains("00 41 ff"), "hex bytes from core");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn csv_defaults_to_table_via_core() {
        let dir = fixture();
        let html = render_view(&dir.join("people.csv"), None);
        assert!(html.contains("<table>"), "table rendered:\n{html}");
        assert!(html.contains("<th>name</th>"), "header cell");
        assert!(html.contains("<td>Alice</td>"), "body cell");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn escaping_and_urlcoding_roundtrip() {
        assert_eq!(esc("a<b>&\"'"), "a&lt;b&gt;&amp;&quot;&#39;");
        assert_eq!(pct_decode("%2Ffoo%20bar"), "/foo bar");
        assert_eq!(pct_decode(&pct_encode("/a b/c?d")), "/a b/c?d");
    }

    #[test]
    fn end_to_end_over_a_socket() {
        let dir = fixture();
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let root = dir.clone();
        let h = thread::spawn(move || {
            if let Ok((stream, _)) = listener.accept() {
                let _ = handle_conn(stream, &root);
            }
        });
        let mut conn = TcpStream::connect(("127.0.0.1", port)).unwrap();
        conn.write_all(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
        let mut resp = String::new();
        conn.read_to_string(&mut resp).unwrap();
        h.join().unwrap();
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "status line:\n{resp}");
        assert!(resp.contains("hello.txt"), "served the browse page");
        let _ = fs::remove_dir_all(&dir);
    }
}
