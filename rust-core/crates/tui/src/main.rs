//! `mdv-tui` — a terminal front-end (ratatui) over `mdvcore-core`.
//!
//! The second of the "one core, three front-ends": the same sans-IO Rust core
//! that backs the SwiftUI app (via FFI) drives this TUI in-process (plain crate
//! link, no FFI). MVP scope: a file-navigation pane + a content viewer that
//! shows text, a HEX dump (`mdvcore_core::hex::render_all`), and an indent
//! badge (`mdvcore_core::indent::detect`).
//!
//! Cross-platform via ratatui/crossterm — runs on macOS now and on Linux
//! unchanged.
//!
//! Keys: ↑/↓ (or j/k) move · ↵ (or l/→) open file / enter dir · ⌫ (or h/←)
//! parent · x toggle text/hex · g/G top/bottom · PgUp/PgDn scroll · q quit.

use std::fs;
use std::io;
use std::io::Read;
use std::path::{Path, PathBuf};

use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Cell, List, ListItem, ListState, Paragraph, Row, Table, Wrap};
use ratatui::{Frame, Terminal};
use ratatui::backend::TestBackend;

/// Max bytes read into a preview (keeps the TUI snappy; larger files truncate).
const PREVIEW_CAP: usize = 1024 * 1024;
/// Cap on text lines kept for display (pathological one-line files).
const MAX_TEXT_LINES: usize = 200_000;
/// Bytes per HEX row (matches the core / Swift default).
const HEX_WIDTH: usize = 16;

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // `--snapshot [path]`: render ONE frame to an in-memory buffer and print it,
    // then exit. No TTY needed — for headless self-validation / demoing the UI
    // (mirrors the Swift app's --diagnose philosophy).
    let snapshot = args.iter().any(|a| a == "--snapshot");
    let start = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .map(PathBuf::from)
        .unwrap_or(std::env::current_dir()?);
    let mut app = App::new(start);
    if snapshot {
        // Pre-open the first file so the content pane shows something.
        if let Some(i) = app.entries.iter().position(|e| !e.is_dir) {
            app.list.select(Some(i));
            app.enter();
        }
        print!("{}", app.snapshot(100, 30));
        return Ok(());
    }
    let mut terminal = ratatui::init();
    let result = app.run(&mut terminal);
    ratatui::restore();
    result
}

/// Flatten a rendered `TestBackend` buffer into newline-separated text.
fn buffer_to_string(terminal: &Terminal<TestBackend>) -> String {
    let buf = terminal.backend().buffer();
    let mut s = String::new();
    for y in 0..buf.area.height {
        for x in 0..buf.area.width {
            s.push_str(buf[(x, y)].symbol());
        }
        s.push('\n');
    }
    s
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Text,
    Hex,
    /// CSV/TSV parsed into a table by `mdvcore_core::csv::parse`.
    Table,
}

struct Entry {
    name: String,
    is_dir: bool,
    is_parent: bool,
}

/// A parsed CSV/TSV table (from the core), for the Table view mode.
struct CsvTable {
    header: Vec<String>,
    rows: Vec<Vec<String>>,
}

struct Preview {
    name: String,
    total: usize,
    truncated: bool,
    raw: Vec<u8>,
    mode: Mode,
    is_csv: bool,
    text_lines: Vec<String>,
    hex_lines: Vec<String>,
    table: Option<CsvTable>,
    indent: String,
    scroll: usize,
}

impl Preview {
    fn lines(&self) -> &[String] {
        match self.mode {
            Mode::Text => &self.text_lines,
            Mode::Hex => &self.hex_lines,
            Mode::Table => &[],
        }
    }

    /// Scrollable item count for the current mode (lines, or table rows).
    fn content_len(&self) -> usize {
        match self.mode {
            Mode::Text => self.text_lines.len(),
            Mode::Hex => self.hex_lines.len(),
            Mode::Table => self.table.as_ref().map_or(0, |t| t.rows.len()),
        }
    }

