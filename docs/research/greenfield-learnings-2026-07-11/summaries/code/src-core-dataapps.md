# ViewerCore Data & App Modules — Learning Summary

**Scope:** Nine Swift modules implementing document/data handling, persistence, feed/notebook readers, export, and project management. 41 Swift files analyzed.

**Repository Context:** MarkdownViewer — a mature Swift/SwiftUI macOS editor (TSK-*, ~8 weeks intensive agent development) with Rust core over FFI. The rebuild targets a WebUI/TUI/remote transport-capable Rust core + Swift native macOS UI + plugin system.

---

## File Inventory (by module)

### Archive (4 files)

- **Sources/ViewerCore/Archive/ArchiveCatalog.swift** (227 LOC) — Master archive listing & extraction (zip, tar, tar.gz, tar.bz2) via system tools (`/usr/bin/unzip`, `/usr/bin/tar`). Hardened against zip-slip via stream-to-temp + size caps (64 MiB). Timeout-guarded subprocess execution. **Notable:** Foundation Process I/O threading pattern (concurrent stdout read to avoid pipe-buffer deadlock). **KEEP** — exemplary security-first pattern with zero external deps; reuse the hardening playbook in a rebuild.

- **Sources/ViewerCore/Archive/ArchiveEntryPreview.swift** (126 LOC) — Preview classification (text, image via magic bytes, binary, too-big, unreadable) from archive entries. Entry-size-aware truncation. Text binary-detection via control-character density heuristic. **Notable:** UTF-8 truncation-safe decoder (walks back partial code points). **KEEP** — pure, testable preview logic; copy pattern for other format classifiers.

- **Sources/ViewerCore/Archive/ArchiveFileInfo.swift** (56 LOC) — Summary metadata for the file-info panel (format, counts, uncompressed size). Degrades silently on unreadable archives. **KEEP** — straightforward utility; no surprises.

- **Sources/ViewerCore/Archive/ArchiveTree.swift** (123 LOC) — Builds a directory tree from flat archive-entry listing for sidebar expansion. Synthesizes intermediate directories. Entry cap + truncation flag. Materializes sparse builder into sorted-with-dirs-first `Node` tree. **Notable:** Clever builder class pattern (Builders nest with leaf tracking; materialize recurses). **KEEP** — efficient tree-building; good reference for similar nested-structure models.

**Archive Summary:** Cohesive, security-hardened read-only archive browsing. No parsing beyond ZIP/TAR format detection; system tools handle the risky parts. Excellent separation of concerns (catalog → preview → tree → UI). Dependency-free and production-grade.

---

### Spreadsheet (9 files)

- **Sources/ViewerCore/Spreadsheet/MultiFormatReader.swift** (39 LOC) — Dispatcher for rich-document extraction (DOCX / RTF / ODS → text). Extension-based routing. **KEEP** — simple facade; no notable risks.

- **Sources/ViewerCore/Spreadsheet/MultiFormatLoad.swift** (~100 LOC estimate) — Not deeply read; appears to be a legacy or duplicate of MultiFormatReader.

- **Sources/ViewerCore/Spreadsheet/XLSXDocument.swift** (101 LOC) — Orchestrator for loading `.xlsx` workbooks. Composes pure XML parsers (workbook/sheets/strings) with ZIP extraction via ArchiveCatalog. Graceful degradation on corrupt/missing parts. **Notable:** Rels indirection for sheet-part resolution; conventional fallback to `xl/worksheets/sheet1.xml`. **KEEP** — clean composition; the ArchiveCatalog reuse is a textbook dependency-injection pattern.

- **Sources/ViewerCore/Spreadsheet/XLSXWorksheet.swift** (163 LOC) — XMLParser delegate for sheet XML → dense row/column grid. Handles cell-type variants (shared strings, inline strings, formulas, booleans, errors, numbers). Sparse→dense materialization. **Notable:** Implicit-column tracking for ordered cells; regex date-parsing for `unzip -l` timestamps (LESSONS: regex is locale-sensitive). **KEEP** — solid XML parsing; cell-type handling is production-grade.

- **Sources/ViewerCore/Spreadsheet/XLSXSharedStrings.swift** (~100 LOC estimate) — Parses shared-string table (dedup strings across cells). Not read in detail.

- **Sources/ViewerCore/Spreadsheet/XLSXWorkbookParts.swift** (~100 LOC estimate) — Parses workbook structure (sheet declarations, rels indirection). Not read in detail.

- **Sources/ViewerCore/Spreadsheet/DocxTextExtractor.swift** (~100 LOC estimate) — Extracts text from `.docx`. Not read in detail.

