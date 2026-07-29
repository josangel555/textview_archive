# Greenfield learnings extraction — 2026-07-11

Goal: mine EVERYTHING this project produced (code, tests, docs, board, process) for learnings to
carry into a from-scratch rebuild of a similar app, plus port-ready artifacts. Requested by the
owner 2026-07-11 (ultracode).

## The next project (owner's requirement statement, verbatim)

> I want to build a Editor application for MacOS. Native swift, but a core which is Rust, which an
> support other UIs like WebUI, TUI. and also Core can deployed remotely and transport via TCP/WS.
> Most importantly its an text editor. I already build prototypes and CM6 is the winner for me.
> Treesitter for syntax highlighting and standard LSP integration. I also wanted multi sessions,
> with nested tabs. Each tab can show files, or plugins or MicroApps. MicroApps can even be Image
> editor, Markdown, PDF viewer, Spreadsheet, DB viewer etc and is an extensible plugin system. I
> don't want replicate VS Code or IntelliJ and build my own. This is agent centric and the main
> goal is to make my interactions with AI non-blackboxy. I hate staring at Codex cli and not
> knowing what is happening. So I need extensive git integration, I want to be able to review code
> and share the review to agent itself. I also want agent to explain to me code, reverse review?
> or a Code Walkthrough? I also want one of the main features to be a Canvas, which is a WebView
> where agents can build UI incrementally and don't have to spit out HTML/JS/CSS top down, and
> also provide all basic features, components etc. Again this can be another Plugin itself.
> Terminal and other dev centric features. How can I approach building it?

Owner is also building an in-project (coupled) project-management app for it — PM learnings feed that.

## Method (two workflows, checkpointed)

**W1 — corpus pass** (this dir's `summaries/`): every source/test/script/rust file + every md file,
summarized in ~54 directory batches. Every agent WRITES ITS OWN REPORT to disk on completion (a
mid-run quota kill loses only in-flight agents; resume re-runs only the dead).
**W2 — aspects + holistic + portables** (`aspects/`, `holistic/`, `PORTABLE/`): ~13 aspect analysts
+ 2 unprimed blank-slate explorers + board archaeology, then 2 Fable holistic agents, then the
port-ready artifacts + master synthesis + completeness critic.

## Model routing (quota discipline)

| Tier | Used for | Count |
|---|---|---|
| Haiku | bulk per-file summarization (code, tests, scripts, bulk docs) | ~48 |
| Sonnet | judgment docs (LESSONS, root/decision docs), aspect analyses, portables, critic | ~25 |
| Fable | ONLY 2 holistic agents (PM-level patterns; greenfield architecture) | 2 |
| Opus | master synthesis only | 1 |

## Layout

- `summaries/code/*.md` — per-batch source/test/script summaries (per-file entries + module patterns)
- `summaries/docs/*.md` — per-batch md-corpus mining (learnings + decision records)
- `summaries/INDEX.md` — roll-up index + most-cited patterns scoreboard
- `aspects/*.md` — per-dimension analyses (test types, bug types, regression types, struggle types,
  inefficiency types, task-management struggles, wall-struggles, automation struggles, …)
- `holistic/*.md` — Fable-level PM + architecture syntheses
- `PORTABLE/*.md` — artifacts to copy into the next project on day 1
- `MASTER_SYNTHESIS.md` — the final read

## Prior analyses treated as INPUT (not re-derived)

- `/Users/me/Local_Docs/local_workspace/project_tracker/pinboard/TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md`
  (the 1.30 GB session-jsonl Haiku map-reduce study)
- `docs/research/project-meta-analysis-2026-07-04/SYNTHESIS.md` (repo+board archaeology)
- `docs/research/prelaunch-audit-2026-07-09/` (~30 unverified audit dimension reports)
- pinboard v4 tracker design docs (`DESIGN_v4_CONSOLIDATED.md`, `design_v4/HLD.md`)
