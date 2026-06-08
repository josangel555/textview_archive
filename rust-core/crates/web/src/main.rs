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
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};
use std::{fs, thread};

use mdvcore_core::filter;
use mdvcore_core::find;
use mdvcore_core::image::{self, ImageInfo};
use mdvcore_core::meta;
use mdvcore_core::nav::{self, SortKey};
use mdvcore_core::outline::{self, Heading};
use mdvcore_core::view::{self, DiffLine, DiffLineKind, FileKind, ViewBody, ViewMode};
use mdvcore_core::whitespace;

/// Max bytes read into a view (parity with the TUI's preview cap). Per-mode
/// shaping (text/hex/table) lives in the shared `mdvcore_core::view`.
const PREVIEW_CAP: usize = 1024 * 1024;

/// Hard ceiling on the bytes consumed parsing the request line + all headers.
/// A client that streams without a terminating blank line (or a multi-GB header
/// line) is cut off here and answered 400 instead of growing a `String` to OOM.
const MAX_HEADER_BYTES: u64 = 16 * 1024;

/// Per-socket read/write timeout. A stalled read (slow-loris, hung tab) returns
/// `WouldBlock`/`TimedOut` instead of parking the worker thread forever, so the
/// thread exits and drops both FDs (the stream and its `try_clone`).
const SOCKET_TIMEOUT: Duration = Duration::from_secs(15);

/// Cap on concurrently-served connections. Past this the listener answers 503
/// and drops the socket rather than spawning an unbounded number of threads /
/// holding unbounded FDs — bounds the blast radius of a runaway local client.
const MAX_INFLIGHT: usize = 128;

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
    let root = Arc::new(root);
    let inflight = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming().flatten() {
        // Reserve a slot; if we're already at the cap, answer 503 and drop the
        // socket instead of spawning an unbounded thread / leaking FDs.
        if inflight.fetch_add(1, Ordering::AcqRel) >= MAX_INFLIGHT {
            inflight.fetch_sub(1, Ordering::AcqRel);
            let _ = refuse_overloaded(stream);
            continue;
        }
        let root = Arc::clone(&root);
        let inflight = Arc::clone(&inflight);
        thread::spawn(move || {
            let _ = handle_conn(stream, &root);
            inflight.fetch_sub(1, Ordering::AcqRel);
        });
    }
    Ok(())
}

/// Best-effort 503 for a connection refused at the concurrency cap. Failures to
/// write are ignored — the socket is dropped either way.
fn refuse_overloaded(mut stream: TcpStream) -> io::Result<()> {
    let _ = stream.set_write_timeout(Some(SOCKET_TIMEOUT));
    const BODY: &str = "server busy: too many in-flight connections";
    let head = format!(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        BODY.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(BODY.as_bytes())?;
    stream.flush()
}

fn handle_conn(mut stream: TcpStream, root: &Path) -> io::Result<()> {
    // Bound stalled reads/writes so a slow-loris / hung client can't park this
    // worker thread (and its two FDs) indefinitely — the read returns an error,
    // the thread unwinds, and both FDs drop (AUDIT S3 DoS hardening).
    stream.set_read_timeout(Some(SOCKET_TIMEOUT))?;
    stream.set_write_timeout(Some(SOCKET_TIMEOUT))?;
    // Cap the bytes consumed parsing the request line + headers so an endless
    // (or giant) header stream is cut off here instead of growing to OOM.
    let mut reader = BufReader::new(stream.try_clone()?.take(MAX_HEADER_BYTES));
    let (status, ctype, body) = match read_request_head(&mut reader) {
        Ok((req_line, host)) if host_allowed(&host) => route(&req_line, root),
        Ok(_) => {
            // A browser ALWAYS sends Host; a non-loopback Host is a cross-origin
            // / DNS-rebind attempt — refuse so a malicious page can't reach the
            // FS.
            ("403 Forbidden", "text/plain; charset=utf-8",
             "refused: Host must be localhost / 127.0.0.1 (anti DNS-rebinding)".to_string())
        }
        // Header section exceeded MAX_HEADER_BYTES (or the socket errored/timed
        // out before a blank-line terminator) — refuse rather than block.
        Err(_) => ("400 Bad Request", "text/plain; charset=utf-8",
                   "request head too large or malformed".to_string()),
    };
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}

/// Read the request line and drain headers from a `MAX_HEADER_BYTES`-capped
/// reader, returning `(request_line, host)`. The reader is a `Take`, so once the
/// cap is hit `read_line` yields `Ok(0)` (EOF) before the blank-line terminator
/// — we surface that as `InvalidData` so the caller answers 400 instead of
/// silently treating a truncated head as complete. `host` is captured for the
/// anti-DNS-rebinding check (AUDIT S1).
fn read_request_head<R: BufRead>(reader: &mut R) -> io::Result<(String, String)> {
    let mut req_line = String::new();
    if reader.read_line(&mut req_line)? == 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "empty request"));
    }
    // A complete request line is newline-terminated; its absence means the cap
    // truncated it mid-line.
    if !req_line.ends_with('\n') {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "request line too large"));
    }
    let mut host = String::new();
    loop {
        let mut h = String::new();
        let n = reader.read_line(&mut h)?;
        if n == 0 {
            // EOF before the blank-line terminator: the header section was cut
            // off by the byte cap (or the peer hung up mid-headers).
            return Err(io::Error::new(io::ErrorKind::InvalidData, "headers too large"));
        }
        if h == "\r\n" || h == "\n" {
            break;
        }
        if let Some(v) = h.to_ascii_lowercase().strip_prefix("host:") {
            host = v.trim().to_string();
        }
    }
    Ok((req_line, host))
}

/// Pure routing: request line → (status, content-type, body). Separated from the
/// socket so it's unit-testable.
fn route(req_line: &str, root: &Path) -> (&'static str, &'static str, String) {
    let mut parts = req_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    const HTML: &str = "text/html; charset=utf-8";
    const TEXT: &str = "text/plain; charset=utf-8";
    if method != "GET" {
        return ("405 Method Not Allowed", TEXT, "only GET is supported".into());
    }
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let q = parse_query(query);
    // Active file-list sort key (default: name), shared by /, /browse and the
    // nav pane of /view — the same dirs-first ordering the TUI applies.
    let sort = q.get("sort").map_or(SortKey::Name, |s| SortKey::from_str_or_name(s));
    // Dotfile visibility (default: hidden). `?hidden=1` reveals dotfiles; the
    // same leading-`.` rule the TUI's `.` toggle applies (`nav::should_show`).
    let show_hidden = q.get("hidden").is_some_and(|h| h == "1");
    // Type-to-narrow quick file find (default: none). `?filter=<needle>` narrows
    // AND ranks the directory listing via the shared `nav::filter_entries`
    // scorer — the same subsequence+prefix ranking the TUI's `f` prompt uses.
    let filter = q.get("filter").map(String::as_str).unwrap_or("");
    match path {
        "/" => ("200 OK", HTML, render_browse(root, sort, show_hidden, filter)),
        // Both /browse and /view confine the requested path UNDER root (AUDIT S2):
        // canonicalize + starts_with closes arbitrary-read / `..` / symlink escape.
        "/browse" => {
            let dir = q.get("path").map_or_else(|| root.to_path_buf(), PathBuf::from);
            match confined(root, &dir) {
                Some(d) => ("200 OK", HTML, render_browse(&d, sort, show_hidden, filter)),
                None => ("404 Not Found", TEXT, "path is outside the served root".into()),
            }
        }
        "/view" => match q.get("path").and_then(|p| confined(root, Path::new(p))) {
            Some(f) => {
                // `?line=<n>` (1-based) jumps to a line: the target row gets an
                // `id="L<n>"` anchor and the page sets a native `#L<n>` fragment
                // so the browser scrolls to it. Parsed leniently — a non-numeric
                // value just means "no jump".
                let line = q.get("line").and_then(|s| s.parse::<usize>().ok());
                // `?tfilter=<needle>` filters CSV table rows (global, or `col:term`
                // for a single column) via the shared `view::table_query` + core
                // `filter`. Ignored for non-table bodies.
                let tfilter = q.get("tfilter").map(String::as_str).unwrap_or("");
                // `?find=<query>` runs the shared in-file content find over the raw
                // bytes; `?fmatch=<i>` (0-based, clamped) selects the current match
                // the page centers + anchors on (see `content_html` / `find_box`).
                let find = q.get("find").map(String::as_str).unwrap_or("");
                let fmatch = q.get("fmatch").and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
                // `?ws=1` reveals whitespace (spaces/tabs → markers) in the Text view.
                let ws = q.get("ws").map(String::as_str) == Some("1");
                // `?wrap=1` soft-wraps long lines in the Text view (default: no wrap).
                let wrap = q.get("wrap").map(String::as_str) == Some("1");
                (
                    "200 OK",
                    HTML,
                    render_view_filtered(
                        &f,
                        q.get("mode").map(String::as_str),
                        sort,
                        show_hidden,
                        line,
                        tfilter,
                        find,
                        fmatch,
                        ws,
                        wrap,
                    ),
                )
            }
            None => ("404 Not Found", TEXT, "path is outside the served root (or missing)".into()),
        },
        _ => ("404 Not Found", TEXT, "not found".into()),
    }
}

/// Reject a present Host header whose host-part isn't loopback. An ABSENT Host is
/// allowed (raw non-browser clients) — browsers always send one, so a missing
/// Host can't be the cross-origin DNS-rebinding vector this guards against.
fn host_allowed(host: &str) -> bool {
    if host.is_empty() {
        return true;
    }
    let hostpart = host.rsplit_once(':').map_or(host, |(h, _)| h);
    hostpart == "127.0.0.1" || hostpart == "localhost" || hostpart == "[::1]" || hostpart == "::1"
}