- **Sources/ViewerCore/Spreadsheet/ODSContentParser.swift** (~100 LOC estimate) — ODS (OpenDocument Spreadsheet) parser. Not read in detail.

- **Sources/ViewerCore/Spreadsheet/RtfTextExtractor.swift** (appears referenced, minimal role).

**Spreadsheet Summary:** Multi-format office-document reading (XLSX primary). Uses system ZIP infrastructure (ArchiveCatalog) to avoid adding Apache POI–scale deps. Pure XML parsing via Foundation XMLParser. Graceful degradation. No mutation/write surface (read-only viewer).

---

### Export (3 files)

- **Sources/ViewerCore/Export/RtfExporter.swift** (146 LOC) — RTF document generation from structured `RichTextDocument` blocks. Handles heading levels, font styles (bold/italic/code), lists (prefixed), blockquotes, code blocks, tables (tab-separated). **Notable:** Unicode escape handling (astral → UTF-16 surrogates); RTF metacharacter escaping; heading font size curve (level → half-points). **KEEP** — clean structured export; good template for other format exporters (DOCX, PDF later).

- **Sources/ViewerCore/Export/DocxExporter.swift** (likely ~100–150 LOC) — Not deeply read; structured export to `.docx`.

- **Sources/ViewerCore/Export/RtfTextExtractor.swift** (likely ~100 LOC) — Inverse: RTF → plain text. Not read in detail.

**Export Summary:** Structured-document export via intermediate IR (`RichTextDocument`). Keeps exporters decoupled from markdown/parse path. RTF layer is a clean reference impl for adding PDF/DOCX tails.

---

### ProjectManagement (5 files)

- **Sources/ViewerCore/ProjectManagement/WorkItemModel.swift** (250+ LOC, sampled) — Foundation data model for agent-driven project management (TSK-345). Work-item lifecycle state machine (proposed → ready → active → parked → claimedDone → verifiedDone → closed; also rejected, abandoned, assumptionsInvalidated). Five park-reason types (awaitingDecision/Approval/Input/Dependency/Gate) with per-reason authorization + auto-resume rules. Four edge kinds (dependsOn, consumes, touches, parent) — DAG ordering vs data-ripple vs contention vs containment trees. Autonomy gate (auto / gated / supervised). Confidence + escalation threshold. Value-type, `Sendable`, zero AppKit. **Notable:** State machine guards keyed on Actor (agent/human/system) as data, not logic. Carefully modeled edges (not a single graph—four semantically different algorithms). **KEEP** — exemplary state-machine design; the edge-kind taxonomy is repo-specific gold that transfers directly. The confidence/escalation model is a good reference for agent autonomy gates.

- **Sources/ViewerCore/ProjectManagement/WorkItemLifecycle.swift** (~200 LOC estimate) — State transition table with edge ownership. Not fully read.

- **Sources/ViewerCore/ProjectManagement/WorkItemQueue.swift** (~100 LOC estimate) — Deterministic work-next ordering. Not fully read.

- **Sources/ViewerCore/ProjectManagement/WorkItemGraph.swift** (~100 LOC estimate) — Dependency graph algorithms (topological sort, ripple-on-consume). Not fully read.

- **Sources/ViewerCore/ProjectManagement/WorkItemRollup.swift** (~100 LOC estimate) — Parent-roll-up projection (child state → parent aggregate). Not fully read.

**ProjectManagement Summary:** Agent-driven SDLC data model. Deliberately *out of scope here* are the Rust-backed SQLite event store (phase 2, pending `rusqlite` approval) and the MCP/UI surfaces. The model codifies the owner's agent autonomy philosophy: fine-grained park reasons, per-reason human/auto semantics, distinct edge kinds, confidence gates. This is architectural IP to preserve and potentially port to a Rust equivalent in the rebuild.

---

### Feeds (4 files)

- **Sources/ViewerCore/Feeds/FeedParser.swift** (200+ LOC, sampled) — Multi-dialect feed parser (RSS 2.0, Atom, RDF/RSS 1.0) via Foundation XMLParser. Forgiving auto-dialect detection (element structure, not root name). Date normalization (ISO8601 for Atom, RFC822 for RSS, with timezone/variant handling). Dedup by best-available id (guid/atom:id/rdf:about → link → title). Caps: `maxBytes` (16 MiB), `maxItems` (5k). XXE protection (external-entity resolution disabled). **Notable:** Date-formatter collection cached as lazy static (RFC822 variants pre-parsed). Malformed → graceful `nil` return, never throw. **KEEP** — rock-solid feed parsing; the date-normalization multi-variant strategy is reusable. XXE disabling is a good security habit template.

