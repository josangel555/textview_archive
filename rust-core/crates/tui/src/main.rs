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
//! parent · x toggle text/hex · n toggle line-number gutter · s cycle sort · .
//! toggle hidden/dotfiles · f quick-find (type to narrow, ↵ opens the top hit,
//! ESC clears) · : go-to-line (type a number, ↵ jumps + centers + flashes the
//! row, ESC cancels) · / in-file find (type a query, ↵ jumps to the first match
//! + centers + flashes; then n/N step next/prev, ESC clears the find; in Table
//! mode `/` opens the column filter instead) · o markdown outline (open a `.md`
//! file, ↑/↓ pick a heading, ↵ jumps to it, ESC/o closes) · g/G top/bottom ·
//! PgUp/PgDn scroll · q quit.

use std::cell::RefCell;
use std::fs;
use std::io;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::UNIX_EPOCH;

use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Cell, Clear, List, ListItem, ListState, Paragraph, Row, Table, Wrap};
use ratatui::{Frame, Terminal};
use ratatui::backend::TestBackend;

use mdvcore_core::nav::{self, SortKey};
use mdvcore_core::outline::{self, Heading};
use mdvcore_core::filter;
use mdvcore_core::find;
use mdvcore_core::git;
use mdvcore_core::history;
use mdvcore_core::meta;
use mdvcore_core::hex::{self, HexSearchMode};
use mdvcore_core::view::{self, DiffLineKind, FileKind, View, ViewBody, ViewMode};
use mdvcore_core::whitespace;
use mdvcore_core::theme::{self, Role};
use mdvcore_highlight::{Lang, Segment, TokenKind};

/// Bytes per hex-dump row (must match `mdvcore_core::hex::render_all`). A hex
/// search match at byte offset `o` lands on dump row `o / HEX_BYTES_PER_ROW`.
/// (TSK-205)
const HEX_BYTES_PER_ROW: usize = 16;

/// Max bytes read into a preview (keeps the TUI snappy; larger files truncate).
/// The per-mode shaping (text/hex/table caps) lives in `mdvcore_core::view`.
const PREVIEW_CAP: usize = 1024 * 1024;

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // `--snapshot [path]`: render ONE frame to an in-memory buffer and print it,
    // then exit. No TTY needed — for headless self-validation / demoing the UI
    // (mirrors the Swift app's --diagnose philosophy).
    let snapshot = args.iter().any(|a| a == "--snapshot");
    // Persistent session state (TSK-235): load saved prefs from
    // ~/.textview/tui/config. An explicit path arg wins; else fall back to the
    // persisted cwd (if it still exists); else the current dir.
    let cfg = config_path();
    let persisted = cfg.as_deref().and_then(load_config);
    let start = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .map(PathBuf::from)
        .or_else(|| persisted.as_ref().and_then(|p| p.cwd.clone()).filter(|d| d.is_dir()))
        .unwrap_or(std::env::current_dir()?);
    let mut app = App::new(start);
    if let Some(p) = &persisted {
        app.apply_prefs(p);
        // TSK-515: re-open last session's buffers (path + scroll + per-file mode),
        // best-effort (missing files skipped, scroll clamped, mode falls back).
        app.restore_tabs(&p.tabs, p.active);
    }
    if snapshot {
        // Pre-open the first file so the content pane shows something.
        if let Some(i) = app.entries.iter().position(|e| !e.is_dir) {
            app.list.select(Some(i));
            app.enter();
        }
        print!("{}", app.snapshot(100, 30)?);
        return Ok(());
    }
    let mut terminal = ratatui::init();
    let result = app.run(&mut terminal);
    ratatui::restore();
    // Persist prefs on exit (TSK-235, best-effort — never blocks quit).
    if let Some(path) = &cfg {
        save_config(path, &app.persist_state());
    }
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

struct Entry {
    name: String,
    is_dir: bool,
    is_parent: bool,
    /// Modification time (whole seconds since the Unix epoch) for the `Modified`
    /// sort key; `None` when the entry couldn't be stat'd.
    mtime: Option<u64>,
    /// Byte size for the `Size` sort key.
    size: u64,
}

/// A directory entry pre-formatted for the file list, built once per directory
/// reload and reused on every frame. `draw_files` runs on every keypress (incl.
/// content-pane-only scroll keys); rebuilding the label `String`s per frame
/// would scale per-frame work with directory size, not the visible viewport.
struct ListRow {
    /// Display label (`name` or `name/` for directories) — the expensive part
    /// (`format!`/`clone`) we cache so frames only borrow it into a `Span`.
    label: String,
    is_dir: bool,
}

/// A loaded file: the raw bytes + metadata, plus the current shaped `View` from
/// the shared `mdvcore_core::view` (the same shaping the web front-end uses).
struct Preview {
    /// Absolute path the bytes were read from — kept so `reload_current` (the
    /// `r` key) can re-read the same file after it changes on disk.
    path: PathBuf,
    name: String,
    total: usize,
    truncated: bool,
    raw: Vec<u8>,
    kind: FileKind,
    view: View,
    scroll: usize,
    /// Applied CSV table-filter needle (`""` = no filter). A `col:term` form
    /// scopes to a column; otherwise it's a global any-cell substring (shared
    /// `view::table_query`). Only meaningful in `Table` mode. Lives on the
    /// Preview so it resets per file and so `content_len`/scroll stay correct.
    table_filter: String,
    /// `Some` while the table-filter prompt is open and capturing keys; holds
    /// the live (uncommitted) needle so results update as you type. `None` = the
    /// prompt is closed and `table_filter` (the committed needle) is in effect.
    table_filter_editing: Option<String>,
    /// Lazily-computed syntax-highlight spans (TSK-257), one `Vec<Segment>` per
    /// Text line. Filled on first Text render with a recognised language and
    /// reused for the file's life (the bytes are immutable per Preview; a reload
    /// builds a fresh Preview → fresh cache). `RefCell` so it can memoise during
    /// the `&self` render without a parsing pass every frame (files cap at 200k
    /// lines, so per-frame re-parse would be far too slow).
    hl_cache: RefCell<Option<Vec<Vec<Segment>>>>,
}

impl Preview {
    /// The highlight language for this file, by extension (`None` = unsupported
    /// → plain rendering).
    fn lang(&self) -> Option<Lang> {
        let ext = self.name.rsplit_once('.').map(|(_, e)| e)?;
        Lang::from_extension(ext)
    }

    /// Per-line highlight segments for the given DISPLAY lines, computing +
    /// caching on first call. `lines` is the Text body (tab-expanded /
    /// `\r`-stripped) — we join with `\n` and let the engine split, so segment
    /// boundaries line up with the rendered columns. Returns `None` when the
    /// language is unsupported.
    fn highlighted_lines(&self, lines: &[String]) -> Option<std::cell::Ref<'_, Vec<Vec<Segment>>>> {
        let lang = self.lang()?;
        if self.hl_cache.borrow().is_none() {
            let src = lines.join("\n");
            *self.hl_cache.borrow_mut() = Some(mdvcore_highlight::highlight_lines(&src, lang));
        }
        Some(std::cell::Ref::map(self.hl_cache.borrow(), |o| {
            o.as_ref().expect("just filled above")
        }))
    }

    /// Scrollable item count for the current mode (lines, table rows, or the
    /// FILTERED table-row count when a CSV filter is active).
    fn content_len(&self) -> usize {
        match &self.view.body {
            ViewBody::Text(l) | ViewBody::Hex(l) => l.len(),
            ViewBody::Table { header, rows, .. } => self.filtered_table_indices(header, rows).len(),
            ViewBody::Diff(lines) => lines.len(),
            // The image card is a fixed panel, not a scrollable list.
            ViewBody::Image(_) => 0,
        }
    }

    /// The effective table-filter needle: the live prompt text while editing,
    /// else the committed `table_filter`.
    fn table_needle(&self) -> &str {
        self.table_filter_editing.as_deref().unwrap_or(&self.table_filter)
    }

    /// Original-row indices that survive the active filter (no row cloning), via
    /// the shared `view::table_query` + `filter::matching_indices_in`.
    fn filtered_table_indices(&self, header: &[String], rows: &[Vec<String>]) -> Vec<u32> {
        let query = view::table_query(header, self.table_needle());
        filter::matching_indices_in(rows, &query)
    }
}

/// One cross-file grep result (TSK-213): the file it's in, the 0-based matching
/// line, and that line's text — the row the results overlay shows and the target
/// Enter opens.
#[derive(Clone)]
struct GrepHit {
    path: PathBuf,
    line: usize,
    text: String,
}

/// How many recently-opened files the in-session history keeps (TSK-233).
const RECENT_CAP: usize = 20;

/// A command-palette action (TSK-408). Copy so the static table + selection are
/// trivially passed around; dispatched by `run_palette_cmd`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Cmd {
    CycleSort,
    ToggleHidden,
    ToggleGutter,
    ToggleWhitespace,
    ToggleWrap,
    Find,
    Grep,
    Outline,
    Recent,
    Reload,
    NextTab,
    PrevTab,
    CloseTab,
    Top,
    Bottom,
    Help,
}

/// The command palette's static action list: the label shown / fuzzy-matched, and
/// the [`Cmd`] it runs. Declaration order is the empty-query display order.
const PALETTE: &[(&str, Cmd)] = &[
    ("find in file", Cmd::Find),
    ("grep across files", Cmd::Grep),
    ("outline (markdown headings)", Cmd::Outline),
    ("recent files", Cmd::Recent),
    ("reload file from disk", Cmd::Reload),
    ("next tab", Cmd::NextTab),
    ("previous tab", Cmd::PrevTab),
    ("close tab", Cmd::CloseTab),
    ("cycle sort order", Cmd::CycleSort),
    ("toggle hidden files", Cmd::ToggleHidden),
    ("toggle line numbers", Cmd::ToggleGutter),
    ("toggle whitespace markers", Cmd::ToggleWhitespace),
    ("toggle word-wrap", Cmd::ToggleWrap),
    ("go to top", Cmd::Top),
    ("go to bottom", Cmd::Bottom),
    ("keyboard help", Cmd::Help),
];

/// TUI color theme (TSK-243). `Adaptive` defers to the terminal's own ANSI
/// theme (the original behavior — zero change by default); `Dark`/`Light` apply
/// the fixed `mdvcore_core::theme` palette so the look is consistent regardless
/// of the terminal theme. Cycled with `t`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum ThemeMode {
    Adaptive,
    Dark,
    Light,
}

/// Persisted front-end session state (TSK-235), saved to `~/.textview/tui/config`
/// on quit and restored on launch (owner-chosen `~/.textview/<frontend>` location;
/// the web front-end uses `wui/`). App-global view/nav preferences only — last
/// dir + sort + dotfile/wrap/gutter toggles + theme. Restoring the last OPEN file
/// + scroll + per-file mode is a follow-up (it needs reopen logic for files that
/// may have moved/changed). Hand-rolled `key=value` codec: no serde dep, no panics
/// (the rust-core gate denies both), lenient to hand-edits.
#[derive(Clone, PartialEq, Eq, Debug)]
struct PersistState {
    cwd: Option<PathBuf>,
    sort: SortKey,
    show_hidden: bool,
    wrap: bool,
    show_gutter: bool,
    theme: ThemeMode,
    /// Open file buffers to restore (TSK-515 phase 2), in tab order. Empty =
    /// nothing was open / nothing to restore.
    tabs: Vec<OpenTab>,
    /// Index of the active tab among `tabs` on restore, clamped to the number
    /// actually re-opened. Meaningless when `tabs` is empty.
    active: usize,
}

/// One persisted open buffer (TSK-515): the file path, its saved scroll
/// offset, and the view mode it was last shown in. Restored best-effort on
/// launch — skipped if the file vanished, scroll clamped to the file's current
/// length, mode falling back to the kind's default if no longer offered.
#[derive(Clone, PartialEq, Eq, Debug)]
struct OpenTab {
    path: PathBuf,
    scroll: usize,
    mode: ViewMode,
}

impl Default for PersistState {
    fn default() -> Self {
        PersistState {
            cwd: None,
            sort: SortKey::Name,
            show_hidden: false,
            wrap: true,
            show_gutter: true,
            theme: ThemeMode::Adaptive,
            tabs: Vec::new(),
            active: 0,
        }
    }
}

impl PersistState {
    /// Serialize to a `key=value` config (one per line).
    fn to_config(&self) -> String {
        let mut s = String::new();
        if let Some(cwd) = &self.cwd {
            s.push_str(&format!("cwd={}\n", cwd.display()));
        }
        s.push_str(&format!("sort={}\n", sort_token(self.sort)));
        s.push_str(&format!("hidden={}\n", self.show_hidden));
        s.push_str(&format!("wrap={}\n", self.wrap));
        s.push_str(&format!("gutter={}\n", self.show_gutter));
        s.push_str(&format!("theme={}\n", theme_token(self.theme)));
        // Open buffers (TSK-515): one `tab=<mode> <scroll> <path>` line each, in
        // tab order, then the active index. Mode + scroll are the first two
        // space-delimited fields; the path is the rest (so spaces in paths
        // survive). Only emitted when something is open — a prefs-only state
        // stays byte-identical to phase 1.
        for t in &self.tabs {
            s.push_str(&format!(
                "tab={} {} {}\n",
                mode_token(t.mode),
                t.scroll,
                t.path.display()
            ));
        }
        if !self.tabs.is_empty() {
            s.push_str(&format!("active={}\n", self.active));
        }
        s
    }

    /// Parse a `key=value` config. Unknown keys are ignored, missing/malformed
    /// values fall back to the default — never panics, never errors.
    fn from_config(text: &str) -> Self {
        let mut st = PersistState::default();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((k, v)) = line.split_once('=') else { continue };
            let (k, v) = (k.trim(), v.trim());
            match k {
                "cwd" => st.cwd = if v.is_empty() { None } else { Some(PathBuf::from(v)) },
                "sort" => st.sort = sort_from_token(v).unwrap_or(st.sort),
                "hidden" => st.show_hidden = parse_bool(v).unwrap_or(st.show_hidden),
                "wrap" => st.wrap = parse_bool(v).unwrap_or(st.wrap),
                "gutter" => st.show_gutter = parse_bool(v).unwrap_or(st.show_gutter),
                "theme" => st.theme = theme_from_token(v).unwrap_or(st.theme),
                // TSK-515: each well-formed `tab=` line appends a buffer to
                // restore; malformed/unknown-mode lines are skipped (lenient).
                "tab" => {
                    if let Some(t) = parse_tab(v) {
                        st.tabs.push(t);
                    }
                }
                "active" => st.active = v.parse().unwrap_or(st.active),
                _ => {}
            }
        }
        st
    }
}

/// Parse a `tab` config value `"<mode> <scroll> <path>"` (TSK-515). Mode + scroll
/// are the first two space-delimited fields; the REST is the path verbatim, so a
/// path containing spaces round-trips. `None` (skip the tab) when the mode token
/// is unknown or a field is missing; a non-numeric scroll degrades to 0. Never
/// panics — the rust-core gate denies that.
fn parse_tab(v: &str) -> Option<OpenTab> {
    let mut it = v.splitn(3, ' ');
    let mode = mode_from_token(it.next()?)?;
    let scroll = it.next()?.parse::<usize>().unwrap_or(0);
    let path = it.next()?;
    if path.is_empty() {
        return None;
    }
    Some(OpenTab {
        path: PathBuf::from(path),
        scroll,
        mode,
    })
}

fn mode_token(m: ViewMode) -> &'static str {
    match m {
        ViewMode::Text => "text",
        ViewMode::Hex => "hex",
        ViewMode::Table => "table",
        ViewMode::Diff => "diff",
        ViewMode::Image => "image",
        ViewMode::Formatted => "formatted",
    }
}
fn mode_from_token(v: &str) -> Option<ViewMode> {
    match v {
        "text" => Some(ViewMode::Text),
        "hex" => Some(ViewMode::Hex),
        "table" => Some(ViewMode::Table),
        "diff" => Some(ViewMode::Diff),
        "image" => Some(ViewMode::Image),
        "formatted" => Some(ViewMode::Formatted),
        _ => None,
    }
}

fn parse_bool(v: &str) -> Option<bool> {
    match v {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}
fn sort_token(s: SortKey) -> &'static str {
    match s {
        SortKey::Name => "name",
        SortKey::Modified => "modified",
        SortKey::Size => "size",
    }
}
fn sort_from_token(v: &str) -> Option<SortKey> {
    match v {
        "name" => Some(SortKey::Name),
        "modified" => Some(SortKey::Modified),
        "size" => Some(SortKey::Size),
        _ => None,
    }
}
fn theme_token(t: ThemeMode) -> &'static str {
    match t {
        ThemeMode::Adaptive => "adaptive",
        ThemeMode::Dark => "dark",
        ThemeMode::Light => "light",
    }
}
fn theme_from_token(v: &str) -> Option<ThemeMode> {
    match v {
        "adaptive" => Some(ThemeMode::Adaptive),
        "dark" => Some(ThemeMode::Dark),
        "light" => Some(ThemeMode::Light),
        _ => None,
    }
}

/// `~/.textview/tui/config` — the owner-chosen per-front-end config location
/// (TSK-235). `None` when `$HOME` is unset (we then run without persistence
/// rather than guessing a path).
fn config_path() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".textview").join("tui").join("config"))
}

/// Read + parse the config at `path`. `None` if it's absent / unreadable.
fn load_config(path: &Path) -> Option<PersistState> {
    let text = fs::read_to_string(path).ok()?;
    Some(PersistState::from_config(&text))
}

/// Write the config to `path`, creating parent dirs. Best-effort — a write
/// failure (read-only HOME, etc.) is swallowed so it never breaks the app.
fn save_config(path: &Path, state: &PersistState) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(path, state.to_config());
}

struct App {
    cwd: PathBuf,
    /// Recently-opened files, newest-first, de-duplicated and capped at
    /// [`RECENT_CAP`] via the shared `history::push` (TSK-233). In-session only —
    /// disk persistence is the separate TSK-235. `R` opens the picker overlay.
    recent: Vec<PathBuf>,
    /// `true` while the recents picker overlay is open (captures ↑/↓/↵/ESC).
    recent_open: bool,
    /// Selected row in the recents overlay; indexes into `recent`.
    recent_sel: usize,
    /// `Some(query)` while the command palette is open (TSK-408); the live fuzzy
    /// query. `None` = closed.
    palette: Option<String>,
    /// Ranked `PALETTE` indices matching the current query (best-first).
    palette_hits: Vec<usize>,
    /// Selected row in the palette overlay; indexes into `palette_hits`.
    palette_sel: usize,
    /// Git working-tree summary for `cwd` (branch + ahead/behind + dirty counts),
    /// refreshed by `reload_dir` via the shared `git::parse_status`. `None` when
    /// `cwd` isn't a git repo (or git isn't installed) — the title omits it.
    git_status: Option<git::RepoStatus>,
    entries: Vec<Entry>,
    /// Pre-formatted file-list rows, rebuilt in `reload_dir` (1:1 with
    /// `entries`) and reused by `draw_files` so per-frame work is viewport-
    /// bounded rather than scaling with directory size.
    list_rows: Vec<ListRow>,
    list: ListState,
    /// Open file buffers as TABS (TSK-249): each carries its own scroll/mode/
    /// find-independent `Preview` state, so switching tabs preserves where you
    /// were. `tabs.get(active)` is the rendered buffer (replaces the old single
    /// `preview` field — call sites read `self.tabs.get(self.active)` inline to
    /// keep partial borrows). Empty = nothing open yet.
    tabs: Vec<Preview>,
    /// Index of the active tab in `tabs`; meaningless when `tabs` is empty.
    active: usize,
    status: String,
    /// Last-drawn content-pane inner height, used for page scrolling.
    content_height: usize,
    /// Active file-list sort key (cycled with `s`); dirs always group first.
    sort: SortKey,
    /// Whether dotfiles (names with a leading `.`) are listed. Toggled with `.`;
    /// the dir is re-listed so the filter applies to the freshly `read_dir`'d set.
    show_hidden: bool,
    /// Type-to-narrow quick-find state. `Some(needle)` means the filter prompt
    /// is active and capturing keys; the files pane shows only entries matching
    /// `needle` via `nav::filter_entries`, ranked best-first. `None` means the
    /// prompt is closed and the full listing is shown. Toggled with `f`; ESC
    /// clears + closes; Enter opens the top hit.
    filter: Option<String>,
    /// When the filter prompt is active, the subset of `entries` indices that
    /// match the current needle, in best-first (ranked) order. The visible list
    /// is built from this, and the `ListState` selection indexes INTO it (not
    /// into `entries`), so `filtered[selection]` is the real entry index.
    filtered: Vec<usize>,
    /// Whether the Text/HEX content pane prefixes each visible line with a
    /// right-aligned, DIM line-number gutter (width via `view::gutter_width`).
    /// Toggled with `n`; on by default. Table mode is unaffected (rows aren't
    /// line-numbered).
    show_gutter: bool,
    /// Whether the Text content pane renders whitespace as visible markers
    /// (spaces → ·, tabs → →) via the shared `whitespace::reveal`. Toggled with
    /// `i`; off by default. Text mode only (HEX/table are unaffected).
    show_whitespace: bool,
    /// Whether the Text content pane soft-wraps long lines (on by default) or —
    /// when off — truncates them at the pane edge. Toggled with `w`.
    wrap: bool,
    /// Active color theme (TSK-243). `Adaptive` (default) renders today's exact
    /// ANSI colors; `Dark`/`Light` route the chrome through the core palette.
    /// Cycled with `t`.
    theme_mode: ThemeMode,
    /// Whether the keyboard-help overlay is open (TSK-247). Toggled with `?`;
    /// any key dismisses it. A centered popup listing every keybinding, drawn
    /// over the panes — so the full shortcut set is discoverable without leaving
    /// the app or squinting at the truncated bottom help line.
    show_help: bool,
    /// Cross-file grep prompt (TSK-213). `Some(needle)` means the `F` "search
    /// anywhere" box is open and capturing text; Enter runs the recursive grep,
    /// ESC cancels. `None` means closed.
    grep_prompt: Option<String>,
    /// Results of the last committed cross-file grep. Non-empty (with the prompt
    /// closed) means the results overlay is open: ↑/↓ pick a hit, Enter opens that
    /// file at the line, ESC closes. Cleared when a result is opened or dismissed.
    grep_results: Vec<GrepHit>,
    /// Selected row in the grep results overlay (index into `grep_results`).
    grep_sel: usize,
    /// Go-to-line prompt state. `Some(digits)` means the `:` prompt is open and
    /// capturing a numeric line target; the content-pane title shows the live
    /// "goto: N" input. On Enter the (1-based) line is clamped via
    /// `view::clamp_line`, the content scrolls so the target sits centered, and
    /// `flash` marks the row for a one-frame highlight. `None` means the prompt
    /// is closed. Opened with `:`; ESC cancels; only ASCII digits are captured.
    goto: Option<String>,
    /// 0-based index of the line the last go-to-line jump landed on, highlighted
    /// (reversed) for one render so the eye catches where it jumped. Cleared on
    /// the next scroll / mode change / file open so the flash doesn't linger.
    flash: Option<usize>,
    /// Markdown-outline overlay state. `Some(headings)` means the `o` overlay is
    /// open: it lists the open file's headings (level · title, indented by level)
    /// over the content pane. `None` means closed. Only opened for a markdown
    /// file that actually has at least one heading (`outline::headings`). The
    /// selected row lives in `outline_sel`; Enter jumps to the heading's line via
    /// the same clamp+center path as go-to-line. Built once on open (not per
    /// frame) so the scan cost is paid on the keystroke, not every render.
    outline: Option<Vec<Heading>>,
    /// Selected row in the outline overlay (index into `outline`), kept in range
    /// as the user moves with ↑/↓. Meaningless while `outline` is `None`.
    outline_sel: usize,
    /// In-file find prompt state. `Some(query)` means the `/` find box is open
    /// (in text/hex modes; `/` opens the table filter in Table mode) and
    /// capturing the literal query; the content-pane title shows the live input.
    /// On Enter the query is run through `find::find_matches` over the raw text;
    /// `None` means the prompt is closed. ASCII-case-insensitive.
    find: Option<String>,
    /// The committed query that produced `find_matches`, kept for the status
    /// readout ("find: i of n") and shown verbatim. Empty when no find is active.
    find_query: String,
    /// Matches of `find_query` across the open file, in document order (from the
    /// shared `find::find_matches`). Non-empty ⇒ a find is active: `n`/`N`
    /// navigate it (and `n` no longer toggles the gutter), `Esc` dismisses it.
    /// Cleared when the open file changes.
    find_matches: Vec<find::Match>,
    /// Index into `find_matches` of the current match (the one centered+flashed).
    /// Stepped by `n`/`N`; meaningless when `find_matches` is empty.
    find_sel: usize,
    /// True when the active matches came from a HEX byte/ASCII search (TSK-205)
    /// instead of the text find — each `.line` is a hex-dump ROW (byte/16), so
    /// the jump stays in Hex mode rather than forcing Text.
    find_is_hex: bool,
}

