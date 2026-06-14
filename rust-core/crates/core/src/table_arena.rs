//! Contiguous arena storage for a parsed CSV table (audit TSK-546).
//!
//! The wire [`Table`] is `Vec<Vec<String>>` — fine as a transfer DTO, but as
//! the SESSION's resident store it costs ~2 allocations + a `Vec` header per
//! row plus one heap `String` per cell (~2M+ allocations for a 1M-cell CSV),
//! and the per-keystroke filter scan pointer-chases scattered cells.
//!
//! [`TableArena`] keeps the same data in exactly TWO heap blocks: one
//! contiguous `String` holding every cell's bytes (header first, then body
//! row-major) and one flat offset table. The filter scan walks one linear
//! buffer; wire shapes are projected from spans on demand (serde serializes
//! `&str` exactly like `String`, so frames stay byte-identical).
//!
//! Offsets are `usize`, not `u32`: the 4 bytes/cell saved would buy a silent
//! dependence on the CSV heap caps staying under 4 GiB — an invariant this
//! type can't see (`Limits` is caller-supplied). Correctness unconditioned
//! on a far-away cap beats the marginal shrink.
//!
//! Arity: rows are stored at the header's column count, mirroring the wire
//! [`Table`] contract ("body with column count normalized to header.len()" —
//! `csv::parse` always emits that shape). A hand-built ragged `Table` is
//! normalized here (short rows pad with empty cells, long rows truncate).

use crate::filter::{CellMatcher, Query, Scope};
use crate::wire::{Table, WireFault};
use serde::Serialize;

/// A parsed CSV table in arena layout: all cell text in one contiguous
/// buffer + a flat cell-boundary offset table. Immutable after build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableArena {
    delimiter: String,
    truncated: bool,
    cols: usize,
    row_count: usize,
    /// Every cell's bytes, concatenated: header cells 0..cols, then body
    /// rows row-major. Cell boundaries are always char boundaries (cells
    /// are whole `str`s).
    bytes: String,
    /// Cell boundaries: global cell `k` spans `bytes[offsets[k]..offsets[k+1]]`.
    /// Header cell `c` is global cell `c`; body cell `(r, c)` is global cell
    /// `cols + r*cols + c`. Length = total cells + 1 (a lone `[0]` when the
    /// table has no cells at all).
    offsets: Vec<usize>,
}

impl TableArena {
    /// Build from a wire [`Table`], consuming it. One pass; the arena ends up
    /// holding exactly two heap blocks regardless of cell count.
    #[must_use]
    pub fn from_table(table: Table) -> Self {
        let cols = table.header.len();
        let row_count = table.rows.len();
        let total: usize = table
            .header
            .iter()
            .map(String::len)
            .chain(table.rows.iter().flat_map(|r| r.iter().map(String::len)))
            .sum();
        let mut bytes = String::with_capacity(total);
        let mut offsets = Vec::with_capacity((row_count + 1) * cols + 1);
        offsets.push(0);
        for cell in &table.header {
            bytes.push_str(cell);
            offsets.push(bytes.len());
        }
        for row in &table.rows {
            // Normalize to header arity (the wire Table contract): short rows
            // pad with empty cells, long rows truncate.
            for c in 0..cols {
                if let Some(cell) = row.get(c) {
                    bytes.push_str(cell);
                }
                offsets.push(bytes.len());
            }
        }
        Self {
            delimiter: table.delimiter,
            truncated: table.truncated,
            cols,
            row_count,
            bytes,
            offsets,
        }
    }

    /// Construct directly from already-normalized arena parts — the
    /// `csv::parse_arena` fast path (TSK-844), which writes cell bytes straight
    /// into `bytes` and never materializes a `Vec<Vec<String>>`.
    ///
    /// INVARIANT (caller-guaranteed): `offsets` is the fencepost array for
    /// `cols * (row_count + 1)` cells laid out header-first then body row-major
    /// — i.e. `offsets.len() == cols * (row_count + 1) + 1` — or `vec![0]` for
    /// an empty table. Cell boundaries must be char boundaries in `bytes`.
    pub(crate) fn from_csv_parts(
        delimiter: String,
        truncated: bool,
        cols: usize,
        row_count: usize,
        bytes: String,
        offsets: Vec<usize>,
    ) -> Self {
        Self {
            delimiter,
            truncated,
            cols,
            row_count,
            bytes,
            offsets,
        }
    }

    /// The detected (or supplied) delimiter.
    #[must_use]
    pub fn delimiter(&self) -> &str {
        &self.delimiter
    }

    /// Whether any resource cap fired during the parse.
    #[must_use]
    pub fn truncated(&self) -> bool {
        self.truncated
    }

    /// Column count (the header's arity).
    #[must_use]
    pub fn cols(&self) -> usize {
        self.cols
    }