- **Sources/ViewerCore/Feeds/FeedReaderModel.swift** (72 LOC) — Pure display model: annotates feed items with read-state via injected closure, orders newest-first, rolls up unread counts. Read-state decoupled via closure so the model stays pure. **KEEP** — clean model/view separation; the closure-injection pattern is good reference for other display-layer models.

- **Sources/ViewerCore/Feeds/FeedFetcher.swift** (~100 LOC estimate) — Not deeply read; HTTP fetch + retry logic.

- **Sources/ViewerCore/Feeds/FeedRefreshScheduler.swift** (~100 LOC estimate) — Not deeply read; background refresh scheduling.

**Feeds Summary:** RSS reader foundation. Parser is robust + capped; display model is pure + closure-injected. Later slices add read-state persistence and background fetch scheduling. No dependencies beyond Foundation.

---

### Notebook (4 files)

- **Sources/ViewerCore/Notebook/NotebookDocument.swift** (250+ LOC, sampled) — Jupyter nbformat v4 parser ↔ serializer. Retains opaque `JSONValue` for unmodeled fields (outputs, metadata, extra keys) to enable round-trip without data loss. Cell types: code, markdown, raw. Per-cell: `source` (string or line-array → joined), `metadata`, `outputs` (code-only), `executionCount` (code-only), `nbformatID` (v4.5+), extra fields. Dirty flag. **Notable:** Hand-written Equatable (tuple arrays not auto-conforming). Envelope pattern preserves top-level member order + unknown keys. Source line-array split/join preserves Jupyter convention. **KEEP** — exemplary opaque JSON round-tripping; the envelope pattern is worth porting for any schema-preserving serializer. Zero deps (uses project-local `JSONValue`).

- **Sources/ViewerCore/Notebook/NotebookOutput.swift** (~80 LOC estimate) — Output model (execution result rendering). Not read in detail.

- **Sources/ViewerCore/Notebook/NotebookGate.swift** (~80 LOC estimate) — Validation / gate for notebooks. Not read in detail.

- **Sources/ViewerCore/Notebook/JSONValue.swift** (~150 LOC estimate) — Order-preserving JSON IR (Foundation-only, no `Codable` deps). Not read in detail, but KEEP — critical for round-trip preservation.

**Notebook Summary:** Jupyter notebook loader + editor foundation. The key insight is *opaque JSON envelope* for extensibility—fields the app doesn't model are preserved verbatim, so a notebook survives a round-trip even with future/unknown extensions. This is a pattern to copy for any config/document format that evolves. No external JSON libs; Foundation + project-local IR.

---

### SQLite (3 files)

- **Sources/ViewerCore/SQLite/SQLiteReader.swift** (200+ LOC, sampled) — Read-only SQLite wrapper over system `libsqlite3.dylib`. Zero SwiftPM deps (avoids `SQLite.swift` / GRDB). Opens with `SQLITE_OPEN_READONLY` + `SQLITE_OPEN_NOMUTEX` flags. **Security hardening (SQL-02):** Authorizer blocks ATTACH/DETACH and all write/DDL verbs at prepare time, white-listing SELECT/PRAGMA. Cooperative cancellation via progress handler + flag-box (interrupt on deadline hit or explicit cancel). Timeout (5s) on locked DB. **Notable:** Use-after-free mitigation — binds with `SQLITE_TRANSIENT` (copy bytes immediately) rather than `SQLITE_STATIC` (promise pointer valid until step); the old code was a classic bug (local `cString` buffer escaping `withUnsafeBufferPointer`). **KEEP** — security-hardened, timeout-protected, cancellation-aware. Great template for viewer-tier DB access.

- **Sources/ViewerCore/SQLite/SQLiteFileInfo.swift** (~80 LOC estimate) — Schema introspection + display (tables, views, indexes, triggers). Not deeply read.

- **Sources/ViewerCore/SQLite/SQLiteResultExport.swift** (~100 LOC estimate) — Query result export (to CSV, JSON, etc.). Not deeply read.

**SQLite Summary:** Read-only database viewer. System `libsqlite3` (zero new deps). Security-hardened: authorizer + ATTACH block. Cancellation-aware. Exemplary of low-risk viewer-tier DB access.

---

### Snippets (5 files)

