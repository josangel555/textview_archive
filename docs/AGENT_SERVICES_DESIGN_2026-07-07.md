# Agent Services — spike + design (TSK-697, 2026-07-07)

**The wish** (wishlist P7): *Agent Services — Semantic/LSP code search, Global
search, Refactor (rename/move), Test runner, Code review.*

**The finding**: this is NOT a greenfield epic. The app already ships an
agent surface — the MCP server (24+ tools incl. `run_verb` over the ~160-verb
catalog, plus the async LSP lane) — and the five services partition into
**2 done, 3 exposure gaps** over engines that already exist. The design is
therefore *extend `MCPToolCatalog`*, not build a suite.

## Per-service gap analysis (code-verified)

| Service | Engine today | Agent-callable today | Gap |
| --- | --- | --- | --- |
| Global search | CrossFileSearch (rust-backed) | ✅ `search_files` MCP tool | none |
| Semantic/LSP code search | LSP definition/references (`LSPClient`), `who_calls` | ✅ `who_calls` (async lane) | `goto_definition` + `find_references` tools — same async-lane pattern as `who_calls` |
| Refactor: rename | `LSPService`/`LSPClient` `textDocument/rename` (TSK-640) — EXISTS, host-tested | ❌ | a `rename_symbol` tool: async lane → WorkspaceEdit → apply through the standard save path; **dry-run by default** (return the edit summary; `apply:true` executes) |
| Refactor: move | nothing (LSP `willRenameFiles` unwired) | ❌ | larger; SEPARATE slice, spike the willRenameFiles support per server first |
| Test runner | TaskRunner + stores | ✅ `list_runnable_tasks` (list only) | a `run_task` tool: execute a **listed** task (allowlist = the runnable list itself, no arbitrary commands), stream/capture output, return exit + tail |
| Code review | ReviewStore, CommitDiffAnchor, ReviewQAContext (TSK-318 model), export | ❌ (export is app→out only) | `get_review_context` (ReviewQAContext.build over the current review) + `list_review_comments` — read-only first |

## Design principles

1. **One surface.** Every service lands as an `MCPToolCatalog` tool — the
   agent already speaks this; no second protocol. LSP-backed tools ride the
   existing **async lane** (`isAsyncTool`) so a slow server never parks main.
2. **Read-only by default; mutations are explicit + dry-run-first.**
   `rename_symbol` returns the WorkspaceEdit summary unless `apply:true`;
   `run_task` only runs tasks already in `list_runnable_tasks` (the
   allowlist), never shell strings.
3. **Existing tests patterns**: each tool = catalog census bump + a
   HeadlessHarness command-path test (the `who_calls` precedent).

## Breakdown (filed as children of TSK-697)

- **s1** `goto_definition` + `find_references` MCP tools (async lane).
- **s2** `rename_symbol` MCP tool — dry-run default, `apply:true` through the
  standard save path.
- **s3** `run_task` MCP tool — allowlisted to `list_runnable_tasks`, output
  capture + exit code, bounded runtime.
- **s4** `get_review_context` + `list_review_comments` MCP tools (read-only).
- **s5 (spike)** move-file refactor — per-server `willRenameFiles` support
  audit before any build.

Sequencing: s1→s2 share the async-lane plumbing; s3, s4 independent; s5 last.
Each slice is host-testable (FakeLSP server for s1/s2; temp task stores for
s3; fixture reviews for s4).