impl App {
    fn new(start: PathBuf) -> Self {
        let cwd = start.canonicalize().unwrap_or(start);
        let mut app = App {
            cwd,
            recent: Vec::new(),
            recent_open: false,
            recent_sel: 0,
            palette: None,
            palette_hits: Vec::new(),
            palette_sel: 0,
            git_status: None,
            entries: Vec::new(),
            list_rows: Vec::new(),
            list: ListState::default(),
            tabs: Vec::new(),
            active: 0,
            status: String::new(),
            content_height: 1,
            sort: SortKey::Name,
            show_hidden: false,
            filter: None,
            filtered: Vec::new(),
            show_gutter: true,
            show_whitespace: false,
            wrap: true,
            theme_mode: ThemeMode::Adaptive,
            show_help: false,
            grep_prompt: None,
            grep_results: Vec::new(),
            grep_sel: 0,
            goto: None,
            flash: None,
            outline: None,
            outline_sel: 0,
            find: None,
            find_query: String::new(),
            find_matches: Vec::new(),
            find_sel: 0,
            find_is_hex: false,
        };
        app.reload_dir();
        app
    }

    /// Cycle the color theme Adaptive → Dark → Light → Adaptive (TSK-243, `t`).
    fn cycle_theme(&mut self) {
        self.theme_mode = match self.theme_mode {
            ThemeMode::Adaptive => ThemeMode::Dark,
            ThemeMode::Dark => ThemeMode::Light,
            ThemeMode::Light => ThemeMode::Adaptive,
        };
        let label = match self.theme_mode {
            ThemeMode::Adaptive => "adaptive (terminal)",
            ThemeMode::Dark => "dark",
            ThemeMode::Light => "light",
        };
        self.status = format!("theme: {label}");
    }

    /// Resolve a semantic [`Role`] to a ratatui `Color`. In `Adaptive` mode this
    /// returns `adaptive` verbatim — the caller's existing ANSI color, so the
    /// default look is byte-identical to before. In `Dark`/`Light` it returns
    /// the core palette's `Color::Rgb`, painting a fixed look independent of the
    /// terminal theme (TSK-243).
    fn tc(&self, role: Role, adaptive: Color) -> Color {
        let mode = match self.theme_mode {
            ThemeMode::Adaptive => return adaptive,
            ThemeMode::Dark => theme::Mode::Dark,
            ThemeMode::Light => theme::Mode::Light,
        };
        let c = theme::Palette::for_mode(mode).color(role);
        Color::Rgb(c.r, c.g, c.b)
    }

    /// Capture the current app-global prefs + open buffers for persistence
    /// (TSK-235 prefs; TSK-515 open tabs — path + scroll + per-file view mode).
    fn persist_state(&self) -> PersistState {
        PersistState {
            cwd: Some(self.cwd.clone()),
            sort: self.sort,
            show_hidden: self.show_hidden,
            wrap: self.wrap,
            show_gutter: self.show_gutter,
            theme: self.theme_mode,
            tabs: self
                .tabs
                .iter()
                .map(|t| OpenTab {
                    path: t.path.clone(),
                    scroll: t.scroll,
                    mode: t.view.mode,
                })
                .collect(),
            active: self.active,
        }
    }

    /// Restore the persisted open buffers (TSK-515) best-effort, in tab order:
    /// each saved file that still exists is re-read + re-shaped in its saved
    /// mode (or the kind's default if that mode is no longer offered), scrolled
    /// to its clamped saved offset. Files that vanished / became unreadable are
    /// silently skipped (the user just lands on the file nav for those), so the
    /// restored `active` is clamped to however many tabs actually re-opened.
    fn restore_tabs(&mut self, tabs: &[OpenTab], active: usize) {
        for t in tabs {
            self.open_restored(&t.path, t.mode, t.scroll);
        }
        if !self.tabs.is_empty() {
            self.active = active.min(self.tabs.len() - 1);
        }
    }

    /// Open `path` into a NEW tab in `mode` (falling back to the kind's default
    /// when `mode` isn't offered for the file's type), scrolled to `scroll`
    /// clamped to the file's current content length. Silently returns if the
    /// file can't be read — the restore path must never abort startup (TSK-515).
    fn open_restored(&mut self, path: &Path, mode: ViewMode, scroll: usize) {
        let Ok((raw, truncated, total)) = read_capped(path, PREVIEW_CAP) else {
            return;
        };
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        let kind = view::classify(&name);
        // The file may have changed type since last launch; only honor the saved
        // mode if it's still offered for the (re-classified) kind.
        let mode = if view::available_modes(kind).contains(&mode) {
            mode
        } else {
            view::default_mode(kind)
        };
        let v = view::build(&raw, &name, total, truncated, mode);
        let mut p = Preview {
            path: path.to_path_buf(),
            name,
            total,
            truncated,
            raw,
            kind,
            view: v,
            scroll: 0,
            table_filter: String::new(),
            table_filter_editing: None,
            hl_cache: RefCell::new(None),
        };
        // Clamp the saved scroll into the (possibly grown/shrunk) content.
        let max_scroll = p.content_len().saturating_sub(1);
        p.scroll = scroll.min(max_scroll);
        self.tabs.push(p);
        self.recent =
            history::push(std::mem::take(&mut self.recent), path.to_path_buf(), RECENT_CAP);
    }

    /// Apply restored prefs (TSK-235): sort / dotfile / wrap / gutter / theme,
    /// then re-list so the sort + hidden filter take effect. `cwd` is applied by
    /// `main` (it picks the start dir BEFORE construction), so it's intentionally
    /// not re-applied here.
    fn apply_prefs(&mut self, p: &PersistState) {
        self.sort = p.sort;
        self.show_hidden = p.show_hidden;
        self.wrap = p.wrap;
        self.show_gutter = p.show_gutter;
        self.theme_mode = p.theme;
        self.reload_dir();
    }

    // MARK: - Directory navigation (the front-end owns IO; the core is sans-IO)

    fn reload_dir(&mut self) {
        let mut entries: Vec<Entry> = Vec::new();
        if self.cwd.parent().is_some() {
            entries.push(Entry {
                name: "..".into(),
                is_dir: true,
                is_parent: true,
                mtime: None,
                size: 0,
            });
        }
        match fs::read_dir(&self.cwd) {
            Ok(rd) => {
                let mut items: Vec<Entry> = rd
                    .filter_map(Result::ok)
                    .map(|e| {
                        let meta = e.metadata().ok();
                        let is_dir = meta.as_ref().map(fs::Metadata::is_dir).unwrap_or(false);
                        let size = meta.as_ref().map(fs::Metadata::len).unwrap_or(0);
                        let mtime = meta.as_ref().and_then(mtime_secs);
                        Entry {
                            name: e.file_name().to_string_lossy().into_owned(),
                            is_dir,
                            is_parent: false,
                            mtime,
                            size,
                        }
                    })
                    // Drop dotfiles unless `show_hidden` is on — the shared core
                    // rule, so TUI and web suppress the same names by construction.
                    .filter(|e| nav::should_show(&e.name, self.show_hidden))
                    .collect();
                // Order via the shared core sorter (dirs-first, active key) —
                // the SAME ordering the web front-end applies.
                sort_loaded(&mut items, self.sort);
                entries.extend(items);
                self.status = format!("{}", self.cwd.display());
            }
            Err(e) => self.status = format!("cannot read dir: {e}"),
        }
        // Refresh the git summary for the new cwd (front-end owns the IO; the
        // core only parses). Cheap enough to do per directory change.
        self.git_status = git_status_for(&self.cwd);
        self.rebuild_rows(entries);
    }

    /// The files-pane title for the normal (non-filter) state: breadcrumb + sort
    /// key + dotfile state, plus the git working-tree summary when `cwd` is a
    /// repo. Extracted so the composition is host-testable independent of ratatui
    /// block clipping (a narrow pane truncates the tail on screen).
    fn files_title(&self) -> String {
        let hidden = if self.show_hidden { " · hidden shown" } else { " · . shows hidden" };
        let git = self
            .git_status
            .as_ref()
            .map(|g| format!(" · git: {}", g.summary()))
            .unwrap_or_default();
        format!(" {} · sort: {}{hidden}{git} ", breadcrumb_trail(&self.cwd), self.sort.as_str())
    }

    /// Re-sort the already-loaded entries by the active key (no `read_dir`),
    /// keeping the `..` parent row pinned at the top. Used by the `s` toggle so
    /// re-ordering doesn't re-stat the directory.
    fn resort(&mut self) {
        let mut entries = std::mem::take(&mut self.entries);
        // Split off the pinned `..` row (always index 0 when present) so the
        // sorter only orders real entries; re-prepend it after.
        let parent = if entries.first().is_some_and(|e| e.is_parent) {
            Some(entries.remove(0))
        } else {
            None
        };
        sort_loaded(&mut entries, self.sort);
        if let Some(p) = parent {
            entries.insert(0, p);
        }
        self.rebuild_rows(entries);
    }

    /// Cache the per-entry display labels (rebuilt only when `entries` changes,
    /// so `draw_files` never reallocates per frame) and reset the selection.
    fn rebuild_rows(&mut self, entries: Vec<Entry>) {
        self.list_rows = entries
            .iter()
            .map(|e| ListRow {
                label: if e.is_dir && !e.is_parent { format!("{}/", e.name) } else { e.name.clone() },
                is_dir: e.is_dir,
            })
            .collect();
        self.entries = entries;
        self.list.select(if self.entries.is_empty() { None } else { Some(0) });
    }

    /// Cycle to the next sort key and re-order the current listing.
    fn cycle_sort(&mut self) {
        self.sort = self.sort.next();
        self.resort();
    }

    /// Toggle dotfile visibility and re-list the directory. We `read_dir` again
    /// (rather than re-sort the cached set) because hidden entries were dropped
    /// at load time, so they aren't present to un-filter.
    fn toggle_hidden(&mut self) {
        self.show_hidden = !self.show_hidden;
        self.reload_dir();
    }

    // MARK: - Type-to-narrow quick file find (shared `nav::filter_entries`)

    /// Whether the quick-find prompt is open and capturing keys.
    fn filtering(&self) -> bool {
        self.filter.is_some()
    }

    /// Open the quick-find prompt with an empty needle (lists everything ranked
    /// neutrally), or — if already open — leave it as-is. Re-entrant `f` is a
    /// no-op so it can't clobber an in-progress needle.
    fn open_filter(&mut self) {
        if self.filter.is_none() {
            self.filter = Some(String::new());
            self.recompute_filter();
        }
    }

    /// Close the quick-find prompt and clear the needle, restoring the full
    /// listing and resetting the selection to the top.
    fn clear_filter(&mut self) {
        self.filter = None;
        self.filtered.clear();
        self.list.select(if self.entries.is_empty() { None } else { Some(0) });
    }

    /// Append a typed character to the needle and re-narrow live.
    fn filter_push(&mut self, c: char) {
        if let Some(n) = &mut self.filter {
            n.push(c);
            self.recompute_filter();
        }
    }

    /// Delete the last needle character and re-narrow live.
    fn filter_backspace(&mut self) {
        if let Some(n) = &mut self.filter {
            n.pop();
            self.recompute_filter();
        }
    }

    /// Recompute the matching subset from the current needle via the shared core
    /// scorer (`nav::filter_entries`, best-first ranked) and pin the selection to
    /// the top hit. The `..` parent row is excluded from the match set — quick-
    /// find narrows to *named* entries; the user navigates up with the dedicated
    /// parent key. Case-insensitive (filenames; matches the nav name handling).
    fn recompute_filter(&mut self) {
        let Some(needle) = self.filter.clone() else {
            self.filtered.clear();
            return;
        };
        // Build the candidate name slice with stable indices, skipping `..`.
        let candidates: Vec<(usize, &str)> = self
            .entries
            .iter()
            .enumerate()
            .filter(|(_, e)| !e.is_parent)
            .map(|(i, e)| (i, e.name.as_str()))
            .collect();
        let names: Vec<&str> = candidates.iter().map(|(_, n)| *n).collect();
        // `filter_entries` returns (position-in-`names`, score) best-first; map
        // each back to the real `entries` index it came from.
        self.filtered = nav::filter_entries(&names, &needle, false)
            .into_iter()
            .filter_map(|(pos, _)| candidates.get(pos).map(|(i, _)| *i))
            .collect();
        self.list.select(if self.filtered.is_empty() { None } else { Some(0) });
    }

    /// Resolve the current selection to a real `entries` index, honoring the
    /// active filter (the `ListState` selection indexes into `filtered` when the
    /// prompt is open, else directly into `entries`).
    fn selected_entry_index(&self) -> Option<usize> {
        let sel = self.list.selected()?;
        if self.filtering() {
            self.filtered.get(sel).copied()
        } else {
            Some(sel)
        }
    }

    fn selected(&self) -> Option<&Entry> {
        self.selected_entry_index().and_then(|i| self.entries.get(i))
    }

    /// Count of currently-visible rows (the filtered subset when narrowing, else
    /// the full listing) — the bound the selection clamps against.
    fn visible_len(&self) -> usize {
        if self.filtering() { self.filtered.len() } else { self.entries.len() }
    }

    fn move_selection(&mut self, delta: isize) {
        let len = self.visible_len();
        if len == 0 {
            return;
        }
        let cur = self.list.selected().unwrap_or(0) as isize;
        let next = (cur + delta).clamp(0, len as isize - 1);
        self.list.select(Some(next as usize));
    }

    /// Enter the selected entry: descend a dir, or open a file into the viewer.
    /// A directory change closes the quick-find prompt (the needle belongs to
    /// the directory it was typed in); opening a *file* in place leaves the
    /// narrowed listing intact so the user can keep skimming hits.
    fn enter(&mut self) {
        let Some(entry) = self.selected() else { return };
        if entry.is_parent {
            if let Some(parent) = self.cwd.parent().map(Path::to_path_buf) {
                self.clear_filter();
                self.cwd = parent;
                self.reload_dir();
            }
            return;
        }
        let path = self.cwd.join(&entry.name);
        if entry.is_dir {
            self.clear_filter();
            self.cwd = path;
            self.reload_dir();
        } else {
            self.open_file(&path);
        }
    }

    fn go_parent(&mut self) {
        if let Some(parent) = self.cwd.parent().map(Path::to_path_buf) {
            self.clear_filter();
            self.cwd = parent;
            self.reload_dir();
        }
    }