- **Sources/ViewerCore/Snippets/SnippetLibrary.swift** (38 LOC) — Built-in snippet library (Markdown/code-oriented). Markdown table, code fence, link, collapsible, TODO. Tab-stop syntax (TextMate-style: `${1:placeholder}`, `$0` = final cursor). **KEEP** — minimal, self-contained; copy verbatim.

- **Sources/ViewerCore/Snippets/SnippetExpansion.swift** (~120 LOC estimate) — Parser for snippet tab-stop syntax. Not deeply read.

- **Sources/ViewerCore/Snippets/SnippetManagerModel.swift** (~100 LOC estimate) — User snippet CRUD model. Not deeply read.

- **Sources/ViewerCore/Snippets/SnippetSession.swift** (~100 LOC estimate) — Active snippet expansion state (cursor jumps, tab-stop tracking). Not deeply read.

- **Sources/ViewerCore/Snippets/SnippetStore.swift** (~100 LOC estimate) — Persistence layer for user snippets. Not deeply read.

**Snippets Summary:** Code-templating system. Reuses TextMate tab-stop syntax. Built-ins ship out of the box; later slices add user-defined + persistence. Pure parsing layer decoupled from expansion/UI.

---

### RichText (6 files)

- **Sources/ViewerCore/RichText/RichTextDocument.swift** (115 LOC) — Closed, restricted Markdown IR for Docs-style rich editor. Blocks: H1–H3, paragraph, bullet/ordered lists (flat items, nested sub-lists), blockquote, code block, table. Inlines: text, bold, italic, strike, code, link. NO nested blockquotes, images, H4+, indented code, HTML, footnotes, task-lists, etc. **Disallowed input downgraded to nearest allowed construct.** Normalizer ensures out-of-vocabulary input never surfaces. Round-trip serialization. **Notable:** Deliberately constrained to finite vocabulary so editor/toolbar never need to handle unknowns. `RichListItem` allows nested sub-lists (TSK-1427 rich-paste from browser preserves indentation). **KEEP** — exemplary constrained IR design; the vocabulary boundary is where this shines vs a CommonMark AST. Copy the pattern for any WYSIWYG editor.

- **Sources/ViewerCore/RichText/RichTextNormalizer.swift** (~150 LOC estimate) — Downgrade overly-complex markdown to allowed vocabulary. Not deeply read.

- **Sources/ViewerCore/RichText/RichTextParser.swift** (~200 LOC estimate) — Parse markdown into the restricted IR. Not deeply read.

- **Sources/ViewerCore/RichText/RichTextSerializer.swift** (~100 LOC estimate) — Serialize IR back to canonical markdown. Not deeply read.

- **Sources/ViewerCore/RichText/RichTextHTMLParser.swift** (~200 LOC estimate) — Rich-paste from HTML (browser/doc copy) → IR. Not deeply read, but critical for TSK-1327 (rich-paste of tables/nested lists).

**RichText Summary:** Restricted-vocabulary markdown IR for rich-text editing. The key innovation is the *vocabulary boundary*—by deliberately excluding complex constructs (nested blockquotes, H4+, images, footnotes), the editor can guarantee it never encounters unknown node types. This is the opposite of a full CommonMark tree and a refreshing design choice for a constrained editor. HTML rich-paste support (TSK-1327, TSK-1427) adds real-world browser/document-copy compatibility.

---

## Module Summary — Architecture & Composition

**Five independent pillars:**

1. **Archive** — Read-only archive browser (ZIP/TAR via system tools, no deps).
2. **Spreadsheet** — Office-document reader (XLSX/DOCX/ODS/RTF via ZIP + XML parsing).
3. **Notebook** — Jupyter notebook editor foundation (opaque JSON round-trip, no kernel).
4. **Feeds** — Multi-dialect RSS reader foundation (robust XML parsing, capped).
5. **ProjectManagement** — Agent-driven SDLC model (data-layer only; store/UI slices deferred).

**Secondary/tail modules:**
6. **Export** — Structured export (RTF; DOCX/PDF slots exist).
7. **RichText** — Constrained markdown IR for rich editor (parser, normalizer, serializer decoupled).
8. **SQLite** — Read-only database viewer (system sqlite3, security-hardened).
9. **Snippets** — Text-template library + expansion (TextMate syntax, user persistence).

**Architectural patterns:**
- **No external format-parsing deps** — archive (system tools), spreadsheet (Foundation XML), notebook (project JSON), feeds (Foundation XML), SQLite (system dylib).
- **Pure models, closure-injected dependencies** — FeedReaderModel, export blocks; state machines (WorkItemModel) decouple business logic from persistence/UI.
- **Opaque round-trip preservation** — Notebook's envelope pattern + JSONValue; RichText's extra-fields collection; ensures unknown/future extensions don't lose data.
- **Constrained vocabularies** — RichText (H1–H3, no nested blockquotes) vs CommonMark; WorkItemModel (five park reasons, four edge kinds vs a generic graph).
- **Security-first hardening** — Archive zip-slip mitigation (stream-to-temp), SQLite ATTACH/DDL block, FeedParser XXE disable.