    /// Body row count.
    #[must_use]
    pub fn row_count(&self) -> usize {
        self.row_count
    }

    /// The span of global cell `k`. Out-of-range → `""` (no-panic).
    fn span(&self, k: usize) -> &str {
        let (Some(&start), Some(&end)) = (self.offsets.get(k), self.offsets.get(k + 1)) else {
            return "";
        };
        self.bytes.get(start..end).unwrap_or("")
    }

    /// Header cell `c`, or `""` when out of range.
    #[must_use]
    pub fn header_cell(&self, c: usize) -> &str {
        if c >= self.cols {
            return "";
        }
        self.span(c)
    }

    /// Body cell `(row, col)`, or `""` when out of range.
    #[must_use]
    pub fn cell(&self, row: usize, col: usize) -> &str {
        if row >= self.row_count || col >= self.cols {
            return "";
        }
        self.span(self.cols + row * self.cols + col)
    }

    /// Iterate body row `row`'s cells (empty iterator when out of range).
    pub fn row(&self, row: usize) -> impl Iterator<Item = &str> {
        let in_range = row < self.row_count;
        (0..if in_range { self.cols } else { 0 }).map(move |c| self.cell(row, c))
    }

    /// Header cells as borrowed slices (wire-projection helper).
    #[must_use]
    pub fn header_vec(&self) -> Vec<&str> {
        (0..self.cols).map(|c| self.header_cell(c)).collect()
    }

    /// Materialize an owned wire [`Table`] (tests / callers that need the
    /// DTO). The wire-frame hot path should use [`TableArena::table_frame`].
    #[must_use]
    pub fn to_table(&self) -> Table {
        Table {
            delimiter: self.delimiter.clone(),
            header: self.header_vec().into_iter().map(str::to_string).collect(),
            rows: (0..self.row_count)
                .map(|r| self.row(r).map(str::to_string).collect())
                .collect(),
            truncated: self.truncated,
        }
    }

    /// Encode the full table as a length-prefixed MessagePack frame,
    /// byte-identical to `wire::encode_frame(&self.to_table())` — but
    /// serialized straight from spans, no owned `Table` materialized.
    ///
    /// # Errors
    /// [`WireFault::Encode`] / [`WireFault::TooLarge`] per `encode_frame`.
    pub fn table_frame(&self) -> Result<Vec<u8>, WireFault> {
        let rows: Vec<Vec<&str>> = (0..self.row_count)
            .map(|r| self.row(r).collect())
            .collect();
        let view = TableView {
            delimiter: &self.delimiter,
            header: self.header_vec(),
            rows,
            truncated: self.truncated,
        };
        crate::wire::encode_frame(&view)
    }

    /// Apply `query` over the arena, returning surviving body-row indices —
    /// same semantics as `filter::matching_indices_in` (the shared
    /// [`CellMatcher`] is the single home of the match rules), but the scan
    /// walks one contiguous buffer instead of pointer-chasing per-cell heap
    /// blocks.
    #[must_use]
    pub fn matching_indices(&self, query: &Query) -> Vec<u32> {
        if query.is_empty() {
            return (0..self.row_count)
                .map(|i| u32::try_from(i).unwrap_or(u32::MAX))
                .collect();
        }
        let matcher = CellMatcher::new(&query.text);
        let mut indices = Vec::new();
        for r in 0..self.row_count {
            let matched = match &query.scope {
                Scope::All => self.row(r).any(|cell| matcher.matches(cell)),
                Scope::Column(c) => *c < self.cols && matcher.matches(self.cell(r, *c)),
            };
            if matched {
                indices.push(u32::try_from(r).unwrap_or(u32::MAX));
            }
        }
        indices
    }
}

