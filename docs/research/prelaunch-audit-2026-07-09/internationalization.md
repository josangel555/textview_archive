# Pre-launch Product Review — Internationalization & Character Support

**Dimension:** Internationalization + character support
**Lens:** Hardcoded user-facing strings (localizability), Unicode/emoji/CJK/RTL handling in editor + viewers, locale-aware number/date formatting, UTF-16 vs grapheme handling.
**Reviewer:** automated review agent
**Date:** 2026-07-09
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer` (read-only except this report)

---

## Executive summary

The codebase's **Unicode correctness** — the hard, crash-prone part — is genuinely well-engineered. Encoding detection, encoding round-trip on save, BOM handling, UTF-16 offset math at the LSP/NSTextView boundaries, and index-safe case-insensitive search are all handled deliberately and are documented with the exact traps they avoid (ß/Σ/İ index desync, silent UTF-8 re-encode on save, UTF-16 BOM re-detection). These are the areas where an i18n audit usually finds data-loss bugs, and here they are solid. There are **no P0/P1 findings** — nothing crashes, corrupts, or breaks a core flow on international content.

The gaps are all in **localization and locale-adaptation**, not correctness:

- **The app is English-only with zero localization scaffolding** — no `NSLocalizedString`/`String(localized:)`, no `.lproj`, no `CFBundleLocalizations`; ~794 UI string literals are inlined at their call sites. This is a defensible launch posture for a developer-focused tool, but it makes a future l10n retrofit an XL effort because there is no string table to populate. This is the one finding worth a product decision before launch.
- **Several user-facing formatters are deliberately pinned to `en_US_POSIX`** (file dates, file sizes) for host-test determinism, so a French/German/Japanese user sees US-format dates and `.`-decimal sizes regardless of their system locale.
- **`Sort Lines` uses Unicode-scalar ordering**, not locale collation, so non-English users get surprising order (uppercase before lowercase, accented letters last).
- **The Rust `find` engine (TUI/web tiers) folds ASCII case only** — though the flagship macOS in-document find and project-wide search are Unicode-correct, so end-user impact is limited.
- **No explicit RTL/bidi handling** in native surfaces; WebView-hosted content (Markdown, CodeMirror) inherits WebKit's bidi algorithm, but the native chrome and the bundled HTML hardcode `lang="en"` with no `dir`.

Net: this dimension is in good shape for an English-first v1. The findings below are almost entirely P2/P3 — one localizability architecture note and a cluster of locale-adaptation polish items.

---

## Methodology

**What I examined (static analysis; no UI/window tests run):**

- **Localization surface:** searched all of `Sources/` for `NSLocalizedString` / `LocalizedStringKey` / `String(localized:)` (zero hits); counted UI string literals (`Text("`, `Button("`, `Label("`, `.help("`, `.navigationTitle("` → 794 sites in `ViewerUI`); checked `Info.plist` (`scripts/Info.plist`, `dist/…/Info.plist`) for `CFBundleDevelopmentRegion` / `CFBundleLocalizations`; checked `Package.swift` for `defaultLocalization` and resource localization.
- **Encoding / decode / save path:** read `Sources/ViewerCore/TextFileLoader.swift` (`TextDecoder`), `Sources/ViewerCore/EditorBuffer.swift` (`EditorWriter`), `Sources/ViewerUI/DocumentModel+SaveCopy.swift`. Verified BOM detection, CP1252/Latin-1 fallback, BOM-less UTF-16, save-side encoding round-trip.
- **Grapheme vs UTF-16 vs byte handling:** read `Sources/ViewerCore/LSP/LSPPositionConverter.swift`, `SpellCheckEngine.swift` (LineIndex), `CrossFileSearch.swift`, `FindEngine.swift`; audited `.prefix`/`.suffix`/truncation call sites for grapheme splitting; audited `.lowercased()`/`.uppercased()` (140 sites) for comparison-path Turkish-İ risk.
- **Locale-aware formatting:** grepped `NumberFormatter` / `DateFormatter` / `Locale` / `ByteCountFormatter`; read `DisplayDateFormatter.swift`, `DocumentController.swift`, `Git/UnifiedHistoryViewModel.swift`.
- **Rust engines:** read `rust-core/crates/core/src/find.rs`, `filter.rs`, `hex.rs`; checked `tui`/`web`/`highlight` Cargo manifests for `unicode-width`.
- **RTL/bidi:** grepped `Sources/` + `Resources/` for `rtl`/`bidi`/`direction`/`writingDirection`/`dir=`/`lang=`.

**Depth:** ~380K LOC source; I read the ~15 files that concentrate i18n-relevant logic in full or in the relevant region, plus targeted greps across the tree. I did **not** run the app or any tests (constraint), and did not exhaustively read all 794 string-literal sites (sampled).

---

## Findings

### F1 — No localization infrastructure; ~794 UI strings inlined (localizability retrofit is XL)
- **Severity:** P2
- **Files:** `Sources/ViewerUI/**` (794 literal string sites), `scripts/Info.plist`, `Package.swift`
- **Evidence:**
  - Zero hits for `NSLocalizedString` / `LocalizedStringKey` / `String(localized:` across all of `Sources/`.
  - 794 UI-string literal sites in `ViewerUI` (`Text("…")`, `Button("…")`, `.help("…")`, etc.), e.g. `Sources/ViewerUI/StatusBar.swift:262 Text("No local branches")`, `:408 Text("Modified")`, `:448 Text("Zoom")`.
  - Non-UI user-facing strings inlined too, e.g. `Sources/ViewerCore/DocumentController.swift:174-190` returns `"File not found."`, `"File is not valid UTF-8 or Latin-1 text."` as raw literals.
  - `CFBundleDevelopmentRegion` = `en`; no `CFBundleLocalizations`, no `.lproj` bundles, no `defaultLocalization:` in `Package.swift`.
- **Impact:** App ships English-only with no path to localize short of touching ~800 call sites. This is fine as a v1 product decision, but it should be an explicit decision, not a default — retrofitting NSLocalizedString/String Catalog after the string sites have proliferated further is materially more expensive than adopting a String Catalog now and wrapping strings as they are written.
- **Suggested fix:** Make an explicit launch decision. If English-only is intended, document it and move on. If localization is on the roadmap, adopt a `.xcstrings` String Catalog now and start wrapping user-facing strings (a lint/grep gate can flag new bare `Text("…")` literals). Centralizing the `DocumentController.message(for:)`-style error strings first is the cheap high-value slice.
- **Fix size:** XL (full retrofit) / S (decision + catalog scaffolding + first slice)
- **Fix risk:** safe

### F2 — `Sort Lines` uses Unicode-scalar order, not locale collation
- **Severity:** P3
- **File:** `Sources/ViewerCore/TextTools.swift:79-84` (`sortLines`)
- **Evidence:** `let sorted = splitLines(s).sorted()` — Swift's default `String` `<` is Unicode-scalar lexicographic, documented in-line as *"Unicode scalar order — deterministic across locales."*
- **Impact:** A user-facing "Sort Lines" command orders `Z` before `a` (uppercase scalars precede lowercase) and places accented/non-ASCII letters after all ASCII (`z` < `å`). A Swedish/German/French user sorting a list gets an order that looks wrong for their language (e.g. `ä`/`ö`/`å` collation). Determinism was chosen intentionally, but the tradeoff surfaces to end users.
- **Suggested fix:** Use `.sorted { $0.localizedStandardCompare($1) == .orderedAscending }` (Finder-style, locale + numeric-aware) for the user-facing command, or offer both a "natural/locale" and a "byte/scalar" sort. Keep scalar order only where a stable machine order is actually required.
- **Fix size:** S
- **Fix risk:** careful (changes observable output of an existing command; add a test pinning the new order)

### F3 — User-facing file dates pinned to fixed `en_US_POSIX` format, ignoring locale & 12h/24h preference
- **Severity:** P3
- **File:** `Sources/ViewerCore/DisplayDateFormatter.swift:20-24` (used by `StatusBar.swift`, `Git/FolderStatsView.swift`, `BookmarksSection.swift`, `MetadataPanel.swift`)
- **Evidence:** `f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"`. Doc comment states this is deliberate to avoid `MM/dd` vs `dd.MM` drift.
- **Impact:** Every user-visible Created/Modified timestamp renders `2026-06-03 14:07` regardless of the user's Region settings or 12-hour-clock preference. The chosen format is unambiguous (a defensible pro), but it ignores the OS locale entirely — a US user who set a 12-hour clock still sees 24h; no locale sees their native date order.
- **Suggested fix:** For user-visible file dates, prefer `Date.FormatStyle`/`DateFormatter` with `dateStyle`/`timeStyle` and `.autoupdatingCurrent` locale (as `DateTimeStamp.swift` already does elsewhere), OR keep the fixed format as an opt-in "ISO timestamps" preference. Retain `en_US_POSIX` only for log/diagnostic strings that must be machine-stable.
- **Fix size:** S–M
- **Fix risk:** careful (host tests may assert the literal format; those assertions would need to pin locale, not the app default)

### F4 — File-size numbers pinned to `en_US_POSIX`; decimal separator never localizes
- **Severity:** P3
- **Files:** `Sources/ViewerCore/DocumentController.swift:164-171` (`mbFormatter`); `Sources/ViewerUI/Git/UnifiedHistoryViewModel.swift:249` (hand-rolled "1.2 KB"/"3.4 MB", explicitly to avoid `ByteCountFormatter` locale variance)
- **Evidence:** `mbFormatter.locale = Locale(identifier: "en_US_POSIX")` with a comment: *"so '5.0 MB' doesn't become '5,0 MB' on fr_FR."* The Git byte formatter is hand-rolled to sidestep `ByteCountFormatter`'s locale-awareness.
- **Impact:** A locale that uses `,` as the decimal separator (fr_FR, de_DE, most of continental Europe) still sees `5.0 MB` / `1.2 KB`. Minor, but it's a visible locale mismatch and the pinning was chosen for test determinism, not user benefit.
- **Suggested fix:** Use `ByteCountFormatter` (or `.formatted(.byteCount(style:))`) with the current locale for user-facing sizes; pin `en_US_POSIX` only in tests by injecting the locale. Same for `mbFormatter`.
- **Fix size:** S
- **Fix risk:** careful (tests assert literal `.` output)

### F5 — Rust `find` engine folds ASCII case only (affects TUI/web tiers)
- **Severity:** P3
- **File:** `rust-core/crates/core/src/find.rs:9-14, 40-45` (`find_matches`, `Case::Insensitive`)
- **Evidence:** Module doc: *"Case-insensitive matching folds ASCII only (A..Z ⇆ a..z) … Full Unicode case-folding … is out of scope; the front-ends document 'case-insensitive = ASCII'."*
- **Impact:** In the ratatui TUI's `/` find and the web tier's find box, a case-insensitive search for `café`, `Straße`, Cyrillic, Greek, or Turkish text will not fold non-ASCII case (e.g. `Ω` won't match `ω`). **Mitigant:** the flagship macOS in-document find (`Sources/ViewerCore/FindEngine.swift:193`, NSString `.caseInsensitive`) and project-wide `CrossFileSearch` are full-Unicode, so the primary product is unaffected; and the CSV filter (`rust-core/crates/core/src/filter.rs:117-129`) correctly falls back to Unicode `to_lowercase()` for non-ASCII. So this is a secondary-tier limitation, not a flagship one.
- **Suggested fix:** Accept as documented for the TUI/web tiers, or route those tiers' case-insensitive find through the same Unicode fold the CSV filter already uses (`to_lowercase().contains`) when either side is non-ASCII — at the cost of an allocation and byte-offset re-mapping. Given the byte-offset contract, a fold that changes byte lengths needs care; keep as documented unless a tier needs it.
- **Fix size:** M (if implemented — offset re-mapping) / S (document + close)
- **Fix risk:** careful

### F6 — No explicit RTL/bidi handling in native surfaces; bundled HTML hardcodes `lang="en"`, no `dir`
- **Severity:** P3
- **Files:** native views (`Sources/ViewerUI/**` — no `writingDirection`/`LayoutDirection` set); `Sources/ViewerUI/Resources/codemirror/codemirror.html` (`<html lang="en">`, no `dir` attribute); `Sources/ViewerUI/Resources/canvas/canvas.html`
- **Evidence:** No `rightToLeft` / `writingDirection` / `LayoutDirection` / `dir=auto` usage anywhere in `Sources/`. Bundled editor/canvas HTML declares `lang="en"` with no `dir`.
- **Impact:** WebView-hosted content (Markdown render, CodeMirror editor, Canvas) inherits WebKit's Unicode bidi algorithm, so Arabic/Hebrew **text runs** render with correct glyph ordering for free. But: (a) the editor host document declares `lang="en"` and no `dir="auto"`, so paragraph-level base direction of predominantly-RTL documents isn't auto-detected (RTL paragraphs render LTR-based); (b) native chrome (status bar, sidebar, hex ASCII pane, CSV table) has no RTL mirroring. For a viewer/editor this is a real but low-frequency gap.
- **Suggested fix:** Add `dir="auto"` to the CodeMirror/Markdown host containers so per-paragraph base direction is inferred; consider `lang` reflecting content where known. Native-surface RTL mirroring is a larger, lower-priority effort — defer unless RTL is a target market.
- **Fix size:** S (WebView `dir="auto"`) / L (native mirroring)
- **Fix risk:** safe (dir=auto) / careful (native)

### F7 — 256 KB byte-prefix slice in secret-scan can split a UTF-8 codepoint at the boundary
- **Severity:** P3
- **File:** `Sources/ViewerCore/HistoryContentFilter.swift:47-49`
- **Evidence:** `String(decoding: Array(content.utf8.prefix(scanLimit)), as: UTF8.self)` where `scanLimit = 256 * 1024`. Slicing UTF-8 bytes at a fixed count can cut a multi-byte codepoint mid-sequence.
- **Impact:** Benign — `String(decoding:as:)` substitutes `U+FFFD` for the truncated trailing bytes rather than crashing. Only effect is that a token straddling the 256 KB boundary in the local-history secret-scan could be mangled (one edge token), marginally affecting redaction near the cap. No user-visible corruption of stored content (this is a scan-only copy).
- **Suggested fix:** Slice on a `Character`/`String.Index` boundary (`String(content.prefix(scanLimitInChars))`) or back the byte cut off to the last valid UTF-8 lead byte. Low priority.
- **Fix size:** S
- **Fix risk:** safe

---

## Positive observations

The following were checked and found **correct** — worth recording so they aren't "re-fixed":

- **`TextDecoder` (encoding detection) is robust** — `Sources/ViewerCore/TextFileLoader.swift:400-475`: BOM → binary-guard-with-BOM-less-UTF-16-escape-hatch → UTF-8 → Windows-CP1252 → Latin-1 fallback chain, with an explicit BOM-less UTF-16 probe (≥32 bytes + 80% NUL-parity). This is more thorough than most editors.
- **`EditorWriter.save` preserves encoding and BOM on write** — `Sources/ViewerCore/EditorBuffer.swift:240-260`: re-prepends the UTF-16 BOM (`withByteOrderMark`) so the read path can re-detect; surfaces `EditorWriteError.encodingFailed` instead of silently re-encoding a Shift-JIS/Latin-1 buffer to UTF-8. `DocumentModel+SaveCopy.swift:51-62` documents and enforces the same no-silent-UTF-8-fallback rule (a prior `?? .data(using:.utf8)` was removed as data corruption).
- **`CrossFileSearch` avoids the classic `lowercased()` index-desync bug** — `Sources/ViewerCore/CrossFileSearch.swift:294-296`: uses `.caseInsensitive` `CompareOptions` on original strings, explicitly *not* `lowercased()` (which "changes character count for ß/Σ/İ and breaks index back-mapping"). Correct and rare to see done right.
- **LSP position math is UTF-16-code-unit correct** — `Sources/ViewerCore/LSP/LSPPositionConverter.swift` and `LSPTextEditApplier.swift:24-45` operate in UTF-16 units (`ch.utf16.count`, `Array(text.utf16)`), matching the LSP spec's default `character` = UTF-16 code unit. `SpellCheckEngine`'s LineIndex is likewise UTF-16-consistent with the NSTextView ranges it feeds.
- **CSV filter has a proper Unicode fallback** — `rust-core/crates/core/src/filter.rs:117-129`: ASCII fast-path only when *both* cell and needle are ASCII; otherwise falls back to Unicode `to_lowercase().contains`, keeping semantics identical to Swift.
- **Grapheme-safe truncation** — user-facing truncations use `String.prefix` (Character/grapheme-based, e.g. `ClaudeSessionIndex.swift:386` title cap, `BreadcrumbPath`, `Git/FileHistoryModel.swift:200` short-SHA) rather than manual byte cuts, so emoji/combining sequences aren't split in displayed text.
- **Hex viewer ASCII pane is correctly byte-oriented** — `rust-core/crates/core/src/hex.rs:118-123`: printable `0x20..=0x7e` verbatim, else `.`; multi-byte UTF-8 shown as dots is the correct, expected hex-dump behavior.

---

## Coverage gaps (what I did NOT examine)

- **Runtime/on-screen behavior:** no app launch, no VM UI/pixel tests (constraint). RTL rendering, emoji grapheme rendering in the actual CodeMirror/Markdown WebViews, and caret movement across grapheme clusters (emoji ZWJ sequences, combining marks) were reasoned about from code, **not observed**. WebKit-hosted surfaces almost certainly handle grapheme caret movement correctly, but I could not confirm the flagship editor's caret/selection behavior on `👨‍👩‍👧‍👦`-class clusters on screen.
- **CodeMirror bundle internals:** the minified `codemirror.js` bundle was not audited for its own Unicode handling (column reporting, word-boundary/double-click selection on CJK, `wordChar` regex locale-awareness). Only the host HTML wrapper was checked.
- **The 794 UI string sites were sampled, not exhaustively read** — I confirmed the pattern (bare literals, no localization wrapper) but did not catalog every string.
- **Input method / IME (marked-text) handling** in the AppKit editor paths (`NSTextInputClient` marked-text ranges for CJK/Japanese composition) was not traced — relevant for CJK input in any native `NSTextView`-backed surface (hex editor, CSV cell edit).
- **Font/glyph fallback** for CJK/emoji/rare scripts (whether the app relies on system font substitution) was not examined.
- **Rust `tui`/`web` front-ends' terminal display-width** (`unicode-width` for CJK double-width column alignment): confirmed the crates do **not** add a `unicode-width` dep (minimal-deps posture) and rely on `ratatui`'s internal handling; I did not verify ratatui's width computation is applied at every render site.
- **Sorting/collation elsewhere** — I found `TextTools.sortLines`; other `.sorted()` on user-visible string lists (file lists, symbol outlines, autocomplete) were not exhaustively audited for locale collation.
- **Number/measurement parsing** (as opposed to formatting) — e.g. locale-aware parsing of user-entered numbers in Canvas/formula/CSV — was not reviewed.