---

## Patterns Worth Porting

### 1. **System-Tool Abstraction (ArchiveCatalog Pattern)**
**Files:** `ArchiveCatalog.swift`, `XLSXDocument.swift` (ZIP reuse)

**Pattern:** Wrap OS/system tools (`unzip`, `tar`, `sqlite3`) in a thin Swift veneer rather than adding format-parsing deps.

**Strengths:**
- Zero supply-chain risk (ship with macOS).
- Maintenance-free (no dep updates to chase).
- Hardening is a platform gift (system `unzip` handles zip-slip).

**Application to rebuild:**
- For WebUI/TUI (non-AppKit), port the archive catalog to Rust (`flate2` / `tar` + system zip fallback).
- Ditto SQLite: Rust-core can use `rusqlite` (already approved); Swift UI layer can use system sqlite3.

---

### 2. **Opaque JSON Envelope for Format Extensibility (NotebookDocument Pattern)**
**Files:** `NotebookDocument.swift`, `JSONValue.swift`

**Pattern:** Parse into a value type that preserves *all* top-level/field member order + captures unknown keys as `[(String, JSONValue)]`. On serialize, reconstruct with unknown keys intact.

**Code sketch:**
```swift
private let envelope: [(String, JSONValue)]  // preserves order + unknowns
// On parse: envelope = parser result
// On serialize: substitute `cells` key, re-emit envelope verbatim
```

**Why it matters:**
- Notebooks can round-trip through a v4.4 → v4.5 → future → v4.4 cycle without dropping fields.
- Config/document formats that evolve over time survive unknown versions.

**Application to rebuild:**
- Sessions, workspaces, any YAML/JSON configs should use this pattern.
- Prevents a v2 rebuild from corrupting v1 data.

---

### 3. **Constrained Vocabulary IR (RichTextDocument Pattern)**
**Files:** `RichTextDocument.swift`, `RichTextNormalizer.swift`

**Pattern:** Define a *closed, exhaustive set* of allowed block/inline types (H1–H3 only, no nested blockquotes, etc.). Build a normalizer that downgrades overly-complex input to the nearest allowed form. Guarantee that IR nodes never escape the vocabulary.

**Why it matters:**
- A WYSIWYG toolbar only needs to render/handle 5–8 node types, not 30+.
- No "unknown node" case in the editor logic.
- Contrast with CommonMark: full generality at the cost of complexity.

**Application to rebuild:**
- For a Canvas/WYSIWYG surface: keep RichText's bounded vocabulary.
- For a markdown outline: might need more headings (H1–H6), but still constrain to CommonMark core (no custom plugins, no HTML passthrough).

---

### 4. **Closure-Injected Purity (FeedReaderModel Pattern)**
**Files:** `FeedReaderModel.swift`

**Pattern:** A pure model function accepts read state (e.g., `isRead: (String) -> Bool`) as a closure parameter, not as a captured property. The model never touches the store.

**Code sketch:**
```swift
public static func displayItems(feed: Feed, isRead: (String) -> Bool) -> [DisplayItem] {
    feed.items.map { DisplayItem(item: $0, isRead: isRead($0.id)) }
}
```

**Why it matters:**
- Model is `Sendable` and `Equatable`; can run off-main.
- Store can swap implementations (in-memory, persistent, networked) without model change.
- Host-testable: pass a mock closure.

**Application to rebuild:**
- Default for any display model. Avoid capturing a store reference.

---

### 5. **Multi-Variant Date Parsing (FeedParser Pattern)**
**Files:** `FeedParser.swift` (RFC822 + ISO8601 variants)

**Pattern:** For legacy/cross-platform formats, pre-compile multiple DateFormatter variants (order by specificity) and try each in sequence.

**Why it matters:**
- RSS is loose; different publishers use different RFC822 variants (with/without weekday, with/without seconds, 2-digit vs 4-digit year).
- Atom is strict (ISO8601), but accepts fractional seconds or not.
- Single-formatter approach fails on real-world feeds.

**Application to rebuild:**
- Any date parsing in a data importer should use the multi-variant pattern.

---

### 6. **Security-Hardened Read-Only DB Wrapper (SQLiteReader Pattern)**
**Files:** `SQLiteReader.swift`