    /// Modes the user can cycle through for this file (Table only for CSV/TSV).
    fn modes(&self) -> &'static [Mode] {
        if self.is_csv {
            &[Mode::Table, Mode::Text, Mode::Hex]
        } else {
            &[Mode::Text, Mode::Hex]
        }
    }
}

struct App {
    cwd: PathBuf,
    entries: Vec<Entry>,
    list: ListState,
    preview: Option<Preview>,
    status: String,
    /// Last-drawn content-pane inner height, used for page scrolling.
    content_height: usize,
}

impl App {
    fn new(start: PathBuf) -> Self {
        let cwd = start.canonicalize().unwrap_or(start);
        let mut app = App {
            cwd,
            entries: Vec::new(),
            list: ListState::default(),
            preview: None,
            status: String::new(),
            content_height: 1,
        };
        app.reload_dir();
        app
    }

    // MARK: - Directory navigation (the front-end owns IO; the core is sans-IO)

    fn reload_dir(&mut self) {
        let mut entries: Vec<Entry> = Vec::new();
        if self.cwd.parent().is_some() {
            entries.push(Entry { name: "..".into(), is_dir: true, is_parent: true });
        }
        match fs::read_dir(&self.cwd) {
            Ok(rd) => {
                let mut items: Vec<Entry> = rd
                    .filter_map(Result::ok)
                    .map(|e| {
                        let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
                        Entry { name: e.file_name().to_string_lossy().into_owned(), is_dir, is_parent: false }
                    })
                    .collect();
                // Dirs first, then files; case-insensitive name within each.
                items.sort_by(|a, b| {
                    b.is_dir
                        .cmp(&a.is_dir)
                        .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
                });
                entries.extend(items);
                self.status = format!("{}", self.cwd.display());
            }
            Err(e) => self.status = format!("cannot read dir: {e}"),
        }
        self.entries = entries;
        self.list.select(if self.entries.is_empty() { None } else { Some(0) });
    }

    fn selected(&self) -> Option<&Entry> {
        self.list.selected().and_then(|i| self.entries.get(i))
    }

    fn move_selection(&mut self, delta: isize) {
        if self.entries.is_empty() {
            return;
        }
        let cur = self.list.selected().unwrap_or(0) as isize;
        let next = (cur + delta).clamp(0, self.entries.len() as isize - 1);
        self.list.select(Some(next as usize));
    }

    /// Enter the selected entry: descend a dir, or open a file into the viewer.
    fn enter(&mut self) {
        let Some(entry) = self.selected() else { return };
        if entry.is_parent {
            if let Some(parent) = self.cwd.parent() {
                self.cwd = parent.to_path_buf();
                self.reload_dir();
            }
            return;
        }
        let path = self.cwd.join(&entry.name);
        if entry.is_dir {
            self.cwd = path;
            self.reload_dir();
        } else {
            self.open_file(&path);
        }
    }

    fn go_parent(&mut self) {
        if let Some(parent) = self.cwd.parent() {
            self.cwd = parent.to_path_buf();
            self.reload_dir();
        }
    }

