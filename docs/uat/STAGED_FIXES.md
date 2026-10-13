# Staged UAT fixes — landing checklist

Run `wf_7f6adec6-3ab` (2026-06-03). Each fix is committed to its own branch; worktrees reaped (55GB reclaimed). Full repro/root-cause per bug: `UAT_BUGS.md`. Report: `docs/uat/UAT_REPORT_undated.md`.

## Already landed on `main`
- `6f21d7d` — BUG-019 (off-menu .rendered clamp, gate-green)
- `2b54f37` — BUG-021 (dirty-close script verb)

## Prerequisite to land the rest
The host headless gate is red on KNOWN-unrelated failures (#201 macOS-26 MarkdownLinkPolicy + FoldBench/CrossFileSearchBench parallel flakes). Quarantine/guard those, then rebase+ff each vetted branch.

## Reconcile before landing
- **-52 vs -56**: both BUG-009 (delay-verb) — keep one.
- **-65 vs -71**: BUG-028 fragment overlap — reconcile.
- 12 `git stash` entries (`RECOVERED-*-belongs-to-sibling`) preserved in shared .git as backup — inspect/drop after landing.

## Staged branches
| Branch | Bug | Commit |
|---|---|---|
| `-47` | BUG-007 ✅gate-green | `e333a2c` |
| `-49` | BUG-022 | `0ec0c56` |
| `-50` | BUG-023 | `6b2e534` |
| `-51` | BUG-008 | `24bd8a3` |
| `-52` | BUG-009 | `0ebcda4` |
| `-53` | BUG-024 | `914d7f9` |
| `-54` | BUG-010 | `abe06af` |
| `-55` | BUG-025 | `6aae77a` |
| `-56` | BUG-009 (DUP of -52) | `11f2790` |
| `-57` | BUG-001 | `f0996e6` |
| `-58` | BUG-011 ✅gate-green | `6c8af71` |
| `-59` | BUG-012 | `2c51ab9` |
| `-60` | BUG-016 | `50e4513` |
| `-61` | BUG-026 | `61dc017` |
| `-62` | BUG-003 | `57ee7ac` |
| `-63` | BUG-013 | `36c80a4` |
| `-64` | BUG-027 | `4050b4b` |
| `-65` | BUG-002 | `98686cb` |
| `-66` | BUG-014 | `5371904` |
| `-67` | BUG-015 | `c2ce89e` |
| `-68` | BUG-017 | `c4f4389` |
| `-69` | BUG-004 | `d6be294` |
| `-70` | BUG-018 | `d4b7ed5` |
| `-71` | BUG-028 (overlaps -65) | `32b1325` |
| `-73` | BUG-005 | `2c36d25` |
| `-74` | BUG-029 | `7124966` |
| `-75` | BUG-030 | `b8a8e3c` |
| `-76` | BUG-019 ✅gate-green | `6890cbd` |
| `-77` | BUG-006 | `2323930` |
| `-78` | BUG-020 | `3dd46b9` |
| `-79` | BUG-031 | `7368929` |

## FINAL OUTCOME (2026-06-03 13:19) — 27 fixes landed on main, gate GREEN
- Bulk-landed (cherry-pick + gate-verified): 49,51,52,53,55,57,59,60,61,62,65,66,67,68,69,70,71,73,74,75,77,78 (22) + earlier 47(BUG-007),58(BUG-011),#201 + run-landed 6f21d7d(BUG-019),5ef...(BUG-021). All redundant fixer branches reaped (content on main).
- **5 HELD for manual reconcile (branches kept):** -54 BUG-010 off-menu clamp (overlaps landed BUG-007/019 guards — worth reconciling, completes the family); -64 BUG-027 sessions-store (overlaps -62); -63 BUG-013 (redundant dup of landed -51 wireLifecycle — likely droppable); -50 BUG-023 + -79 BUG-031 (comment-only scope notes, trivial).
- 1 non-bug (-72 BUG-032).
