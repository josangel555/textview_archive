# Multi-sheet spreadsheet (xlsx/ods) UI — design (TSK-1141, epic TSK-673)

**Status:** design (autonomous spike+design, 2026-06-30). Model/parser done; this is the
view + tab-data design so the build is clean + low-blast. Implement in the slices below.

## Problem
`.xlsx` files are parsed into a full `XLSXWorkbook` (all sheets — `XLSXDocument.load` →
`XLSXWorkbook{ sheets: [XLSXSheet{ name, rows }] }`, done + tested), but the **viewer only
ever shows sheet 0**: the load path flattens the workbook to a single CSV **String** that
becomes `file.contents`, which `CSVTableView(text:)` parses (`ContentView.swift:777`,
`SplitPaneView.swift:200`). The other sheets are discarded at load. No sheet navigation.

## Hard constraint (why a naive change is dangerous)
`file.contents: String` is **load-bearing** across the app: save, dirty-tracking, find/search,
the editor path, session snapshots. Replacing it with a workbook object for xlsx tabs would
ripple through all of those — a high-blast change that risks breaking xlsx save/search. So the
design must add multi-sheet **without** changing the `file.contents`-is-a-String contract.

## Options
- **(A) Parallel workbook field on the tab (RECOMMENDED — low-blast, additive).** Keep
  `file.contents` = the **active sheet's** CSV text (so save/search/dirty/editor are unchanged
  and always see a valid CSV). Add an optional `xlsxWorkbook: XLSXWorkbook?` + `activeSheet: Int`
  to the tab/file model, populated at xlsx-load. A sheet-switch re-derives `file.contents` from
  `sheets[activeSheet]`. Sheet-tabs render only when `xlsxWorkbook != nil` (CSV tabs unaffected).
- **(B) First-class spreadsheet-tab type.** A `SpreadsheetTab` owning the workbook + active sheet,
  with the table viewer reading it directly. Cleaner long-term but high-blast (a new tab type
  through the whole tab system). Defer unless (A) proves insufficient.

## Slice breakdown (each host-tested; the render tail T4-validated on the VM)
1. **Model (host).** Add `xlsxWorkbook: XLSXWorkbook?` + `activeSheet: Int = 0` to the tab/file
   model; populate at xlsx-load (the String stays = sheet-0 CSV). Host test: after loading a
   2-sheet xlsx, the tab holds the workbook with both sheet names; `file.contents` == sheet-0 CSV.
   Additive — zero change to CSV tabs or the String contract.
2. **Sheet-switch (host).** A `selectSheet(_ i:)` that sets `activeSheet` + re-derives
   `file.contents` = `XLSXSheet → CSV` for `sheets[i]`. Host test: select sheet 1 → `file.contents`
   == sheet-1 CSV; the grid (which parses `file.contents`) then shows sheet 1. Pure model — no view.
3. **Sheet-tabs view (render-VM).** A horizontal sheet-tab strip (sheet names, active highlighted),
   shown above `CSVTableView` only when `xlsxWorkbook != nil`. Tab click → `selectSheet`. T4-validate:
   open a multi-sheet xlsx → the tabs render with the right names + count (structural, not AX).
4. **Recalc wiring (host, if needed).** If sheets carry `=formulas`, route them through the existing
   `FormulaEngine` per active sheet (the engine + functions are done — TSK-673/1141 formula slices).

## Save / search compat (the payoff of option A)
- **Save:** `file.contents` is always a valid CSV (the active sheet) → existing CSV-save path works
  unchanged. (True xlsx round-trip write is a separate, larger concern — explicitly out of scope here;
  note it as a follow-on so editing an xlsx + save doesn't silently lose other sheets — surface a
  "saves active sheet as CSV" affordance or block xlsx-save until round-trip lands.)
- **Search:** searches the active sheet (the current behavior, unchanged). Search-all-sheets is a
  follow-on.

## Validation
Slices 1–2 + 4 are host-tested (model: workbook-hold, sheet-switch re-derive, recalc). Slice 3 is
T4-structural (the tabs render + count) on the VM — no T5-pixel, no AX needed (the tab strip is a
structural element; the click maps to the host-tested `selectSheet`).

## Why design-first
The model/parser is done; the risk is entirely the file-representation. Option A confines the change
to an additive parallel field + a re-derive, keeping the load-bearing `String` contract intact — so
the build is a clean 4-slice sequence, not a risky rewrite. The one genuinely-deferred concern is
true xlsx **write** round-trip (call it out at slice 1 so save semantics are explicit).