    fn open_file(&mut self, path: &Path) {
        match read_capped(path, PREVIEW_CAP) {
            Ok((raw, truncated, total)) => {
                let text = String::from_utf8_lossy(&raw);
                let text_lines: Vec<String> = text
                    .split('\n')
                    .take(MAX_TEXT_LINES)
                    .map(|l| l.replace('\t', "    ").replace('\r', ""))
                    .collect();
                // Core usage #1: detect indentation style for the status badge.
                let indent = mdvcore_core::indent::detect(&text, 50);
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.display().to_string());
                let is_csv = matches!(
                    path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).as_deref(),
                    Some("csv" | "tsv")
                );
                self.preview = Some(Preview {
                    name,
                    total,
                    truncated,
                    raw,
                    mode: if is_csv { Mode::Table } else { Mode::Text },
                    is_csv,
                    text_lines,
                    hex_lines: Vec::new(),
                    table: None,
                    indent,
                    scroll: 0,
                });
                if let Some(p) = &mut self.preview {
                    Self::ensure_mode_built(p); // build the default mode (table for CSV)
                }
                self.status = format!("opened {}", path.display());
            }
            Err(e) => self.status = format!("open failed: {e}"),
        }
    }

    /// Cycle to the next available view mode for the current file, building the
    /// HEX dump / CSV table lazily (both via `mdvcore_core`).
    fn cycle_mode(&mut self) {
        if let Some(p) = &mut self.preview {
            let modes = p.modes();
            let idx = modes.iter().position(|&m| m == p.mode).unwrap_or(0);
            p.mode = modes[(idx + 1) % modes.len()];
            Self::ensure_mode_built(p);
            p.scroll = 0;
        }
    }

    /// Materialize the current mode's content if it hasn't been yet.
    fn ensure_mode_built(p: &mut Preview) {
        match p.mode {
            // Core usage #2: HEX dump rendered in the Rust core (lazy + cached).
            Mode::Hex if p.hex_lines.is_empty() => {
                let dump = mdvcore_core::hex::render_all(&p.raw, HEX_WIDTH, p.total, p.truncated);
                let mut lines: Vec<String> = dump.split('\n').map(str::to_string).collect();
                if lines.last().is_some_and(String::is_empty) {
                    lines.pop(); // render_all ends with a trailing '\n'
                }
                p.hex_lines = lines;
            }
            // Core usage #3: CSV/TSV parsed in the Rust core (delimiter auto-detected).
            Mode::Table if p.table.is_none() => {
                let text = String::from_utf8_lossy(&p.raw);
                let t = mdvcore_core::csv::parse(&text);
                p.table = Some(CsvTable { header: t.header, rows: t.rows });
            }
            _ => {}
        }
    }

    fn scroll_by(&mut self, delta: isize) {
        if let Some(p) = &mut self.preview {
            let max = p.content_len().saturating_sub(1);
            let next = (p.scroll as isize + delta).clamp(0, max as isize);
            p.scroll = next as usize;
        }
    }

    fn scroll_to(&mut self, top: bool) {
        if let Some(p) = &mut self.preview {
            p.scroll = if top { 0 } else { p.content_len().saturating_sub(1) };
        }
    }

    // MARK: - Event loop

    fn run(&mut self, terminal: &mut ratatui::DefaultTerminal) -> io::Result<()> {
        loop {
            terminal.draw(|frame| self.draw(frame))?;
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press && self.on_key(key.code) {
                    return Ok(());
                }
            }
        }
    }

    /// Handle a key. Returns `true` to quit.
    fn on_key(&mut self, code: KeyCode) -> bool {
        let page = self.content_height.max(1) as isize;
        match code {
            KeyCode::Char('q') | KeyCode::Esc => return true,
            KeyCode::Down | KeyCode::Char('j') => self.move_selection(1),
            KeyCode::Up | KeyCode::Char('k') => self.move_selection(-1),
            KeyCode::Enter | KeyCode::Right | KeyCode::Char('l') => self.enter(),
            KeyCode::Backspace | KeyCode::Left | KeyCode::Char('h') => self.go_parent(),
            KeyCode::Char('x') => self.cycle_mode(),
            KeyCode::Char('g') => self.scroll_to(true),
            KeyCode::Char('G') => self.scroll_to(false),
            KeyCode::PageDown => self.scroll_by(page),
            KeyCode::PageUp => self.scroll_by(-page),
            _ => {}
        }
        false
    }

    /// Render one frame to an in-memory buffer and return it as text (for
    /// `--snapshot` and tests — no real terminal involved).
    fn snapshot(&mut self, w: u16, h: u16) -> String {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).expect("test backend");
        terminal.draw(|f| self.draw(f)).expect("draw");
        buffer_to_string(&terminal)
    }

    // MARK: - Rendering

    fn draw(&mut self, frame: &mut Frame) {
        let rows = Layout::vertical([Constraint::Min(1), Constraint::Length(1)]).split(frame.area());
        let cols =
            Layout::horizontal([Constraint::Percentage(35), Constraint::Percentage(65)]).split(rows[0]);
        self.draw_files(frame, cols[0]);
        self.draw_content(frame, cols[1]);
        self.draw_status(frame, rows[1]);
    }

    fn draw_files(&mut self, frame: &mut Frame, area: Rect) {
        let title = format!(" {} ", short_path(&self.cwd));
        let items: Vec<ListItem> = self
            .entries
            .iter()
            .map(|e| {
                let label = if e.is_dir { format!("{}/", e.name) } else { e.name.clone() };
                let style = if e.is_dir {
                    Style::new().fg(Color::Cyan).bold()
                } else {
                    Style::new()
                };
                ListItem::new(Line::from(Span::styled(label, style)))
            })
            .collect();
        let list = List::new(items)
            .block(Block::bordered().title(title))
            .highlight_symbol("▶ ")
            .highlight_style(Style::new().reversed());
        frame.render_stateful_widget(list, area, &mut self.list);
    }

    fn draw_content(&mut self, frame: &mut Frame, area: Rect) {
        let inner_h = area.height.saturating_sub(2) as usize; // minus borders
        self.content_height = inner_h.max(1);
        let Some(p) = &self.preview else {
            let hint = Paragraph::new("Select a file and press ↵ to view it.\nx cycles view modes (table / text / HEX).")
                .block(Block::bordered().title(" content "))
                .style(Style::new().fg(Color::DarkGray));
            frame.render_widget(hint, area);
            return;
        };

        let trunc = if p.truncated { " · TRUNCATED" } else { "" };
        // Table mode renders a real ratatui Table from the core-parsed CSV.
        if p.mode == Mode::Table {
            if let Some(t) = &p.table {
                let title = format!(
                    " {} · table · {}×{} · {}{trunc} ",
                    p.name,
                    t.rows.len(),
                    t.header.len(),
                    human_size(p.total),
                );
                let widths = column_widths(&t.header, &t.rows);
                let header = Row::new(t.header.iter().map(|h| Cell::from(h.clone())))
                    .style(Style::new().fg(Color::Cyan).bold());
                let start = p.scroll.min(t.rows.len().saturating_sub(1));
                let body: Vec<Row> = t
                    .rows
                    .iter()
                    .skip(start)
                    .take(inner_h.saturating_sub(1).max(1))
                    .map(|r| Row::new(r.iter().map(|c| Cell::from(c.clone())).collect::<Vec<_>>()))
                    .collect();
                let table = Table::new(body, widths)
                    .header(header)
                    .column_spacing(1)
                    .block(Block::bordered().title(title));
                frame.render_widget(table, area);
                return;
            }
        }

        // Text / HEX: a scrolled paragraph of the visible lines.
        let mode = match p.mode {
            Mode::Text => "text",
            Mode::Hex => "hex",
            Mode::Table => "table",
        };
        let title = format!(
            " {} · {mode} · indent: {} · {}{trunc} ",
            p.name,
            p.indent,
            human_size(p.total),
        );
        let lines = p.lines();
        let start = p.scroll.min(lines.len().saturating_sub(1));
        let visible: Vec<Line> = lines
            .iter()
            .skip(start)
            .take(inner_h)
            .map(|s| Line::raw(s.clone()))
            .collect();
        let para = Paragraph::new(visible)
            .block(Block::bordered().title(title))
            .wrap(Wrap { trim: false });
        frame.render_widget(para, area);
    }

    fn draw_status(&self, frame: &mut Frame, area: Rect) {
        let help = "↑/↓ move · ↵ open · ⌫ up · x hex · g/G top/bot · PgUp/PgDn · q quit";
        let line = Line::from(vec![
            Span::styled(" mdv-tui ", Style::new().fg(Color::Black).bg(Color::Cyan).bold()),
            Span::raw(" "),
            Span::styled(help, Style::new().fg(Color::DarkGray)),
        ]);
        frame.render_widget(Paragraph::new(line), area);
    }
}