/// Borrow-based serialization mirror of [`Table`]. Field names, types-as-
/// serialized, and ORDER match `Table` exactly, so `to_vec_named` produces a
/// byte-identical named-map frame (`&str` serializes like `String`).
#[derive(Serialize)]
struct TableView<'a> {
    delimiter: &'a str,
    header: Vec<&'a str>,
    rows: Vec<Vec<&'a str>>,
    truncated: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire;

    fn sample() -> Table {
        Table {
            delimiter: ",".into(),
            header: vec!["name".into(), "city".into()],
            rows: vec![
                vec!["Alice".into(), "Paris".into()],
                vec!["Bob".into(), "Parma".into()],
                vec!["Carol".into(), "Berlin".into()],
            ],
            truncated: false,
        }
    }

    fn unicode() -> Table {
        Table {
            delimiter: ";".into(),
            header: vec!["place".into(), "note".into()],
            rows: vec![
                vec!["İstanbul".into(), "city".into()],
                vec!["Straße".into(), String::new()],
                vec!["PARIS".into(), "Capital 😀".into()],
            ],
            truncated: true,
        }
    }

    #[test]
    fn round_trips_to_table() {
        for t in [sample(), unicode()] {
            let arena = TableArena::from_table(t.clone());
            assert_eq!(arena.to_table(), t, "arena must hold the exact table");
            assert_eq!(arena.row_count(), t.rows.len());
            assert_eq!(arena.cols(), t.header.len());
            assert_eq!(arena.truncated(), t.truncated);
            assert_eq!(arena.delimiter(), t.delimiter);
        }
    }

    #[test]
    fn cell_accessors_and_out_of_range() {
        let arena = TableArena::from_table(sample());
        assert_eq!(arena.header_cell(0), "name");
        assert_eq!(arena.header_cell(1), "city");
        assert_eq!(arena.cell(0, 0), "Alice");
        assert_eq!(arena.cell(2, 1), "Berlin");
        // Out of range — empty, never a panic.
        assert_eq!(arena.cell(3, 0), "");
        assert_eq!(arena.cell(0, 2), "");
        assert_eq!(arena.header_cell(2), "");
        assert_eq!(arena.row(9).count(), 0);
    }

    #[test]
    fn empty_table_is_safe() {
        let t = Table {
            delimiter: ",".into(),
            header: vec![],
            rows: vec![],
            truncated: false,
        };
        let arena = TableArena::from_table(t.clone());
        assert_eq!(arena.to_table(), t);
        assert_eq!(arena.cell(0, 0), "");
        assert!(arena.matching_indices(&Query::empty()).is_empty());
    }

    #[test]
    fn ragged_rows_normalize_to_header_arity() {
        // The wire Table contract: body normalized to header.len().
        let t = Table {
            delimiter: ",".into(),
            header: vec!["a".into(), "b".into()],
            rows: vec![vec!["only".into()], vec!["x".into(), "y".into(), "z".into()]],
            truncated: false,
        };
        let arena = TableArena::from_table(t);
        assert_eq!(arena.cell(0, 0), "only");
        assert_eq!(arena.cell(0, 1), "", "short row pads");
        assert_eq!(arena.cell(1, 1), "y");
        assert_eq!(arena.cell(1, 2), "", "long row truncates to header arity");
        assert_eq!(arena.to_table().rows, vec![vec!["only", ""], vec!["x", "y"]]);
    }

    #[test]
    fn table_frame_is_byte_identical_to_owned_encode() {
        for t in [sample(), unicode()] {
            let owned_frame = wire::encode_frame(&t).unwrap();
            let arena = TableArena::from_table(t);
            assert_eq!(
                arena.table_frame().unwrap(),
                owned_frame,
                "span-projected frame must match the owned Table frame byte-for-byte"
            );
        }
    }

    #[test]
    fn matching_indices_parity_with_vec_based_filter() {
        // The arena scan and the Vec<Vec<String>>-based scan must agree on
        // EVERY query — the shared CellMatcher is the single home of the
        // match semantics, and this pins that neither path drifts.
        let tables = [sample(), unicode()];
        let queries = [
            Query::empty(),
            Query { text: "par".into(), scope: Scope::All },
            Query { text: "PAR".into(), scope: Scope::All },
            Query { text: "istanbul".into(), scope: Scope::All },
            Query { text: "İstanbul".into(), scope: Scope::All },
            Query { text: "straße".into(), scope: Scope::All },
            Query { text: "strasse".into(), scope: Scope::All },
            Query { text: "a".into(), scope: Scope::Column(0) },
            Query { text: "a".into(), scope: Scope::Column(99) },
            Query { text: "zzz".into(), scope: Scope::All },
            Query { text: "😀".into(), scope: Scope::Column(1) },
        ];
        for t in &tables {
            let arena = TableArena::from_table(t.clone());
            for q in &queries {
                assert_eq!(
                    arena.matching_indices(q),
                    crate::filter::matching_indices_in(&t.rows, q),
                    "arena/vec filter parity for {q:?}"
                );
            }
        }
    }

    #[test]
    fn arena_is_two_heap_blocks() {
        // The point of the type: cell storage collapses to ONE String + ONE
        // offset Vec (plus the small delimiter). If a per-row/per-cell
        // container sneaks back into the struct, this size pin fails.
        assert_eq!(
            core::mem::size_of::<TableArena>(),
            core::mem::size_of::<String>() * 2          // delimiter + bytes
                + core::mem::size_of::<Vec<usize>>()    // offsets
                + core::mem::size_of::<usize>() * 2     // cols + row_count
                + core::mem::size_of::<usize>(),        // truncated (padded)
            "TableArena grew beyond {{delimiter, truncated, cols, row_count, bytes, offsets}}"
        );
    }
}