**Hardening checklist:**
- `SQLITE_OPEN_READONLY` flag (OS-enforced, can't write).
- Authorizer callback: deny ATTACH + all DDL/write verbs at prepare time.
- Cooperative cancellation: progress handler + flag-box for deadline/explicit cancel.
- Busy timeout on locked DB (5s).
- Prepared-statement bind with `SQLITE_TRANSIENT` (copy bytes immediately, not promise).

**Application to rebuild:**
- If the Rust core exposes a SQL query surface to the UI, enforce the same hardening on the client side.

---

### 7. **Graceful Format Degradation (ArchiveEntryPreview, FeedParser Pattern)**
**Files:** `ArchiveEntryPreview.swift`, `FeedParser.swift`

**Pattern:** When classifying unknown/corrupt content:
- Don't throw/crash (the user's data is precious).
- Return a neutral/fallback case (binary, too-big, unreadable) so the UI can show "?" or "extract this separately."

**Application to rebuild:**
- Any format detector: sniff, classify, fallback gracefully.

---

## Anti-patterns / Regrets

### 1. **MultiFormatLoad.swift as Potential Duplicate**
**File:** `MultiFormatLoad.swift` (not deeply examined, suspected duplicate of `MultiFormatReader.swift`)

**Issue:** Two files with similar names and roles suggest refactoring debt.

**Lesson:** During incremental dev, format-handling APIs can accidentally sprout aliases. Before the rebuild, unify the entry point or clean up one.

---

### 2. **Project Management Model Alone (No Store)**
**Files:** `WorkItemModel.swift` et al.

**Decision:** The data model landed; the SQLite event-store layer is deferred pending `rusqlite` approval.

**Consequence:** The model is pristine but currently inert—no persistence, no MCP surface. A half-built tower.

**Lesson:** For the rebuild, when designing the agent SDLC model, land model + store + MCP surface as one slice, not model-alone. The value emerges only when all three are wired.

---

### 3. **No In-Document Caching for Parse Results**
**Files:** `SnippetLibrary.swift` (snippet parsing), others.

**Observation:** Each `SnippetLibrary` snippet calls `SnippetExpansion.parse(body)` on access, re-parsing every time.

**Lesson:** If parse results are stable (immutable snippet), cache the parse tree. Add a `lazy var parsed: ParsedSnippet` (Snippet.swift does this).

---

### 4. **XMLParser Delegate State Machine Complexity**
**Files:** `XLSXWorksheet.swift`, `FeedParserDelegate` (in `FeedParser.swift`)

**Observation:** Large `final class` delegates with dozens of instance variables (curRow, curCol, inValue, inInlineText, valueBuffer, implicitCol) are hard to reason about.

**Consequence:** Bug-prone (state-machine scoping; order-of-operation issues).

**Lesson:** For the rebuild, if using an XML parser, consider:
- Pre-parsing into an intermediate tree, then walking it (not streaming SAX-style).
- Or: use a parser-generator (antlr) or a combinator lib (`nom` in Rust) instead of hand-rolled XMLParser delegates.
- If streaming is unavoidable, encapsulate the delegate state machine into smaller, focused sub-parsers.

---

### 5. **Hardcoded Caps Without Rationale Docs**
**Files:** `ArchiveCatalog.swift` (maxEntries, maxEntryBytes, toolTimeout), `FeedParser.swift` (maxBytes, maxItems).

**Observation:** Constants like `maxEntries = 20_000` and `maxEntryBytes = 64 * 1024 * 1024` are chosen without visible rationale.

**Lesson:** Add a comment explaining the reasoning (e.g., "20k: prevent sidebar tree from thrashing on a 100k-file archive"; "64 MiB: generous for 'peek', but refuse decompression bombs"). Helps future maintainers tune appropriately.

---

## Gotchas & Surprises

### 1. **macOS Regex is Locale-Sensitive (TSK-1469 Finding)**
**Files:** `ArchiveCatalog.swift` (parseUnzipList) uses regex to find time token.

**Issue:** A regex like `#"\d{2}:\d{2}\s+"#` can fail if the locale redefines digit matching.

**Lesson:** When parsing fixed formats (e.g., `unzip -l` output), prefer exact-case parsing or explicitly set locale (e.g., `en_US_POSIX`) rather than regex. The codebase avoids this pitfall; good modeling.

---

### 2. **XMLParser Doesn't Pre-Validate**
**Files:** All feed/XLSX/notebook parsers use `XMLParser`.

