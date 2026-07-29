# Verification pass — security / packaging / dead-render-tail findings (GAPS §3, 2/2)

Read-only verification against current `main` (commit at time of check: see `git log -1`
in the repo; not modified by this pass). Each finding: verdict, current file:line, decisive
excerpt.

---

## 1. MCP socket unauthenticated — **CONFIRMED**

`Sources/ViewerCore/Automation/MCPSocketListener.swift:15-16`:

```swift
/// remote surface, no auth token in v1. The tool surface itself is unchanged
/// (the TSK-954 `open_path` containment fence applies exactly as on stdio).
```

The listener binds a per-user Unix-domain socket at
`~/Library/Application Support/MarkdownViewer/mcp.sock` (`MCPSocketListener.swift:44-53`),
`listen()`s (`:97`), and spawns an unauthenticated accept loop (`:125-134`) — every accepted
connection gets a full `MCPServer` instance with no handshake, token, or consent gate before
dispatch. The full ~60-verb `run_verb` surface plus every other cataloged MCP tool
(`MCPToolCatalog.swift`) is reachable to **any local process/user that can connect to the
socket path** (Unix-socket permissions are the only gate, and the code comment explicitly
disclaims a token for "v1"). Confirmed as designed, not a bug — but a real trust-boundary
gap for a greenfield rebuild to close (proper capability token / consent prompt per
connection, not just filesystem permissions on the socket node).

---

## 2. `run_verb` open/save-copy bypasses the home-jail fence — **CONFIRMED**

`MCPToolCatalog.swift` DOES fence most path-taking tools through
`validatedExistingURL(from:)` (`:146, 427, 434, 458, 603, 995, 1045, 1243` — 7 call sites),
which is the TSK-954 containment fence referenced in the `MCPSocketListener.swift:16`
comment. **But `run_verb` is not one of those call sites.** `run_verb` (`:786-812`) only
validates the verb TOKEN against `ScriptVerbCatalog.tokens` (`:807-809`) — it does zero
validation on the verb's trailing path argument. It dispatches the raw line via
`host.automationRunVerb(line)` straight into `ScriptVerbDispatch.swift`, where:

- `case "open"` → `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift:182`:
  `model.openPath(URL(fileURLWithPath: arg))` — raw arg string to `URL`, no containment check.
- `case "save-copy"` → `ScriptVerbDispatch.swift:383-393`:
  `try model.saveCopyOfCurrentTab(to: URL(fileURLWithPath: arg))` — same, writes an arbitrary
  absolute path.

Neither `DocumentModel.openPath(_:)` (`DocumentModel.swift:706`) nor
`saveCopyOfCurrentTab(to:)` calls `validatedExistingURL` or any equivalent fence — they take
the `URL` at face value. So an MCP client (local, unauthenticated per finding 1) can issue
`run_verb {"verb": "open /etc/passwd"}` or `run_verb {"verb": "save-copy /Users/<other>/..."}`
and reach any path readable/writable by the app process, outside whatever home-jail the other
7 `validatedExistingURL` call sites enforce. This is a real fence bypass, not merely a
theoretical one — the containment mechanism exists in the same file and is simply not
threaded through this specific tool's argument.

---

## 3. `THIRD_PARTY_NOTICES.md` not copied into the app bundle — **CONFIRMED**

`grep -n "THIRD_PARTY\|NOTICES\|LICENSE" scripts/build-app.sh` → **zero matches**. The file
exists at repo root (`THIRD_PARTY_NOTICES.md`) but `build-app.sh` never references or copies
it into `Contents/Resources`.

Verified against the actual installed bundle
(`dist/TextView.app/Contents/Resources/`): no `THIRD_PARTY_NOTICES.md`, `NOTICES`, or root
`LICENSE` anywhere. The only license-shaped file present is a nested SwiftPM resource-bundle
artifact, `Contents/Resources/MarkdownViewer_ViewerUI.bundle/LICENSE` (a single vendored
license swept in incidentally via `Bundle.module` resource copying, not the curated
third-party notices file). A rebuild that ships to real users needs the notices file wired
into the packaging script explicitly.

---

## 4. Notarization lane never run / no Developer ID — **CONFIRMED**

`scripts/sign-and-notarize.sh` exists (213 lines) and is a real, apparently-complete script
(codesign each dylib + resource bundle → sign `.app` with entitlements + hardened runtime →
`xcrun notarytool submit` → poll → `xcrun stapler staple/validate` → zip for distribution).
But:

- **No Developer ID identity installed:** `security find-identity -v -p codesigning` →
  `0 valid identities found` on this machine. The script's own preflight
  (`sign-and-notarize.sh:64-72`) greps the keychain for `"Developer ID Application"` and
  `die`s if absent — it would fail at step 1 today.
- **No notary credential profile:** `xcrun notarytool history --keychain-profile MV_NOTARY`
  → `Error: No Keychain password item found for profile: MV_NOTARY`.
- **Not wired into CI:** `grep -rl sign-and-notarize .github` → no matches; nothing invokes
  this script automatically.
- Consistent with `CLAUDE.md`'s own project notes: *"Local signing only (cert
  'MarkdownViewer Local Dev'); no Developer ID until shipping public."*

So the notarization lane is fully scripted but has never actually been exercised
end-to-end (no cert, no credentials, no CI trigger) — a from-scratch rebuild targeting
public distribution needs this run at least once before it's trustworthy (notarytool
rejections are common on first submission — unsigned nested binaries, missing hardened-
runtime entitlements, etc. — and won't surface until it's actually tried).

---

## 5. Vendored Mermaid version — **CONFIRMED, 11.4.1**