/// Resolve `candidate` and confine it to `root` (already canonical). Returns the
/// canonical path iff it IS root or strictly under it — the single chokepoint
/// that closes arbitrary file-read, `..` traversal, and symlink-escape.
fn confined(root: &Path, candidate: &Path) -> Option<PathBuf> {
    let c = candidate.canonicalize().ok()?;
    if c == *root || c.starts_with(root) { Some(c) } else { None }
}

// MARK: - Page rendering

fn render_browse(dir: &Path, sort: SortKey, show_hidden: bool, filter: &str) -> String {
    page(
        &short(dir),
        &nav_html(dir, None, sort, show_hidden, filter),
        "<p class=\"hint\">Select a file to view its contents.</p>",
    )
}

fn render_view(
    file: &Path,
    mode: Option<&str>,
    sort: SortKey,
    show_hidden: bool,
    line: Option<usize>,
) -> String {
    render_view_filtered(file, mode, sort, show_hidden, line, "", "", 0, false, false)
}

/// `render_view` plus the active CSV table-filter needle (`?tfilter=`), threaded
/// to `content_html`. The no-filter case is the common one, so `render_view`
/// wraps this with an empty needle.
#[allow(clippy::too_many_arguments)]
fn render_view_filtered(
    file: &Path,
    mode: Option<&str>,
    sort: SortKey,
    show_hidden: bool,
    line: Option<usize>,
    tfilter: &str,
    find: &str,
    fmatch: usize,
    ws: bool,
    wrap: bool,
) -> String {
    let parent = file.parent().unwrap_or(file);
    let name = file_name(file);
    // The file view's nav column lists the parent directory unfiltered — the
    // quick-find needle is a /browse-only narrowing, not carried onto a viewed
    // file (the user has already picked a file).
    page(
        &name,
        &nav_html(parent, Some(&name), sort, show_hidden, ""),
        &content_html(file, mode, line, tfilter, find, fmatch, ws, wrap),
    )
}

/// List `dir`'s entries: dotfile-filtered, dirs-first sorted, and — when
/// `filter` is non-empty — narrowed AND re-ranked best-first by the shared
/// `nav::filter_entries` subsequence+prefix scorer (the same logic behind the
/// TUI's `f` prompt). An empty `filter` is the no-narrowing fast path: the
/// listing is returned in pure sort order.
fn read_entries(dir: &Path, sort: SortKey, show_hidden: bool, filter: &str) -> Vec<nav::Entry> {
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut items: Vec<nav::Entry> = rd
        .filter_map(Result::ok)
        .map(|e| {
            let meta = e.metadata().ok();
            let is_dir = meta.as_ref().map(fs::Metadata::is_dir).unwrap_or(false);
            let size = meta.as_ref().map(fs::Metadata::len).unwrap_or(0);
            let mtime = meta.as_ref().and_then(mtime_secs);
            nav::Entry { name: e.file_name().to_string_lossy().into_owned(), is_dir, mtime, size }
        })
        // Drop dotfiles unless `?hidden=1` — the shared core rule, so web and TUI
        // suppress the same names by construction.
        .filter(|e| nav::should_show(&e.name, show_hidden))
        .collect();
    // Shared core sorter (dirs-first, active key) — the SAME ordering the TUI
    // applies, so the two front-ends list a directory identically.
    nav::sort_entries(&mut items, sort, true);
    if filter.is_empty() {
        return items;
    }
    // Narrow + rank via the shared scorer. We rank against the sorted set so a
    // tie in score falls back to the dirs-first sort order (deterministic).
    let names: Vec<&str> = items.iter().map(|e| e.name.as_str()).collect();
    // Case-insensitive, matching the TUI prompt and the rest of nav's name handling.
    let ranked = nav::filter_entries(&names, filter, false);
    ranked.into_iter().filter_map(|(i, _)| items.get(i).cloned()).collect()
}

/// The `&hidden=1` query suffix to append to a nav/sort link, or `""` when
/// dotfiles are hidden (the default). Threading this onto every link keeps the
/// toggle "sticky" — descending a dir or re-sorting preserves the current state.
fn hidden_q(show_hidden: bool) -> &'static str {
    if show_hidden { "&hidden=1" } else { "" }
}

/// The `&filter=<needle>` query suffix to append to sort/toggle links so the
/// active quick-find narrowing is "sticky" across a re-sort or a dotfile toggle
/// — `""` when no filter is active. The needle is percent-encoded for the URL.
/// (Entry links deliberately do NOT carry this: clicking a file opens it, and
/// descending a directory should start that directory's listing un-narrowed.)
fn filter_q(filter: &str) -> String {
    if filter.is_empty() {
        String::new()
    } else {
        format!("&filter={}", pct_encode(filter))
    }
}

/// Sort-mode link bar: one link per [`SortKey`], the active one bold. Each link
/// re-browses the SAME directory with `?sort=`, so the choice round-trips. The
/// current dotfile state (`&hidden=1`) and quick-find needle (`&filter=`) ride
/// along so re-sorting resets neither.
fn sort_links(dir: &Path, active: SortKey, show_hidden: bool, filter: &str) -> String {
    let dir_q = pct_encode(&dir.to_string_lossy());
    let hq = hidden_q(show_hidden);
    let fq = filter_q(filter);
    let mut s = String::from("<div class=\"sort\">sort: ");
    for k in [SortKey::Name, SortKey::Modified, SortKey::Size] {
        let label = k.as_str();
        if k == active {
            s.push_str(&format!("<b>{label}</b> "));
        } else {
            s.push_str(&format!("<a href=\"/browse?path={dir_q}&sort={label}{hq}{fq}\">{label}</a> "));
        }
    }
    s.push_str("</div>");
    s
}

/// The dotfile-toggle link: re-browses the SAME directory flipping `hidden`,
/// preserving the active sort key and quick-find needle. Label reflects the
/// action it performs.
fn hidden_toggle_link(dir: &Path, sort: SortKey, show_hidden: bool, filter: &str) -> String {
    let dir_q = pct_encode(&dir.to_string_lossy());
    let label = if show_hidden { "hide hidden" } else { "show hidden" };
    // Flip the state: when currently showing, the link drops `hidden`; when
    // hiding, it sets `hidden=1`.
    let next = hidden_q(!show_hidden);
    let fq = filter_q(filter);
    format!(
        "<div class=\"hidden-toggle\"><a href=\"/browse?path={dir_q}&sort={}{next}{fq}\">{label}</a></div>",
        sort.as_str()
    )
}

/// The quick-find box: a JS-free GET form that re-browses the SAME directory
/// with `?filter=<needle>`, carrying the active sort + dotfile state as hidden
/// inputs so submitting the box preserves them. Empty needle = no narrowing.
/// A "clear" link appears when a filter is active. Server-side narrowing means
/// no client JS — the form submit round-trips through `read_entries`.
fn filter_box(dir: &Path, sort: SortKey, show_hidden: bool, filter: &str) -> String {
    let dir_q = pct_encode(&dir.to_string_lossy());
    let hq = hidden_q(show_hidden);
    let mut s = String::from("<form class=\"find\" method=\"get\" action=\"/browse\">");
    // Preserve the directory + sort + dotfile state across the GET submit.
    s.push_str(&format!("<input type=\"hidden\" name=\"path\" value=\"{}\">", esc(&dir.to_string_lossy())));
    s.push_str(&format!("<input type=\"hidden\" name=\"sort\" value=\"{}\">", sort.as_str()));
    if show_hidden {
        s.push_str("<input type=\"hidden\" name=\"hidden\" value=\"1\">");
    }
    s.push_str(&format!(
        "<input type=\"text\" name=\"filter\" value=\"{}\" placeholder=\"find file…\" autofocus>",
        esc(filter)
    ));
    s.push_str("<button type=\"submit\">find</button>");
    if !filter.is_empty() {
        // Clear = re-browse the same dir/sort/hidden with no filter.
        s.push_str(&format!(
            "<a class=\"clear\" href=\"/browse?path={dir_q}&sort={}{hq}\">clear</a>",
            sort.as_str()
        ));
    }
    s.push_str("</form>");
    s
}

/// A clickable breadcrumb trail for `dir` (TSK-230): every ancestor segment is a
/// `/browse?path=` link carrying the sticky sort+hidden state; the final segment
/// (the current directory) renders as plain text. Built from the shared
/// `nav::breadcrumbs` splitter so the web trail and the TUI's are the same by
/// construction. Labels and the encoded link target both pass through `esc` /
/// `pct_encode`, so a crafted directory name can't inject markup or break the URL.
fn breadcrumb_html(dir: &Path, sort: SortKey, show_hidden: bool) -> String {
    let hq = hidden_q(show_hidden);
    let trail = nav::breadcrumbs(&dir.to_string_lossy());
    let last = trail.len().saturating_sub(1);
    let mut s = String::from("<div class=\"crumbs\">");
    for (i, c) in trail.iter().enumerate() {
        if i > 0 {
            s.push_str("<span class=\"sep\">\u{203a}</span>");
        }
        if i == last {
            s.push_str(&format!("<span class=\"here\">{}</span>", esc(&c.label)));
        } else {
            s.push_str(&format!(
                "<a href=\"/browse?path={}&sort={}{hq}\">{}</a>",
                pct_encode(&c.path),
                sort.as_str(),
                esc(&c.label)
            ));
        }
    }
    s.push_str("</div>");
    s
}