    fn open_file(&mut self, path: &Path) {
        // Already open in a tab? Focus it (preserving its scroll/mode/etc) rather
        // than re-reading — `r` is the explicit reload. (TSK-249)
        if let Some(i) = self.tabs.iter().position(|t| t.path == path) {
            self.active = i;
            self.flash = None;
            self.outline = None;
            self.clear_find();
            self.recent = history::push(std::mem::take(&mut self.recent), path.to_path_buf(), RECENT_CAP);
            self.status = format!("switched to {}", path.display());
            return;
        }
        match read_capped(path, PREVIEW_CAP) {
            Ok((raw, truncated, total)) => {
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.display().to_string());
                // The shared core view-model does ALL the shaping (file-type
                // detect, mode set, text/hex/table build, indent badge) — the
                // same path the web front-end uses.
                let kind = view::classify(&name);
                let v = view::build(&raw, &name, total, truncated, view::default_mode(kind));
                // New buffer → push a tab and make it active (TSK-249).
                self.tabs.push(Preview {
                    path: path.to_path_buf(),
                    name,
                    total,
                    truncated,
                    raw,
                    kind,
                    view: v,
                    scroll: 0,
                    table_filter: String::new(),
                    table_filter_editing: None,
                    hl_cache: RefCell::new(None),
                });
                self.active = self.tabs.len() - 1;
                self.flash = None;
                self.outline = None; // a stale outline belongs to the old file
                self.clear_find(); // matches/needle belong to the old file
                // Record the open in the MRU history (shared `history::push`):
                // re-opening bumps to front, no dups, capped (TSK-233).
                self.recent = history::push(
                    std::mem::take(&mut self.recent),
                    path.to_path_buf(),
                    RECENT_CAP,
                );
                self.status = format!("opened {}", path.display());
            }
            Err(e) => self.status = format!("open failed: {e}"),
        }
    }

    /// Re-read the open file from disk and re-shape it (the `r` key / TSK-239).
    /// Preserves the CURRENT view mode and clamps the saved scroll to the new
    /// content length, so picking up an external edit doesn't reset the user's
    /// place or mode. The active table filter survives too. If the file's type
    /// changed on disk such that the current mode is no longer offered, falls
    /// back to the new kind's default mode. Find matches are cleared (offsets
    /// belonged to the old content).
    fn reload_current(&mut self) {
        let Some(p) = self.tabs.get(self.active) else { return };
        let path = p.path.clone();
        let prev_mode = p.view.mode;
        let prev_scroll = p.scroll;
        let table_filter = p.table_filter.clone();
        match read_capped(&path, PREVIEW_CAP) {
            Ok((raw, truncated, total)) => {
                let shown = path.display().to_string();
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| shown.clone());
                let kind = view::classify(&name);
                // Keep the mode the user was in unless the file changed type and
                // no longer offers it.
                let mode = if view::available_modes(kind).contains(&prev_mode) {
                    prev_mode
                } else {
                    view::default_mode(kind)
                };
                let v = view::build(&raw, &name, total, truncated, mode);
                let mut next = Preview {
                    path,
                    name,
                    total,
                    truncated,
                    raw,
                    kind,
                    view: v,
                    scroll: 0,
                    table_filter,
                    table_filter_editing: None,
                    hl_cache: RefCell::new(None),
                };
                // Clamp the old scroll into the (possibly shorter) new content.
                let max_scroll = next.content_len().saturating_sub(1);
                next.scroll = prev_scroll.min(max_scroll);
                // Replace the active tab in place (reload keeps the same tab).
                if let Some(slot) = self.tabs.get_mut(self.active) {
                    *slot = next;
                }
                self.flash = None;
                self.outline = None; // a stale outline belongs to the old bytes
                self.clear_find(); // matches/needle belong to the old content
                self.status = format!("reloaded {shown}");
            }
            Err(e) => self.status = format!("reload failed: {e}"),
        }
    }

    /// Cycle to the next available view mode, re-shaping via the shared core.
    fn cycle_mode(&mut self) {
        if let Some(p) = self.tabs.get_mut(self.active) {
            let next = view::cycle(p.view.mode, p.kind);
            p.view = view::build(&p.raw, &p.name, p.total, p.truncated, next);
            p.scroll = 0;
        }
        self.flash = None;
    }

    /// Open-as: directly force the `idx`-th available view mode (0-based; the
    /// number keys map `1`→0, `2`→1, …). A deliberate forced override versus the
    /// `x` cycle — the web tier's `?mode=` equivalent. Out-of-range indices and a
    /// no-op re-select of the current mode are ignored. The applied table filter
    /// (on the Preview) survives the rebuild, so table→text→table keeps it.
    fn set_mode(&mut self, idx: usize) {
        if let Some(p) = self.tabs.get_mut(self.active) {
            if let Some(&mode) = p.view.available_modes.get(idx) {
                if mode != p.view.mode {
                    p.view = view::build(&p.raw, &p.name, p.total, p.truncated, mode);
                    p.scroll = 0;
                }
            }
        }
        self.flash = None;
    }

    fn scroll_by(&mut self, delta: isize) {
        if let Some(p) = self.tabs.get_mut(self.active) {
            let max = p.content_len().saturating_sub(1);
            let next = (p.scroll as isize + delta).clamp(0, max as isize);
            p.scroll = next as usize;
        }
        self.flash = None;
    }

    fn scroll_to(&mut self, top: bool) {
        if let Some(p) = self.tabs.get_mut(self.active) {
            p.scroll = if top { 0 } else { p.content_len().saturating_sub(1) };
        }
        self.flash = None;
    }

    // MARK: - Go to line (shared `view::clamp_line`)

    /// Whether the go-to-line prompt is open and capturing digits.
    fn goto_active(&self) -> bool {
        self.goto.is_some()
    }

    /// Open the go-to-line prompt with an empty target. A no-op when there's no
    /// open file (nothing to jump within) or the prompt is already open (so a
    /// re-pressed `:` can't clobber an in-progress number).
    fn open_goto(&mut self) {
        if self.tabs.get(self.active).is_some() && self.goto.is_none() {
            self.goto = Some(String::new());
        }
    }

    /// Cancel the go-to-line prompt without jumping.
    fn cancel_goto(&mut self) {
        self.goto = None;
    }

    /// Append an ASCII digit to the go-to-line target (non-digits are ignored so
    /// the field only ever holds a parseable number).
    fn goto_push(&mut self, c: char) {
        if let Some(g) = &mut self.goto {
            if c.is_ascii_digit() {
                g.push(c);
            }
        }
    }

    /// Delete the last digit of the go-to-line target.
    fn goto_backspace(&mut self) {
        if let Some(g) = &mut self.goto {
            g.pop();
        }
    }

    /// Commit the go-to-line prompt: parse the typed number, clamp it to a valid
    /// 1-based line via the shared `view::clamp_line`, scroll so the target sits
    /// centered in the content pane, and flash the row. An empty / blank field
    /// just closes the prompt. Centering keeps the jumped-to line visible with
    /// context above and below rather than pinned to the top edge.
    fn commit_goto(&mut self) {
        let Some(raw) = self.goto.take() else { return };
        let Some(p) = self.tabs.get_mut(self.active) else { return };
        let Ok(target) = raw.trim().parse::<usize>() else {
            // Empty / unparseable (e.g. bare `:` then Enter) — nothing to jump to.
            return;
        };
        let len = p.content_len();
        let line0 = view::clamp_line(target, len).saturating_sub(1); // 1-based → 0-based
        // Center the target in the viewport: put roughly half the visible rows
        // above it, clamped so we never scroll past the last line.
        let half = self.content_height / 2;
        let max_scroll = len.saturating_sub(1);
        p.scroll = line0.saturating_sub(half).min(max_scroll);
        self.flash = Some(line0);
    }

    // MARK: - Cross-file folder grep (shared `find::grep_lines`, TSK-213)

    /// Open the "search anywhere" prompt (`F`). Clears any prior results so the
    /// box starts fresh; a no-op if it's already open.
    fn open_grep(&mut self) {
        if self.grep_prompt.is_none() {
            self.grep_results.clear();
            self.grep_sel = 0;
            self.grep_prompt = Some(String::new());
        }
    }

    /// Whether the grep results overlay is open (results present, prompt closed).
    fn grep_overlay_open(&self) -> bool {
        self.grep_prompt.is_none() && !self.grep_results.is_empty()
    }

    /// Key handling while the grep prompt is open: ESC cancels, Enter runs the
    /// grep, Backspace trims, any printable char extends the needle.
    fn on_key_grep_prompt(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => self.grep_prompt = None,
            KeyCode::Enter => {
                if let Some(q) = self.grep_prompt.clone() {
                    self.run_grep(&q);
                }
            }
            KeyCode::Backspace => {
                if let Some(q) = &mut self.grep_prompt {
                    q.pop();
                }
            }
            KeyCode::Char(c) => {
                if let Some(q) = &mut self.grep_prompt {
                    q.push(c);
                }
            }
            _ => {}
        }
        false
    }

    /// Key handling while the grep results overlay is open: ↑/↓ (or j/k) move the
    /// selection, Enter opens the selected hit at its line, ESC/q close.
    fn on_key_grep_results(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc | KeyCode::Char('q') => self.grep_results.clear(),
            KeyCode::Down | KeyCode::Char('j') => {
                if self.grep_sel + 1 < self.grep_results.len() {
                    self.grep_sel += 1;
                }
            }
            KeyCode::Up | KeyCode::Char('k') => self.grep_sel = self.grep_sel.saturating_sub(1),
            KeyCode::Enter => self.open_grep_result(),
            _ => {}
        }
        false
    }

    /// Recursively grep readable text files under `cwd` for `needle`
    /// (case-insensitive literal via the shared `find::grep_lines`). Skips
    /// dotfiles unless `show_hidden`, skips binary/empty files
    /// (`view::content_state`), guards against symlink loops, and is bounded by
    /// the `GREP_*` caps so a huge tree can't hang the UI. Populates
    /// `grep_results` and closes the prompt.
    fn run_grep(&mut self, needle: &str) {
        const GREP_MAX_FILES: usize = 2000;
        const GREP_MAX_HITS: usize = 500;
        const GREP_PER_FILE: usize = 50;
        let needle = needle.trim();
        self.grep_results.clear();
        self.grep_sel = 0;
        if needle.is_empty() {
            self.grep_prompt = None;
            return;
        }
        let mut visited: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
        let mut stack: Vec<PathBuf> = vec![self.cwd.clone()];
        let mut files = 0usize;
        let mut out: Vec<GrepHit> = Vec::new();
        'walk: while let Some(d) = stack.pop() {
            if files >= GREP_MAX_FILES || out.len() >= GREP_MAX_HITS {
                break;
            }
            if let Ok(canon) = d.canonicalize() {
                if !visited.insert(canon) {
                    continue; // symlink loop — already scanned this dir
                }
            }
            let Ok(rd) = fs::read_dir(&d) else { continue };
            let mut entries: Vec<fs::DirEntry> = rd.filter_map(Result::ok).collect();
            entries.sort_by_key(fs::DirEntry::file_name);
            for e in entries {
                let name = e.file_name().to_string_lossy().into_owned();
                if !nav::should_show(&name, self.show_hidden) {
                    continue;
                }
                let p = e.path();
                if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    stack.push(p);
                    continue;
                }
                if files >= GREP_MAX_FILES {
                    break;
                }
                files += 1;
                let Ok((raw, _, _)) = read_capped(&p, PREVIEW_CAP) else { continue };
                if view::content_state(&raw) != view::ContentState::Readable {
                    continue; // empty or binary
                }
                let remaining = GREP_MAX_HITS.saturating_sub(out.len());
                if remaining == 0 {
                    break 'walk;
                }
                let text = String::from_utf8_lossy(&raw);
                for h in find::grep_lines(&text, needle, find::Case::Insensitive, GREP_PER_FILE.min(remaining)) {
                    out.push(GrepHit { path: p.clone(), line: h.line, text: h.text });
                }
            }
        }
        let n = out.len();
        self.grep_results = out;
        self.grep_prompt = None;
        self.status = if n == 0 {
            format!("grep: no matches for \"{needle}\"")
        } else {
            format!("grep: {n} hit(s) for \"{needle}\"")
        };
    }

    /// Open the selected grep hit: load its file and center+flash the match line
    /// (the same clamp+center path go-to-line uses). Closes the results overlay.
    fn open_grep_result(&mut self) {
        let Some(hit) = self.grep_results.get(self.grep_sel).cloned() else { return };
        self.grep_results.clear();
        self.open_file(&hit.path);
        if let Some(p) = self.tabs.get_mut(self.active) {
            let len = p.content_len();
            let line0 = view::clamp_line(hit.line + 1, len).saturating_sub(1);
            let half = self.content_height / 2;
            let max_scroll = len.saturating_sub(1);
            p.scroll = line0.saturating_sub(half).min(max_scroll);
            self.flash = Some(line0);
        }
    }

    // MARK: - CSV table filter (shared `view::table_query` + `filter`)

    /// Whether the table-filter prompt is open (capturing keys).
    fn table_filtering(&self) -> bool {
        self.tabs.get(self.active).is_some_and(|p| p.table_filter_editing.is_some())
    }

    /// Open the table-filter prompt (Table mode only), seeding it with the
    /// currently-applied needle so re-opening lets you edit it. A no-op with a
    /// status hint when the current view isn't a table.
    fn open_table_filter(&mut self) {
        let is_table = self.tabs.get(self.active).is_some_and(|p| p.view.mode == ViewMode::Table);
        if !is_table {
            self.status = "filter: switch to table view first (x)".into();
            return;
        }
        if let Some(p) = self.tabs.get_mut(self.active) {
            if p.table_filter_editing.is_none() {
                p.table_filter_editing = Some(p.table_filter.clone());
            }
        }
    }

    /// Commit the prompt: the live needle becomes the applied filter; scroll
    /// resets to the top of the narrowed rows.
    fn commit_table_filter(&mut self) {
        if let Some(p) = self.tabs.get_mut(self.active) {
            if let Some(needle) = p.table_filter_editing.take() {
                p.table_filter = needle;
                p.scroll = 0;
            }
        }
    }

    /// Cancel the prompt, reverting to the previously-applied filter (live edits
    /// discarded).
    fn cancel_table_filter(&mut self) {
        if let Some(p) = self.tabs.get_mut(self.active) {
            p.table_filter_editing = None;
            p.scroll = 0;
        }
    }

    /// Append a character to the live needle (results re-filter as you type).
    fn table_filter_push(&mut self, c: char) {
        if let Some(p) = self.tabs.get_mut(self.active) {
            if let Some(n) = &mut p.table_filter_editing {
                n.push(c);
                p.scroll = 0;
            }
        }
    }

    /// Delete the last character of the live needle.
    fn table_filter_backspace(&mut self) {
        if let Some(p) = self.tabs.get_mut(self.active) {
            if let Some(n) = &mut p.table_filter_editing {
                n.pop();
                p.scroll = 0;
            }
        }
    }

    // MARK: - Markdown outline overlay (shared `outline::headings`)

    /// Whether the markdown-outline overlay is open.
    fn outline_active(&self) -> bool {
        self.outline.is_some()
    }

    /// Toggle the outline overlay. Opening it scans the open file's text for
    /// headings via the shared `outline::headings`; the overlay only opens for a
    /// markdown file (`outline::is_markdown`) that actually has at least one
    /// heading — otherwise it's a no-op (with a status hint) so `o` never opens
    /// an empty box. Re-pressing `o` while open closes it.
    fn toggle_outline(&mut self) {
        if self.outline.is_some() {
            self.outline = None;
            return;
        }
        let Some(p) = self.tabs.get(self.active) else {
            self.status = "outline: open a markdown file first".into();
            return;
        };
        if !outline::is_markdown(&p.name) {
            self.status = "outline: not a markdown file".into();
            return;
        }
        // The view text is shaped per-mode; scan the RAW bytes so the outline is
        // mode-independent (it works even while viewing the file as hex/table).
        let text = String::from_utf8_lossy(&p.raw);
        let headings = outline::headings(&text, &p.name);
        if headings.is_empty() {
            self.status = "outline: no headings found".into();
            return;
        }
        self.outline_sel = 0;
        self.outline = Some(headings);
    }

    /// Close the outline overlay without jumping.
    fn close_outline(&mut self) {
        self.outline = None;
    }

    /// Move the outline selection by `delta`, clamped to the heading count.
    fn outline_move(&mut self, delta: isize) {
        if let Some(hs) = &self.outline {
            if hs.is_empty() {
                return;
            }
            let max = hs.len() as isize - 1;
            self.outline_sel = (self.outline_sel as isize + delta).clamp(0, max) as usize;
        }
    }

    /// Commit the outline selection: jump the content pane to the selected
    /// heading's line. Reuses the SAME `view::clamp_line` + center-the-target
    /// path as go-to-line (so the heading lands mid-viewport and flashes), then
    /// closes the overlay. A Text-mode switch is forced first if needed so the
    /// line-based jump lands on the markdown source (hex/table rows don't map to
    /// heading line numbers).
    fn commit_outline(&mut self) {
        let Some(hs) = &self.outline else { return };
        let Some(h) = hs.get(self.outline_sel) else {
            self.outline = None;
            return;
        };
        let target = h.line;
        // Heading lines index the markdown SOURCE — ensure we're in Text mode so
        // the jump lands on a real line (re-shape via the shared core if not).
        if let Some(p) = self.tabs.get_mut(self.active) {
            if p.view.mode != ViewMode::Text {
                p.view = view::build(&p.raw, &p.name, p.total, p.truncated, ViewMode::Text);
                p.scroll = 0;
            }
        }
        self.outline = None;
        let Some(p) = self.tabs.get_mut(self.active) else { return };
        let len = p.content_len();
        let line0 = view::clamp_line(target, len).saturating_sub(1); // 1-based → 0-based
        let half = self.content_height / 2;
        let max_scroll = len.saturating_sub(1);
        p.scroll = line0.saturating_sub(half).min(max_scroll);
        self.flash = Some(line0);
    }

    // MARK: - Recently-opened picker (shared `history::push`)

    /// Whether the recents overlay is open and capturing navigation keys.
    fn recent_active(&self) -> bool {
        self.recent_open
    }

    /// Open the recents picker (`R`). No-op with an empty history (nothing to
    /// pick); resets the selection to the most-recent entry.
    fn open_recent(&mut self) {
        if self.recent.is_empty() {
            self.status = "recents: nothing opened yet".into();
            return;
        }
        self.recent_sel = 0;
        self.recent_open = true;
    }

    /// Move the recents selection by `delta`, clamped to the list length.
    fn recent_move(&mut self, delta: isize) {
        if self.recent.is_empty() {
            return;
        }
        let max = self.recent.len() as isize - 1;
        self.recent_sel = (self.recent_sel as isize + delta).clamp(0, max) as usize;
    }

    /// Commit the recents selection: re-open the chosen file (which also bumps it
    /// to the front of the history) and close the overlay.
    fn commit_recent(&mut self) {
        let Some(path) = self.recent.get(self.recent_sel).cloned() else {
            self.recent_open = false;
            return;
        };
        self.recent_open = false;
        self.open_file(&path);
    }

    /// Key handling while the recents overlay is open: ↑/↓ pick, ↵ open, ESC/R
    /// close. Never quits the app.
    fn on_key_recent(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc | KeyCode::Char('R') => self.recent_open = false,
            KeyCode::Enter => self.commit_recent(),
            KeyCode::Down | KeyCode::Char('j') => self.recent_move(1),
            KeyCode::Up | KeyCode::Char('k') => self.recent_move(-1),
            _ => {}
        }
        false
    }

    // MARK: - Multi-file tabs (TSK-249)

    /// Switch to the next (`delta=1`) / previous (`delta=-1`) tab, wrapping. A
    /// tab-switch preserves each tab's own scroll/mode (its `Preview` lives on);
    /// the transient find/outline overlays belong to the old file, so clear them.
    /// No-op with 0 or 1 tabs.
    fn cycle_tab(&mut self, delta: isize) {
        let n = self.tabs.len();
        if n <= 1 {
            return;
        }
        self.active = (self.active as isize + delta).rem_euclid(n as isize) as usize;
        self.flash = None;
        self.outline = None;
        self.clear_find();
    }

    /// Close the active tab; the tab to its right (or the new last tab) becomes
    /// active. No-op with no tabs.
    fn close_tab(&mut self) {
        if self.active >= self.tabs.len() {
            return;
        }
        self.tabs.remove(self.active);
        if self.active >= self.tabs.len() {
            self.active = self.tabs.len().saturating_sub(1);
        }
        self.flash = None;
        self.outline = None;
        self.clear_find();
        self.status = if self.tabs.is_empty() {
            "closed last tab".into()
        } else {
            format!("closed tab · {} open", self.tabs.len())
        };
    }

    // MARK: - Command palette (TSK-408)

    /// Whether the command palette is open and capturing keys.
    fn palette_active(&self) -> bool {
        self.palette.is_some()
    }

    /// Open the palette (`p`): empty query, all commands listed, selection at top.
    fn open_palette(&mut self) {
        self.palette = Some(String::new());
        self.palette_sel = 0;
        self.recompute_palette();
    }

    /// Re-rank the command list against the live query via the SAME shared
    /// subsequence scorer (`nav::filter_entries`) the quick file-find uses. An
    /// empty query lists every command in declaration order.
    fn recompute_palette(&mut self) {
        let needle = self.palette.clone().unwrap_or_default();
        self.palette_hits = if needle.is_empty() {
            (0..PALETTE.len()).collect()
        } else {
            let names: Vec<&str> = PALETTE.iter().map(|(label, _)| *label).collect();
            nav::filter_entries(&names, &needle, false).into_iter().map(|(pos, _)| pos).collect()
        };
        let max = self.palette_hits.len().saturating_sub(1);
        self.palette_sel = self.palette_sel.min(max);
    }

    /// Extend / trim the palette query, re-narrowing live.
    fn palette_push(&mut self, c: char) {
        if let Some(q) = &mut self.palette {
            q.push(c);
            self.recompute_palette();
        }
    }
    fn palette_backspace(&mut self) {
        if let Some(q) = &mut self.palette {
            q.pop();
            self.recompute_palette();
        }
    }

    /// Move the palette selection by `delta`, clamped to the matched-command count.
    fn palette_move(&mut self, delta: isize) {
        if self.palette_hits.is_empty() {
            return;
        }
        let max = self.palette_hits.len() as isize - 1;
        self.palette_sel = (self.palette_sel as isize + delta).clamp(0, max) as usize;
    }

    /// Run the selected command and close the palette.
    fn commit_palette(&mut self) {
        let cmd =
            self.palette_hits.get(self.palette_sel).and_then(|&p| PALETTE.get(p)).map(|(_, c)| *c);
        self.palette = None;
        if let Some(cmd) = cmd {
            self.run_palette_cmd(cmd);
        }
    }

    /// Dispatch a palette [`Cmd`] to the same action methods the keymap uses, so
    /// the palette is a discoverable front door to existing behaviour (no logic
    /// duplicated).
    fn run_palette_cmd(&mut self, cmd: Cmd) {
        match cmd {
            Cmd::CycleSort => self.cycle_sort(),
            Cmd::ToggleHidden => self.toggle_hidden(),
            Cmd::ToggleGutter => self.show_gutter = !self.show_gutter,
            Cmd::ToggleWhitespace => self.show_whitespace = !self.show_whitespace,
            Cmd::ToggleWrap => self.wrap = !self.wrap,
            Cmd::Find => self.open_find(),
            Cmd::Grep => self.open_grep(),
            Cmd::Outline => self.toggle_outline(),
            Cmd::Recent => self.open_recent(),
            Cmd::Reload => self.reload_current(),
            Cmd::NextTab => self.cycle_tab(1),
            Cmd::PrevTab => self.cycle_tab(-1),
            Cmd::CloseTab => self.close_tab(),
            Cmd::Top => self.scroll_to(true),
            Cmd::Bottom => self.scroll_to(false),
            Cmd::Help => self.show_help = true,
        }
    }

    /// Key handling while the palette is open: type to filter, ↑/↓ select, ↵ run,
    /// ESC close. Never quits the app (printable keys are query text).
    fn on_key_palette(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => self.palette = None,
            KeyCode::Enter => self.commit_palette(),
            KeyCode::Down => self.palette_move(1),
            KeyCode::Up => self.palette_move(-1),
            KeyCode::Backspace => self.palette_backspace(),
            KeyCode::Char(c) => self.palette_push(c),
            _ => {}
        }
        false
    }

    // MARK: - In-file content find (shared `find::find_matches`)

    /// Whether the find prompt is open and capturing the query.
    fn find_prompt_open(&self) -> bool {
        self.find.is_some()
    }

    /// Open the in-file find prompt (text/hex modes; `/` opens the table filter
    /// in Table mode — see `on_key`). Seeds the box with the last committed query
    /// so re-pressing `/` lets you refine it. A no-op when no file is open or the
    /// prompt is already up.
    fn open_find(&mut self) {
        if self.tabs.get(self.active).is_some() && self.find.is_none() {
            self.find = Some(self.find_query.clone());
        }
    }

    /// Close the find prompt, leaving any already-applied matches in place (so
    /// `Esc` out of the prompt keeps the current highlight + `n`/`N` nav).
    fn cancel_find(&mut self) {
        self.find = None;
    }

    /// Drop the find prompt AND its applied matches (used on file open, and on
    /// `Esc` from browse mode to dismiss the find highlight).
    fn clear_find(&mut self) {
        self.find = None;
        self.find_query.clear();
        self.find_matches.clear();
        self.find_sel = 0;
        self.find_is_hex = false;
    }

    /// Cell hits of the active find query within the current TABLE view's SHOWN
    /// (filtered) rows, in reading order (header first), via the shared
    /// `find::find_in_table` (TSK-499). Empty unless a find is active AND the
    /// active view is a table. Recomputed on demand (cheap — tables are small and
    /// already re-rendered per frame) so it always reflects the current row
    /// filter, exactly matching what the table render highlights.
    fn current_table_find_hits(&self) -> Vec<find::TableHit> {
        if self.find_query.is_empty() {
            return Vec::new();
        }
        let Some(p) = self.tabs.get(self.active) else { return Vec::new() };
        if p.view.mode != ViewMode::Table {
            return Vec::new();
        }
        let ViewBody::Table { header, rows, .. } = &p.view.body else { return Vec::new() };
        let shown_idx = p.filtered_table_indices(header, rows);
        let shown: Vec<&Vec<String>> =
            shown_idx.iter().filter_map(|&i| rows.get(i as usize)).collect();
        find::find_in_table(header, &shown, &self.find_query, find::Case::Insensitive, true, None)
    }

    /// Scroll the table so the current cell-hit's row is visible, only adjusting
    /// when it's outside the body window (so a fully-visible table never jumps).
    /// A header hit (`row == TABLE_HEADER_ROW`) brings the view to the top. The
    /// table counterpart of `jump_to_current_match` — but it never changes the
    /// view mode; cell-find stays in the table.
    fn scroll_table_to_current_hit(&mut self, hits: &[find::TableHit]) {
        let Some(hit) = hits.get(self.find_sel.min(hits.len().saturating_sub(1))) else { return };
        let target = usize::try_from(hit.row).unwrap_or(0); // header row (-1) -> top
        let visible = self.content_height.saturating_sub(1).max(1); // body rows (minus header)
        if let Some(p) = self.tabs.get_mut(self.active) {
            if target < p.scroll {
                p.scroll = target;
            } else if target >= p.scroll + visible {
                p.scroll = target + 1 - visible;
            }
        }
    }

    /// Append any character to the live query (printable keys), so the find box
    /// accepts the full text — unlike go-to-line, which only takes digits.
    fn find_push(&mut self, c: char) {
        if let Some(q) = &mut self.find {
            q.push(c);
        }
    }

    /// Delete the last character of the live query.
    fn find_backspace(&mut self) {
        if let Some(q) = &mut self.find {
            q.pop();
        }
    }

    /// Commit the find: run the typed query through the shared
    /// `find::find_matches` over the file's RAW bytes (mode-independent, like the
    /// outline), select the first match at or after the current scroll position,
    /// and jump to it. An empty query clears any active find. A query with no
    /// matches leaves the prompt closed with a "no matches" status (and no
    /// stale highlight).
    fn commit_find(&mut self) {
        let Some(query) = self.find.take() else { return };
        if query.is_empty() {
            self.clear_find();
            return;
        }
        let Some(p) = self.tabs.get(self.active) else { return };
        // Table mode (TSK-499): CELL-find — locate + highlight matching cells and
        // arm n/N cell-stepping, over the SHOWN (filtered) rows so coords line up
        // with the render. Distinct from the `/` row FILTER (find never narrows),
        // and it must NOT fall through to the text branch below — that would force
        // Text mode via jump_to_current_match. Composes with the row filter.
        if p.view.mode == ViewMode::Table {
            let hits = if let ViewBody::Table { header, rows, .. } = &p.view.body {
                let shown_idx = p.filtered_table_indices(header, rows);
                let shown: Vec<&Vec<String>> =
                    shown_idx.iter().filter_map(|&i| rows.get(i as usize)).collect();
                find::find_in_table(header, &shown, &query, find::Case::Insensitive, true, None)
            } else {
                Vec::new()
            };
            if hits.is_empty() {
                self.find_query.clear();
                self.find_matches.clear();
                self.find_is_hex = false;
                self.status = format!("find: no matches for \"{query}\"");
                return;
            }
            self.find_query = query;
            self.find_matches.clear(); // a table find tracks cell hits, not line matches
            self.find_is_hex = false;
            self.find_sel = 0;
            self.scroll_table_to_current_hit(&hits);
            return;
        }
        // HEX mode (TSK-205): search the raw BYTES for a byte/ASCII pattern via
        // the shared core `hex::hex_search`, and land each match on the dump ROW
        // it falls in (offset / 16). Distinct from the text find below.
        if p.view.mode == ViewMode::Hex {
            // Prefer a hex-byte reading ("41", "ff 7f", "deadbeef"); fall back to
            // ASCII when the query isn't valid hex (odd-length / non-hex token).
            let mode = match hex::hex_search_parse(&query, HexSearchMode::Hex) {
                Some(b) if !b.is_empty() => HexSearchMode::Hex,
                _ => HexSearchMode::Ascii,
            };
            let pat_len = hex::hex_search_parse(&query, mode).map_or(1, |b| b.len().max(1));
            let offsets = hex::hex_search(&query, mode, &p.raw);
            if offsets.is_empty() {
                self.find_query.clear();
                self.find_matches.clear();
                self.find_is_hex = false;
                self.status = format!("hex: no matches for \"{query}\"");
                return;
            }
            let matches: Vec<find::Match> = offsets
                .iter()
                .map(|&o| find::Match {
                    line: o / HEX_BYTES_PER_ROW,
                    start: o % HEX_BYTES_PER_ROW,
                    end: (o % HEX_BYTES_PER_ROW) + pat_len,
                })
                .collect();
            let from_row = p.scroll;
            self.find_sel = find::first_from(&matches, from_row, 0).unwrap_or(0);
            self.find_query = query;
            self.find_matches = matches;
            self.find_is_hex = true;
            self.jump_to_current_match();
            return;
        }
        let text = String::from_utf8_lossy(&p.raw);
        let matches = find::find_matches(&text, &query, find::Case::Insensitive);
        if matches.is_empty() {
            self.find_query.clear();
            self.find_matches.clear();
            self.find_is_hex = false;
            self.status = format!("find: no matches for \"{query}\"");
            return;
        }
        // Pick the first match at/after where the user is currently looking, so a
        // find jumps forward from the viewport rather than always to the top.
        let from_line = p.scroll;
        self.find_sel = find::first_from(&matches, from_line, 0).unwrap_or(0);
        self.find_query = query;
        self.find_matches = matches;
        self.find_is_hex = false;
        self.jump_to_current_match();
    }

    /// Step to the next (`forward`) or previous match, wrapping, and jump to it.
    /// A no-op when no find is active.
    fn find_step(&mut self, forward: bool) {
        // In a table view, n/N step the CELL hits (TSK-499) — recomputed over the
        // current shown rows so the step stays aligned with the render (e.g. after
        // a re-filter) — and never leave table mode. Elsewhere, the line matches.
        let table_hits = self.current_table_find_hits();
        if !table_hits.is_empty() {
            let n = table_hits.len();
            let cur = self.find_sel.min(n - 1);
            self.find_sel = if forward { (cur + 1) % n } else { (cur + n - 1) % n };
            self.scroll_table_to_current_hit(&table_hits);
            return;
        }
        if self.find_matches.is_empty() {
            return;
        }
        let stepped = if forward {
            find::next_index(&self.find_matches, self.find_sel)
        } else {
            find::prev_index(&self.find_matches, self.find_sel)
        };
        if let Some(i) = stepped {
            self.find_sel = i;
            self.jump_to_current_match();
        }
    }

    /// Center the content pane on the current match's line (forcing Text mode
    /// first so the line index maps to a real row — the same clamp+center+flash
    /// path as go-to-line / outline) and update the "find: i of n" status.
    fn jump_to_current_match(&mut self) {
        let Some(target) = self.find_matches.get(self.find_sel).map(|m| m.line) else { return };
        if !self.find_is_hex {
            // Text matches index the SOURCE lines — ensure Text mode so the jump
            // lands on a real line (table rows don't map to source line numbers).
            // HEX matches index dump ROWS, so we STAY in Hex (TSK-205).
            if let Some(p) = self.tabs.get_mut(self.active) {
                if p.view.mode != ViewMode::Text {
                    p.view = view::build(&p.raw, &p.name, p.total, p.truncated, ViewMode::Text);
                    p.scroll = 0;
                }
            }
        }
        let i = self.find_sel + 1;
        let n = self.find_matches.len();
        let q = self.find_query.clone();
        let label = if self.find_is_hex { "hex" } else { "find" };
        let Some(p) = self.tabs.get_mut(self.active) else { return };
        let len = p.content_len();
        let line0 = view::clamp_line(target + 1, len).saturating_sub(1); // 0-based → 1-based → clamp → 0-based
        let half = self.content_height / 2;
        let max_scroll = len.saturating_sub(1);
        p.scroll = line0.saturating_sub(half).min(max_scroll);
        self.flash = Some(line0);
        self.status = format!("{label}: {i} of {n} · \"{q}\"");
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
        // The keyboard-help overlay (TSK-247) is modal: while it's up, ANY key
        // dismisses it and nothing else fires. Runs before every other handler.
        if self.show_help {
            self.show_help = false;
            return false;
        }
        // The cross-file grep prompt captures text; its results overlay captures
        // navigation. Both run before the normal keymap (TSK-213).
        if self.grep_prompt.is_some() {
            return self.on_key_grep_prompt(code);
        }
        if self.grep_overlay_open() {
            return self.on_key_grep_results(code);
        }
        // While the quick-find prompt is open it captures text input, so the
        // single-letter command keys (`x`/`s`/`q`/`hjkl`/…) become literal needle
        // characters instead. Arrow keys still navigate the narrowed list; ESC
        // closes the prompt; Enter opens the top hit. This must run BEFORE the
        // normal keymap so `q`/`x`/etc. don't fire mid-needle.
        if self.filtering() {
            return self.on_key_filtering(code);
        }
        // The go-to-line prompt captures digit input the same way quick-find
        // captures the needle — it must run BEFORE the normal keymap so typed
        // digits don't fall through to command keys.
        if self.goto_active() {
            return self.on_key_goto(code);
        }
        // The outline overlay captures navigation keys (↑/↓ pick a heading, ↵
        // jumps, ESC/o closes) before the normal keymap so they drive the
        // overlay rather than the file list / content pane underneath.
        if self.outline_active() {
            return self.on_key_outline(code);
        }
        // The recents picker captures navigation keys (↑/↓ pick, ↵ open, ESC/R
        // close) before the normal keymap (TSK-233).
        if self.recent_active() {
            return self.on_key_recent(code);
        }
        // The command palette captures typing + nav before the normal keymap so
        // command keys become query text, not commands (TSK-408).
        if self.palette_active() {
            return self.on_key_palette(code);
        }
        // The table-filter prompt captures text the same way — runs before the
        // normal keymap so typed needle chars don't fire command keys.
        if self.table_filtering() {
            return self.on_key_table_filter(code);
        }
        // The in-file find prompt captures the typed query before the normal
        // keymap (so `q`/`x`/etc. become literal query chars, not commands).
        if self.find_prompt_open() {
            return self.on_key_find(code);
        }
        let page = self.content_height.max(1) as isize;
        match code {
            KeyCode::Char('q') => return true,
            // ESC dismisses an active find's highlight first; with no find up it
            // quits (preserving the historical ESC-to-quit for the common case).
            KeyCode::Esc => {
                if self.find_matches.is_empty() && self.current_table_find_hits().is_empty() {
                    return true;
                }
                self.clear_find();
            }
            KeyCode::Down | KeyCode::Char('j') => self.move_selection(1),
            KeyCode::Up | KeyCode::Char('k') => self.move_selection(-1),
            KeyCode::Enter | KeyCode::Right | KeyCode::Char('l') => self.enter(),
            KeyCode::Backspace | KeyCode::Left | KeyCode::Char('h') => self.go_parent(),
            KeyCode::Char('x') => self.cycle_mode(),
            // `r` re-reads the open file from disk (picks up external edits),
            // preserving mode + scroll (TSK-239).
            KeyCode::Char('r') => self.reload_current(),
            // Open-as: 1-9 force the file's Nth available mode directly.
            KeyCode::Char(c @ '1'..='9') => self.set_mode(c as usize - '1' as usize),
            // `n`/`N` step the find matches WHILE a find is active; with no
            // active find, `n` keeps its line-number-gutter toggle.
            KeyCode::Char('n') => {
                if self.find_matches.is_empty() && self.current_table_find_hits().is_empty() {
                    self.show_gutter = !self.show_gutter;
                } else {
                    self.find_step(true);
                }
            }
            KeyCode::Char('N') => self.find_step(false),
            // Toggle show-invisibles (whitespace markers) for the Text view.
            KeyCode::Char('i') => self.show_whitespace = !self.show_whitespace,
            // Toggle soft-wrap vs truncate for the Text view.
            KeyCode::Char('w') => self.wrap = !self.wrap,
            KeyCode::Char('s') => self.cycle_sort(),
            KeyCode::Char('t') => self.cycle_theme(),
            KeyCode::Char('.') => self.toggle_hidden(),
            KeyCode::Char('f') => self.open_filter(),
            KeyCode::Char(':') => self.open_goto(),
            // `/` searches: the table filter in Table mode, in-file find otherwise.
            KeyCode::Char('/') => {
                let is_table =
                    self.tabs.get(self.active).is_some_and(|p| p.view.mode == ViewMode::Table);
                if is_table {
                    self.open_table_filter();
                } else {
                    self.open_find();
                }
            }
            KeyCode::Char('o') => self.toggle_outline(),
            // `]`/`[` cycle tabs; `X` closes the active tab (TSK-249).
            KeyCode::Char(']') => self.cycle_tab(1),
            KeyCode::Char('[') => self.cycle_tab(-1),
            KeyCode::Char('X') => self.close_tab(),
            // `R` opens the recently-opened picker (TSK-233).
            KeyCode::Char('R') => self.open_recent(),
            // `p` opens the command palette (TSK-408).
            KeyCode::Char('p') => self.open_palette(),
            // `F` opens the cross-file "search anywhere" grep prompt (TSK-213).
            KeyCode::Char('F') => self.open_grep(),
            // `?` opens the keyboard-help overlay (any key then dismisses it).
            KeyCode::Char('?') => self.show_help = true,
            KeyCode::Char('g') => self.scroll_to(true),
            KeyCode::Char('G') => self.scroll_to(false),
            KeyCode::PageDown => self.scroll_by(page),
            KeyCode::PageUp => self.scroll_by(-page),
            _ => {}
        }
        false
    }

    /// Key handling while the go-to-line prompt is open. Never quits (`q`/`Esc`
    /// close the prompt rather than the app). ASCII digits extend the target;
    /// Backspace trims it; Enter commits the jump (clamp + center + flash); ESC
    /// cancels.
    fn on_key_goto(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => self.cancel_goto(),
            KeyCode::Enter => self.commit_goto(),
            KeyCode::Backspace => self.goto_backspace(),
            KeyCode::Char(c) => self.goto_push(c),
            _ => {}
        }
        false
    }

    /// Key handling while the in-file find prompt is open. Never quits (`q`
    /// becomes a literal query char; ESC cancels the prompt). Any printable char
    /// extends the query; Backspace trims; Enter runs the search and jumps to the
    /// first match; ESC closes the prompt (keeping any previously-applied find).
    fn on_key_find(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => self.cancel_find(),
            KeyCode::Enter => self.commit_find(),
            KeyCode::Backspace => self.find_backspace(),
            KeyCode::Char(c) => self.find_push(c),
            _ => {}
        }
        false
    }

    /// Key handling while the table-filter prompt is open. Never quits (`q`/`Esc`
    /// close/cancel the prompt rather than the app). Printable chars extend the
    /// needle (live re-filter); Backspace trims; Enter commits; ESC cancels.
    fn on_key_table_filter(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => self.cancel_table_filter(),
            KeyCode::Enter => self.commit_table_filter(),
            KeyCode::Backspace => self.table_filter_backspace(),
            KeyCode::Char(c) => self.table_filter_push(c),
            _ => {}
        }
        false
    }

    /// Key handling while the markdown-outline overlay is open. Never quits
    /// (`q` is inert here; ESC or `o` close the overlay). ↑/↓ (or j/k) move the
    /// heading selection; Enter jumps to the selected heading; ESC / `o` close
    /// without jumping.
    fn on_key_outline(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc | KeyCode::Char('o') => self.close_outline(),
            KeyCode::Enter => self.commit_outline(),
            KeyCode::Down | KeyCode::Char('j') => self.outline_move(1),
            KeyCode::Up | KeyCode::Char('k') => self.outline_move(-1),
            _ => {}
        }
        false
    }

    /// Key handling while the quick-find prompt is open. Returns `true` to quit
    /// (never — the prompt swallows `q` as a needle char; the user ESCs out and
    /// then quits). Printable chars extend the needle; Backspace trims it; the
    /// arrow keys move within the narrowed hits; Enter opens the top/selected
    /// hit and ESC closes the prompt.
    fn on_key_filtering(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => self.clear_filter(),
            KeyCode::Enter => self.enter(),
            KeyCode::Backspace => self.filter_backspace(),
            KeyCode::Down => self.move_selection(1),
            KeyCode::Up => self.move_selection(-1),
            // Any printable character extends the needle and re-narrows live.
            KeyCode::Char(c) => self.filter_push(c),
            _ => {}
        }
        false
    }

    /// Render one frame to an in-memory buffer and return it as text (for
    /// `--snapshot` and tests — no real terminal involved). Reachable from the
    /// user-facing `--snapshot` CLI flag, so errors propagate as `io::Result`
    /// (matching `main`'s discipline) instead of panicking — the release
    /// profile is `panic = "abort"`, which would otherwise turn a failure into
    /// a bare process abort with no message.
    fn snapshot(&mut self, w: u16, h: u16) -> io::Result<String> {
        let mut terminal = Terminal::new(TestBackend::new(w, h))?;
        terminal.draw(|f| self.draw(f))?;
        Ok(buffer_to_string(&terminal))
    }

    // MARK: - Rendering

    fn draw(&mut self, frame: &mut Frame) {
        // Footer is TWO rows so the full key legend wraps instead of truncating
        // at the right edge (the idle help is long; `t theme` etc. pushed it past
        // one line). `draw_status` soft-wraps the help across both rows.
        let rows = Layout::vertical([Constraint::Min(1), Constraint::Length(2)]).split(frame.area());
        let cols =
            Layout::horizontal([Constraint::Percentage(35), Constraint::Percentage(65)]).split(rows[0]);
        self.draw_files(frame, cols[0]);
        // With ≥2 open buffers, reserve the content column's top line for the tab
        // strip (TSK-249); a single buffer uses the full height as before.
        let content = if self.tabs.len() >= 2 {
            let v = Layout::vertical([Constraint::Length(1), Constraint::Min(0)]).split(cols[1]);
            self.draw_tabstrip(frame, v[0]);
            v[1]
        } else {
            cols[1]
        };
        self.draw_content(frame, content);
        // The outline overlay floats over the content pane when open.
        if self.outline.is_some() {
            self.draw_outline(frame, content);
        }
        // The recents picker floats over the content pane when open (TSK-233).
        if self.recent_open {
            self.draw_recent(frame, content);
        }
        // The command palette floats over the content pane when open (TSK-408).
        if self.palette.is_some() {
            self.draw_palette(frame, content);
        }
        // The cross-file grep prompt / results overlay floats over the content row.
        if self.grep_prompt.is_some() || !self.grep_results.is_empty() {
            self.draw_grep(frame, rows[0]);
        }
        // The keyboard-help overlay floats over the whole content row when open.
        if self.show_help {
            self.draw_help(frame, rows[0]);
        }
        self.draw_status(frame, rows[1]);
    }

    fn draw_files(&mut self, frame: &mut Frame, area: Rect) {
        // When the quick-find prompt is open the pane title becomes the live
        // filter input ("find: <needle>▏ · N hits") so the user can see what
        // they're typing and how many entries survive. Otherwise it surfaces the
        // path + sort key + dotfile state as before.
        let title = if let Some(needle) = &self.filter {
            format!(" find: {needle}▏ · {} hits ", self.filtered.len())
        } else {
            // Path + sort key + dotfile state + git summary (see `files_title`).
            self.files_title()
        };
        // Reuse the labels formatted once in `reload_dir`; per frame we only
        // borrow them into a `Span` (zero string allocs). When filtering we walk
        // the ranked `filtered` index list (best-first) instead of the full
        // `list_rows`, so the pane shows only the narrowed, ranked subset. The
        // `ListState` selection indexes into THIS rendered order in both cases.
        let items: Vec<ListItem> = if self.filtering() {
            self.filtered
                .iter()
                .filter_map(|&i| self.list_rows.get(i))
                .map(Self::row_item)
                .collect()
        } else {
            self.list_rows.iter().map(Self::row_item).collect()
        };
        let list = List::new(items)
            .block(Block::bordered().title(title))
            .highlight_symbol("▶ ")
            .highlight_style(Style::new().reversed());
        frame.render_stateful_widget(list, area, &mut self.list);
    }

    /// Build a styled list item for one cached row (dirs in bold cyan).
    fn row_item(r: &ListRow) -> ListItem<'_> {
        let style = if r.is_dir { Style::new().fg(Color::Cyan).bold() } else { Style::new() };
        ListItem::new(Line::from(Span::styled(r.label.as_str(), style)))
    }

    fn draw_content(&mut self, frame: &mut Frame, area: Rect) {
        let inner_h = area.height.saturating_sub(2) as usize; // minus borders
        self.content_height = inner_h.max(1);
        let Some(p) = self.tabs.get(self.active) else {
            let hint = Paragraph::new("Select a file and press ↵ to view it.\nx cycles view modes (table / text / HEX).")
                .block(Block::bordered().title(" content "))
                .style(Style::new().fg(Color::DarkGray));
            frame.render_widget(hint, area);
            return;
        };

        let trunc = if p.truncated { " · TRUNCATED" } else { "" };
        // Empty/binary content banner (shared `view::content_state`): surfaces WHY
        // a text pane is blank or garbled, where today the file just renders as an
        // empty pane / noise with no explanation (TSK-245). Truncation above is a
        // separate, already-surfaced signal.
        let state = view::content_state_banner(view::content_state(&p.raw))
            .map(|b| format!(" · {b}"))
            .unwrap_or_default();
        match &p.view.body {
            // Table mode renders a real ratatui Table from the core-parsed CSV.
            ViewBody::Table { header, rows, truncated } => {
                // `trunc` = file byte-cap; `clamp` = CSV parse-level column clamp
                // (PARSE-04) — distinct signals, surface both (TSK-155).
                let clamp = if *truncated { " · CLAMPED" } else { "" };
                // Apply the active CSV filter (shared core); project the surviving
                // rows without cloning the full body. `column_widths` uses the FULL
                // rows so columns don't jitter as the filter narrows the set.
                let shown_idx = p.filtered_table_indices(header, rows);
                let shown: Vec<&Vec<String>> =
                    shown_idx.iter().filter_map(|&i| rows.get(i as usize)).collect();
                let needle = p.table_needle();
                let title = if p.table_filter_editing.is_some() {
                    format!(
                        " {} · table · filter: {needle}▏ · {}/{} rows (↵ apply · ESC cancel) ",
                        p.name,
                        shown.len(),
                        rows.len(),
                    )
                } else if !needle.is_empty() {
                    format!(
                        " {} · table · filter \"{needle}\" · {}/{} rows · {}{trunc}{clamp} ",
                        p.name,
                        shown.len(),
                        rows.len(),
                        human_size(p.total),
                    )
                } else {
                    format!(
                        " {} · table · {}×{} · {}{trunc}{clamp} ",
                        p.name,
                        rows.len(),
                        header.len(),
                        human_size(p.total),
                    )
                };
                let widths = column_widths(header, rows);
                // Cell-find (TSK-499): when an in-file find is active, highlight
                // matching CELLS via the shared `find::find_in_table` over the
                // SHOWN (filtered) rows — so hit coords index straight into the
                // displayed set (parity with the web table cell-find). The CURRENT
                // match (find_sel-th in reading order) gets a distinct style so the
                // n/N cell-stepping is visible. Find LOCATES; it never narrows —
                // that's the `/` row filter, with which it composes.
                // Theme-routed (TSK-243): Adaptive keeps the exact ANSI colors;
                // Dark/Light paint the core palette's HighlightBg/CurrentBg.
                let hl = Style::new()
                    .bg(self.tc(Role::HighlightBg, Color::Yellow))
                    .fg(self.tc(Role::OnHighlight, Color::Black));
                let cur_hl = Style::new()
                    .bg(self.tc(Role::CurrentBg, Color::Magenta))
                    .fg(self.tc(Role::OnHighlight, Color::White))
                    .bold();
                let hv = if self.find_query.is_empty() {
                    Vec::new()
                } else {
                    find::find_in_table(header, &shown, &self.find_query, find::Case::Insensitive, true, None)
                };
                let cur = hv.get(self.find_sel.min(hv.len().saturating_sub(1))).map(|h| (h.row, h.col));
                let hits: std::collections::HashSet<(i64, usize)> =
                    hv.iter().map(|h| (h.row, h.col)).collect();
                let style_for = |coord: (i64, usize)| -> Option<Style> {
                    if Some(coord) == cur {
                        Some(cur_hl)
                    } else if hits.contains(&coord) {
                        Some(hl)
                    } else {
                        None
                    }
                };
                let header_row = Row::new(
                    header
                        .iter()
                        .enumerate()
                        .map(|(j, h)| {
                            let cell = Cell::from(h.clone());
                            match style_for((find::TABLE_HEADER_ROW, j)) {
                                Some(s) => cell.style(s),
                                None => cell,
                            }
                        })
                        .collect::<Vec<_>>(),
                )
                .style(Style::new().fg(Color::Cyan).bold());
                let start = p.scroll.min(shown.len().saturating_sub(1));
                let body: Vec<Row> = shown
                    .iter()
                    .enumerate()
                    .skip(start)
                    .take(inner_h.saturating_sub(1).max(1))
                    .map(|(i, r)| {
                        Row::new(
                            r.iter()
                                .enumerate()
                                .map(|(j, c)| {
                                    let cell = Cell::from(c.clone());
                                    match style_for((i as i64, j)) {
                                        Some(s) => cell.style(s),
                                        None => cell,
                                    }
                                })
                                .collect::<Vec<_>>(),
                        )
                    })
                    .collect();
                let table = Table::new(body, widths)
                    .header(header_row)
                    .column_spacing(1)
                    .block(Block::bordered().title(title));
                frame.render_widget(table, area);
            }
            // Image: a metadata card (a terminal can't draw pixels). Shows the
            // format + dimensions parsed by the shared core, plus the byte size.
            ViewBody::Image(info) => {
                let title = format!(" {} · image ", p.name);
                let mut lines: Vec<Line> = Vec::new();
                if let Some(i) = info {
                    lines.push(Line::from(Span::styled(
                        format!("{} image", i.kind.label()),
                        Style::new().fg(Color::Cyan).bold(),
                    )));
                    lines.push(Line::from(format!("{} × {} px", i.width, i.height)));
                } else {
                    lines.push(Line::from(Span::styled(
                        "image (dimensions unavailable)",
                        Style::new().fg(Color::Cyan).bold(),
                    )));
                }
                lines.push(Line::from(human_size(p.total)));
                if p.truncated {
                    lines.push(Line::from(Span::styled(
                        "· file truncated at the preview cap",
                        Style::new().fg(Color::Yellow),
                    )));
                }
                lines.push(Line::from(""));
                lines.push(Line::from(Span::styled(
                    "the terminal can't render pixels — open in the web tier or a GUI viewer",
                    Style::new().fg(Color::DarkGray),
                )));
                lines.push(Line::from(Span::styled(
                    "press x to inspect the raw bytes as HEX",
                    Style::new().fg(Color::DarkGray),
                )));
                let para = Paragraph::new(lines)
                    .block(Block::bordered().title(title))
                    .wrap(Wrap { trim: false });
                frame.render_widget(para, area);
            }
            // Diff: a scrolled paragraph with each line colored by its kind
            // (added/removed/header/hunk), classified by the shared core.
            ViewBody::Diff(lines) => {
                let title = format!(
                    " {} · diff · {} lines · {}{trunc} ",
                    p.name,
                    lines.len(),
                    human_size(p.total),
                );
                let start = p.scroll.min(lines.len().saturating_sub(1));
                let gw = view::gutter_width(lines.len());
                let gutter = self.show_gutter;
                let visible: Vec<Line> = lines
                    .iter()
                    .skip(start)
                    .take(inner_h)
                    .enumerate()
                    .map(|(offset, dl)| {
                        let idx = start + offset; // 0-based line index
                        let color = match dl.kind {
                            DiffLineKind::FileHeader => Color::Cyan,
                            DiffLineKind::Hunk => Color::Magenta,
                            DiffLineKind::Added => Color::Green,
                            DiffLineKind::Removed => Color::Red,
                            DiffLineKind::Context => Color::Gray,
                        };
                        let content = Span::styled(dl.text.clone(), Style::new().fg(color));
                        if gutter {
                            let n = idx + 1;
                            let label = format!("{n:>gw$} ");
                            Line::from(vec![
                                Span::styled(label, Style::new().fg(Color::DarkGray)),
                                Span::styled("│ ", Style::new().fg(Color::DarkGray)),
                                content,
                            ])
                        } else {
                            Line::from(content)
                        }
                    })
                    .collect();
                let para = Paragraph::new(visible)
                    .block(Block::bordered().title(title))
                    .wrap(Wrap { trim: false });
                frame.render_widget(para, area);
            }
            // Text / HEX: a scrolled paragraph of the visible lines.
            ViewBody::Text(lines) | ViewBody::Hex(lines) => {
                let mode = match p.view.mode {
                    ViewMode::Text => "text",
                    ViewMode::Hex => "hex",
                    ViewMode::Table => "table",
                    ViewMode::Diff => "diff",
                    ViewMode::Image => "image",
                    ViewMode::Formatted => "formatted",
                };
                // While the go-to-line prompt is open the title becomes the live
                // "goto: N" input so the user sees the number they're typing.
                // Encoding + line-ending badge and file-metadata metrics (shared
                // `core::meta`) — only meaningful for the Text view; HEX shows raw
                // bytes, so skip it.
                let badge = if matches!(p.view.mode, ViewMode::Text) {
                    let lossy = String::from_utf8_lossy(&p.raw);
                    let m = meta::text_metrics(&lossy);
                    format!(
                        " · {} · {} · {} lines · {} words",
                        meta::encoding_label(&p.raw),
                        meta::line_ending(&p.raw).as_str(),
                        m.lines,
                        m.words,
                    )
                } else {
                    String::new()
                };
                let title = if let Some(f) = &self.find {
                    format!(" {} · find: {f}▏ (↵ search · ESC cancel) ", p.name)
                } else if let Some(g) = &self.goto {
                    format!(" {} · goto line: {g}▏ (↵ jump · ESC cancel) ", p.name)
                } else {
                    format!(
                        " {}{state} · {mode} · indent: {} · {}{badge}{trunc} ",
                        p.name,
                        p.view.indent,
                        human_size(p.total),
                    )
                };
                let start = p.scroll.min(lines.len().saturating_sub(1));
                // Gutter width tracks the LARGEST line number in the file (not
                // just the visible window) so the column never jitters as you
                // scroll. Shared `view::gutter_width` gives the digit count; the
                // number is the original 1-based line index (`start+offset+1`).
                let gw = view::gutter_width(lines.len());
                let gutter = self.show_gutter;
                let show_ws = self.show_whitespace;
                let flash = self.flash;
                // Syntax highlighting (TSK-257): only in Text mode (HEX shares
                // this arm but its "lines" are byte dumps), only for a known
                // language, and only when NOT revealing whitespace (reveal
                // rewrites the text, breaking the spans' column alignment).
                let hl = if matches!(p.view.mode, ViewMode::Text) && !show_ws {
                    p.highlighted_lines(lines)
                } else {
                    None
                };
                let visible: Vec<Line> = lines
                    .iter()
                    .skip(start)
                    .take(inner_h)
                    .enumerate()
                    .map(|(offset, s)| {
                        let idx = start + offset; // 0-based line index
                        // The just-jumped-to line is highlighted (reversed) for
                        // one frame so the eye lands on where the jump went.
                        let is_flash = flash == Some(idx);
                        let content_style =
                            if is_flash { Style::new().reversed() } else { Style::new() };
                        // Highlighted segments win unless the line is flashed or
                        // whitespace-reveal is on; otherwise a single plain span.
                        let line_segs = hl
                            .as_deref()
                            .filter(|_| !is_flash)
                            .and_then(|all| all.get(idx));
                        let content_spans: Vec<Span> = match line_segs {
                            Some(segs) => segs
                                .iter()
                                .map(|seg| match token_color(seg.kind) {
                                    Some(c) => Span::styled(seg.text.clone(), Style::new().fg(c)),
                                    None => Span::raw(seg.text.clone()),
                                })
                                .collect(),
                            None => {
                                // Show-invisibles: spaces/tabs → markers (shared core).
                                let text = if show_ws { whitespace::reveal(s) } else { s.clone() };
                                vec![Span::styled(text, content_style)]
                            }
                        };
                        if gutter {
                            let n = idx + 1;
                            // Right-align to `gw`, then a thin "│ " separator;
                            // the gutter is DIM so the content stays primary.
                            let label = format!("{n:>gw$} ");
                            let mut spans = vec![
                                Span::styled(label, Style::new().fg(Color::DarkGray)),
                                Span::styled("│ ", Style::new().fg(Color::DarkGray)),
                            ];
                            spans.extend(content_spans);
                            Line::from(spans)
                        } else {
                            Line::from(content_spans)
                        }
                    })
                    .collect();
                let para = Paragraph::new(visible).block(Block::bordered().title(title));
                // Word-wrap toggle (`w`): soft-wrap long lines (default) or, when
                // off, truncate them at the pane edge.
                let para = if self.wrap { para.wrap(Wrap { trim: false }) } else { para };
                frame.render_widget(para, area);
            }
        }
    }

    /// Render the markdown-outline overlay as a centered popup over `area` (the
    /// content pane). Headings are listed one per row, indented two spaces per
    /// level past the first and prefixed with their level (`H1`..`H6`), so the
    /// document structure reads at a glance. The selected row is reversed; the
    /// list scrolls to keep the selection visible. `Clear` wipes the cells under
    /// the popup so the content pane doesn't bleed through.
    fn draw_outline(&self, frame: &mut Frame, area: Rect) {
        let Some(hs) = &self.outline else { return };
        let popup = centered_rect(70, 70, area);
        frame.render_widget(Clear, popup);
        let inner_h = popup.height.saturating_sub(2) as usize; // minus borders
        // Scroll the list so the selection stays on-screen (simple window).
        let start = self.outline_sel.saturating_sub(inner_h.saturating_sub(1));
        let items: Vec<ListItem> = hs
            .iter()
            .enumerate()
            .skip(start)
            .take(inner_h.max(1))
            .map(|(i, h)| {
                // Indent two spaces per level past H1 so nesting is visible.
                let indent = "  ".repeat(usize::from(h.level).saturating_sub(1));
                let label = format!("{indent}H{} {}", h.level, h.title);
                let style = if i == self.outline_sel {
                    Style::new().reversed()
                } else {
                    Style::new()
                };
                ListItem::new(Line::from(Span::styled(label, style)))
            })
            .collect();
        let title = format!(" outline · {} headings · ↵ jump · ESC close ", hs.len());
        let list = List::new(items).block(Block::bordered().title(title));
        frame.render_widget(list, popup);
    }

    /// Render the recently-opened picker (TSK-233) as a centered popup: one row
    /// per recent file (newest first, path made relative to `cwd` when possible),
    /// the selection reversed, scrolled to keep it visible. `Clear` wipes the
    /// cells underneath. Mirrors the outline/grep overlays.
    fn draw_recent(&self, frame: &mut Frame, area: Rect) {
        if self.recent.is_empty() {
            return;
        }
        let popup = centered_rect(70, 70, area);
        frame.render_widget(Clear, popup);
        let inner_h = popup.height.saturating_sub(2) as usize;
        let start = self.recent_sel.saturating_sub(inner_h.saturating_sub(1));
        let items: Vec<ListItem> = self
            .recent
            .iter()
            .enumerate()
            .skip(start)
            .take(inner_h.max(1))
            .map(|(i, p)| {
                let label = p.strip_prefix(&self.cwd).unwrap_or(p).to_string_lossy().into_owned();
                let style = if i == self.recent_sel { Style::new().reversed() } else { Style::new() };
                ListItem::new(Line::from(Span::styled(label, style)))
            })
            .collect();
        let title = format!(" recent · {} files · ↵ open · ESC close ", self.recent.len());
        let list = List::new(items).block(Block::bordered().title(title));
        frame.render_widget(list, popup);
    }

    /// Render the command palette (TSK-408): the live query in the title + the
    /// fuzzy-matched command labels, the selection reversed, scrolled to keep it
    /// visible. Mirrors the recents/outline overlays.
    fn draw_palette(&self, frame: &mut Frame, area: Rect) {
        let Some(query) = &self.palette else { return };
        let popup = centered_rect(60, 70, area);
        frame.render_widget(Clear, popup);
        let inner_h = popup.height.saturating_sub(2) as usize;
        let start = self.palette_sel.saturating_sub(inner_h.saturating_sub(1));
        let items: Vec<ListItem> = self
            .palette_hits
            .iter()
            .enumerate()
            .skip(start)
            .take(inner_h.max(1))
            .filter_map(|(i, &p)| {
                PALETTE.get(p).map(|(label, _)| {
                    let style =
                        if i == self.palette_sel { Style::new().reversed() } else { Style::new() };
                    ListItem::new(Line::from(Span::styled(*label, style)))
                })
            })
            .collect();
        let title = format!(" command palette · {query}▏ · ↵ run · ESC close ");
        let list = List::new(items).block(Block::bordered().title(title));
        frame.render_widget(list, popup);
    }

    /// Render the keyboard-help overlay (TSK-247) as a centered popup listing
    /// every keybinding (key on the left, action on the right). `Clear` wipes the
    /// cells underneath so the panes don't bleed through. Any key closes it (see
    /// `on_key`). The bindings here mirror the live keymap in `on_key`.
    fn draw_help(&self, frame: &mut Frame, area: Rect) {
        const BINDINGS: &[(&str, &str)] = &[
            ("↑/↓ j/k", "move selection"),
            ("↵ → l", "open file / enter dir"),
            ("⌫ ← h", "go to parent dir"),
            ("x", "cycle view mode (text/table/hex/…)"),
            ("1-9", "open-as: force the Nth view mode"),
            ("r", "reload current file from disk"),
            ("n / N", "next / prev find match (else n: line numbers)"),
            ("i", "toggle whitespace markers"),
            ("w", "toggle word-wrap"),
            ("s", "cycle sort (name/modified/size)"),
            (".", "toggle hidden (dot) files"),
            ("f", "quick file-find (type to narrow)"),
            ("F", "grep across all files (search anywhere)"),
            ("/", "find in file (table filter in table mode)"),
            (":", "go to line"),
            ("o", "markdown outline"),
            ("] / [", "next / prev tab"),
            ("X", "close active tab"),
            ("p", "command palette"),
            ("R", "recently-opened files"),
            ("g / G", "jump to top / bottom"),
            ("PgUp/PgDn", "scroll by a page"),
            ("?", "this help (any key closes)"),
            ("q / ESC", "quit"),
        ];
        let popup = centered_rect(70, 80, area);
        frame.render_widget(Clear, popup);
        let inner_h = popup.height.saturating_sub(2) as usize; // minus borders
        // Left-pad the key column to a common width so the actions align.
        let keyw = BINDINGS.iter().map(|(k, _)| k.chars().count()).max().unwrap_or(0);
        let items: Vec<ListItem> = BINDINGS
            .iter()
            .take(inner_h.max(1))
            .map(|(k, desc)| {
                let line = Line::from(vec![
                    Span::styled(format!("{k:<keyw$}"), Style::new().fg(Color::Cyan).bold()),
                    Span::raw("  "),
                    Span::raw(*desc),
                ]);
                ListItem::new(line)
            })
            .collect();
        let list = List::new(items).block(Block::bordered().title(" keyboard help · any key closes "));
        frame.render_widget(list, popup);
    }

    /// Render the cross-file grep UI (TSK-213): the input box while the prompt is
    /// open, otherwise the results overlay (one `path:line: text` row per hit,
    /// selected row reversed, scrolled to keep the selection visible). `Clear`
    /// wipes the cells underneath so the panes don't bleed through.
    fn draw_grep(&self, frame: &mut Frame, area: Rect) {
        if let Some(needle) = &self.grep_prompt {
            let popup = centered_rect(60, 18, area);
            frame.render_widget(Clear, popup);
            let para = Paragraph::new(format!("{needle}▏")).block(
                Block::bordered().title(" search anywhere · grep all files (↵ run · ESC cancel) "),
            );
            frame.render_widget(para, popup);
            return;
        }
        if self.grep_results.is_empty() {
            return;
        }
        let popup = centered_rect(85, 80, area);
        frame.render_widget(Clear, popup);
        let inner_h = popup.height.saturating_sub(2) as usize;
        let start = self.grep_sel.saturating_sub(inner_h.saturating_sub(1));
        let items: Vec<ListItem> = self
            .grep_results
            .iter()
            .enumerate()
            .skip(start)
            .take(inner_h.max(1))
            .map(|(i, h)| {
                let rel = h.path.strip_prefix(&self.cwd).unwrap_or(&h.path).to_string_lossy();
                let label = format!("{rel}:{}: {}", h.line + 1, h.text.trim());
                let style = if i == self.grep_sel { Style::new().reversed() } else { Style::new() };
                ListItem::new(Line::from(Span::styled(label, style)))
            })
            .collect();
        let title = format!(" grep: {} hits · ↵ open · ESC close ", self.grep_results.len());
        let list = List::new(items).block(Block::bordered().title(title));
        frame.render_widget(list, popup);
    }

    /// Build the find match-minimap strip — a compact, FIXED-width distribution
    /// of where the active find's matches sit in the document, with the current
    /// match's bucket distinguished from the rest. Reuses the shared
    /// `find::match_minimap`/`find::bucket_of` so the bucketing is identical
    /// across all three front-ends (web TSK-254 is the sibling); the GLYPHS — not
    /// color — carry the signal, so the colorless TUI snapshot can assert it.
    /// `▮` = current match's bucket, `▪` = a bucket with ≥1 other match, `·` =
    /// empty. Returns `[…]` bracketed for unambiguous matching in the status line.
    fn find_minimap(&self) -> String {
        const BUCKETS: usize = 24;
        let total = self.tabs.get(self.active).map_or(0, Preview::content_len);
        let lines: Vec<usize> = self.find_matches.iter().map(|m| m.line).collect();
        let counts = find::match_minimap(&lines, total, BUCKETS);
        let cur = self.find_matches.get(self.find_sel).map(|m| find::bucket_of(m.line, total, BUCKETS));
        let mut s = String::with_capacity(BUCKETS + 2);
        s.push('[');
        for (i, &c) in counts.iter().enumerate() {
            s.push(if Some(i) == cur {
                '▮'
            } else if c > 0 {
                '▪'
            } else {
                '·'
            });
        }
        s.push(']');
        s
    }

    /// Render the tab strip (TSK-249): one chip per open buffer, `▸N name` for
    /// the active tab and ` N name` for the rest. The `▸` marker (not just color)
    /// makes the active tab assertable in the colorless snapshot; the active chip
    /// also gets a cyan style for the real terminal. Only drawn for ≥2 tabs (see
    /// `draw`).
    fn draw_tabstrip(&self, frame: &mut Frame, area: Rect) {
        let mut spans: Vec<Span> = Vec::new();
        for (i, t) in self.tabs.iter().enumerate() {
            let active = i == self.active;
            let marker = if active { '▸' } else { ' ' };
            let label = format!("{marker}{} {} ", i + 1, t.name);
            let style = if active {
                Style::new()
                    .fg(self.tc(Role::OnHighlight, Color::Black))
                    .bg(self.tc(Role::Accent, Color::Cyan))
                    .bold()
            } else {
                Style::new().fg(self.tc(Role::Muted, Color::DarkGray))
            };
            spans.push(Span::styled(label, style));
            spans.push(Span::raw(" "));
        }
        frame.render_widget(Paragraph::new(Line::from(spans)), area);
    }

    fn draw_status(&self, frame: &mut Frame, area: Rect) {
        // While the quick-find prompt is open, the command keys are captured as
        // needle text — show the prompt-specific bindings so the help isn't a lie.
        let help: String = if self.filtering() {
            "type to filter · ↑/↓ move · ↵ open top hit · ⌫ delete · ESC clear".into()
        } else if self.table_filtering() {
            "type to filter rows (col:term scopes a column) · ↵ apply · ⌫ delete · ESC cancel".into()
        } else if self.goto_active() {
            "type a line number · ↵ jump · ⌫ delete · ESC cancel".into()
        } else if self.outline_active() {
            "↑/↓ pick heading · ↵ jump to it · ESC / o close outline".into()
        } else if self.find_prompt_open() {
            "type to search this file · ↵ find + jump · ⌫ delete · ESC cancel".into()
        } else if !self.current_table_find_hits().is_empty() {
            // Table cell-find (TSK-499): position among matching CELLS in reading
            // order; n/N step cells, / opens the row filter, ESC clears. Shown in
            // place of the line-match readout because in a table the find tracks
            // cells, not lines.
            let hits = self.current_table_find_hits();
            let n = hits.len();
            let cur = self.find_sel.min(n.saturating_sub(1)) + 1;
            format!(
                "find: {cur} of {n} cells · \"{}\" · n/N next/prev cell · / filter · ESC clear",
                self.find_query,
            )
        } else if !self.find_matches.is_empty() {
            // Show the live match position so the count is visible (the `status`
            // line field is not rendered) — "find: i of n · …" / "hex: …" when
            // the query parsed as a hex byte pattern (TSK-205 parity).
            format!(
                "{}: {} of {} {} \"{}\" · n/N next/prev · / new · ESC clear",
                if self.find_is_hex { "hex" } else { "find" },
                self.find_sel + 1,
                self.find_matches.len(),
                self.find_minimap(),
                self.find_query,
            )
        } else {
            "↑/↓ move · ↵ open · ⌫ up · x mode · 1-9 open-as · r reload · n nums · i ws · w wrap · s sort · t theme · . hidden · f file-find · F grep · / find · : goto · o outline · ]/[ tabs · X close · p palette · R recent · ? help · q quit".into()
        };
        let line = Line::from(vec![
            Span::styled(
                " mdv-tui ",
                Style::new()
                    .fg(self.tc(Role::OnHighlight, Color::Black))
                    .bg(self.tc(Role::Accent, Color::Cyan))
                    .bold(),
            ),
            Span::raw(" "),
            Span::styled(help, Style::new().fg(self.tc(Role::Muted, Color::DarkGray))),
        ]);
        // Soft-wrap across the 2-row footer (TSK-243 follow-up): the badge +
        // legend flow onto the second row instead of being cut off. `trim:false`
        // keeps the leading-space alignment of wrapped continuation lines.
        frame.render_widget(Paragraph::new(line).wrap(Wrap { trim: false }), area);
    }
}