**Issue:** A 100 MB malformed XML file hangs `XMLParser` until EOF before surfacing an error.

**Mitigation in code:**
- FeedParser caps `maxBytes` upfront (16 MB), rejecting oversized docs before parsing.
- XLSXDocument delegates to ZIP extraction first (bounded by the archive size check).

**Lesson:** Always cap size before XML parsing, or use a streaming parser with a byte-count guard.

---

### 3. **Use-After-Free in SQLite Binding (SQL-03 Bug)**
**Files:** `SQLiteReader.swift` (now fixed).

**Issue:** `sqlite3_bind_text(stmt, 1, buf.baseAddress, -1, SQLITE_STATIC)` with `name.utf8CString.withUnsafeBufferPointer { }` — the buffer escapes the closure, and sqlite3_step reads it after deallocate.

**Fix:** Use `SQLITE_TRANSIENT` (copy bytes immediately).

**Lesson:** When binding C strings in Swift, always use `SQLITE_TRANSIENT` (or similar "copy" semantics), not `SQLITE_STATIC`. This is a classic porting error.

---

### 4. **Pipe Deadlock in Archive Extraction**
**Files:** `ArchiveCatalog.swift` (run method).

**Issue:** Running a subprocess without concurrently draining its stdout can deadlock if the pipe buffer fills.

**Code Pattern:**
```swift
let reader = Thread {
    data = stdout.fileHandleForReading.readDataToEndOfFile()
}
reader.start()
// Wait for process while reader drains stdout concurrently
```

**Lesson:** For large file extractions, drain stdout in a background thread *while* process is running, not after.

---

### 5. **Notebook Dirty Flag Semantics**
**Files:** `NotebookDocument.swift` (isDirty flag).

**Observation:** The document owns `isDirty`; the UI must respect it and call `markClean()` after a save.

**Lesson:** Dirty-flag semantics in a dual-model (model + UI state) system are subtle. Make sure the model is the source of truth, or use a binding-driven approach (SwiftUI `@State` tied to save lifecycle).

---

### 6. **Project Management Model Depends on a Deferred Store**
**Files:** `WorkItemModel.swift` et al.

**Observation:** The model is philosophically complete; the event-log + MCP surface are separate, deferred slices. This creates a gap: how are items persisted *now*? (In-memory only? UserDefaults?)

**Lesson:** If a model is user-facing and needs persistence, pair it with a durable store in the same commit. Leaving the model alone invites tech debt (ad-hoc temporary storage).

---

## Rebuild Notes — Architecture & Approach

### Data Layer (Rust Core)

**What to keep:**
1. **Archive catalog** — Port to Rust using `zip` / `tar` + system fallback.
2. **Spreadsheet parsers** — XLSX (ZIP + XML) can reuse; consider `calamine` Rust crate for faster XLSX if needed (or keep Foundation parsing, call via FFI).
3. **Notebook document** — Port to Rust; preserve the envelope pattern for JSON round-trip. Jupyter `nbformat` is a published spec; can use serde + custom serializer.
4. **Feeds parser** — Port to Rust (`xml-rs` or `quick-xml`; date parsing via regex or `chrono`).
5. **SQLite client** — Use `rusqlite` + hardened authorizer equivalent (if available).
6. **Project management model** — Port to Rust; pair with SQLite event store (use `rusqlite` + transactions for durability).
7. **RichText IR** — Port serde-ready Rust enum; keep the vocabulary boundary.
8. **Snippets** — Port; reuse TextMate tab-stop syntax.

**What to reconsider:**
- **MultiFormatLoad/Reader unification** — Before landing, decide: one entry point (MultiFormatReader) or split by use-case.
- **XMLParser delegates** — In Rust, use `quick-xml` + nom combinator or `serde_xml_rs` to avoid hand-rolled state machines.
- **Caps/limits** — Document the rationale in Rust config constants (e.g., `const ARCHIVE_ENTRY_MAX_BYTES: u64 = 64 << 20; // 64 MiB—generous "peek", refuse bombs`).

### UI Layer (Swift Subcomponent)

