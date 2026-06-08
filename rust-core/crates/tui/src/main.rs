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

use std::fs;
use std::io;
use std::io::Read;
use std::path::{Path, PathBuf};
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
use mdvcore_core::meta;
use mdvcore_core::hex::{self, HexSearchMode};
use mdvcore_core::view::{self, DiffLineKind, FileKind, View, ViewBody, ViewMode};
use mdvcore_core::whitespace;

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
        print!("{}", app.snapshot(100, 30)?);
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
}

impl Preview {
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

struct App {
    cwd: PathBuf,
    entries: Vec<Entry>,
    /// Pre-formatted file-list rows, rebuilt in `reload_dir` (1:1 with
    /// `entries`) and reused by `draw_files` so per-frame work is viewport-
    /// bounded rather than scaling with directory size.
    list_rows: Vec<ListRow>,
    list: ListState,
    preview: Option<Preview>,
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
    /// Whether the keyboard-help overlay is open (TSK-247). Toggled with `?`;
    /// any key dismisses it. A centered popup listing every keybinding, drawn
    /// over the panes — so the full shortcut set is discoverable without leaving
    /// the app or squinting at the truncated bottom help line.
    show_help: bool,
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
            entries: Vec::new(),
            list_rows: Vec::new(),
            list: ListState::default(),
            preview: None,
            status: String::new(),
            content_height: 1,
            sort: SortKey::Name,
            show_hidden: false,
            filter: None,
            filtered: Vec::new(),
            show_gutter: true,
            show_whitespace: false,
            wrap: true,
            show_help: false,
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
        self.rebuild_rows(entries);
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
                self.preview = Some(Preview {
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
                });
                self.flash = None;
                self.outline = None; // a stale outline belongs to the old file
                self.clear_find(); // matches/needle belong to the old file
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
        let Some(p) = &self.preview else { return };
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
                };
                // Clamp the old scroll into the (possibly shorter) new content.
                let max_scroll = next.content_len().saturating_sub(1);
                next.scroll = prev_scroll.min(max_scroll);
                self.preview = Some(next);
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
        if let Some(p) = &mut self.preview {
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
        if let Some(p) = &mut self.preview {
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
        if let Some(p) = &mut self.preview {
            let max = p.content_len().saturating_sub(1);
            let next = (p.scroll as isize + delta).clamp(0, max as isize);
            p.scroll = next as usize;
        }
        self.flash = None;
    }

    fn scroll_to(&mut self, top: bool) {
        if let Some(p) = &mut self.preview {
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
        if self.preview.is_some() && self.goto.is_none() {
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
        let Some(p) = &mut self.preview else { return };
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

    // MARK: - CSV table filter (shared `view::table_query` + `filter`)

    /// Whether the table-filter prompt is open (capturing keys).
    fn table_filtering(&self) -> bool {
        self.preview.as_ref().is_some_and(|p| p.table_filter_editing.is_some())
    }

    /// Open the table-filter prompt (Table mode only), seeding it with the
    /// currently-applied needle so re-opening lets you edit it. A no-op with a
    /// status hint when the current view isn't a table.
    fn open_table_filter(&mut self) {
        let is_table = self.preview.as_ref().is_some_and(|p| p.view.mode == ViewMode::Table);
        if !is_table {
            self.status = "filter: switch to table view first (x)".into();
            return;
        }
        if let Some(p) = &mut self.preview {
            if p.table_filter_editing.is_none() {
                p.table_filter_editing = Some(p.table_filter.clone());
            }
        }
    }

    /// Commit the prompt: the live needle becomes the applied filter; scroll
    /// resets to the top of the narrowed rows.
    fn commit_table_filter(&mut self) {
        if let Some(p) = &mut self.preview {
            if let Some(needle) = p.table_filter_editing.take() {
                p.table_filter = needle;
                p.scroll = 0;
            }
        }
    }

    /// Cancel the prompt, reverting to the previously-applied filter (live edits
    /// discarded).
    fn cancel_table_filter(&mut self) {
        if let Some(p) = &mut self.preview {
            p.table_filter_editing = None;
            p.scroll = 0;
        }
    }

    /// Append a character to the live needle (results re-filter as you type).
    fn table_filter_push(&mut self, c: char) {
        if let Some(p) = &mut self.preview {
            if let Some(n) = &mut p.table_filter_editing {
                n.push(c);
                p.scroll = 0;
            }
        }
    }

    /// Delete the last character of the live needle.
    fn table_filter_backspace(&mut self) {
        if let Some(p) = &mut self.preview {
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
        let Some(p) = &self.preview else {
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
        if let Some(p) = &mut self.preview {
            if p.view.mode != ViewMode::Text {
                p.view = view::build(&p.raw, &p.name, p.total, p.truncated, ViewMode::Text);
                p.scroll = 0;
            }
        }
        self.outline = None;
        let Some(p) = &mut self.preview else { return };
        let len = p.content_len();
        let line0 = view::clamp_line(target, len).saturating_sub(1); // 1-based → 0-based
        let half = self.content_height / 2;
        let max_scroll = len.saturating_sub(1);
        p.scroll = line0.saturating_sub(half).min(max_scroll);
        self.flash = Some(line0);
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
        if self.preview.is_some() && self.find.is_none() {
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
        let Some(p) = &self.preview else { return };
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
            if let Some(p) = &mut self.preview {
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
        let Some(p) = &mut self.preview else { return };
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
                if self.find_matches.is_empty() {
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
                if self.find_matches.is_empty() {
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
            KeyCode::Char('.') => self.toggle_hidden(),
            KeyCode::Char('f') => self.open_filter(),
            KeyCode::Char(':') => self.open_goto(),
            // `/` searches: the table filter in Table mode, in-file find otherwise.
            KeyCode::Char('/') => {
                let is_table =
                    self.preview.as_ref().is_some_and(|p| p.view.mode == ViewMode::Table);
                if is_table {
                    self.open_table_filter();
                } else {
                    self.open_find();
                }
            }
            KeyCode::Char('o') => self.toggle_outline(),
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
        let rows = Layout::vertical([Constraint::Min(1), Constraint::Length(1)]).split(frame.area());
        let cols =
            Layout::horizontal([Constraint::Percentage(35), Constraint::Percentage(65)]).split(rows[0]);
        self.draw_files(frame, cols[0]);
        self.draw_content(frame, cols[1]);
        // The outline overlay floats over the content pane when open.
        if self.outline.is_some() {
            self.draw_outline(frame, cols[1]);
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
            // Surface the dotfile state: a clear "hidden shown" marker when on,
            // and a "(. shows hidden)" affordance when suppressing — so the user
            // knows dotfiles are filtered and how to reveal them.
            let hidden = if self.show_hidden { " · hidden shown" } else { " · . shows hidden" };
            format!(" {} · sort: {}{hidden} ", breadcrumb_trail(&self.cwd), self.sort.as_str())
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
        let Some(p) = &self.preview else {
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
                let header_row = Row::new(header.iter().map(|h| Cell::from(h.clone())))
                    .style(Style::new().fg(Color::Cyan).bold());
                let start = p.scroll.min(shown.len().saturating_sub(1));
                let body: Vec<Row> = shown
                    .iter()
                    .skip(start)
                    .take(inner_h.saturating_sub(1).max(1))
                    .map(|r| Row::new(r.iter().map(|c| Cell::from(c.clone())).collect::<Vec<_>>()))
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
                        // Show-invisibles: spaces/tabs → markers via shared core.
                        let text = if show_ws { whitespace::reveal(s) } else { s.clone() };
                        if gutter {
                            let n = idx + 1;
                            // Right-align to `gw`, then a thin "│ " separator;
                            // the gutter is DIM so the content stays primary.
                            let label = format!("{n:>gw$} ");
                            Line::from(vec![
                                Span::styled(label, Style::new().fg(Color::DarkGray)),
                                Span::styled("│ ", Style::new().fg(Color::DarkGray)),
                                Span::styled(text, content_style),
                            ])
                        } else {
                            Line::from(Span::styled(text, content_style))
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
            ("/", "find in file (table filter in table mode)"),
            (":", "go to line"),
            ("o", "markdown outline"),
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
        } else if !self.find_matches.is_empty() {
            // Show the live match position so the count is visible (the `status`
            // line field is not rendered) — "find: i of n · …" / "hex: …" when
            // the query parsed as a hex byte pattern (TSK-205 parity).
            format!(
                "{}: {} of {} \"{}\" · n/N next/prev · / new · ESC clear",
                if self.find_is_hex { "hex" } else { "find" },
                self.find_sel + 1,
                self.find_matches.len(),
                self.find_query,
            )
        } else {
            "↑/↓ move · ↵ open · ⌫ up · x mode · 1-9 open-as · r reload · n nums · i ws · w wrap · s sort · . hidden · f file-find · / find · : goto · o outline · ? help · q quit".into()
        };
        let line = Line::from(vec![
            Span::styled(" mdv-tui ", Style::new().fg(Color::Black).bg(Color::Cyan).bold()),
            Span::raw(" "),
            Span::styled(help, Style::new().fg(Color::DarkGray)),
        ]);
        frame.render_widget(Paragraph::new(line), area);
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
    fn hex_search_in_hex_mode_matches_bytes_and_stays_in_hex() {
        // TSK-205: `/` in HEX mode searches the raw BYTES via the shared
        // `core::hex::hex_search` and lands on the dump ROW, staying in Hex
        // (not forced to Text like the text find).
        let dir = fixture_dir();
        let mut app = App::new(dir.clone());
        select_name(&mut app, "data.bin"); // bytes: 00 41 ff 7f
        app.enter();
        app.cycle_mode(); // → Hex (per hex_of_binary_uses_core_render)
        assert_eq!(app.preview.as_ref().unwrap().view.mode, ViewMode::Hex, "in hex mode");
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
            app.preview.as_ref().unwrap().view.mode,
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
        let p = app.preview.as_ref().unwrap();
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
        assert_eq!(app.preview.as_ref().unwrap().view.mode, ViewMode::Formatted);
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
        assert_eq!(app.preview.as_ref().unwrap().view.mode, ViewMode::Text, "mode preserved");
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
        assert_eq!(app.preview.as_ref().unwrap().scroll, 99usize.saturating_sub(half));
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
        let len = app.preview.as_ref().unwrap().content_len();
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
        assert_eq!(app.preview.as_ref().unwrap().view.mode, ViewMode::Hex);
        let _ = render(&mut app);
        // Outline scans the raw bytes, so it opens even in hex mode.
        app.on_key(KeyCode::Char('o'));
        assert!(app.outline_active(), "outline opens regardless of view mode");
        app.on_key(KeyCode::Enter); // jump to H1
        // Jumping a heading forces Text mode so the line target is meaningful.
        assert_eq!(app.preview.as_ref().unwrap().view.mode, ViewMode::Text, "jump switches to text");
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