// MARK: - Helpers

/// Order the loaded TUI entries (always dirs-first) by `key`, delegating the
/// comparison to the shared `mdvcore_core::nav` comparator. The front-end `Entry`
/// carries an extra `is_parent` flag the core type lacks, so we sort an
/// index-tagged `nav::Entry` mirror with `nav::cmp` (a single STABLE `sort_by`),
/// then apply the permutation back — TUI and web tiers thus order identically by
/// construction, without re-deriving the dirs-first / per-key / tie-break logic.
fn sort_loaded(items: &mut Vec<Entry>, key: SortKey) {
    let mut mirror: Vec<(usize, nav::Entry)> = items
        .iter()
        .enumerate()
        .map(|(i, e)| {
            (i, nav::Entry { name: e.name.clone(), is_dir: e.is_dir, mtime: e.mtime, size: e.size })
        })
        .collect();
    mirror.sort_by(|(_, a), (_, b)| nav::cmp(a, b, key, true));
    let order: Vec<usize> = mirror.into_iter().map(|(i, _)| i).collect();
    let mut slots: Vec<Option<Entry>> = std::mem::take(items).into_iter().map(Some).collect();
    *items = order
        .into_iter()
        .filter_map(|i| slots.get_mut(i).and_then(Option::take))
        .collect();
}