fn nav_html(dir: &Path, selected: Option<&str>, sort: SortKey, show_hidden: bool, filter: &str) -> String {
    let hq = hidden_q(show_hidden);
    let mut s = format!(
        "{}{}{}{}<ul>",
        breadcrumb_html(dir, sort, show_hidden),
        filter_box(dir, sort, show_hidden, filter),
        sort_links(dir, sort, show_hidden, filter),
        hidden_toggle_link(dir, sort, show_hidden, filter)
    );
    if let Some(parent) = dir.parent() {
        s.push_str(&format!(
            "<li class=\"dir\"><a href=\"/browse?path={}&sort={}{hq}\">../</a></li>",
            pct_encode(&parent.to_string_lossy()),
            sort.as_str()
        ));
    }
    // Entry links deliberately omit the `&filter=` needle: clicking a file
    // opens it, and descending into a sub-dir should list it un-narrowed (the
    // needle was about THIS directory). The sticky carriers are sort + hidden.
    for e in read_entries(dir, sort, show_hidden, filter) {
        let href = pct_encode(&dir.join(&e.name).to_string_lossy());
        if e.is_dir {
            s.push_str(&format!(
                "<li class=\"dir\"><a href=\"/browse?path={}&sort={}{hq}\">{}/</a></li>",
                href,
                sort.as_str(),
                esc(&e.name)
            ));
        } else {
            let cls = if selected == Some(e.name.as_str()) { " class=\"sel\"" } else { "" };
            s.push_str(&format!(
                "<li{}><a href=\"/view?path={}&sort={}{hq}\">{}</a></li>",
                cls,
                href,
                sort.as_str(),
                esc(&e.name)
            ));
        }
    }
    s.push_str("</ul>");
    s
}

#[allow(clippy::too_many_arguments)]
fn content_html(
    file: &Path,
    mode_param: Option<&str>,
    line: Option<usize>,
    tfilter: &str,
    find: &str,
    fmatch: usize,
    ws: bool,
    wrap: bool,
) -> String {
    let (raw, truncated, total) = match read_capped(file, PREVIEW_CAP) {
        Ok(x) => x,
        Err(e) => return format!("<p class=\"hint\">cannot read: {}</p>", esc(&e.to_string())),
    };
    let name = file_name(file);
    let kind = view::classify(&name);
    let mode = parse_mode(mode_param, kind);
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
    // Encoding + line-ending badge and file-metadata metrics (shared `core::meta`,
    // same logic as the TUI) — Text mode only; HEX/table/image show raw bytes or
    // structured data. The badge content is digits + a fixed safe label set (no
    // HTML metacharacters), so no escaping is needed.
    let badge = if v.mode == ViewMode::Text {
        let lossy = String::from_utf8_lossy(&raw);
        let m = meta::text_metrics(&lossy);
        format!(
            " · {} · {} · {} lines · {} words",
            meta::encoding_label(&raw),
            meta::line_ending(&raw).as_str(),
            m.lines,
            m.words
        )
    } else {
        String::new()
    };
    let bar = format!(
        "<div class=\"bar\">{} · {} · indent: {} · {}{}{}</div>",
        esc(&name),
        mode_str(v.mode),
        esc(&v.indent),
        human_size(total),
        badge,
        trunc
    );

    // Markdown outline: for a `.md` file rendered as text, scan the RAW bytes
    // for headings (shared `outline::headings`) and offer a clickable TOC. Each
    // entry is a native `#L<line>` fragment link; the matching source rows carry
    // `id="L<line>"` anchors (added to the gutter below) so the jump needs no JS.
    // The outline is text-mode only — a hex/table view has no source lines to
    // anchor against.
    let headings = if v.mode == ViewMode::Text && outline::is_markdown(&name) {
        outline::headings(&String::from_utf8_lossy(&raw), &name)
    } else {
        Vec::new()
    };
    let outline_nav = outline_html(&headings);

    let content = match &v.body {
        ViewBody::Hex(lines) | ViewBody::Text(lines) => {
            // In-file content find (TSK-198): when `?find=` is set, run the shared
            // `find::find_matches` over the RAW bytes (mode-independent, like the
            // outline) and steer the existing line-jump machinery to the current
            // match's line — the matched row gets the same `id="L<n>"` anchor +
            // `.cur` highlight as go-to-line, and the find box's prev/next links
            // carry `#L<n>` so the browser scrolls natively (no JS). `?fmatch=<i>`
            // (clamped) selects which match is current.
            let matches = if find.is_empty() {
                Vec::new()
            } else {
                find::find_matches(&String::from_utf8_lossy(&raw), find, find::Case::Insensitive)
            };
            let find_nav = find_box(&href, mode_str(v.mode), find, fmatch, &matches, lines.len());
            // An active find overrides `?line=` so the page centers on the match;
            // otherwise honor the go-to-line target.
            let target = if matches.is_empty() {
                line.map(|n| view::clamp_line(n, lines.len()))
            } else {
                let fi = fmatch.min(matches.len() - 1);
                Some(view::clamp_line(matches[fi].line + 1, lines.len()))
            };
            let goto = goto_box(&href, mode_str(v.mode), target);
            // Anchor every heading line (not just the goto target) so the outline
            // links resolve; the set is empty for non-markdown / non-text views.
            let anchors: Vec<usize> = headings.iter().map(|h| h.line).collect();
            // Show-invisibles (TSK-242): reveal spaces/tabs as markers via the
            // shared core, Text mode only (HEX shows raw bytes). Build the revealed
            // lines only when the toggle is on to avoid cloning otherwise.
            let revealed: Vec<String>;
            let display: &[String] = if ws && v.mode == ViewMode::Text {
                revealed = lines.iter().map(|l| whitespace::reveal(l)).collect();
                &revealed
            } else {
                lines
            };
            format!("{}{}{}", find_nav, goto, gutter_html(display, target, &anchors))
        }
        ViewBody::Table { header, rows, truncated } => {
            // Apply the active CSV filter (shared `view::table_query` + core
            // `filter`); a `col:term` needle scopes to a column, else global. The
            // filter box rides above the table and is "sticky" via `?tfilter=`.
            let query = view::table_query(header, tfilter);
            let (_, shown) = filter::apply_rows(rows, &query);
            let box_html = table_filter_box(&href, mode_str(v.mode), tfilter, shown.len(), rows.len());
            format!("{}{}", box_html, table_html(header, &shown, *truncated))
        }
        ViewBody::Diff(lines) => diff_html(lines),
        ViewBody::Image(info) => image_html(&name, &raw, *info, truncated),
    };
    // Whitespace-markers toggle link (Text mode only): flips `?ws=` and preserves
    // the path + mode. Labels reflect the current state.
    // Current-state strings so each toggle link preserves the OTHER flag on click.
    let cur_ws = if ws { "1" } else { "0" };
    let cur_wrap = if wrap { "1" } else { "0" };
    let ws_link = if v.mode == ViewMode::Text {
        let (label, next) = if ws { ("hide whitespace", "0") } else { ("show whitespace", "1") };
        format!(
            "<div class=\"wstoggle\"><a href=\"/view?path={href}&mode={}&ws={next}&wrap={cur_wrap}\">{label}</a></div>",
            mode_str(v.mode)
        )
    } else {
        String::new()
    };
    // Word-wrap toggle (TSK-232): a `?wrap=` link + an inline override flipping the
    // `.src` pane to soft-wrap (the base stylesheet is `white-space:pre`).
    let wrap_link = if v.mode == ViewMode::Text {
        let (label, next) = if wrap { ("nowrap", "0") } else { ("wrap", "1") };
        format!(
            "<div class=\"wraptoggle\"><a href=\"/view?path={href}&mode={}&ws={cur_ws}&wrap={next}\">{label}</a></div>",
            mode_str(v.mode)
        )
    } else {
        String::new()
    };
    let wrap_style = if wrap && v.mode == ViewMode::Text {
        "<style>.src{white-space:pre-wrap;overflow-wrap:anywhere}</style>"
    } else {
        ""
    };
    format!("{modes}{bar}{ws_link}{wrap_link}{wrap_style}{outline_nav}{content}")
}

/// The go-to-line box: a JS-free GET form that reloads `/view` with `?line=<n>`.
/// On reload the server clamps the line, tags that row `id="L<n>"`, and — because
/// the form's submit lands on a page whose target row carries the id — a "scroll
/// to line" anchor link beside the form jumps there natively via the `#L<n>`
/// fragment (no client JS). When a line is already targeted the box echoes it and
/// renders the live `#L<n>` jump link so a reload re-centers without retyping.
fn goto_box(href: &str, mode: &str, target: Option<usize>) -> String {
    let mut s = String::from("<form class=\"goto\" method=\"get\" action=\"/view\">");
    // Preserve the file path + active mode across the GET submit.
    s.push_str(&format!("<input type=\"hidden\" name=\"path\" value=\"{}\">", esc(&pct_decode(href))));
    s.push_str(&format!("<input type=\"hidden\" name=\"mode\" value=\"{}\">", esc(mode)));
    let val = target.map_or(String::new(), |n| n.to_string());
    s.push_str(&format!(
        "<input type=\"number\" name=\"line\" min=\"1\" value=\"{val}\" placeholder=\"line #\">"
    ));
    s.push_str("<button type=\"submit\">go to line</button>");
    if let Some(n) = target {
        // A native fragment link to the tagged row — clicking it (or following
        // it after the reload) scrolls the browser to line n with no JS.
        s.push_str(&format!("<a class=\"jump\" href=\"#L{n}\">jump to {n}</a>"));
    }
    s.push_str("</form>");
    s
}