// MARK: - Helpers

/// Read up to `cap` bytes; returns (bytes, truncated, total-file-size).
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

/// Per-column widths for the table view: the widest of header + a sample of
/// rows, clamped to a sane cell range so one long value can't blow the layout.
fn column_widths(header: &[String], rows: &[Vec<String>]) -> Vec<Constraint> {
    let ncols = header.len().max(1);
    let mut w = vec![0usize; ncols];
    for (i, h) in header.iter().enumerate() {
        if let Some(c) = w.get_mut(i) {
            *c = h.chars().count();
        }
    }
    for row in rows.iter().take(200) {
        for (i, cell) in row.iter().enumerate() {
            if let Some(c) = w.get_mut(i) {
                *c = (*c).max(cell.chars().count());
            }
        }
    }
    w.into_iter()
        .map(|x| Constraint::Length(x.clamp(4, 30) as u16))
        .collect()
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

/// Abbreviate `$HOME` to `~` in a path for the pane title.
fn short_path(path: &Path) -> String {
    let s = path.display().to_string();
    if let Some(home) = std::env::var_os("HOME") {
        let home = home.to_string_lossy();
        if let Some(rest) = s.strip_prefix(home.as_ref()) {
            return format!("~{rest}");
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_dir() -> PathBuf {
        // Unique per call (pid + atomic counter) so parallel tests never share
        // a dir and `remove_dir_all` each other mid-run.
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "mdv-tui-test-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join("hello.txt"), b"line one\nline two\n").unwrap();
        fs::write(dir.join("data.bin"), [0x00u8, 0x41, 0xff, 0x7f]).unwrap();
        fs::write(dir.join("people.csv"), b"name,age,city\nAlice,30,NYC\nBob,25,LA\n").unwrap();
        dir
    }

    fn render(app: &mut App) -> String {
        app.snapshot(100, 24)
    }

    fn select_name(app: &mut App, name: &str) {
        let i = app.entries.iter().position(|e| e.name == name).expect("entry present");
        app.list.select(Some(i));
    }

    #[test]
    fn lists_directory_entries() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        let out = render(&mut app);
        assert!(out.contains("sub/"), "dir entry shown:\n{out}");
        assert!(out.contains("hello.txt"), "file entry shown:\n{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn opens_file_and_shows_text_then_hex() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "hello.txt");
        app.enter(); // open the file
        let text = render(&mut app);
        assert!(text.contains("line one"), "text content shown:\n{text}");
        assert!(text.contains("indent:"), "indent badge shown:\n{text}");

        app.cycle_mode(); // → HEX via mdvcore_core::hex::render_all
        let hex = render(&mut app);
        assert!(hex.contains("00000000"), "hex offset column shown:\n{hex}");
        assert!(hex.contains("· hex ·"), "title reflects hex mode:\n{hex}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn hex_of_binary_uses_core_render() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "data.bin");
        app.enter();
        app.cycle_mode();
        let hex = render(&mut app);
        // bytes 00 41 ff 7f → ".A.." in the ASCII gutter (core renderer).
        assert!(hex.contains("00 41 ff 7f"), "raw hex bytes:\n{hex}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn csv_opens_as_table_via_core() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "people.csv");
        app.enter(); // CSV defaults to Table mode, parsed by mdvcore_core::csv
        let out = render(&mut app);
        assert!(out.contains("· table ·"), "title shows table mode:\n{out}");
        assert!(out.contains("name"), "header cell shown:\n{out}");
        assert!(out.contains("Alice"), "body cell shown:\n{out}");
        assert!(out.contains("NYC"), "third-column cell shown:\n{out}");
        // x cycles table → text → hex; from table the next is text.
        app.cycle_mode();
        let text = render(&mut app);
        assert!(text.contains("· text ·"), "cycled to text:\n{text}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn navigates_into_and_out_of_subdir() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "sub");
        app.enter();
        assert!(app.cwd.ends_with("sub"));
        app.go_parent();
        assert_eq!(app.cwd, dir.canonicalize().unwrap_or(dir.clone()));
        let _ = fs::remove_dir_all(&dir);
    }
}
