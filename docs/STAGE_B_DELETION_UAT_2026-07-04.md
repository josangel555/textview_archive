# Stage-B Swift-twin deletion — validation/UAT plan (TSK-649)

**Owner resolution (2026-07-04): NO calendar soak.** Single-user app — soak assumes organic
traffic; with one user a soak window is theater. Validation is DELIBERATE instead: the
evidence ladder below runs per deletion batch, and the owner UAT checklist replaces
"wait N days".

## The evidence ladder (per deleted twin)

1. **Pre-deletion parity green** — the engine's A/B parity + differential suites pass on
   current `main` (rust already default-ON; the twin is dead code in practice — deletion
   risk = losing the fallback + compile coupling, not behavior change).
2. **Post-deletion host gate** — `bash scripts/test-headless-gate.sh` green on the deletion
   commit (each engine = its own commit; smallest blast radius first per TSK-810).
3. **Scoped VM slice** for render-touching engines (markdown/highlight/folds/cmEdit):
   `bash scripts/test-in-vm.sh all` — the relevant WV/T4/T5 slice, `all` mode (stale-dist trap).
4. **Owner UAT checklist** (below) — the real app from `/Applications`, per engine,
   ~3–5 min each after the batch that deletes it. Full pass ≈ 30–45 min.

> **Safety note after deletion:** there is NO Swift fallback anymore — `RustCoreFallback`
> for that engine is gone. The no-panic fuzz lanes (TSK-1223/1232) + typed-error FFI are
> the remaining net. Any rust panic in a deleted-twin engine is a P0.

## Owner UAT checklist — per engine

- **CSV (`CSVParser`/`CSVFilter`):** open a ~100k-row CSV → scroll/sort/filter feel instant;
  edit a cell + save round-trips; convert commands (TSV/JSON) produce correct output;
  a file ending in a lone `""` row parses right (TSK-1286 class).
- **Hex (`HexDumpBuilder`/`HexSearchEngine`):** open a binary; scroll deep; search an ASCII
  needle + a hex-byte needle; verify counts/jump. (Known open bug TSK-1423 — search ignores
  unsaved edits — is PRE-EXISTING; don't attribute it to the deletion.)
- **Find (`FindEngine`):** in-file find highlights ALL matches (TSK-1140 behavior);
  regex + case-sensitive modes; replace-one and replace-all.
- **Fuzzy (`FuzzyMatcher`):** palette file-jump and command narrowing rank sanely
  (prefix > substring > scattered).
- **Transcript (`ClaudeLogParser`):** open a Claude session `.jsonl`; events project
  correctly; tail-follow updates live while the session appends.
- **Markdown (`HTMLVisitor`-structural):** render a doc with YAML frontmatter (hidden —
  TSK-1433), tables, fenced code (highlighted), mermaid block, TOC links that jump (TSK-1430).
- **cmEdit (`CMEditApplier`):** typing latency feels unchanged in a large file; undo/redo
  deep history; multi-cursor edit applies once per cursor.
- **Highlight (twin already deleted — TSK-854):** spot-check 4–5 languages incl. Swift
  `//` comments + rust SCREAMING_CASE (TSK-1201 class) — colors present, no grey-out.
- **Folds (`TreeSitterEngine+Folds`, after the fold-gate flip):** fold/unfold gutter
  chevrons in a big JSON + a Swift file; fold-all/unfold-all; structural search returns.
- **Formula (`FormulaEngine`, only after TSK-1215 consumption lands + flip):** `=A1+B1`
  shows the computed value in the grid (view AND edit states); the dedicated formula edit
  box shows/edits the raw source; editing a dependency recalcs; the computed-cell marker
  is visible but subtle.

## Deletion order (smallest blast radius first, per roadmap/TSK-810)

1. `FuzzyMatcher` → 2. `FindEngine` → 3. `ClaudeLogParser` → 4. hex pair →
5. `CSVParser`/`CSVFilter` → 6. `CMEditApplier` → 7. markdown structural visitor →
8. `TreeSitterEngine` folds (needs fold flip first) → 9. `FormulaEngine` (needs 1215 + flip).

Each step: delete + retarget twin-coupled tests + gate + UAT slice + own commit.