/// The in-file find box (TSK-198): a JS-free GET form that reloads `/view` with
/// `?find=<query>`. The server runs the shared `find::find_matches` over the raw
/// bytes; this box echoes the query, shows the `i of n` match count, and renders
/// prev/next anchor links that bump `?fmatch=` (wrapping) and carry the matching
/// row's `#L<n>` fragment so the browser scrolls there natively (no client JS) —
/// the same line-anchor mechanism go-to-line uses. An empty query renders just
/// the input; a query with no hits shows "no matches".
fn find_box(
    href: &str,
    mode: &str,
    find: &str,
    fmatch: usize,
    matches: &[find::Match],
    content_len: usize,
) -> String {
    let mut s = String::from("<form class=\"find\" method=\"get\" action=\"/view\">");
    s.push_str(&format!("<input type=\"hidden\" name=\"path\" value=\"{}\">", esc(&pct_decode(href))));
    s.push_str(&format!("<input type=\"hidden\" name=\"mode\" value=\"{}\">", esc(mode)));
    s.push_str(&format!(
        "<input type=\"text\" name=\"find\" value=\"{}\" placeholder=\"find in file\">",
        esc(find)
    ));
    s.push_str("<button type=\"submit\">find</button>");
    if !find.is_empty() {
        if matches.is_empty() {
            s.push_str("<span class=\"count\">no matches</span>");
        } else {
            let n = matches.len();
            let cur = fmatch.min(n - 1);
            let fq = pct_encode(find);
            // Wrapping prev/next; each carries the target row's `#L<line>` so the
            // browser jumps natively. `content_len` clamps an out-of-range line.
            let link = |idx: usize, label: &str| -> String {
                let line = view::clamp_line(matches[idx].line + 1, content_len);
                format!(
                    "<a class=\"jump\" href=\"/view?path={href}&mode={mode}&find={fq}&fmatch={idx}#L{line}\">{label}</a>"
                )
            };
            let prev = (cur + n - 1) % n;
            let next = (cur + 1) % n;
            s.push_str(&link(prev, "prev"));
            s.push_str(&link(next, "next"));
            s.push_str(&format!("<span class=\"count\">{} of {n}</span>", cur + 1));
        }
    }
    s.push_str("</form>");
    s
}

/// Map the `?mode=` query value to a `ViewMode`, defaulting via the core (and
/// refusing Table for a non-tabular file even if hand-typed in the URL).
fn parse_mode(param: Option<&str>, kind: FileKind) -> ViewMode {
    match param {
        Some("hex") => ViewMode::Hex,
        Some("text") => ViewMode::Text,
        Some("table") if kind == FileKind::Tabular => ViewMode::Table,
        Some("diff") if kind == FileKind::Diff => ViewMode::Diff,
        Some("image") if kind == FileKind::Image => ViewMode::Image,
        Some("formatted") if kind == FileKind::Structured => ViewMode::Formatted,
        _ => view::default_mode(kind),
    }
}

fn mode_str(m: ViewMode) -> &'static str {
    match m {
        ViewMode::Text => "text",
        ViewMode::Hex => "hex",
        ViewMode::Table => "table",
        ViewMode::Diff => "diff",
        ViewMode::Image => "image",
        ViewMode::Formatted => "formatted",
    }
}

/// Render text/HEX lines as a two-column layout: a non-selectable gutter of
/// right-aligned 1-based line numbers beside the content `<pre>`. The gutter is
/// `user-select:none` (CSS) so copying the content never drags the line numbers
/// in. Numbers track each line's original index; the gutter is right-padded to
/// the shared `view::gutter_width` so the column is flush. Both panes share the
/// same monospace line-height, so row N lines up with line N.
///
/// `target` (1-based, already `clamp_line`-bounded) is the go-to-line row: its
/// gutter number is wrapped in `<span id="L<n>" class="cur">` so a `#L<n>` URL
/// fragment scrolls the browser there natively (no JS), and the matching source
/// line is wrapped in a `<span class="cur">` so the row is visibly highlighted.
/// `None` renders a plain gutter (the un-targeted case).
///
/// `anchors` is the set of additional 1-based lines that get an `id="L<n>"`
/// anchor *without* the highlight — the markdown-outline heading rows, so a
/// `#L<line>` fragment from the outline TOC scrolls to the heading natively (no
/// JS). The goto `target`, when set, already anchors+highlights its own row;
/// an anchor that coincides with the target is subsumed by it (no duplicate id).
fn gutter_html(lines: &[String], target: Option<usize>, anchors: &[usize]) -> String {
    let gw = view::gutter_width(lines.len());
    // Build the gutter column (numbers, newline-joined) and the content column
    // (the lines, newline-joined + escaped) as two parallel `<pre>` blocks. Both
    // are pre-escaped per-segment; the only raw markup injected is the static
    // `<span>` wrappers around the (escaped) target / anchored rows.
    let mut nums = String::new();
    let mut src = String::new();
    for (i, raw_line) in lines.iter().enumerate() {
        if i > 0 {
            nums.push('\n');
            src.push('\n');
        }
        // 1-based, right-aligned to the gutter width (decimal digits).
        let n = i + 1;
        let label = esc(&format!("{n:>gw$}"));
        let line = esc(raw_line);
        if target == Some(n) {
            // Anchor + highlight the target row. The id lives in the gutter so a
            // `#L<n>` fragment scrolls here; both panes get the `.cur` highlight.
            nums.push_str(&format!("<span id=\"L{n}\" class=\"cur\">{label}</span>"));
            src.push_str(&format!("<span class=\"cur\">{line}</span>"));
        } else if anchors.contains(&n) {
            // A heading row from the outline: anchor (so the TOC `#L<n>` link
            // scrolls here) but no highlight — it isn't the active goto target.
            nums.push_str(&format!("<span id=\"L{n}\">{label}</span>"));
            src.push_str(&line);
        } else {
            nums.push_str(&label);
            src.push_str(&line);
        }
    }
    format!(
        "<div class=\"code\"><pre class=\"gutter\" aria-hidden=\"true\">{nums}</pre><pre class=\"src\">{src}</pre></div>"
    )
}

/// Render the markdown outline as a collapsible `<nav>` table-of-contents: one
/// `<a href="#L<line>">` per heading, indented by level via a `data-lvl` class
/// (`lvl1`..`lvl6`). The fragment links resolve against the `id="L<line>"`
/// anchors `gutter_html` tags on the heading rows, so clicking an entry scrolls
/// to the heading natively (no JS). Returns `""` for an empty heading list (a
/// non-markdown file, or one with no headings) so nothing renders.
fn outline_html(headings: &[Heading]) -> String {
    if headings.is_empty() {
        return String::new();
    }
    let mut s = String::from("<details class=\"outline\" open><summary>outline</summary><ul>");
    for h in headings {
        let lvl = h.level.clamp(1, 6);
        s.push_str(&format!(
            "<li class=\"lvl{lvl}\"><a href=\"#L{}\">{}</a></li>",
            h.line,
            esc(&h.title)
        ));
    }
    s.push_str("</ul></details>");
    s
}

/// The CSV table-filter box: a JS-free GET form that reloads `/view` with
/// `?tfilter=<needle>`, carrying the active path + mode as hidden fields so the
/// filter is "sticky". Shows the surviving/total row count and a clear link when
/// a filter is active. `href` is the percent-encoded path (as used by `goto_box`).
fn table_filter_box(href: &str, mode: &str, tfilter: &str, shown: usize, total: usize) -> String {
    let mut s = String::from("<form class=\"find\" method=\"get\" action=\"/view\">");
    s.push_str(&format!("<input type=\"hidden\" name=\"path\" value=\"{}\">", esc(&pct_decode(href))));
    s.push_str(&format!("<input type=\"hidden\" name=\"mode\" value=\"{mode}\">"));
    s.push_str(&format!(
        "<input type=\"text\" name=\"tfilter\" value=\"{}\" placeholder=\"filter rows (col:term)\u{2026}\">",
        esc(tfilter)
    ));
    s.push_str("<button type=\"submit\">filter</button>");
    if !tfilter.is_empty() {
        s.push_str(&format!(
            "<a class=\"clear\" href=\"/view?path={href}&mode={mode}\">clear</a>\
             <span class=\"count\">{shown}/{total} rows</span>"
        ));
    }
    s.push_str("</form>");
    s
}