/// Modification time of `meta` as whole seconds since the Unix epoch, or `None`
/// when unavailable (platform without mtime / pre-epoch time).
fn mtime_secs(meta: &fs::Metadata) -> Option<u64> {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
}

/// Working-tree git summary for `dir`, or `None` when it isn't a git repo / git
/// isn't installed. The front-end owns this IO (spawns `git`); the core only
/// parses the porcelain output via `git::parse_status`. `--no-optional-locks`
/// keeps it read-only-friendly (no index-lock churn) and the non-zero exit on a
/// non-repo path maps cleanly to `None` (no panic, no error spew).
fn git_status_for(dir: &Path) -> Option<git::RepoStatus> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["--no-optional-locks", "status", "--porcelain=v1", "--branch"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(git::parse_status(&String::from_utf8_lossy(&out.stdout)))
}

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

/// Per-column widths for the table view as ratatui `Constraint`s, derived from
/// the shared `view::table_col_widths` (the widest of header + a row sample,
/// clamped to a sane range) so the TUI and the web tier size CSV columns
/// identically by construction (TSK-237).
fn column_widths(header: &[String], rows: &[Vec<String>]) -> Vec<Constraint> {
    view::table_col_widths(header, rows)
        .into_iter()
        .map(|x| Constraint::Length(u16::try_from(x).unwrap_or(u16::MAX)))
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

/// Map a syntax [`TokenKind`] to a terminal colour (TSK-257). `None` = leave the
/// default foreground (structural tokens like punctuation/operators/plain
/// variables stay uncoloured so the highlight reads as accents, not a rainbow).
fn token_color(kind: TokenKind) -> Option<Color> {
    match kind {
        TokenKind::Keyword => Some(Color::Magenta),
        TokenKind::String => Some(Color::Green),
        TokenKind::Number | TokenKind::Constant => Some(Color::Yellow),
        TokenKind::Comment => Some(Color::DarkGray),
        TokenKind::Function | TokenKind::Tag => Some(Color::Blue),
        TokenKind::Type | TokenKind::Property | TokenKind::Attribute => Some(Color::Cyan),
        TokenKind::Variable | TokenKind::Operator | TokenKind::Punctuation | TokenKind::Other => None,
    }
}

/// A rect `pct_x`% wide × `pct_y`% tall, centered inside `area` — the geometry
/// for the floating outline popup. Percentages are clamped to `1..=100`.
fn centered_rect(pct_x: u16, pct_y: u16, area: Rect) -> Rect {
    let pct_x = pct_x.clamp(1, 100);
    let pct_y = pct_y.clamp(1, 100);
    let w = area.width.saturating_mul(pct_x) / 100;
    let h = area.height.saturating_mul(pct_y) / 100;
    let x = area.x + (area.width.saturating_sub(w)) / 2;
    let y = area.y + (area.height.saturating_sub(h)) / 2;
    Rect { x, y, width: w, height: h }
}

/// Tail-keeping length cap for a pane-title string (TSK-497). If `s` exceeds
/// `max` columns, keep the LAST `max-1` chars behind a leading `…`, so the most
/// specific tail — the deepest path segments / current dir — stays visible while
/// the ` · sort: … · hidden …` state markers still fit on the title line.
/// Char-based, so a multi-byte UTF-8 scalar is never split.
fn cap_tail(s: &str, max: usize) -> String {
    let count = s.chars().count();
    if count > max {
        let tail: String = s.chars().skip(count - max.saturating_sub(1)).collect();
        return format!("…{tail}");
    }
    s.to_string()
}

/// The files-pane breadcrumb for `dir` (TSK-229): the path split into its
/// segments and rejoined with ` › ` via the shared `nav::breadcrumbs` splitter,
/// so the TUI's path trail matches the web front-end's by construction. Then
/// [`cap_tail`]-bounded so a deep path (e.g. a long macOS `$TMPDIR`) can't fill
/// the title and clip the trailing ` · sort: … · hidden …` state markers.
fn breadcrumb_trail(dir: &Path) -> String {
    const MAX: usize = 36;
    let labels: Vec<String> =
        nav::breadcrumbs(&dir.to_string_lossy()).into_iter().map(|c| c.label).collect();
    cap_tail(&labels.join(" \u{203a} "), MAX)
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
        // Compact JSON so the `Formatted` mode visibly re-indents it (TSK-217).
        fs::write(dir.join("config.json"), br#"{"a":1,"b":[2,3]}"#).unwrap();
        // A dotfile + a dot-directory, hidden by default (see the `.` toggle).
        fs::write(dir.join(".secret"), b"hidden\n").unwrap();
        fs::create_dir_all(dir.join(".cache")).unwrap();
        dir
    }

    fn render(app: &mut App) -> String {
        app.snapshot(100, 24).expect("snapshot render")
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

    /// Distinct foreground colours of the rendered ALPHABETIC cells — host
    /// "pixel" coverage for syntax highlighting (TSK-257). A keyword colours its
    /// letters Magenta and a string Green; neither appears among letters unless
    /// tree-sitter highlighting actually ran, so this is teeth, not a snapshot.
    fn letter_fg_colors(app: &mut App, w: u16, h: u16) -> std::collections::HashSet<Color> {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).expect("backend");
        terminal.draw(|f| app.draw(f)).expect("draw");
        let buf = terminal.backend().buffer();
        let mut set = std::collections::HashSet::new();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                let cell = &buf[(x, y)];
                if cell.symbol().chars().next().is_some_and(|c| c.is_ascii_alphabetic()) {
                    set.insert(cell.fg);
                }
            }
        }
        set
    }

    #[test]
    fn rust_source_view_is_syntax_highlighted() {
        let dir = fixture_dir();
        fs::write(dir.join("snippet.rs"), b"fn main() {\n    let s = \"hi\";\n}\n").unwrap();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "snippet.rs");
        app.enter();
        let colors = letter_fg_colors(&mut app, 100, 24);
        // `fn`/`let` → Keyword → Magenta; the `hi` string → String → Green.
        assert!(colors.contains(&Color::Magenta), "keyword highlight present: {colors:?}");
        assert!(colors.contains(&Color::Green), "string highlight present: {colors:?}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn plain_text_and_hex_are_not_highlighted() {
        let dir = fixture_dir();
        fs::write(dir.join("snippet.rs"), b"fn main() {}\n").unwrap();
        let mut app = App::new(dir.clone());
        // `.txt` has no grammar → no keyword colour (the lang gate).
        select_name(&mut app, "hello.txt");
        app.enter();
        assert!(
            !letter_fg_colors(&mut app, 100, 24).contains(&Color::Magenta),
            "plain text must not be highlighted",
        );
        // HEX shares the render arm but must stay uncoloured (the mode gate).
        select_name(&mut app, "snippet.rs");
        app.enter();
        app.cycle_mode(); // Text → HEX
        assert!(
            !letter_fg_colors(&mut app, 100, 24).contains(&Color::Magenta),
            "hex view must not be highlighted",
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn content_state_banner_flags_empty_and_binary_files() {
        let dir = fixture_dir();
        fs::write(dir.join("empty.txt"), b"").unwrap();
        let mut app = App::new(dir.clone());
        // data.bin (has a NUL) opens as Text (Plain default) — the title flags it
        // binary so the garbled bytes aren't a mystery.
        select_name(&mut app, "data.bin");
        app.enter();
        let bin = render(&mut app);
        assert!(bin.contains("binary file"), "binary banner in content title:\n{bin}");
        // An empty file → the title says so (the pane would otherwise be blank).
        select_name(&mut app, "empty.txt");
        app.enter();
        let empty = render(&mut app);
        assert!(empty.contains("empty file"), "empty banner in content title:\n{empty}");
        // A normal text file shows neither banner.
        select_name(&mut app, "hello.txt");
        app.enter();
        let ok = render(&mut app);
        assert!(
            !ok.contains("binary file") && !ok.contains("empty file"),
            "readable text gets no state banner:\n{ok}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn text_view_shows_line_number_gutter_and_n_toggles_it() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "hello.txt");
        app.enter(); // opens in Text mode, gutter on by default
        assert!(app.show_gutter, "gutter on by default");
        let with = render(&mut app);
        // Two-line file → 1-wide gutter with the "│" separator beside line 1/2.
        assert!(with.contains("1 │ line one"), "gutter numbers line 1:\n{with}");
        assert!(with.contains("2 │ line two"), "gutter numbers line 2:\n{with}");
        // `n` toggles the gutter off — the bare content remains, the separator goes.
        app.on_key(KeyCode::Char('n'));
        assert!(!app.show_gutter, "n turns the gutter off");
        let without = render(&mut app);
        assert!(without.contains("line one"), "content still shown sans gutter:\n{without}");
        assert!(!without.contains("│ line one"), "separator gone when gutter off:\n{without}");
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
    fn open_as_number_keys_force_view_mode() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "people.csv");
        app.enter(); // Table mode; available_modes = [Table, Text, Hex]
        assert!(render(&mut app).contains("· table ·"), "opens as table");
        // Number keys force the file's Nth available mode directly (open-as).
        app.on_key(KeyCode::Char('2'));
        assert!(render(&mut app).contains("· text ·"), "2 forces text");
        app.on_key(KeyCode::Char('3'));
        assert!(render(&mut app).contains("· hex ·"), "3 forces hex");
        app.on_key(KeyCode::Char('1'));
        assert!(render(&mut app).contains("· table ·"), "1 forces table");
        // Out-of-range (only 3 modes) is a no-op, not a crash.
        app.on_key(KeyCode::Char('9'));
        assert!(render(&mut app).contains("· table ·"), "out-of-range 9 ignored");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn table_filter_narrows_rows_and_scopes_columns() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "people.csv");
        app.enter(); // Table mode: Alice,30,NYC / Bob,25,LA
        // Render wide so the long content-pane title (filter + count) never clips.
        let wide = |a: &mut App| a.snapshot(200, 24).expect("snapshot render");
        // `/` opens the prompt; typing a global needle narrows live.
        app.on_key(KeyCode::Char('/'));
        assert!(app.table_filtering(), "filter prompt open");
        for c in "Alice".chars() {
            app.on_key(KeyCode::Char(c));
        }
        // Assert on the city-column cells (NYC/LA) — they only appear in body
        // rows, never in the filter-prompt title echo, so they're unambiguous.
        let out = wide(&mut app);
        assert!(out.contains("NYC"), "Alice's row (NYC) kept:\n{out}");
        assert!(!out.contains("LA"), "Bob's row (LA) filtered out:\n{out}");
        assert!(out.contains("filter:"), "title shows the live filter prompt:\n{out}");
        // Enter commits; the prompt closes but the filter persists.
        app.on_key(KeyCode::Enter);
        assert!(!app.table_filtering(), "prompt closed after Enter");
        let committed = wide(&mut app);
        assert!(committed.contains("NYC") && !committed.contains("LA"), "applied filter persists:\n{committed}");
        // Re-open, delete to empty, commit → the full table returns.
        app.on_key(KeyCode::Char('/'));
        for _ in 0..10 {
            app.on_key(KeyCode::Backspace);
        }
        app.on_key(KeyCode::Enter);
        let full = wide(&mut app);
        assert!(full.contains("NYC") && full.contains("LA"), "empty needle restores all rows:\n{full}");
        // Column-scoped `city:Alice` matches nothing — "Alice" is in the name
        // column, not city — so no body rows survive (NYC/LA both gone).
        app.on_key(KeyCode::Char('/'));
        for c in "city:Alice".chars() {
            app.on_key(KeyCode::Char(c));
        }
        let scoped = wide(&mut app);
        assert!(!scoped.contains("NYC") && !scoped.contains("LA"), "city-scoped Alice matches no rows:\n{scoped}");
        assert!(scoped.contains("0/2 rows"), "count shows zero matches:\n{scoped}");
        let _ = fs::remove_dir_all(&dir);
    }

    /// Render to a `TestBackend` and hand back the terminal so a test can inspect
    /// per-cell STYLE (the `String` snapshot drops styling — needed to assert the
    /// cell-find highlight, not just its text).
    fn render_buf(app: &mut App, w: u16, h: u16) -> Terminal<TestBackend> {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).expect("backend");
        terminal.draw(|f| app.draw(f)).expect("draw");
        terminal
    }

    /// Background color of the first `word` occurring in the screen row that also
    /// contains `marker`. Matched cell-by-cell (NOT by byte offset) so the table's
    /// multi-byte border glyph `│` doesn't shift the column mapping. `None` if the
    /// row/word isn't rendered.
    fn bg_in_row(buf: &ratatui::buffer::Buffer, marker: &str, word: &str) -> Option<Color> {
        let want: Vec<String> = word.chars().map(|c| c.to_string()).collect();
        for y in 0..buf.area.height {
            let syms: Vec<String> =
                (0..buf.area.width).map(|x| buf[(x, y)].symbol().to_string()).collect();
            if !syms.concat().contains(marker) {
                continue;
            }
            for x in 0..syms.len() {
                if x + want.len() <= syms.len() && (0..want.len()).all(|k| syms[x + k] == want[k]) {
                    return Some(buf[(x as u16, y)].bg);
                }
            }
        }
        None
    }

    #[test]
    fn theme_toggle_routes_highlight_colors_through_the_core_palette() {
        // TSK-243: `t` cycles Adaptive → Dark → Light → Adaptive, routing the
        // chrome through `mdvcore_core::theme`. This is a REAL per-cell pixel
        // assertion — it reads the actual bg `Color` of the find-highlight cells
        // (reusing the proven CSV cell-find path). Adaptive keeps the exact ANSI
        // colors (so the default look is unchanged — the existing find tests stay
        // green); Dark/Light swap in the palette's `Color::Rgb`. A layout-only
        // check would miss the color entirely (the original park's concern).
        let dir = fixture_dir();
        fs::write(dir.join("cells.csv"), b"city,note\nParis,xx\nplan,Paris\n").unwrap();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "cells.csv");
        app.enter();
        // Open the in-file find via the palette and commit "par" → hits (0,0)+(1,1).
        app.on_key(KeyCode::Char('p'));
        for c in "find".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        for c in "par".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);

        // Adaptive (default): current cell magenta, other hit yellow — UNCHANGED.
        let term = render_buf(&mut app, 100, 24);
        let buf = term.backend().buffer();
        assert_eq!(bg_in_row(buf, "xx", "Paris"), Some(Color::Magenta), "adaptive current");
        assert_eq!(bg_in_row(buf, "plan", "Paris"), Some(Color::Yellow), "adaptive other hit");

        // `t` → Dark: the highlight bgs become the palette's dark RGB tokens.
        app.on_key(KeyCode::Char('t'));
        assert_eq!(app.theme_mode, ThemeMode::Dark);
        let cur_d = theme::Palette::for_mode(theme::Mode::Dark).color(Role::CurrentBg);
        let hl_d = theme::Palette::for_mode(theme::Mode::Dark).color(Role::HighlightBg);
        let term = render_buf(&mut app, 100, 24);
        let buf = term.backend().buffer();
        assert_eq!(
            bg_in_row(buf, "xx", "Paris"),
            Some(Color::Rgb(cur_d.r, cur_d.g, cur_d.b)),
            "dark mode paints the current cell with the palette CurrentBg"
        );
        assert_eq!(
            bg_in_row(buf, "plan", "Paris"),
            Some(Color::Rgb(hl_d.r, hl_d.g, hl_d.b)),
            "dark mode paints the other hit with the palette HighlightBg"
        );

        // `t` → Light: distinct light RGB tokens.
        app.on_key(KeyCode::Char('t'));
        assert_eq!(app.theme_mode, ThemeMode::Light);
        let cur_l = theme::Palette::for_mode(theme::Mode::Light).color(Role::CurrentBg);
        let term = render_buf(&mut app, 100, 24);
        assert_eq!(
            bg_in_row(term.backend().buffer(), "xx", "Paris"),
            Some(Color::Rgb(cur_l.r, cur_l.g, cur_l.b)),
            "light mode paints the light CurrentBg"
        );
        assert_ne!((cur_d.r, cur_d.g, cur_d.b), (cur_l.r, cur_l.g, cur_l.b), "dark≠light");

        // `t` → back to Adaptive (the exact ANSI Magenta again).
        app.on_key(KeyCode::Char('t'));
        assert_eq!(app.theme_mode, ThemeMode::Adaptive);
        let term = render_buf(&mut app, 100, 24);
        assert_eq!(
            bg_in_row(term.backend().buffer(), "xx", "Paris"),
            Some(Color::Magenta),
            "cycles back to adaptive (ANSI magenta)"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn persist_state_config_roundtrips() {
        // TSK-235: serialize → parse is identity for a fully-populated state.
        let st = PersistState {
            cwd: Some(PathBuf::from("/tmp/some/dir")),
            sort: SortKey::Size,
            show_hidden: true,
            wrap: false,
            show_gutter: false,
            theme: ThemeMode::Dark,
            tabs: Vec::new(),
            active: 0,
        };
        assert_eq!(PersistState::from_config(&st.to_config()), st);
    }

    #[test]
    fn persist_config_is_lenient_to_missing_unknown_and_malformed() {
        // Recognized key applies; unknown key ignored; malformed value + missing
        // keys fall back to defaults — never panics (the gate denies panics).
        let st = PersistState::from_config(
            "sort=modified\nbogus=zzz\nwrap=notabool\n# a comment\n\ntheme=dark\n",
        );
        assert_eq!(st.sort, SortKey::Modified); // recognized
        assert_eq!(st.theme, ThemeMode::Dark); // recognized
        assert!(st.wrap); // malformed "notabool" → default (true)
        assert!(!st.show_hidden); // missing → default (false)
        assert!(st.show_gutter); // missing → default (true)
        assert_eq!(st.cwd, None); // missing → None
    }

    #[test]
    fn save_then_load_config_roundtrips_via_disk() {
        // IO roundtrip through a TEMP path (never the real ~/.textview).
        let dir = fixture_dir();
        let path = dir.join("tui").join("config"); // parent dirs auto-created
        let st = PersistState {
            cwd: Some(dir.clone()),
            sort: SortKey::Modified,
            show_hidden: true,
            wrap: false,
            show_gutter: true,
            theme: ThemeMode::Light,
            tabs: Vec::new(),
            active: 0,
        };
        save_config(&path, &st);
        assert_eq!(load_config(&path), Some(st));
        // Absent file → None (not an error).
        assert_eq!(load_config(&dir.join("nope").join("config")), None);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn apply_prefs_sets_app_view_state() {
        let dir = fixture_dir();
        fs::write(dir.join("a.txt"), b"x\n").unwrap();
        let mut app = App::new(dir.clone());
        assert_eq!(app.sort, SortKey::Name); // defaults pre-apply
        assert!(!app.show_hidden);
        let p = PersistState {
            cwd: None,
            sort: SortKey::Size,
            show_hidden: true,
            wrap: false,
            show_gutter: false,
            theme: ThemeMode::Dark,
            tabs: Vec::new(),
            active: 0,
        };
        app.apply_prefs(&p);
        assert_eq!(app.sort, SortKey::Size);
        assert!(app.show_hidden);
        assert!(!app.wrap);
        assert!(!app.show_gutter);
        assert_eq!(app.theme_mode, ThemeMode::Dark);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn persist_state_roundtrips_open_tabs() {
        // TSK-515: the codec round-trips open buffers (path + scroll + per-file
        // mode) + the active index. A path WITH A SPACE proves the
        // mode/scroll/path field split keeps the path intact.
        let st = PersistState {
            cwd: Some(PathBuf::from("/tmp/some/dir")),
            sort: SortKey::Name,
            show_hidden: false,
            wrap: true,
            show_gutter: true,
            theme: ThemeMode::Adaptive,
            tabs: vec![
                OpenTab {
                    path: PathBuf::from("/tmp/my dir/file name.txt"),
                    scroll: 42,
                    mode: ViewMode::Hex,
                },
                OpenTab {
                    path: PathBuf::from("/tmp/data.csv"),
                    scroll: 0,
                    mode: ViewMode::Table,
                },
            ],
            active: 1,
        };
        assert_eq!(PersistState::from_config(&st.to_config()), st);
    }

    #[test]
    fn tab_config_is_lenient_to_malformed_lines() {
        // TSK-515: each well-formed `tab=` appends a buffer; unknown-mode and
        // missing-field lines are skipped; a non-numeric scroll degrades to 0;
        // a path with spaces survives — never panics.
        let st = PersistState::from_config(
            "tab=text 5 /a.txt\n\
             tab=bogusmode 1 /skip-me.txt\n\
             tab=hex\n\
             tab=table notanum /spaced path.csv\n\
             active=1\n",
        );
        assert_eq!(st.tabs.len(), 2, "unknown-mode + field-less lines skipped");
        assert_eq!(st.tabs[0].mode, ViewMode::Text);
        assert_eq!(st.tabs[0].scroll, 5);
        assert_eq!(st.tabs[0].path, PathBuf::from("/a.txt"));
        assert_eq!(st.tabs[1].mode, ViewMode::Table);
        assert_eq!(st.tabs[1].scroll, 0, "non-numeric scroll → 0");
        assert_eq!(st.tabs[1].path, PathBuf::from("/spaced path.csv"));
        assert_eq!(st.active, 1);
    }

    #[test]
    fn restore_tabs_reopens_saved_files_with_mode_and_clamped_scroll() {
        // TSK-515: restore re-opens each saved file in tab order, skips ones that
        // vanished, clamps an over-large scroll to the content, honors the saved
        // mode, and clamps `active` to the count actually re-opened.
        let dir = fixture_dir();
        fs::write(dir.join("a.txt"), b"l1\nl2\nl3\n").unwrap();
        fs::write(dir.join("data.csv"), b"name,age\nAlice,30\nBob,25\n").unwrap();
        let mut app = App::new(dir.clone());
        let tabs = vec![
            OpenTab {
                path: dir.join("a.txt"),
                scroll: 9999, // huge → must clamp to content
                mode: ViewMode::Text,
            },
            OpenTab {
                path: dir.join("gone.txt"), // missing → skipped
                scroll: 0,
                mode: ViewMode::Text,
            },
            OpenTab {
                path: dir.join("data.csv"),
                scroll: 0,
                mode: ViewMode::Table,
            },
        ];
        app.restore_tabs(&tabs, 2);

        assert_eq!(app.tabs.len(), 2, "the missing file is skipped");
        assert_eq!(app.tabs[0].path, dir.join("a.txt"));
        assert_eq!(app.tabs[0].view.mode, ViewMode::Text);
        assert_eq!(
            app.tabs[0].scroll,
            app.tabs[0].content_len().saturating_sub(1),
            "an over-large saved scroll clamps to the content's last line"
        );
        assert_eq!(app.tabs[1].path, dir.join("data.csv"));
        assert_eq!(app.tabs[1].view.mode, ViewMode::Table, "saved Table mode honored for a CSV");
        // active was 2 (the missing tab's intended slot); only 2 tabs re-opened
        // so it clamps to the last valid index.
        assert_eq!(app.active, 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn table_cell_find_highlights_current_steps_and_clears() {
        // TSK-499 slice 2b: CSV table CELL-find on the rust-core TUI (parity with
        // the web slice + Swift CSVFind). Reachable via the command palette ("find
        // in file") since `/` is the row filter in table mode; highlights matching
        // cells (the current one distinctly), n/N step the cells, ESC clears. This
        // is a pixel-style assertion: it inspects the rendered buffer's per-cell bg
        // — a layout-only "is rendered" check would miss the highlight entirely.
        let dir = fixture_dir();
        // "Paris" sits in TWO cells (row 0 col 0 and row 1 col 1) so stepping is
        // non-degenerate; "xx"/"plan" tag the two body rows for the bg lookup.
        fs::write(dir.join("cells.csv"), b"city,note\nParis,xx\nplan,Paris\n").unwrap();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "cells.csv");
        app.enter(); // CSV opens in Table mode
        assert!(render(&mut app).contains("· table ·"), "opens as table");

        // Drive the REAL trigger: the command palette (p → "find" → ↵ runs
        // Cmd::Find → open_find), proving the feature is reachable without a
        // dedicated key and that `/` stays the row filter.
        app.on_key(KeyCode::Char('p'));
        for c in "find".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        assert!(
            app.find_prompt_open(),
            "palette 'find in file' opens the find prompt while a table is showing"
        );
        for c in "par".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter); // commit: case-insensitive → hits (0,0) and (1,1)
        assert_eq!(app.find_sel, 0, "first cell selected on commit");

        // Current hit (row 0 "Paris", in the "xx" row) is magenta; the other hit
        // (row 1 "Paris", in the "plan" row) is yellow; a non-match ("plan") has no
        // highlight (default Reset bg).
        let term = render_buf(&mut app, 100, 24);
        let buf = term.backend().buffer();
        assert_eq!(bg_in_row(buf, "xx", "Paris"), Some(Color::Magenta), "current cell is distinct");
        assert_eq!(bg_in_row(buf, "plan", "Paris"), Some(Color::Yellow), "other hit highlighted");
        assert_eq!(bg_in_row(buf, "plan", "plan"), Some(Color::Reset), "non-match not highlighted");
        assert!(render(&mut app).contains("find: 1 of 2 cells"), "status shows the cell position");

        // n steps to the second cell — the current marker moves to row 1's "Paris".
        app.on_key(KeyCode::Char('n'));
        assert_eq!(app.find_sel, 1, "n steps to the second cell");
        let term2 = render_buf(&mut app, 100, 24);
        let buf2 = term2.backend().buffer();
        assert_eq!(bg_in_row(buf2, "plan", "Paris"), Some(Color::Magenta), "current moved to cell 2");
        assert_eq!(bg_in_row(buf2, "xx", "Paris"), Some(Color::Yellow), "cell 1 is now a plain hit");
        assert!(render(&mut app).contains("find: 2 of 2 cells"), "status advanced");

        // n wraps back to the first cell.
        app.on_key(KeyCode::Char('n'));
        assert_eq!(app.find_sel, 0, "n wraps past the end to the first cell");

        // ESC clears the find — nothing stays highlighted.
        app.on_key(KeyCode::Esc);
        assert!(app.find_query.is_empty(), "ESC clears the table find");
        let term3 = render_buf(&mut app, 100, 24);
        let buf3 = term3.backend().buffer();
        assert_eq!(bg_in_row(buf3, "xx", "Paris"), Some(Color::Reset), "no highlight after clear");
        assert_eq!(bg_in_row(buf3, "plan", "Paris"), Some(Color::Reset), "no highlight after clear");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn in_file_find_jumps_to_first_match_and_n_steps() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "hello.txt");
        app.enter(); // Text mode: "line one" / "line two"
        let _ = render(&mut app); // populate content_height (centering needs it)
        // `/` opens the IN-FILE find prompt in text mode (table filter only in
        // table mode); the live query shows in the content-pane title.
        app.on_key(KeyCode::Char('/'));
        assert!(app.find_prompt_open(), "/ opens the in-file find prompt");
        for c in "line".chars() {
            app.on_key(KeyCode::Char(c));
        }
        assert!(render(&mut app).contains("find: line"), "title shows the live query");
        // Enter runs the search across the file's raw text via `find::find_matches`.
        app.on_key(KeyCode::Enter);
        assert!(!app.find_prompt_open(), "Enter closes the prompt");
        assert_eq!(app.find_matches.len(), 2, "'line' matches both lines");
        assert_eq!(app.find_sel, 0, "first match selected on commit");
        assert!(render(&mut app).contains("find: 1 of 2"), "status shows match position");
        // n steps forward (wrapping); N steps back.
        app.on_key(KeyCode::Char('n'));
        assert_eq!(app.find_sel, 1, "n → next match");
        app.on_key(KeyCode::Char('n'));
        assert_eq!(app.find_sel, 0, "n wraps past the end");
        app.on_key(KeyCode::Char('N'));
        assert_eq!(app.find_sel, 1, "N wraps back to the last");
        // ESC dismisses the active find; `n` then resumes toggling the gutter.
        app.on_key(KeyCode::Esc);
        assert!(app.find_matches.is_empty(), "ESC clears the active find");
        let gutter = app.show_gutter;
        app.on_key(KeyCode::Char('n'));
        assert_ne!(app.show_gutter, gutter, "with no find, n toggles the gutter again");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn find_minimap_marks_match_buckets_and_current_and_renders_in_status() {
        // TSK-253: the find-bar minimap is a fixed 24-bucket distribution of the
        // active find's matches (shared `find::match_minimap`/`bucket_of`, parity
        // with web TSK-254). hello.txt is 2 lines; "line" matches BOTH, so they
        // land in buckets 0 (line 0) and 12 (line 1 → 1*24/2). The CURRENT match
        // is `▮`, other hit buckets `▪`, empty `·`. The glyphs (not color) carry
        // the signal so the colorless snapshot has teeth.
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "hello.txt");
        app.enter();
        let _ = render(&mut app);
        app.on_key(KeyCode::Char('/'));
        for c in "line".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        assert_eq!(app.find_matches.len(), 2, "'line' matches both lines");

        // Structural invariants — stable regardless of the file's exact line count
        // (the first match is line 0, which buckets to 0 for ANY total).
        let m0 = app.find_minimap();
        assert_eq!(m0.chars().count(), 26, "bracketed strip is [ + 24 buckets + ]");
        assert_eq!(m0.matches('▮').count(), 1, "exactly one current-match marker");
        assert!(m0.starts_with("[▮"), "current match (sel 0, line 0 → bucket 0) marks the first bucket: {m0}");
        assert!(m0.contains('▪'), "the other match shows as a hit bucket: {m0}");
        assert!(render(&mut app).contains(&m0), "minimap is actually drawn in the status line");

        // n advances the selection → the single current marker moves OFF bucket 0,
        // which becomes a plain hit. Proves the marker tracks find_sel.
        app.on_key(KeyCode::Char('n'));
        assert_eq!(app.find_sel, 1, "n advanced the selection");
        let m1 = app.find_minimap();
        assert_eq!(m1.matches('▮').count(), 1, "still exactly one current marker");
        assert!(m1.starts_with("[▪"), "bucket 0 is now a plain hit, not current: {m1}");
        assert_ne!(m0, m1, "the current marker moved with the selection");
        assert!(render(&mut app).contains(&m1), "moved minimap is drawn");

        // ESC clears the find → no current-bucket marker anywhere on screen.
        app.on_key(KeyCode::Esc);
        assert!(app.find_matches.is_empty(), "ESC clears the find");
        assert!(!render(&mut app).contains('▮'), "no minimap when no find is active");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn command_palette_lists_fuzzy_filters_and_runs_a_command() {
        // TSK-408: `p` opens a palette listing actions; typing fuzzy-filters via
        // the shared nav::filter_entries scorer; Enter runs the selected action
        // (a real model outcome); ESC closes without running.
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());

        app.on_key(KeyCode::Char('p'));
        assert!(app.palette_active(), "p opens the command palette");
        let out = render(&mut app);
        assert!(out.contains("command palette"), "palette titled:\n{out}");
        assert!(out.contains("toggle hidden files"), "commands listed:\n{out}");
        assert_eq!(app.palette_hits.len(), PALETTE.len(), "empty query lists every command");

        // Fuzzy-narrow to the hidden-files command ("hidden" only subsequence-
        // matches that one label).
        for c in "hidden".chars() {
            app.on_key(KeyCode::Char(c));
        }
        let top = app.palette_hits.first().and_then(|&p| PALETTE.get(p)).map(|(l, _)| *l);
        assert_eq!(top, Some("toggle hidden files"), "fuzzy narrows to the hidden cmd: {:?}", app.palette_hits);

        // Enter runs it → show_hidden flips and the palette closes.
        let before = app.show_hidden;
        app.on_key(KeyCode::Enter);
        assert!(!app.palette_active(), "Enter closes the palette");
        assert_ne!(app.show_hidden, before, "running 'toggle hidden files' flipped the model");

        // ESC closes without running any command.
        app.on_key(KeyCode::Char('p'));
        let hidden = app.show_hidden;
        app.on_key(KeyCode::Esc);
        assert!(!app.palette_active(), "ESC closes the palette");
        assert_eq!(app.show_hidden, hidden, "ESC ran nothing");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tabs_open_switch_retain_state_focus_existing_and_close() {
        // TSK-249: each open file is a tab with its own Preview (scroll/mode); a
        // strip lists them with the active marked `▸`; ]/[ cycle and preserve
        // per-tab state; re-opening an open file focuses its tab; X closes.
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());

        // One open file → no tab strip (single buffer uses full height).
        select_name(&mut app, "hello.txt");
        app.enter();
        assert_eq!(app.tabs.len(), 1, "one tab open");
        assert!(!render(&mut app).contains('▸'), "no tab strip for a single buffer");

        // Open a second file → 2 tabs, the new one active and strip-marked.
        select_name(&mut app, "config.json");
        app.enter();
        assert_eq!(app.tabs.len(), 2, "second file opened a second tab");
        assert_eq!(app.active, 1, "newly opened tab is active");
        let strip = render(&mut app);
        assert!(strip.contains("hello.txt") && strip.contains("config.json"), "strip lists both:\n{strip}");
        assert!(strip.contains("▸2 config.json"), "active tab is marked in the strip:\n{strip}");

        // Per-tab state retention: change the active tab's (config.json) mode, switch
        // away and back — the Preview lives on, so its mode is preserved.
        let before = app.tabs.get(app.active).unwrap().view.mode;
        app.on_key(KeyCode::Char('x'));
        let after = app.tabs.get(app.active).unwrap().view.mode;
        assert_ne!(before, after, "x cycled the active tab's mode");
        app.on_key(KeyCode::Char('[')); // → tab 0 (hello.txt)
        assert_eq!(app.active, 0, "[ moved to the previous tab");
        assert_eq!(app.tabs.get(app.active).unwrap().name, "hello.txt", "tab 0 is hello.txt");
        app.on_key(KeyCode::Char(']')); // → back to tab 1 (config.json)
        assert_eq!(app.active, 1, "] wrapped back to config.json");
        assert_eq!(app.tabs.get(app.active).unwrap().view.mode, after, "per-tab mode retained across switch");

        // Re-opening an already-open file focuses its tab (no duplicate).
        select_name(&mut app, "hello.txt");
        app.enter();
        assert_eq!(app.tabs.len(), 2, "re-open focuses, does not duplicate");
        assert_eq!(app.active, 0, "focused the existing hello.txt tab");

        // X closes the active tab; the other becomes active.
        app.on_key(KeyCode::Char('X'));
        assert_eq!(app.tabs.len(), 1, "X closed a tab");
        assert_eq!(app.tabs.get(app.active).unwrap().name, "config.json", "remaining tab is active");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recents_picker_lists_opened_files_mru_and_enter_reopens() {
        // TSK-233: opening files records them in an MRU history (shared
        // history::push); `R` opens a picker overlay listing them newest-first;
        // Enter re-opens the selected one. Glyph-free text rows, so the colorless
        // snapshot can assert them.
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());

        // R with empty history is a no-op (nothing opened yet).
        app.on_key(KeyCode::Char('R'));
        assert!(!app.recent_active(), "R does nothing with an empty history");

        // Open two files; the second becomes the most-recent.
        select_name(&mut app, "hello.txt");
        app.enter();
        select_name(&mut app, "data.bin");
        app.enter();
        assert_eq!(app.recent.len(), 2, "two distinct opens recorded");

        // R opens the picker; it lists both, newest (data.bin) first and selected.
        app.on_key(KeyCode::Char('R'));
        assert!(app.recent_active(), "R opens the recents picker");
        let out = render(&mut app);
        assert!(out.contains("recent ·"), "recents overlay titled:\n{out}");
        assert!(out.contains("data.bin") && out.contains("hello.txt"), "both files listed:\n{out}");
        assert_eq!(app.recent_sel, 0, "selection starts at the most-recent");

        // ↓ selects the older entry (hello.txt); Enter re-opens it, which also
        // bumps it back to the front of the MRU.
        app.on_key(KeyCode::Down);
        assert_eq!(app.recent_sel, 1, "down moves to the older entry");
        app.on_key(KeyCode::Enter);
        assert!(!app.recent_active(), "Enter closes the picker");
        assert_eq!(
            app.tabs.get(app.active).map(|p| p.name.as_str()),
            Some("hello.txt"),
            "Enter re-opened the selected recent file"
        );
        assert_eq!(
            app.recent.first().and_then(|p| p.file_name()).and_then(|n| n.to_str()),
            Some("hello.txt"),
            "re-open bumped it to the front of the MRU"
        );

        // ESC closes the picker without opening (re-open it, then ESC).
        app.on_key(KeyCode::Char('R'));
        assert!(app.recent_active());
        app.on_key(KeyCode::Esc);
        assert!(!app.recent_active(), "ESC closes the picker");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn files_title_shows_git_branch_and_dirty_summary_for_a_repo() {
        // TSK-251: a git working tree's summary (branch + dirty counts) appears
        // in the files-pane title, parsed by the shared `git::parse_status`. The
        // front-end owns the `git` invocation; here we stand up a real throwaway
        // repo so the IO wiring (git_status_for → parse_status → title) is
        // exercised end to end, not mocked. (cargo runs tests in threads within
        // one process, so the pid-named dir is unique to this test.)
        let dir = std::env::temp_dir().join(format!("mdv-tui-git-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("mk tmp repo dir");
        let init = Command::new("git").arg("-C").arg(&dir).arg("init").output().expect("spawn git");
        assert!(init.status.success(), "git init failed: {init:?}");
        fs::write(dir.join("scratch.txt"), b"hi").expect("write untracked file");

        let app = App::new(dir.clone());
        let st = app.git_status.as_ref().expect("cwd is a git repo ⇒ Some status");
        assert_eq!(st.untracked, 1, "one untracked file");
        assert!(!st.is_clean(), "an untracked file makes the tree dirty");

        let title = app.files_title();
        assert!(title.contains("git: "), "title carries the git segment: {title}");
        assert!(title.contains("?1"), "title shows the untracked count: {title}");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn hex_search_in_hex_mode_matches_bytes_and_stays_in_hex() {
        // TSK-205: `/` in HEX mode searches the raw BYTES via the shared
        // `core::hex::hex_search` and lands on the dump ROW, staying in Hex
        // (not forced to Text like the text find).
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "data.bin"); // bytes: 00 41 ff 7f
        app.enter();
        app.cycle_mode(); // → Hex (per hex_of_binary_uses_core_render)
        assert_eq!(app.tabs.get(app.active).unwrap().view.mode, ViewMode::Hex, "in hex mode");
        let _ = render(&mut app); // populate content_height (centering needs it)

        // Hex-byte query "41" → byte 0x41 at offset 1 → dump row 0.
        app.on_key(KeyCode::Char('/'));
        assert!(app.find_prompt_open(), "/ opens find in hex mode");
        for c in "41".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        assert!(app.find_is_hex, "match came from the hex byte search");
        assert_eq!(app.find_matches.len(), 1, "one 0x41 byte in data.bin");
        assert_eq!(app.find_matches[0].line, 0, "offset 1 → dump row 0");
        assert_eq!(
            app.tabs.get(app.active).unwrap().view.mode,
            ViewMode::Hex,
            "hex search STAYS in Hex view (not forced to Text)"
        );
        assert!(render(&mut app).contains("hex: 1 of 1"), "status shows the hex match position");

        // A pattern absent from the file → no matches + a hex-labelled status.
        app.on_key(KeyCode::Char('/'));
        for _ in 0..8 {
            app.on_key(KeyCode::Backspace); // clear the seeded prior query
        }
        for c in "0000".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        assert!(app.find_matches.is_empty(), "no 00 00 byte pair in data.bin");
        assert!(!app.find_is_hex, "no-match resets the hex flag");
        // The bottom bar falls back to the browse help on a miss (the `status`
        // field is not rendered — see in_file_find_no_match_reports_*), so the
        // hex-labelled report lives in the model field; assert it there.
        assert!(
            app.status.starts_with("hex: no matches"),
            "no-match status is hex-labelled: {:?}",
            app.status,
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn json_offers_formatted_mode_and_pretty_prints() {
        // TSK-217: a .json file is classified Structured, so its mode set offers
        // Formatted (Text → Formatted → Hex). Cycling to Formatted re-indents the
        // compact source via the shared core pretty-printer.
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "config.json"); // {"a":1,"b":[2,3]}
        app.enter();
        let p = app.tabs.get(app.active).unwrap();
        assert_eq!(p.kind, view::FileKind::Structured, "json is Structured");
        assert_eq!(p.view.mode, ViewMode::Text, "opens in Text (the raw source)");
        assert_eq!(
            p.view.available_modes,
            vec![ViewMode::Text, ViewMode::Formatted, ViewMode::Hex],
            "Formatted is offered between Text and Hex",
        );
        // Raw Text mode shows the compact one-liner (no indentation).
        let raw = render(&mut app);
        assert!(raw.contains(r#"{"a":1,"b":[2,3]}"#), "Text shows compact source:\n{raw}");

        // Cycle Text → Formatted; the body is now the pretty-printed JSON.
        app.cycle_mode();
        assert_eq!(app.tabs.get(app.active).unwrap().view.mode, ViewMode::Formatted);
        let pretty = render(&mut app);
        assert!(pretty.contains("formatted"), "title reflects formatted mode:\n{pretty}");
        assert!(pretty.contains(r#"  "a": 1,"#), "2-space indented key:\n{pretty}");
        assert!(pretty.contains(r#"    2,"#), "nested array element indented:\n{pretty}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn r_reloads_current_file_from_disk() {
        // TSK-239: `r` re-reads the open file, picking up an external edit while
        // preserving the view mode. No auto-reload before the key is pressed.
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "hello.txt"); // "line one\nline two\n"
        app.enter();
        assert!(render(&mut app).contains("line one"), "initial content shown");

        // External edit on disk.
        fs::write(dir.join("hello.txt"), b"fresh alpha\nfresh beta\nfresh gamma\n").unwrap();
        // Stale until the user reloads — the preview is not a live file watcher.
        let stale = render(&mut app);
        assert!(stale.contains("line one") && !stale.contains("fresh alpha"),
            "content stays stale until reload:\n{stale}");

        // `r` re-reads from disk.
        app.on_key(KeyCode::Char('r'));
        let out = render(&mut app);
        assert!(out.contains("fresh alpha") && out.contains("fresh gamma"),
            "reloaded content shown:\n{out}");
        assert!(!out.contains("line one"), "old content gone:\n{out}");
        assert_eq!(app.tabs.get(app.active).unwrap().view.mode, ViewMode::Text, "mode preserved");
        assert!(app.status.starts_with("reloaded"), "status reports reload: {:?}", app.status);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn in_file_find_no_match_reports_and_leaves_no_highlight() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "hello.txt");
        app.enter();
        let _ = render(&mut app);
        app.on_key(KeyCode::Char('/'));
        for c in "zebra".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        assert!(app.find_matches.is_empty(), "no matches for 'zebra'");
        assert!(!app.find_prompt_open(), "prompt closed after a no-match search");
        // With no active find the status bar falls back to the browse help (it
        // never enters the find-active "n/N next/prev" branch).
        let out = render(&mut app);
        // "x mode" sits early in the browse help (the long help truncates at the
        // status-bar width, so assert on an early token, not a trailing one).
        assert!(out.contains("x mode"), "browse help shown (no find-active bar):\n{out}");
        assert!(!out.contains("n/N next/prev"), "no find-active bar after a miss:\n{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn files_pane_shows_active_sort_and_s_cycles_it() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        // Render wide so the long temp-dir path in the pane title doesn't clip
        // the `· sort: <key>` suffix off the right border of the 35%-width pane.
        let wide = |a: &mut App| a.snapshot(220, 24).expect("snapshot render");
        // Default is name; the pane title advertises it.
        assert_eq!(app.sort, SortKey::Name, "opens on the name key");
        assert!(wide(&mut app).contains("sort: name"), "default sort shown in title");
        // `s` cycles name → modified → size → name; titles track it.
        app.on_key(KeyCode::Char('s'));
        assert_eq!(app.sort, SortKey::Modified);
        assert!(wide(&mut app).contains("sort: modified"), "s → modified");
        app.on_key(KeyCode::Char('s'));
        assert_eq!(app.sort, SortKey::Size);
        assert!(wide(&mut app).contains("sort: size"), "s → size");
        app.on_key(KeyCode::Char('s'));
        assert_eq!(app.sort, SortKey::Name);
        assert!(wide(&mut app).contains("sort: name"), "s wraps → name");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn files_pane_title_shows_breadcrumb_trail() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        // Render wide so the breadcrumb at the START of the pane title isn't
        // clipped by the 35%-width pane border.
        let wide = app.snapshot(220, 24).expect("snapshot render");
        // The cwd is shown as a `›`-separated breadcrumb (root + ≥1 segment), so
        // at least one separator is visible — this is the breadcrumb, not the old
        // plain path. The leaf segment (the temp dir name) is its tail.
        assert!(wide.contains('\u{203a}'), "pane title shows a breadcrumb separator:\n{wide}");
        let leaf = dir.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        assert!(wide.contains(&leaf), "breadcrumb tail is the current dir name:\n{wide}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn question_mark_opens_keyboard_help_overlay_and_any_key_closes() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        assert!(!app.show_help, "help is closed by default");
        // Render wide+tall so the centered help popup isn't clipped.
        let big = |a: &mut App| a.snapshot(120, 30).expect("snapshot render");
        app.on_key(KeyCode::Char('?'));
        assert!(app.show_help, "? opens the help overlay");
        let out = big(&mut app);
        assert!(out.contains("keyboard help"), "overlay is titled:\n{out}");
        assert!(out.contains("cycle view mode"), "a binding action is listed:\n{out}");
        assert!(out.contains("go to line"), "another binding action is listed:\n{out}");
        // Any key dismisses it (modal) — and does NOT also fire that key's command.
        app.on_key(KeyCode::Char('j'));
        assert!(!app.show_help, "any key closes the help overlay");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn capital_f_greps_across_files_and_enter_opens_hit_at_line() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        let big = |a: &mut App| a.snapshot(120, 30).expect("snapshot render");
        // `F` opens the grep prompt; type a needle present in hello.txt ("line one/two").
        app.on_key(KeyCode::Char('F'));
        assert!(app.grep_prompt.is_some(), "F opens the grep prompt");
        for c in "line".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter); // run the recursive grep
        assert!(app.grep_prompt.is_none(), "Enter closes the prompt");
        assert!(!app.grep_results.is_empty(), "grep found hits");
        assert!(
            app.grep_results.iter().all(|h| h.path.ends_with("hello.txt")),
            "only hello.txt contains the needle: {:?}",
            app.grep_results.iter().map(|h| h.path.clone()).collect::<Vec<_>>()
        );
        let out = big(&mut app);
        assert!(out.contains("grep:"), "results overlay titled:\n{out}");
        assert!(out.contains("hello.txt"), "matching file listed in the overlay:\n{out}");
        // Enter on the selected hit opens that file and flashes the match line.
        let target_line = app.grep_results[0].line;
        app.on_key(KeyCode::Enter);
        assert!(app.grep_results.is_empty(), "opening a hit closes the overlay");
        assert!(app.tabs.get(app.active).is_some_and(|p| p.name == "hello.txt"), "hit's file opened");
        assert_eq!(app.flash, Some(target_line), "the hit line is flashed");
        // A no-match query reports cleanly and shows no overlay.
        app.on_key(KeyCode::Char('F'));
        for c in "zzzznotfound".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        assert!(app.grep_results.is_empty(), "no-match grep shows no overlay");
        assert!(app.status.contains("no matches"), "no-match status: {}", app.status);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn sort_keeps_dirs_first_and_parent_pinned() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        app.on_key(KeyCode::Char('s')); // → modified (re-sorts in place)
        // `..` stays pinned at index 0; the real `sub` dir still precedes files.
        assert!(app.entries.first().is_some_and(|e| e.is_parent), "parent pinned top");
        let first_file = app.entries.iter().position(|e| !e.is_dir).unwrap_or(app.entries.len());
        assert!(app.entries[..first_file].iter().all(|e| e.is_dir), "dirs lead under any sort");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn dotfiles_hidden_by_default_and_dot_toggles_them() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        // Default: dotfiles are suppressed; ordinary files remain.
        assert!(!app.show_hidden, "opens with dotfiles hidden");
        assert!(!app.entries.iter().any(|e| e.name == ".secret"), ".secret hidden by default");
        assert!(!app.entries.iter().any(|e| e.name == ".cache"), ".cache hidden by default");
        assert!(app.entries.iter().any(|e| e.name == "hello.txt"), "ordinary file still listed");
        // `.` reveals them and the pane title advertises the state.
        app.on_key(KeyCode::Char('.'));
        assert!(app.show_hidden, ". turns on show_hidden");
        assert!(app.entries.iter().any(|e| e.name == ".secret"), ".secret revealed");
        assert!(app.entries.iter().any(|e| e.name == ".cache"), ".cache revealed");
        let wide = app.snapshot(220, 24).expect("snapshot render");
        assert!(wide.contains("hidden shown"), "title marks revealed state:\n{wide}");
        // `.` again re-hides; toggling re-lists from disk, so the count round-trips.
        app.on_key(KeyCode::Char('.'));
        assert!(!app.show_hidden, ". toggles back off");
        assert!(!app.entries.iter().any(|e| e.name == ".secret"), ".secret hidden again");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn cap_tail_keeps_the_tail_under_the_column_budget() {
        // A short string passes through unchanged.
        assert_eq!(cap_tail("/tmp/a", 36), "/tmp/a");
        // A long string is left-ellipsized to <=max columns, keeping the TAIL
        // (the most specific suffix) so the files-pane title still has room for
        // the ` · sort: … · hidden …` state markers (TSK-497).
        let long = "/private/var/folders/rw/l8yh97w15_5frl0n0bhvpvtc0000gn/T/mdv-tui-test-1519";
        let out = cap_tail(long, 36);
        assert!(out.chars().count() <= 36, "capped to 36 cols, got {}: {out}", out.chars().count());
        assert!(out.starts_with('…'), "truncation marked with a leading ellipsis: {out}");
        assert!(out.ends_with("mdv-tui-test-1519"), "keeps the tail (current dir): {out}");
    }

    #[test]
    fn breadcrumb_trail_segments_the_path_and_caps_it() {
        use std::path::PathBuf;
        // Short absolute path → root crumb then segments, joined with ` › `.
        assert_eq!(breadcrumb_trail(&PathBuf::from("/a/b/c")), "/ \u{203a} a \u{203a} b \u{203a} c");
        // The root is a single crumb.
        assert_eq!(breadcrumb_trail(&PathBuf::from("/")), "/");
        // A deep path is tail-capped (leading ellipsis) but still carries the
        // breadcrumb separator into the kept tail.
        let deep = PathBuf::from(
            "/private/var/folders/rw/l8yh97w15_5frl0n0bhvpvtc0000gn/T/mdv-tui-test-1519",
        );
        let out = breadcrumb_trail(&deep);
        assert!(out.chars().count() <= 36, "capped to 36 cols: {out}");
        assert!(out.starts_with('…'), "long trail is ellipsized: {out}");
        assert!(out.contains('\u{203a}'), "kept tail still shows a › separator: {out}");
    }

    #[test]
    fn text_view_title_shows_encoding_and_line_ending_badge() {
        let dir = fixture_dir();
        // A CRLF, no-BOM file written BEFORE App::new so it is in the listing.
        // CRLF (not LF) proves the badge is computed from the bytes, not hardcoded.
        fs::write(dir.join("crlf.txt"), b"a\r\nb\r\n").unwrap();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "crlf.txt");
        app.enter();
        let out = app.snapshot(220, 24).expect("snapshot render");
        assert!(out.contains("UTF-8"), "encoding label in the text-view title:\n{out}");
        assert!(out.contains("CRLF"), "CRLF line-ending badge (from bytes, not hardcoded):\n{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn w_toggles_word_wrap_in_text_view() {
        let dir = fixture_dir();
        // A line far longer than the content pane so wrap vs truncate is
        // observable: the trailing "TAIL" only renders when the line soft-wraps.
        let long = "X".repeat(200);
        fs::write(dir.join("long.txt"), format!("{long}TAIL\n")).unwrap();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "long.txt");
        app.enter();
        assert!(app.wrap, "wrap on by default");
        let wrapped = app.snapshot(120, 24).expect("render");
        assert!(wrapped.contains("TAIL"), "wrapped line shows its tail:\n{wrapped}");
        // `w` turns wrap OFF → the long line truncates at the pane edge, hiding TAIL.
        app.on_key(KeyCode::Char('w'));
        assert!(!app.wrap, "w toggles wrap off");
        let truncated = app.snapshot(120, 24).expect("render");
        assert!(!truncated.contains("TAIL"), "truncated line hides its tail:\n{truncated}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn text_view_title_shows_file_metrics() {
        let dir = fixture_dir();
        // 2 lines, 3 words — distinct counts so a lines/words swap would fail.
        fs::write(dir.join("metrics.txt"), b"alpha beta\ngamma\n").unwrap();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "metrics.txt");
        app.enter();
        let out = app.snapshot(220, 24).expect("snapshot render");
        assert!(out.contains("2 lines"), "line count in the title:\n{out}");
        assert!(out.contains("3 words"), "word count in the title:\n{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn i_toggles_whitespace_markers_in_text_view() {
        let dir = fixture_dir();
        // The shared view expands tabs to spaces upstream, so the front-end sees
        // spaces; the `i` toggle reveals every space as `·`. (Assert on the
        // content substring "a·b", NOT a bare "·" — the pane title bars use "·"
        // as a separator regardless of this toggle.)
        fs::write(dir.join("ws.txt"), b"a b c\n").unwrap();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "ws.txt");
        app.enter();
        // Off by default: raw spaces are shown, no markers.
        let before = app.snapshot(120, 24).expect("render");
        assert!(before.contains("a b c"), "raw spaces shown before toggle:\n{before}");
        assert!(!before.contains("a·b"), "no space marker before toggle:\n{before}");
        // `i` reveals whitespace: spaces → ·.
        app.on_key(KeyCode::Char('i'));
        assert!(app.show_whitespace, "i turns show_whitespace on");
        let after = app.snapshot(120, 24).expect("render");
        assert!(after.contains("a·b·c"), "spaces revealed as markers after toggle:\n{after}");
        // `i` again turns it back off.
        app.on_key(KeyCode::Char('i'));
        assert!(!app.show_whitespace, "i toggles back off");
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

    #[test]
    fn f_opens_quick_find_prompt_and_narrows_live() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        // `f` opens the prompt; the pane title shows the live "find:" input.
        app.on_key(KeyCode::Char('f'));
        assert!(app.filtering(), "f opens the quick-find prompt");
        let out = render(&mut app);
        assert!(out.contains("find:"), "pane title shows the filter prompt:\n{out}");
        // Type "hel" → only hello.txt survives (people.csv / data.bin / sub drop).
        for c in "hel".chars() {
            app.on_key(KeyCode::Char(c));
        }
        assert_eq!(app.filter.as_deref(), Some("hel"), "needle accumulates typed chars");
        let names: Vec<&str> =
            app.filtered.iter().filter_map(|&i| app.entries.get(i)).map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["hello.txt"], "only hello.txt matches 'hel': {names:?}");
        let narrowed = render(&mut app);
        assert!(narrowed.contains("hello.txt"), "match shown:\n{narrowed}");
        assert!(!narrowed.contains("people.csv"), "non-match hidden:\n{narrowed}");
        assert!(narrowed.contains("1 hits"), "hit count in title:\n{narrowed}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn quick_find_enter_opens_top_hit() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        app.on_key(KeyCode::Char('f'));
        // "peo" → people.csv is the (only / top) hit; Enter opens it.
        for c in "peo".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        let out = render(&mut app);
        assert!(out.contains("· table ·"), "Enter opened the CSV top hit as a table:\n{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn quick_find_subsequence_match_via_core_scorer() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        app.on_key(KeyCode::Char('f'));
        // "hw" is a subsequence of "hello.txt"? no ('w' absent). Use "ho" which is
        // a subsequence of hell**o**... actually validate the subsequence path:
        // "dt" matches da**t**a.bin? d→a→t→a: 'd' then 't' → yes (data.bin). It is
        // NOT a substring, proving we route through nav::filter_entries.
        for c in "dt".chars() {
            app.on_key(KeyCode::Char(c));
        }
        let names: Vec<&str> =
            app.filtered.iter().filter_map(|&i| app.entries.get(i)).map(|e| e.name.as_str()).collect();
        assert!(names.contains(&"data.bin"), "'dt' subsequence-matches data.bin: {names:?}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn esc_clears_quick_find_and_restores_full_listing() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        app.on_key(KeyCode::Char('f'));
        for c in "hel".chars() {
            app.on_key(KeyCode::Char(c));
        }
        assert!(app.filtering(), "prompt open mid-needle");
        // ESC closes the prompt and clears the needle; the full listing returns.
        app.on_key(KeyCode::Esc);
        assert!(!app.filtering(), "ESC closes the quick-find prompt");
        assert!(app.filter.is_none(), "needle cleared");
        let out = render(&mut app);
        assert!(out.contains("hello.txt") && out.contains("people.csv"), "full listing restored:\n{out}");
        assert!(!out.contains("find:"), "filter prompt gone from title:\n{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn quick_find_backspace_widens_the_match_set() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        app.on_key(KeyCode::Char('f'));
        for c in "hello".chars() {
            app.on_key(KeyCode::Char(c));
        }
        let narrow = app.filtered.len();
        // Backspace to "hell" should match at least as many entries (monotone).
        app.on_key(KeyCode::Backspace);
        assert_eq!(app.filter.as_deref(), Some("hell"), "backspace trims one char");
        assert!(app.filtered.len() >= narrow, "shorter needle matches >= entries");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn quick_find_command_keys_are_literal_needle_text() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        app.on_key(KeyCode::Char('f'));
        // 's' would normally cycle sort and 'q' would quit — while filtering they
        // must be captured as needle characters, not fire their commands.
        let sort_before = app.sort;
        let quit = app.on_key(KeyCode::Char('s'));
        assert!(!quit, "'s' does not quit while filtering");
        assert_eq!(app.sort, sort_before, "'s' did NOT cycle sort while filtering");
        let quit = app.on_key(KeyCode::Char('q'));
        assert!(!quit, "'q' is a needle char, not a quit, while filtering");
        assert_eq!(app.filter.as_deref(), Some("sq"), "command keys appended to the needle");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn entering_a_dir_clears_the_quick_find() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        app.on_key(KeyCode::Char('f'));
        for c in "su".chars() {
            app.on_key(KeyCode::Char(c));
        }
        // "su" → the `sub` directory is the top hit; Enter descends into it AND
        // closes the prompt (the needle belonged to the parent directory).
        app.on_key(KeyCode::Enter);
        assert!(app.cwd.ends_with("sub"), "descended into the matched dir");
        assert!(!app.filtering(), "entering a dir clears the quick-find prompt");
        let _ = fs::remove_dir_all(&dir);
    }

    /// Write a fixture file with `n` numbered lines and return its dir + path.
    fn many_line_fixture(n: usize) -> (PathBuf, PathBuf) {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "mdv-tui-goto-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let body: String = (1..=n).map(|i| format!("line {i}\n")).collect();
        let path = dir.join("long.txt");
        fs::write(&path, body).unwrap();
        (dir, path)
    }

    #[test]
    fn colon_opens_goto_prompt_and_jump_centers_and_flashes() {
        let (dir, path) = many_line_fixture(200);
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        // Render once so `content_height` is populated (centering depends on it).
        let _ = render(&mut app);
        // `:` opens the go-to-line prompt; the title shows the live input.
        app.on_key(KeyCode::Char(':'));
        assert!(app.goto_active(), ": opens the go-to-line prompt");
        let prompt = render(&mut app);
        assert!(prompt.contains("goto line:"), "prompt shown in title:\n{prompt}");
        // Type "100" then Enter → jump to line 100 (1-based).
        for c in "100".chars() {
            app.on_key(KeyCode::Char(c));
        }
        assert_eq!(app.goto.as_deref(), Some("100"), "digits accumulate");
        app.on_key(KeyCode::Enter);
        assert!(!app.goto_active(), "Enter closes the prompt");
        assert_eq!(app.flash, Some(99), "flash marks the 0-based target line");
        // Centered: scroll puts line 100 roughly mid-viewport (not at the top).
        let half = app.content_height / 2;
        assert_eq!(app.tabs.get(app.active).unwrap().scroll, 99usize.saturating_sub(half));
        // The target line is now visible in the rendered frame.
        let out = render(&mut app);
        assert!(out.contains("line 100"), "jumped-to line visible:\n{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn goto_clamps_overshoot_to_last_line_via_core() {
        let (dir, path) = many_line_fixture(50);
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        let _ = render(&mut app);
        app.on_key(KeyCode::Char(':'));
        // 9999 over-shoots a 50-line file (plus the trailing empty line = 51 lines);
        // clamp_line pins it to the last line. Flash is the last 0-based index.
        for c in "9999".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        let len = app.tabs.get(app.active).unwrap().content_len();
        assert_eq!(app.flash, Some(len - 1), "over-shoot clamps to the last line");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn goto_prompt_captures_digits_not_commands_and_esc_cancels() {
        let (dir, path) = many_line_fixture(30);
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        let _ = render(&mut app);
        app.on_key(KeyCode::Char(':'));
        // Non-digit command keys are ignored inside the prompt (don't fire, don't
        // append); only digits accumulate.
        let quit = app.on_key(KeyCode::Char('q'));
        assert!(!quit, "'q' does not quit while the goto prompt is open");
        app.on_key(KeyCode::Char('1'));
        app.on_key(KeyCode::Char('x')); // ignored (not a digit)
        app.on_key(KeyCode::Char('2'));
        assert_eq!(app.goto.as_deref(), Some("12"), "only digits captured: {:?}", app.goto);
        // ESC cancels without jumping (no flash set).
        app.on_key(KeyCode::Esc);
        assert!(!app.goto_active(), "ESC closes the prompt");
        assert!(app.flash.is_none(), "cancel does not flash");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn colon_is_a_noop_with_no_file_open() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        // No preview yet → `:` can't open the goto prompt (nothing to jump in).
        app.on_key(KeyCode::Char(':'));
        assert!(!app.goto_active(), ": is inert with no open file");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn scrolling_clears_the_goto_flash() {
        let (dir, path) = many_line_fixture(100);
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        let _ = render(&mut app);
        app.on_key(KeyCode::Char(':'));
        for c in "50".chars() {
            app.on_key(KeyCode::Char(c));
        }
        app.on_key(KeyCode::Enter);
        assert!(app.flash.is_some(), "jump sets the flash");
        // Any subsequent scroll clears the one-shot highlight.
        app.on_key(KeyCode::PageDown);
        assert!(app.flash.is_none(), "scrolling clears the flash");
        let _ = fs::remove_dir_all(&dir);
    }

    // MARK: - Markdown outline overlay (`o`)

    /// Write a markdown fixture (with a code fence carrying a `#` decoy) and
    /// return its dir + path.
    fn markdown_fixture() -> (PathBuf, PathBuf) {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "mdv-tui-outline-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let body = "\
# Title
intro paragraph

## Section A
some text
```
# not a heading (in a fence)
```

## Section B
more text
";
        let path = dir.join("doc.md");
        fs::write(&path, body).unwrap();
        (dir, path)
    }

    #[test]
    fn o_opens_outline_for_markdown_and_lists_headings() {
        let (dir, path) = markdown_fixture();
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        let _ = render(&mut app);
        app.on_key(KeyCode::Char('o'));
        assert!(app.outline_active(), "o opens the outline for a .md file");
        // Three real headings; the fenced `#` decoy is excluded.
        let hs = app.outline.as_ref().expect("outline present");
        assert_eq!(hs.len(), 3, "headings: {hs:?}");
        let out = render(&mut app);
        assert!(out.contains("outline"), "overlay titled:\n{out}");
        assert!(out.contains("H1 Title"), "H1 listed:\n{out}");
        assert!(out.contains("H2 Section A"), "H2 listed:\n{out}");
        assert!(out.contains("H2 Section B"), "second H2 listed:\n{out}");
        assert!(!out.contains("not a heading"), "fenced decoy excluded:\n{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn outline_enter_jumps_to_heading_line_and_flashes() {
        let (dir, path) = markdown_fixture();
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        let _ = render(&mut app);
        app.on_key(KeyCode::Char('o'));
        // Move to the third heading (## Section B, on line 11) and jump.
        app.on_key(KeyCode::Down);
        app.on_key(KeyCode::Down);
        assert_eq!(app.outline_sel, 2, "selection moved to the 3rd heading");
        let target_line = app.outline.as_ref().unwrap()[2].line; // 1-based
        app.on_key(KeyCode::Enter);
        assert!(!app.outline_active(), "Enter closes the overlay");
        // The flash marks the 0-based target line (heading line - 1).
        assert_eq!(app.flash, Some(target_line - 1), "flashed the heading's line");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn outline_jump_forces_text_mode_from_hex() {
        let (dir, path) = markdown_fixture();
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        app.cycle_mode(); // → HEX
        assert_eq!(app.tabs.get(app.active).unwrap().view.mode, ViewMode::Hex);
        let _ = render(&mut app);
        // Outline scans the raw bytes, so it opens even in hex mode.
        app.on_key(KeyCode::Char('o'));
        assert!(app.outline_active(), "outline opens regardless of view mode");
        app.on_key(KeyCode::Enter); // jump to H1
        // Jumping a heading forces Text mode so the line target is meaningful.
        assert_eq!(app.tabs.get(app.active).unwrap().view.mode, ViewMode::Text, "jump switches to text");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn o_and_esc_close_the_outline() {
        let (dir, path) = markdown_fixture();
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        app.on_key(KeyCode::Char('o'));
        assert!(app.outline_active(), "open");
        app.on_key(KeyCode::Char('o')); // re-press toggles closed
        assert!(!app.outline_active(), "o toggles the outline closed");
        app.on_key(KeyCode::Char('o')); // re-open
        app.on_key(KeyCode::Esc); // ESC closes
        assert!(!app.outline_active(), "ESC closes the outline");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn o_is_inert_for_non_markdown_files() {
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "hello.txt");
        app.enter();
        app.on_key(KeyCode::Char('o'));
        assert!(!app.outline_active(), "o does nothing for a non-.md file");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn opening_another_file_clears_a_stale_outline() {
        let (dir, path) = markdown_fixture();
        let mut app = App::new(dir.clone());
        app.open_file(&path);
        app.on_key(KeyCode::Char('o'));
        assert!(app.outline_active(), "outline open on the md file");
        // Opening another file drops the previous file's outline.
        let other = dir.join("other.md");
        fs::write(&other, b"# Only\n").unwrap();
        app.open_file(&other);
        assert!(!app.outline_active(), "a new file clears the stale outline");
        let _ = fs::remove_dir_all(&dir);
    }
}