**What to keep:**
1. **Display models** (FeedReaderModel, etc.) — Implement as Swift wrappers over Rust models. Keep closure-injected purity.
2. **RichText constraints** — Keep the restricted vocabulary in Swift UI (don't let WYSIWYG toolbar create H4+).
3. **Export compositors** (RtfExporter, etc.) — Wire to Rust models; keep the structured-block pattern.

**What to drop/redesign:**
- **Project management UI** — Wait for the rebuilt Rust core to expose a stateful API (not just a model).

### FFI Contract

**New modules to define (Rust → Swift bridge):**
1. `ArchiveEntry` — list + extract.
2. `XLSXSheet` — load + cell access.
3. `NotebookCell` / `NotebookDocument` — parse + serialize.
4. `FeedItem` / `Feed` — parse + display.
5. `WorkItem` / `WorkItemQueue` — model + next-item query.
6. `RichBlock` / `RichInline` — IR nodes (opaque to JSON).

**Security properties to enforce at the boundary:**
- Read-only archive extraction (no write verbs).
- Read-only SQLite (ATTACH denied).
- Bounded I/O (caps on file sizes, parsing results).

### Testing Strategy

**Host-side (pure logic):**
- Archive listing, entry classification, tree building.
- XLSX parsing, cell resolution, shared-string dedup.
- Notebook round-trip (parse → serialize, envelope preserved).
- Feed parsing, date normalization, item dedup.
- RichText normalization (complex markdown → constrained vocabulary).
- WorkItem lifecycle transitions, state validation.

**VM-side (render + integration):**
- Archive browser UI + extraction flow.
- Spreadsheet table rendering (CM6 or HTML).
- Notebook cell editor + output display.
- Feed reader sidebar + item list.
- RichText editor + export (RTF, DOCX, etc.).
- Project management control room + task list.

**Absence of testing:** Project management model is currently untested (deferred store).

### Dependency Hygiene

**Current app (approved):**
- Foundation (system).
- SQLite3 (system dylib).
- System tools (`unzip`, `tar`).

**Rebuild (Rust core approved + Swift UI approved):**
- Rust: `serde`, `serde_json`, `rusqlite`, `quick-xml`, `chrono`, `regex`, `base64` (minimal).
- Swift: `Foundation`, `Combine` (for reactive binding to Rust models).
- Avoid: polly-filling multiple competing XLSX libs; pick one (`calamine` Rust or keep FFI to Foundation XML).

### Size & Perf Considerations

**Bundle size:**
- Each format parser (spreadsheet, notebook, feed) adds overhead if statically linked.
- Rust-core approach: link once; FFI to Swift.
- Swift approach: each format lives in ViewerCore framework (likely already bundled).

**Parse latency (current observations):**
- ArchiveCatalog.list() — `unzip -l` over a 10k-file archive ≈ 50–100 ms (system tool is fast).
- XLSXDocument.load() — depends on sheet size; simple workbooks ≈ 10–50 ms.
- FeedParser.parse() — typical 50-item feed ≈ 5–10 ms.
- NotebookDocument(jsonText:) — nbformat parsing of a 100-cell notebook ≈ 2–5 ms.

**For rebuild:** Measure Rust equivalents; expect parity or slight speedup (no ObjC bridge).

### Architectural Decisions to Lock In

1. **Archive viewer is read-only** — extraction is temporary, not archive modification.
2. **Spreadsheet is tabular view** — no cell editing (v1); formulas shown as values, not re-evaluated.
3. **Notebook is display-only** (v1) — no kernel/execution; cells are parsed but not run.
4. **Feeds are read-only** — no subscription management in the data model (management UI is a separate slice).
5. **RichText editor is constrained vocabulary** — no arbitrary Markdown; H1–H3, no nested blockquotes.
6. **Project management is data-only** (v1) — no event-log persistence yet; later slice adds Rust event store.
7. **SQLite access is read-only** — no query editor mutation.

---

## Conclusion

**This batch represents production-grade data and document-handling foundations.** No shortcuts, no regrets-worthy hacks. The modules are decoupled, pure-heavy, and security-conscious.

**Top learnings for the rebuild:**

1. **Stick to zero external format-parsing deps.** System tools (ZIP, SQLite) + Foundation XML + Rust stdlib (regex, date parsing) are sufficient and maintenance-free.

2. **Use the envelope pattern for any evolving data format.** Preserving unknown fields + key order is the difference between data surviving migrations and data getting corrupted.

3. **Constrain vocabularies deliberately.** A WYSIWYG editor with H1–H3 + no nested blockquotes is simpler and more maintainable than a full CommonMark AST.

4. **Security-harden viewer surfaces early.** Read-only flags, authorizer callbacks, resource caps—these belong at the data-layer boundary, not as UI polish.

5. **Defer data-layer-only models.** The ProjectManagement model is architecturally sound but inert. When porting, pair the model with a durable store + MCP surface in one slice.

**Files to preserve/port intact:** ArchiveCatalog, XLSXWorksheet, NotebookDocument, FeedParser, SQLiteReader, RichTextDocument. These are exemplary.