fn table_html(header: &[String], rows: &[Vec<String>], truncated: bool) -> String {
    // PARSE-04: a clamped table (a row had more columns than the header, or the
    // row/col caps fired) must be flagged so it isn't read as the complete data
    // (TSK-155). Distinct from any byte-cap banner the caller may add.
    let mut s = if truncated {
        String::from("<div class=\"hint\">\u{26a0} Table truncated at parse time \
            (a row exceeded the header width or the size cap fired) \u{2014} \
            some cells were clamped.</div>")
    } else {
        String::new()
    };
    s.push_str("<table><thead><tr>");
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

/// Render a unified diff as a `<pre>` where each line carries a `diff-*` class
/// (per the shared core's [`view::classify_diff_line`]) so added/removed/header/
/// hunk lines are colored. Works for git-format and plain unified diffs alike
/// (the core classifies by leading char, not by `diff --git` structure).
fn diff_html(lines: &[DiffLine]) -> String {
    let mut s = String::from("<pre class=\"diff\">");
    for dl in lines {
        let cls = match dl.kind {
            DiffLineKind::FileHeader => "diff-file",
            DiffLineKind::Hunk => "diff-hunk",
            DiffLineKind::Added => "diff-add",
            DiffLineKind::Removed => "diff-del",
            DiffLineKind::Context => "diff-ctx",
        };
        s.push_str(&format!("<span class=\"{cls}\">{}</span>\n", esc(&dl.text)));
    }
    s.push_str("</pre>");
    s
}

/// Render a raster image: a dimensions/format card plus the image itself,
/// inlined as a base64 `data:` URI so it displays without a separate binary
/// route (the bytes already rode through the path-confined `/view` request). A
/// file truncated at the read cap can't be inlined (the bytes are incomplete),
/// so it shows the card + a notice instead of a broken `<img>`.
fn image_html(name: &str, raw: &[u8], info: Option<ImageInfo>, truncated: bool) -> String {
    let mut s = String::from("<div class=\"imgcard\">");
    if let Some(i) = info {
        s.push_str(&format!(
            "<b>{} image</b> · {} × {} px · {}",
            i.kind.label(),
            i.width,
            i.height,
            human_size(raw.len())
        ));
    } else {
        s.push_str(&format!("<b>image</b> · dimensions unavailable · {}", human_size(raw.len())));
    }
    s.push_str("</div>");
    if truncated {
        s.push_str(
            "<p class=\"hint\">\u{26a0} file exceeds the preview cap — too large to display inline.</p>",
        );
        return s;
    }
    let mime = image::mime_from_name(name).unwrap_or("application/octet-stream");
    s.push_str(&format!(
        "<img class=\"imgview\" alt=\"{}\" src=\"data:{};base64,{}\">",
        esc(name),
        mime,
        base64_encode(raw)
    ));
    s
}

/// Standard base64 (RFC 4648) with `=` padding. Hand-rolled to keep the web tier
/// dependency-free; only used to inline a capped (≤1 MiB) image as a data URI.
fn base64_encode(data: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = u32::from(chunk.first().copied().unwrap_or(0));
        let b1 = u32::from(chunk.get(1).copied().unwrap_or(0));
        let b2 = u32::from(chunk.get(2).copied().unwrap_or(0));
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(A[((triple >> 18) & 0x3F) as usize] as char);
        out.push(A[((triple >> 12) & 0x3F) as usize] as char);
        out.push(if chunk.len() > 1 { A[((triple >> 6) & 0x3F) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { A[(triple & 0x3F) as usize] as char } else { '=' });
    }
    out
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
.crumbs{{font:12px ui-monospace,Menlo,monospace;color:#666;margin:6px 0;word-break:break-all}}\
.crumbs a{{color:#1a5fb4;text-decoration:none}}\
.crumbs .sep{{color:#bbb;margin:0 4px}} .crumbs .here{{color:#333;font-weight:600}}\
.find{{display:flex;gap:4px;align-items:center;margin:0 0 6px;flex-wrap:wrap}}\
.find input[type=text]{{flex:1;min-width:80px;font:12px -apple-system,Segoe UI,sans-serif;padding:3px 6px;border:1px solid #ccc;border-radius:4px}}\
.find button{{font:11px -apple-system,Segoe UI,sans-serif;padding:3px 8px;border:1px solid #ccc;border-radius:4px;background:#fff;cursor:pointer}}\
.find .clear{{font:11px -apple-system,Segoe UI,sans-serif;color:#1a5fb4;text-decoration:none}}\
.find .count{{font:11px ui-monospace,Menlo,monospace;color:#888;margin-left:4px}}\
.sort{{font:11px -apple-system,Segoe UI,sans-serif;color:#888;margin:0 0 4px}}\
.sort a{{color:#1a5fb4;margin-right:6px}} .sort b{{margin-right:6px;color:#333}}\
.hidden-toggle{{font:11px -apple-system,Segoe UI,sans-serif;margin:0 0 8px}}\
.hidden-toggle a{{color:#1a5fb4}}\
.modes a,.modes b{{margin-right:10px}}\
.outline{{margin:0 0 10px;border:1px solid #e3e3e3;border-radius:6px;padding:4px 10px;background:#fafafa}}\
.outline summary{{cursor:pointer;font:11px -apple-system,Segoe UI,sans-serif;color:#666;user-select:none}}\
.outline ul{{list-style:none;margin:4px 0 2px;padding:0}}\
.outline li{{padding:1px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}\
.outline a{{text-decoration:none;color:#1a5fb4}}\
.outline .lvl1{{padding-left:0;font-weight:600}}\
.outline .lvl2{{padding-left:14px}} .outline .lvl3{{padding-left:28px}}\
.outline .lvl4{{padding-left:42px}} .outline .lvl5{{padding-left:56px}}\
.outline .lvl6{{padding-left:70px}}\
.goto{{display:flex;gap:4px;align-items:center;margin:0 0 6px;flex-wrap:wrap}}\
.goto input[type=number]{{width:90px;font:12px -apple-system,Segoe UI,sans-serif;padding:3px 6px;border:1px solid #ccc;border-radius:4px}}\
.goto button{{font:11px -apple-system,Segoe UI,sans-serif;padding:3px 8px;border:1px solid #ccc;border-radius:4px;background:#fff;cursor:pointer}}\
.goto .jump{{font:11px -apple-system,Segoe UI,sans-serif;color:#1a5fb4;text-decoration:none}}\
pre{{font:12px ui-monospace,Menlo,monospace;white-space:pre;overflow:auto;margin:0}}\
.code{{display:flex;align-items:flex-start}}\
.code pre{{line-height:1.4}}\
.gutter{{-webkit-user-select:none;user-select:none;text-align:right;color:#999;padding-right:10px;border-right:1px solid #eee;margin-right:10px;overflow:visible;flex:none}}\
.src{{flex:1}}\
.code .cur{{background:#fff3b0;scroll-margin-top:12px}}\
table{{border-collapse:collapse;font:12px ui-monospace,Menlo,monospace}}\
th,td{{border:1px solid #ddd;padding:2px 6px;text-align:left;max-width:320px;overflow:hidden;text-overflow:ellipsis}}\
th{{background:#eef;position:sticky;top:0}}\
.hint{{color:#999}}\
pre.diff{{line-height:1.4}}\
pre.diff span{{display:block}}\
.diff-file{{color:#1a5fb4;font-weight:600}}\
.diff-hunk{{color:#7a3fb4;background:#f3eefb}}\
.diff-add{{color:#0a7d28;background:#e9f7ec}}\
.diff-del{{color:#c01c28;background:#fbecec}}\
.diff-ctx{{color:#444}}\
.imgcard{{font:12px ui-monospace,Menlo,monospace;color:#444;margin:0 0 10px;padding:6px 10px;border:1px solid #e3e3e3;border-radius:6px;background:#fafafa}}\
.imgview{{max-width:100%;height:auto;border:1px solid #ddd;border-radius:4px;background:repeating-conic-gradient(#eee 0% 25%,#fff 0% 50%) 50%/16px 16px}}\
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

/// Modification time of `meta` as whole seconds since the Unix epoch, or `None`
/// when unavailable (platform without mtime / pre-epoch time) — fed to the
/// shared `nav::Entry` for the `modified` sort key.
fn mtime_secs(meta: &fs::Metadata) -> Option<u64> {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
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
        // Compact JSON so the `Formatted` mode visibly re-indents it (TSK-218).
        fs::write(dir.join("config.json"), br#"{"a":1,"b":[2,3]}"#).unwrap();
        // A markdown file with ATX headings + a fenced `#` decoy, for the outline.
        fs::write(
            dir.join("doc.md"),
            b"# Title\nintro\n\n## Section A\n```\n# fenced decoy\n```\n\n## Section B\n",
        )
        .unwrap();
        // A dotfile, hidden by default (revealed via `?hidden=1`).
        fs::write(dir.join(".secret"), b"hidden\n").unwrap();
        // A plain unified diff (NO `diff --git` header) — exercises the
        // leading-char classifier, not the git-structured parser.
        fs::write(
            dir.join("change.diff"),
            b"--- a/x.rs\n+++ b/x.rs\n@@ -1,2 +1,2 @@\n-old line\n+new line\n unchanged\n",
        )
        .unwrap();
        // A minimal PNG (signature + IHDR with width/height) — enough for the
        // image card + data-URI inlining; the bytes need not be a decodable image.
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
        png.extend_from_slice(&[0, 0, 0, 13]);
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&16u32.to_be_bytes());
        png.extend_from_slice(&8u32.to_be_bytes());
        fs::write(dir.join("pixel.png"), &png).unwrap();
        dir
    }

    #[test]
    fn browse_lists_entries_with_links() {
        let dir = fixture();
        let html = render_browse(&dir, SortKey::Name, false, "");
        assert!(html.contains("hello.txt"), "{html}");
        assert!(html.contains("/browse?path="), "dir link present");
        assert!(html.contains("/view?path="), "file link present");
        assert!(html.contains("sub/"), "subdir shown");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_renders_clickable_breadcrumb_trail() {
        let dir = fixture();
        let html = render_browse(&dir, SortKey::Name, false, "");
        // The breadcrumb container is present, and the current dir is the final
        // (plain-text, non-link) segment.
        assert!(html.contains("class=\"crumbs\""), "breadcrumb bar present:\n{html}");
        let leaf = file_name(&dir);
        assert!(
            html.contains(&format!("<span class=\"here\">{}</span>", esc(&leaf))),
            "current dir is the non-link leaf crumb:\n{html}"
        );
        // Ancestor segments are /browse links carrying the active sort. The temp
        // dir lives under at least one ancestor, so a parent crumb link exists.
        let parent = dir.parent().unwrap();
        let parent_q = pct_encode(&parent.to_string_lossy());
        assert!(
            html.contains(&format!("/browse?path={parent_q}&sort=name")),
            "parent crumb is a sort-carrying /browse link:\n{html}"
        );
        // The root crumb is always a link to "/".
        assert!(html.contains("/browse?path=/&sort=name"), "root crumb links to /:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_renders_sort_links_with_active_bold() {
        let dir = fixture();
        let html = render_browse(&dir, SortKey::Size, false, "");
        // The sort bar offers all three keys; entry links carry the active key.
        assert!(html.contains("class=\"sort\""), "sort bar present:\n{html}");
        assert!(html.contains("<b>size</b>"), "active key is bold");
        assert!(html.contains("&sort=name"), "name link present");
        assert!(html.contains("&sort=modified"), "modified link present");
        assert!(html.contains("&sort=size"), "entry links carry active sort");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_sort_param_is_honored_through_route() {
        let root = fixture().canonicalize().unwrap();
        // ?sort=size must bold the size key (proving route → render_browse threads
        // the param), not the default name.
        let target = format!(
            "GET /browse?path={}&sort=size HTTP/1.1",
            pct_encode(&root.to_string_lossy())
        );
        let (status, _, body) = route(&target, &root);
        assert!(status.starts_with("200"), "browse ok, got {status}");
        assert!(body.contains("<b>size</b>"), "size key active via ?sort=:\n{body}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn browse_hides_dotfiles_by_default_and_offers_toggle() {
        let dir = fixture();
        let html = render_browse(&dir, SortKey::Name, false, "");
        // Dotfiles suppressed; ordinary files shown; a "show hidden" link offered.
        assert!(!html.contains(".secret"), "dotfile suppressed by default:\n{html}");
        assert!(html.contains("hello.txt"), "ordinary file still listed");
        assert!(html.contains("class=\"hidden-toggle\""), "toggle bar present");
        assert!(html.contains(">show hidden</a>"), "offers to reveal dotfiles");
        // The reveal link sets ?hidden=1.
        assert!(html.contains("&hidden=1"), "toggle link sets hidden=1:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_with_hidden_shows_dotfiles_and_sticks_to_links() {
        let dir = fixture();
        let html = render_browse(&dir, SortKey::Name, true, "");
        // Dotfile now listed; toggle flips to "hide hidden".
        assert!(html.contains(".secret"), "dotfile revealed with show_hidden:\n{html}");
        assert!(html.contains(">hide hidden</a>"), "toggle offers to re-hide");
        // The entry links (e.g. the file view) thread hidden=1 so the state is
        // sticky — clicking a file or sub-dir won't silently drop the toggle.
        assert!(
            html.contains("/view?path=") && html.contains("&hidden=1"),
            "entry links carry hidden=1 so the toggle survives navigation:\n{html}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_hidden_param_is_honored_through_route() {
        let root = fixture().canonicalize().unwrap();
        let base = pct_encode(&root.to_string_lossy());
        // Default route hides the dotfile.
        let (status, _, body) = route(&format!("GET /browse?path={base} HTTP/1.1"), &root);
        assert!(status.starts_with("200"), "browse ok, got {status}");
        assert!(!body.contains(".secret"), "default route hides dotfiles:\n{body}");
        // ?hidden=1 reveals it (proves route → render_browse threads the flag).
        let (status, _, body) =
            route(&format!("GET /browse?path={base}&hidden=1 HTTP/1.1"), &root);
        assert!(status.starts_with("200"), "browse ok, got {status}");
        assert!(body.contains(".secret"), "?hidden=1 reveals dotfiles:\n{body}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn browse_renders_the_quick_find_box() {
        let dir = fixture();
        let html = render_browse(&dir, SortKey::Name, false, "");
        // A JS-free GET form pointed at /browse, preserving path + sort as hidden
        // inputs, with a `filter` text field.
        assert!(html.contains("class=\"find\""), "filter box present:\n{html}");
        assert!(html.contains("method=\"get\"") && html.contains("action=\"/browse\""), "GET form to /browse");
        assert!(html.contains("name=\"filter\""), "filter text input present");
        assert!(html.contains("name=\"path\""), "path preserved as a hidden input");
        assert!(html.contains("name=\"sort\""), "sort preserved as a hidden input");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_filter_narrows_and_ranks_via_core() {
        let dir = fixture();
        // "hel" → only hello.txt survives (people.csv / data.bin / sub all drop).
        let html = render_browse(&dir, SortKey::Name, false, "hel");
        assert!(html.contains("hello.txt"), "match listed:\n{html}");
        assert!(!html.contains("people.csv"), "non-match dropped:\n{html}");
        assert!(!html.contains("data.bin"), "non-match dropped:\n{html}");
        // The box shows the active needle, and a "clear" affordance appears.
        assert!(html.contains("value=\"hel\""), "needle echoed into the box:\n{html}");
        assert!(html.contains(">clear</a>"), "clear link offered when filtering");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_filter_matches_subsequence_not_substring() {
        let dir = fixture();
        // "dt" is a subsequence of "data.bin" (d…t) but NOT a substring — proving
        // the listing routes through nav::filter_entries, not a substring contains.
        let html = render_browse(&dir, SortKey::Name, false, "dt");
        assert!(html.contains("data.bin"), "subsequence match listed:\n{html}");
        assert!(!html.contains("hello.txt"), "non-subsequence dropped:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_filter_param_is_honored_through_route() {
        let root = fixture().canonicalize().unwrap();
        let base = pct_encode(&root.to_string_lossy());
        // ?filter=hel must narrow to hello.txt (proves route → render_browse threads
        // the needle into read_entries' nav::filter_entries narrowing).
        let (status, _, body) =
            route(&format!("GET /browse?path={base}&filter=hel HTTP/1.1"), &root);
        assert!(status.starts_with("200"), "browse ok, got {status}");
        assert!(body.contains("hello.txt"), "?filter=hel matches hello.txt:\n{body}");
        assert!(!body.contains("people.csv"), "?filter=hel drops people.csv:\n{body}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn browse_filter_sticks_to_sort_links() {
        let dir = fixture();
        let html = render_browse(&dir, SortKey::Name, false, "hel");
        // The sort links must carry &filter=hel so re-sorting keeps the narrowing.
        assert!(html.contains("&filter=hel"), "sort/toggle links carry the active needle:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn browse_filter_value_is_html_escaped() {
        let dir = fixture();
        // A hostile needle must be escaped where it's reflected into the box value
        // (no raw <script> survives) — the box echoes the needle via esc().
        let html = render_browse(&dir, SortKey::Name, false, "<script>x</script>");
        assert!(!html.contains("<script>x</script>"), "raw needle reflected:\n{html}");
        assert!(html.contains("&lt;script&gt;"), "needle HTML-escaped in the box:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_text_is_escaped() {
        let dir = fixture();
        let html = render_view(&dir.join("hello.txt"), Some("text"), SortKey::Name, false, None);
        assert!(html.contains("hello &lt;world&gt;"), "content HTML-escaped:\n{html}");
        assert!(html.contains("indent:"), "indent badge present");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_text_shows_encoding_and_line_ending_badge() {
        let dir = fixture();
        // CRLF, no-BOM — CRLF (not LF) proves the badge is computed from the bytes.
        fs::write(dir.join("crlf.txt"), b"a\r\nb\r\n").unwrap();
        let html = render_view(&dir.join("crlf.txt"), Some("text"), SortKey::Name, false, None);
        // The combined `UTF-8 · CRLF` form is distinctive — it cannot collide with
        // the page head's lowercase `charset=utf-8` meta.
        assert!(html.contains("UTF-8 · CRLF"), "encoding+line-ending badge in the bar:\n{html}");
        // HEX mode shows raw bytes, so the text badge is suppressed.
        let hex = render_view(&dir.join("crlf.txt"), Some("hex"), SortKey::Name, false, None);
        assert!(!hex.contains("CRLF"), "no line-ending badge in HEX mode:\n{hex}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_text_shows_file_metrics() {
        let dir = fixture();
        // 2 lines, 3 words — distinct counts so a lines/words swap would fail.
        fs::write(dir.join("metrics.txt"), b"alpha beta\ngamma\n").unwrap();
        let html = render_view(&dir.join("metrics.txt"), Some("text"), SortKey::Name, false, None);
        assert!(html.contains("2 lines"), "line count in the /view bar:\n{html}");
        assert!(html.contains("3 words"), "word count in the /view bar:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_text_ws_param_reveals_whitespace() {
        let dir = fixture();
        fs::write(dir.join("ws.txt"), b"a b c\n").unwrap();
        // Default: raw spaces, no markers; the toggle link offers to show them.
        let plain = render_view(&dir.join("ws.txt"), Some("text"), SortKey::Name, false, None);
        assert!(!plain.contains("a·b·c"), "no whitespace markers without ?ws:\n{plain}");
        assert!(plain.contains("show whitespace"), "toggle link offers to show:\n{plain}");
        // ?ws=1: spaces revealed as ·; the toggle now offers to hide.
        let revealed = render_view_filtered(
            &dir.join("ws.txt"), Some("text"), SortKey::Name, false, None, "", "", 0, true, false,
        );
        assert!(revealed.contains("a·b·c"), "spaces revealed with ?ws=1:\n{revealed}");
        assert!(revealed.contains("hide whitespace"), "toggle link offers to hide:\n{revealed}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_text_wrap_param_soft_wraps() {
        let dir = fixture();
        fs::write(dir.join("wrap.txt"), b"a long line\n").unwrap();
        // Default: base stylesheet is white-space:pre (no override); the toggle
        // link offers to turn wrapping ON.
        let plain = render_view(&dir.join("wrap.txt"), Some("text"), SortKey::Name, false, None);
        assert!(!plain.contains("white-space:pre-wrap"), "no wrap override without ?wrap:\n{plain}");
        assert!(plain.contains(">wrap<"), "toggle link offers to wrap:\n{plain}");
        // ?wrap=1: inline override flips .src to soft-wrap; toggle now offers nowrap.
        let wrapped = render_view_filtered(
            &dir.join("wrap.txt"), Some("text"), SortKey::Name, false, None, "", "", 0, false, true,
        );
        assert!(wrapped.contains("white-space:pre-wrap"), "wrap override present with ?wrap=1:\n{wrapped}");
        assert!(wrapped.contains(">nowrap<"), "toggle link offers to stop wrapping:\n{wrapped}");
        // The ws toggle must preserve the active wrap flag (and vice-versa).
        assert!(wrapped.contains("ws=1&wrap=1"), "ws link preserves wrap=1:\n{wrapped}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn in_file_find_shows_count_and_anchors_first_match() {
        let dir = fixture();
        // doc.md (as text) has "## Section A" on line 4 and "## Section B" on line 9.
        // find="Section", fmatch=0 → 2 matches, current is the first (line 4).
        let html = render_view_filtered(
            &dir.join("doc.md"), Some("text"), SortKey::Name, false, None, "", "Section", 0, false, false,
        );
        assert!(html.contains("class=\"find\""), "find box present:\n{html}");
        assert!(html.contains("1 of 2"), "match count shows current+total:\n{html}");
        // The current match's line is the goto target → gets the L4 anchor.
        assert!(html.contains("id=\"L4\""), "first match's line anchored:\n{html}");
        // prev/next links carry the query + a sibling fmatch.
        assert!(html.contains("find=Section"), "nav links carry the query:\n{html}");
        assert!(html.contains("fmatch=1"), "nav links bump fmatch:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn in_file_find_fmatch_selects_and_anchors_that_match() {
        let dir = fixture();
        // fmatch=1 → the second "Section" (line 9) becomes current + anchored.
        let html = render_view_filtered(
            &dir.join("doc.md"), Some("text"), SortKey::Name, false, None, "", "Section", 1, false, false,
        );
        assert!(html.contains("2 of 2"), "second match is current:\n{html}");
        assert!(html.contains("id=\"L9\""), "second match's line (9) anchored:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn in_file_find_no_match_and_query_is_escaped() {
        let dir = fixture();
        // hello.txt has no "<script>" → no matches, and the hostile query must be
        // HTML-escaped where it's reflected into the find-box input value.
        let html = render_view_filtered(
            &dir.join("hello.txt"), Some("text"), SortKey::Name, false, None, "", "<script>", 0, false, false,
        );
        assert!(html.contains("no matches"), "empty result reported:\n{html}");
        assert!(!html.contains("value=\"<script>\""), "raw query reflected unescaped:\n{html}");
        assert!(html.contains("&lt;script&gt;"), "query HTML-escaped in the box:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_hex_uses_core() {
        let dir = fixture();
        let html = render_view(&dir.join("data.bin"), Some("hex"), SortKey::Name, false, None);
        assert!(html.contains("00000000"), "hex offset from core:\n{html}");
        assert!(html.contains("00 41 ff"), "hex bytes from core");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_text_renders_non_selectable_line_number_gutter() {
        let dir = fixture();
        let html = render_view(&dir.join("hello.txt"), Some("text"), SortKey::Name, false, None);
        // Two-column layout: a user-select:none gutter <pre> beside the content.
        assert!(html.contains("class=\"code\""), "two-column wrapper present:\n{html}");
        assert!(html.contains("class=\"gutter\""), "gutter column present:\n{html}");
        assert!(html.contains("class=\"src\""), "source column present:\n{html}");
        // Gutter carries 1-based line numbers (hello.txt has 2 content lines + a
        // trailing empty line from the final newline → numbers 1,2,3 present).
        assert!(html.contains(">1\n2"), "gutter numbers lines from 1:\n{html}");
        // The content still lands in the .src pane, HTML-escaped.
        assert!(html.contains("hello &lt;world&gt;"), "content escaped in src pane:\n{html}");
        // The gutter is marked non-selectable in CSS (so copy skips the numbers).
        assert!(html.contains("user-select:none"), "gutter is user-select:none:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn gutter_width_pads_numbers_to_decimal_digits() {
        // 12 lines → 2-digit gutter: line 1 is right-padded (" 1"), line 12 is "12".
        let lines: Vec<String> = (1..=12).map(|i| format!("line {i}")).collect();
        let html = gutter_html(&lines, None, &[]);
        assert!(html.contains(" 1\n 2"), "single-digit numbers right-padded to width 2:\n{html}");
        assert!(html.contains("12"), "two-digit number present:\n{html}");
        let _ = lines;
    }

    #[test]
    fn view_renders_goto_line_box_for_text() {
        let dir = fixture();
        let html = render_view(&dir.join("hello.txt"), Some("text"), SortKey::Name, false, None);
        // A JS-free GET form to /view with a numeric `line` input and the path +
        // mode preserved as hidden inputs.
        assert!(html.contains("class=\"goto\""), "goto box present:\n{html}");
        assert!(html.contains("action=\"/view\""), "form targets /view");
        assert!(html.contains("name=\"line\""), "line number input present");
        assert!(html.contains("name=\"path\""), "path preserved as hidden input");
        assert!(html.contains("name=\"mode\""), "mode preserved as hidden input");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_line_param_anchors_and_highlights_target_row() {
        let dir = fixture();
        // hello.txt has 2 content lines + a trailing empty line. `?line=2` tags
        // line 2 with id="L2" (the native #L2 fragment scroll target) and wraps
        // both the gutter number and the source line in a .cur highlight span.
        let html = render_view(&dir.join("hello.txt"), Some("text"), SortKey::Name, false, Some(2));
        assert!(html.contains("id=\"L2\""), "target row carries the L<n> anchor:\n{html}");
        assert!(html.contains("class=\"cur\""), "target row highlighted:\n{html}");
        // A native fragment jump link is offered beside the box.
        assert!(html.contains("href=\"#L2\""), "native #L2 fragment jump link:\n{html}");
        // The box echoes the resolved line number.
        assert!(html.contains("value=\"2\""), "line input echoes the target:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn view_line_param_clamps_overshoot_via_core() {
        let dir = fixture();
        // hello.txt is 3 lines (2 + trailing empty). `?line=999` over-shoots →
        // clamp_line pins it to line 3, so the anchor is L3 (never L999).
        let html = render_view(&dir.join("hello.txt"), Some("text"), SortKey::Name, false, Some(999));
        assert!(html.contains("id=\"L3\""), "over-shoot clamped to the last line:\n{html}");
        assert!(!html.contains("id=\"L999\""), "no anchor past the last line:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn route_line_param_is_honored_and_parsed_leniently() {
        let root = fixture().canonicalize().unwrap();
        let file = pct_encode(&root.join("hello.txt").to_string_lossy());
        // ?line=2 threads through route → render_view → gutter_html as the anchor.
        let (status, _, body) = route(&format!("GET /view?path={file}&line=2 HTTP/1.1"), &root);
        assert!(status.starts_with("200"), "view ok, got {status}");
        assert!(body.contains("id=\"L2\""), "?line=2 anchors line 2:\n{body}");
        // A non-numeric line is ignored (no anchor, no panic) — lenient parse.
        let (status, _, body) = route(&format!("GET /view?path={file}&line=abc HTTP/1.1"), &root);
        assert!(status.starts_with("200"), "non-numeric line still 200, got {status}");
        assert!(!body.contains("class=\"cur\""), "garbage line = no jump:\n{body}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn csv_defaults_to_table_via_core() {
        let dir = fixture();
        let html = render_view(&dir.join("people.csv"), None, SortKey::Name, false, None);
        assert!(html.contains("<table>"), "table rendered:\n{html}");
        assert!(html.contains("<th>name</th>"), "header cell");
        assert!(html.contains("<td>Alice</td>"), "body cell");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn diff_defaults_to_colored_diff_via_core() {
        let dir = fixture();
        // No `?mode=` → a `.diff` file opens in Diff mode by default.
        let html = render_view(&dir.join("change.diff"), None, SortKey::Name, false, None);
        assert!(html.contains("<pre class=\"diff\">"), "diff body rendered:\n{html}");
        assert!(
            html.contains("class=\"diff-add\">+new line</span>"),
            "added line colored:\n{html}"
        );
        assert!(
            html.contains("class=\"diff-del\">-old line</span>"),
            "removed line colored:\n{html}"
        );
        assert!(
            html.contains("class=\"diff-hunk\">@@ -1,2 +1,2 @@</span>"),
            "hunk header colored:\n{html}"
        );
        assert!(
            html.contains("class=\"diff-file\">+++ b/x.rs</span>"),
            "file header colored:\n{html}"
        );
        // The mode switcher offers diff (default/bold) plus text & hex fallbacks.
        assert!(html.contains("<b>diff</b>"), "diff is the active mode:\n{html}");
        assert!(html.contains("mode=text"), "text fallback offered:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn image_defaults_to_card_and_inline_data_uri() {
        let dir = fixture();
        let html = render_view(&dir.join("pixel.png"), None, SortKey::Name, false, None);
        assert!(html.contains("class=\"imgcard\""), "image card present:\n{html}");
        assert!(html.contains("PNG image"), "format label shown:\n{html}");
        assert!(html.contains("16 \u{00d7} 8 px"), "dimensions shown:\n{html}");
        assert!(html.contains("src=\"data:image/png;base64,"), "inline data URI:\n{html}");
        // Image is the default (bold) mode; Hex is the only fallback (no Text for
        // binary image bytes).
        assert!(html.contains("<b>image</b>"), "image is the active mode:\n{html}");
        assert!(html.contains("mode=hex"), "hex fallback offered:\n{html}");
        assert!(!html.contains("mode=text"), "text not offered for an image:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn base64_matches_rfc4648_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn mode_param_forces_view_mode_over_default() {
        let dir = fixture();
        let csv = dir.join("people.csv"); // defaults to Table
        // `?mode=text` forces the text body (no <table>) — open-as override.
        let t = render_view(&csv, Some("text"), SortKey::Name, false, None);
        assert!(!t.contains("<table>"), "text override suppresses the table:\n{t}");
        assert!(t.contains("<b>text</b>"), "text is the active mode:\n{t}");
        // `?mode=hex` forces the hex dump.
        let h = render_view(&csv, Some("hex"), SortKey::Name, false, None);
        assert!(h.contains("<b>hex</b>"), "hex override active:\n{h}");
        assert!(!h.contains("<table>"), "hex override suppresses the table:\n{h}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn json_offers_formatted_mode_and_pretty_prints() {
        // TSK-218: a .json file is Structured, so the mode switcher offers a
        // `mode=formatted` link, and `?mode=formatted` pretty-prints via the
        // shared core formatter. (Quotes render HTML-escaped as &quot;.)
        let dir = fixture();
        let json = dir.join("config.json"); // {"a":1,"b":[2,3]}

        // Default open (Text): the Formatted link is offered; body is compact.
        let def = render_view(&json, None, SortKey::Name, false, None);
        assert!(def.contains("&mode=formatted"), "Formatted mode link offered:\n{def}");
        assert!(def.contains("<b>text</b>"), "json defaults to Text:\n{def}");
        assert!(def.contains("{&quot;a&quot;:1"), "Text shows compact source:\n{def}");

        // `?mode=formatted` re-indents it (2-space; `: ` colon-space is unique to
        // the pretty output — compact has `:1` with no space).
        let f = render_view(&json, Some("formatted"), SortKey::Name, false, None);
        assert!(f.contains("<b>formatted</b>"), "formatted is the active mode:\n{f}");
        assert!(f.contains("&quot;a&quot;: 1,"), "2-space pretty key/value:\n{f}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn csv_table_filter_global_and_per_column_scoping() {
        let dir = fixture(); // people.csv = name,age / Alice,30 / Bob,25
        let csv = dir.join("people.csv");
        // Global substring: any cell containing "Alice".
        let g = render_view_filtered(&csv, Some("table"), SortKey::Name, false, None, "Alice", "", 0, false, false);
        assert!(g.contains("class=\"find\""), "filter box present:\n{g}");
        assert!(g.contains("<td>Alice</td>"), "Alice row kept:\n{g}");
        assert!(!g.contains("<td>Bob</td>"), "Bob filtered out:\n{g}");
        assert!(g.contains("1/2 rows"), "match count shown:\n{g}");
        // Column-scoped `age:Alice` matches NOTHING — "Alice" is in the name
        // column, not age — proving the scope restricts the search (global did
        // match it above).
        let c = render_view_filtered(&csv, Some("table"), SortKey::Name, false, None, "age:Alice", "", 0, false, false);
        assert!(!c.contains("<td>Alice</td>"), "age-scoped search excludes the name col:\n{c}");
        assert!(c.contains("0/2 rows"), "no rows match age:Alice:\n{c}");
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
        conn.write_all(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").unwrap();
        let mut resp = String::new();
        conn.read_to_string(&mut resp).unwrap();
        h.join().unwrap();
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "status line:\n{resp}");
        assert!(resp.contains("hello.txt"), "served the browse page");
        let _ = fs::remove_dir_all(&dir);
    }

    // --- Markdown outline / TOC ---

    #[test]
    fn markdown_view_renders_outline_nav_with_fragment_links() {
        let dir = fixture();
        let html = render_view(&dir.join("doc.md"), Some("text"), SortKey::Name, false, None);
        // The outline <nav> lists the three real headings as #L<line> links.
        assert!(html.contains("class=\"outline\""), "outline block present:\n{html}");
        assert!(html.contains(">Title</a>"), "H1 title linked:\n{html}");
        assert!(html.contains(">Section A</a>"), "H2 title linked:\n{html}");
        assert!(html.contains(">Section B</a>"), "second H2 linked:\n{html}");
        // Each entry is a native fragment link to its heading line.
        assert!(html.contains("href=\"#L1\""), "H1 → line 1 fragment link:\n{html}");
        assert!(html.contains("href=\"#L4\""), "Section A → line 4 fragment link:\n{html}");
        assert!(html.contains("href=\"#L9\""), "Section B → line 9 fragment link:\n{html}");
        // The fenced `# fenced decoy` is excluded from the outline.
        assert!(!html.contains("fenced decoy</a>"), "fenced decoy not in outline:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn markdown_outline_anchors_heading_rows_in_the_gutter() {
        let dir = fixture();
        let html = render_view(&dir.join("doc.md"), Some("text"), SortKey::Name, false, None);
        // The heading lines carry id="L<n>" anchors so the TOC fragment links
        // resolve (the #L4 / #L9 targets exist on the page).
        assert!(html.contains("id=\"L1\""), "line 1 anchored:\n{html}");
        assert!(html.contains("id=\"L4\""), "line 4 anchored:\n{html}");
        assert!(html.contains("id=\"L9\""), "line 9 anchored:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn non_markdown_file_has_no_outline() {
        let dir = fixture();
        let html = render_view(&dir.join("hello.txt"), Some("text"), SortKey::Name, false, None);
        assert!(!html.contains("class=\"outline\""), "no outline for a .txt file:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn markdown_hex_view_has_no_outline() {
        let dir = fixture();
        // The outline is text-mode only — viewing the .md as hex has no source
        // lines to anchor against, so no TOC is rendered.
        let html = render_view(&dir.join("doc.md"), Some("hex"), SortKey::Name, false, None);
        assert!(!html.contains("class=\"outline\""), "no outline in hex mode:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn markdown_outline_title_is_html_escaped() {
        let dir = fixture();
        let path = dir.join("xss.md");
        fs::write(&path, b"# <script>alert(1)</script>\n").unwrap();
        let html = render_view(&path, Some("text"), SortKey::Name, false, None);
        // A hostile heading title must be escaped where reflected into the TOC.
        assert!(!html.contains("<script>alert(1)</script>"), "raw title reflected:\n{html}");
        assert!(html.contains("&lt;script&gt;"), "title HTML-escaped in the outline:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    // --- AUDIT S1/S2: filesystem containment boundary regression tests ---

    #[test]
    fn host_allowed_only_loopback() {
        assert!(host_allowed(""));               // absent Host → not a browser cross-origin req
        assert!(host_allowed("127.0.0.1:8765"));
        assert!(host_allowed("localhost"));
        assert!(!host_allowed("evil.example.com"));
        assert!(!host_allowed("attacker.test:8765"));
    }

    #[test]
    fn rejects_foreign_host_over_socket() {
        let dir = fixture();
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let root = dir.clone();
        let h = thread::spawn(move || {
            if let Ok((stream, _)) = listener.accept() { let _ = handle_conn(stream, &root); }
        });
        let mut conn = TcpStream::connect(("127.0.0.1", port)).unwrap();
        conn.write_all(b"GET / HTTP/1.1\r\nHost: rebind.evil.com\r\n\r\n").unwrap();
        let mut resp = String::new();
        conn.read_to_string(&mut resp).unwrap();
        h.join().unwrap();
        assert!(resp.starts_with("HTTP/1.1 403"), "foreign Host refused:\n{resp}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn route_rejects_non_get() {
        let dir = fixture();
        let (status, _, _) = route("POST / HTTP/1.1", &dir);
        assert!(status.starts_with("405"), "non-GET rejected, got {status}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn route_confines_path_to_root() {
        let root = fixture().canonicalize().unwrap();
        // A path OUTSIDE the served root is refused (arbitrary-read closed).
        let (out, _, _) = route("GET /view?path=%2Fetc%2Fhosts HTTP/1.1", &root);
        assert!(out.starts_with("404"), "out-of-root path refused, got {out}");
        let (br, _, _) = route("GET /browse?path=%2F HTTP/1.1", &root);
        assert!(br.starts_with("404"), "out-of-root browse refused, got {br}");
        // A path INSIDE the root still works.
        let inside = format!("GET /view?path={} HTTP/1.1", pct_encode(&root.join("hello.txt").to_string_lossy()));
        let (ok, _, _) = route(&inside, &root);
        assert!(ok.starts_with("200"), "in-root path served, got {ok}");
        let _ = fs::remove_dir_all(&root);
    }

    // --- AUDIT S3: router-contract + reflected-XSS coverage gaps ---
    // (token: Audit_rust_core_crates_web_src_main_rs)

    #[test]
    fn route_unknown_path_is_404() {
        let dir = fixture();
        let (status, _, body) = route("GET /does-not-exist HTTP/1.1", &dir);
        assert!(status.starts_with("404"), "unknown route → 404, got {status}");
        assert!(body.contains("not found"), "404 body: {body}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn route_browse_subdir_lists_it() {
        let root = fixture().canonicalize().unwrap();
        // /browse?path=<subdir> must resolve the query dir and 200 with a
        // listing — the positive arm the prior tests never exercised.
        let target = format!(
            "GET /browse?path={} HTTP/1.1",
            pct_encode(&root.join("sub").to_string_lossy())
        );
        let (status, ctype, body) = route(&target, &root);
        assert!(status.starts_with("200"), "subdir browse → 200, got {status}");
        assert!(ctype.starts_with("text/html"), "html content-type: {ctype}");
        // The page renders the nav frame (an empty subdir still produces the
        // "../" up-link), confirming we listed `sub`, not the root.
        assert!(body.contains("/browse?path="), "browse page rendered:\n{body}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn render_view_does_not_reflect_raw_mode() {
        // A hostile/unknown `?mode=` value must never reach the page unescaped —
        // the mode match falls through to the core default, and nothing reflects
        // the raw param, so no `<script>` survives in the output.
        let dir = fixture();
        let html =
            render_view(&dir.join("hello.txt"), Some("<script>alert(1)</script>"), SortKey::Name, false, None);
        assert!(!html.contains("<script>"), "raw <script> reflected:\n{html}");
        assert!(!html.contains("alert(1)"), "raw mode payload reflected:\n{html}");
        // Sanity: it still rendered the file as a normal text view.
        assert!(html.contains("hello &lt;world&gt;"), "fell back to a text view:\n{html}");
        let _ = fs::remove_dir_all(&dir);
    }

    // --- AUDIT S3: DoS hardening — oversized request head is refused 400 ---

    #[test]
    fn oversized_request_head_is_rejected_400() {
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
        conn.write_all(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n").unwrap();
        // A giant header value with no terminating blank line: the take() cap
        // cuts the read off, so handle_conn answers 400 and closes instead of
        // buffering unbounded bytes.
        let big = format!("X-Pad: {}\r\n", "A".repeat((MAX_HEADER_BYTES as usize) * 2));
        // Writes may short-circuit once the server closes the socket after 400;
        // ignore a broken-pipe so the assertion below is what's tested.
        let _ = conn.write_all(big.as_bytes());
        let mut resp = String::new();
        let _ = conn.read_to_string(&mut resp);
        h.join().unwrap();
        assert!(resp.starts_with("HTTP/1.1 400"), "oversized head → 400:\n{resp}");
        let _ = fs::remove_dir_all(&dir);
    }
}