`Sources/ViewerUI/Resources/mermaid/mermaid.min.js` contains the literal version string
`"11.4.1"` (4 occurrences via `grep -c`). `docs/MERMAID.md:53` documents the pinning intent:
*"Pin a specific version (`mermaid@11.x` LTS) and check in the minified file..."* — consistent
with what's actually vendored. This matches the audit's claim of 11.4.1 exactly (unable to
independently re-verify the "6 CVEs" claim from inside this read-only pass — that requires an
external CVE-database lookup, not a repo grep — but the version number itself is confirmed
accurate). Flag for the rebuild: whatever CVE fixes exist past 11.4.1 in the current mermaid
release line should be pulled in before shipping, and the vendoring process (manual
check-in of a minified file, no lockfile/SBOM entry) has no update-tracking mechanism.

---

## 6. Dead render tails

### 6a. FormulaEngine — **REFUTED** (live, wired to CSVTableView — but as a Rust bridge, not the Swift evaluator)

The audit's premise (a Swift `FormulaEngine` sitting unused) is stale. Per
`Sources/ViewerCore/FormulaEngine.swift:1-10`:

```swift
/// STAGE-B DELETED TWIN (TSK-649/TSK-1213, 2026-07-07): the Swift formula
/// EVALUATOR (lexer/parser/evaluate, ~40 builtin functions, cycle detection)
/// that lived here was deleted after the MDV_RUST_FORMULA default flipped ON
/// — the engine is rust-core's `formula.rs` ...
```

The Swift evaluator was already deleted; what remains under that filename is a thin
value-type/bridge layer (`formulaGridSnapshot()`, `recalcAllFormulas()`). It IS wired to a
real UI caller: `Sources/ViewerUI/CSVTableView.swift:522-526`
(`formulaValuesMap()` → `m.recalcAllFormulas()`), gated by `RustFormulaGate.isEnabled()`
which defaults to `true` (`RustCoreGates.swift:104`, flipped on 2026-07-07 per the inline
comment, off-switch `MDV_RUST_FORMULA=0`). `recalcAllFormulas()` calls
`RustFormulaAdapter.recalc(cells:)` → rust-core's `formula.rs`. `formulaValuesMap()`'s result
feeds the "ƒ" computed-marker rendering (`CSVTableView.swift:460-461, 986`) and the
formula-edit-box routing (`CSVEditRoute`, `:452-455`). **Net: formula evaluation is live and
on-screen (CSV/spreadsheet view), just implemented in rust-core with a Swift bridge — not a
dead tail.** (Corpus writers should not flag this as dead; if anything it's a *migration*
data point — Swift engine deleted, Rust twin promoted to sole implementation — for the
Rust-migration-policy learning, not the dead-code learning.)

### 6b. 3-pane merge UI (TSK-1171 `ConflictResolution*`) — **CONFIRMED dead**

`ConflictResolutionModel` (`Sources/ViewerUI/ConflictResolutionModel.swift`) and
`ConflictResolutionView` (`Sources/ViewerUI/ConflictResolutionView.swift:10`,
`struct ConflictResolutionView: View`) both exist. The model has exactly one non-test
construction site: `DocumentModel.swift:3020-3027`,
`beginConflictResolution(forTabID:url:)`, whose own doc comment says it outright:

```swift
/// Host-testable; the sheet that presents the returned model is the render tail.
```

`beginConflictResolution` itself has **zero callers anywhere in `Sources/`** (only test
callers in `Tests/ViewerUITests/ExternalEditReconcileWiringTests.swift`). `grep -rn
"ConflictResolutionView" Sources/` returns only its own declaration — no `ContentView.swift`
sheet/`.sheet(item:)` presentation, no menu action, nothing instantiates it live. Confirmed:
model layer is built and tested, the SwiftUI presentation layer that would surface a 3-way
merge conflict to the user was never wired up. A user whose file conflicts today only ever
sees the (separately-wired) auto-merge path (`applyExternalAutoMerge`, `:3000-3012`) — the
manual 3-pane resolution UI is unreachable.

### 6c. Dynamic content menu (TSK-1319 `activeContentMenu`/`ContentActionMenu`) — **CONFIRMED dead**

`DocumentModel.activeContentMenu` (`DocumentModel.swift:2151`,
`public var activeContentMenu: (title: String, actions: [ContentActionMenu.Action])?`) is a
computed property backed by `ContentActionMenu` (`Sources/ViewerCore/ContentActionMenu.swift`,
the `FileCategory → actions` model per the commit log entry
`feat(menu): dynamic content-menu model — FileCategory → content actions +
activeContentMenu [CH-H: TSK-1319]`). `grep -rln "activeContentMenu" Sources/` returns
**only `DocumentModel.swift` itself** — no `View` in `ViewerUI` (`ContentView.swift`, menu
bar builders, context-menu builders) reads `model.activeContentMenu` anywhere. All actual
reads are in `Tests/ViewerUITests/DocumentModelContentMenuTests.swift`. Confirmed: the model
is fully built (per-`FileCategory` action lists) but never surfaced to any actual menu —
same pattern as 6b (model landed, render tail never followed).

---

## Summary table

| # | Finding | Verdict |
|---|---|---|
| 1 | MCP socket unauthenticated | CONFIRMED |
| 2 | `run_verb` open/save-copy bypasses fence | CONFIRMED |
| 3 | `THIRD_PARTY_NOTICES.md` not bundled | CONFIRMED |
| 4 | Notarization never run / no Developer ID | CONFIRMED |
| 5 | Vendored Mermaid 11.4.1 | CONFIRMED (version only; CVE count not independently re-checked here) |
| 6a | FormulaEngine dead | REFUTED — live via rust-core bridge, wired to `CSVTableView` |
| 6b | 3-pane merge UI (TSK-1171) zero callers | CONFIRMED |
| 6c | Dynamic content menu (TSK-1319) zero callers | CONFIRMED |
