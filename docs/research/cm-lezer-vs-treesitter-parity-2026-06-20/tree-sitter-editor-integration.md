# Tree-sitter as an editor engine: query model, features, and limitations

Companion to `FINDINGS.md` (TSK-1039). Web research, 2026-06-20.

The thread through everything below: **tree-sitter gives you a fast, incrementally-updated,
error-tolerant concrete syntax tree (CST) — and nothing else.** Every "editor feature" is
built *on top of* that tree via declarative `.scm` queries plus hand-written glue. The
further a feature is from "read a node range off a clean tree," the more it degrades — and
the features that fire *during typing* (when the tree is transiently invalid) are mostly
hand-rolled in spite of tree-sitter, not because of it.

## 0. Core vs. editor convention — the single most important structural fact

Tree-sitter "core" standardizes **only four** query files, owned by two crates:

| Query file | Owned by | Fixed capture vocabulary? |
|---|---|---|
| `highlights.scm` | `tree-sitter-highlight` | **No** — names are pure convention, mapped to colors |
| `injections.scm` | `tree-sitter-highlight` | **Yes** — `@injection.content`, `@injection.language` (+ `#set!`) |
| `locals.scm` | `tree-sitter-highlight` | **Yes** — `@local.scope`, `@local.definition`, `@local.reference`, `@ignore` |
| `tags.scm` | `tree-sitter-tags` | **Recommended, extensible** — `@definition.*`, `@reference.*`, `@name`, `@doc` |

The highlighting docs cover only highlights/locals/injections; the code-navigation docs
cover tags. **`folds.scm`, `indents.scm`, `textobjects.scm`, `rainbows.scm` are never
mentioned in core** — a maintainer says they are "Github specific stuff."

**Everything else is an editor invention, and the dialects don't interoperate:**

- `indents.scm` has **three incompatible vocabularies** (nvim
  `@indent.begin/.end/.dedent/.branch/.align`; Helix `@indent/@outdent/@align/@anchor/@extend`;
  Zed `@indent/@start/@end`; Pulsar yet another).
- `textobjects.scm` has **two naming schisms**: nvim `.inner/.outer` vs Helix `.inside/.around`.
- `rainbows.scm` is **Helix-only**; Neovim uses `rainbow-delimiters.nvim` with its own model.
- Zed has a private set with no analogue: `brackets.scm`, `outline.scm`, `overrides.scm`,
  `redactions.scm` (hide secrets on screen-share), `runnables.scm` (detect tests).
- `context.scm` (`@context`/`@context.end`) is nvim-treesitter-context's invention for
  sticky scroll.
- Even `highlights.scm` *names* aren't standardized: Zed admits its captures are
  "non-standard ... detrimental ... limit[ing] the precision," and "literally only 3
  extensions support captures like `keyword.type`." tree-sitter's `STANDARD_CAPTURE_NAMES`
  "isn't exported, and doesn't match the list in the docs."

## 1. The query-file model, file by file

- **`highlights.scm` (core)** — node -> capture -> theme color. Arbitrary, dot-separated,
  most-specific-wins. De-facto vocab is large but editor-specific; themes aren't portable.
- **`injections.scm` (core)** — embedded languages (§4).
- **`locals.scm` (core)** — scope/definition/reference; the *standardized-but-abandoned*
  file: nvim-treesitter ships it "for (limited) backward compatibility" and doesn't use it;
  real scope/rename goes to LSP.
- **`tags.scm` (core)** — code navigation (§8).
- **`folds.scm` (editor)** — single `@fold` capture (§2).
- **`indents.scm` (editor, 3 dialects)** — the weakest, least portable area (§3).
- **`textobjects.scm` (editor, 2 dialects)** — structural selection + motion (§7).
- **Editor-private:** `rainbows.scm` (Helix), `context.scm` (nvim), `brackets.scm` /
  `outline.scm` / `overrides.scm` / `redactions.scm` / `runnables.scm` (Zed).

## 2. Code folding (`folds.scm`)

The query captures multi-line nodes with `@fold`; the editor turns each captured node's
byte span into a fold region. **Granularity is node-based** (function body, block, array
literal) — semantically aligned, unlike `foldmethod=indent`. Default fold endpoint is "the
start of the node's last child" — right for brace languages, wrong elsewhere.

Consumers: **Neovim core** `vim.treesitter.foldexpr()` (built into core, not the plugin) ->
`foldmethod=expr`; **Helix/Zed** derive folds from `@fold` ranges.

Limitations: **comment folding breaks** (block-comment nodes often have no children, so
"end at last child" fails; Pulsar needed a `fold.endAt` predicate); **`#region`/`#endregion`
marker folding is not native** (folds nodes, not comment-pair markers); **per-line foldexpr
is a perf tax** (re-evaluated per line on every change); **flaky updates** (folds returning
level 0 until an edit, `E490: no fold found`, defaulting to all-closed-on-open). The safer
of the two `.scm` extensions — nvim-treesitter does NOT flag folding as experimental.

## 3. Auto-indent (`indents.scm`) — the weakest area, by consensus

The projects that pioneered it keep a hand-written indenter as the *default* and disable
the tree-sitter path per-language.

Mechanism: walk from the node at the start of the new line upward; each captured node
adjusts the running indent. Capture vocab diverges (no standard).

**Maturity — explicitly experimental:**
- nvim-treesitter labels indentation "experimental"; it is **opt-in**; Neovim keeps native
  `indentexpr` as the default.
- **nvim-treesitter `master` was archived (read-only) April 3 2026**, replaced by an
  incompatible rewrite — the most-referenced indent implementation is now frozen.
- A competing plugin **nvim-yati** exists because "the experience of the builtin indent
  module ... was terrible."

**Editors that deliberately DON'T use tree-sitter indent:**
- **Helix actively disabled it for Python** — commit "Disable tree-sitter python indents,
  use fallback for now," citing "considerable user complaints about its performance" and
  "the fallback actually works better."
- **VS Code** still ships regex/declarative indentation; tree-sitter indent is only an open
  feature request (#208985).
- **Neovim** defaults to native `indentexpr`.

**What tree-sitter does NOT give you that a hand-written indenter does:**
1. **Incomplete-parse blindness (the killer):** while typing, the buffer is invalid, so the
   node you'd indent against doesn't exist yet. Helix: "if there isn't a value for a node
   yet, we don't know that we should indent it." A regex indenter reasons about the
   *previous line's raw text* and needs no valid tree.
2. **Braceless/brace-optional contexts** (C `if` with vs without `{}`).
3. **Electric characters** — snapping indent as you type `}`/`:`/`end` isn't in the query
   model; it's editor keystroke wiring.
4. **Multi-level constructs** (switch/case), **alignment/continuation lines**.
5. **Injections** — indent queries "run only against the root layer and don't properly
   respect injections," so JS-in-HTML / code-in-Markdown indent wrong.
6. **Global-computation footgun** (Helix) — computing indent over the whole file clobbers
   intentional "wrong" indentation.

## 4. Language injection (`injections.scm`) vs. Lezer `parseMixed`

Mechanism: `@injection.content` (re-parse this range) + `@injection.language` (read name
from node text) or `#set! injection.language "x"` (static pin). Low-level primitive:
`ts_parser_set_included_ranges()`. **Each injection is a separate parse tree** ("language
layer") mounted under the parent; nests iteratively. Child nodes redacted by default unless
`include-children`. `#set! injection.combined` parses scattered fragments (ERB blocks) as
one document.

| Surface | Robustness | Why |
|---|---|---|
| JS-in-HTML `<script>`, CSS-in-HTML `<style>` | **Solid** | static pin, single clean range, valid as top-level |
| Markdown code fences | **Fragile** | dynamic name lookup; unknown lang = silent no-op; needs `markdown` + `markdown_inline` |
| SQL/regex/HTML inside string literals | **Often broken** | fragment frequently isn't valid top-level code -> ERROR soup |

**Biggest limitation:** injected content is parsed as a **top-level** node. There's no way
to say "parse this range starting from rule X." Injecting a TS fragment like `T extends
string` fails (it's a type-parameter, not a valid top-level statement; open issue #3625).
Combined injections are the hard corner — Pulsar punted on them entirely.

**The injection *perf* cliff is in the editor's integration layer, not the C core:**
Neovim's `LanguageTree` was *not incremental* — on every edit it recreated child trees and
re-ran queries, "catastrophic performance"; child-tree retrieval was once 97.5% of
buffer-load time (#18107).

**Lezer `parseMixed` comparison:**

| Aspect | Tree-sitter | Lezer `parseMixed` |
|---|---|---|
| When it runs | injection queries -> separate layer trees | post-pass over finished outer tree, mounts via `NodeProp.mounted` |
| Language selection | static `#set!` or node-text lookup | **JS callback per node** |
| Nesting model | child layers | **two mount kinds: regular (replace) + overlay** |
| Templating | combined + child-redaction | overlay explicitly models non-hierarchical interleaving |
| Memory | larger trees | deliberately more compact |

Lezer's **overlay** is a more principled answer to templating; the per-node JS callback
sidesteps the "valid as top-level only" trap. But Lezer is JS-only single-runtime, and its
basic `parseMixed` setup "completely bypasses ... folding information and autocompletion" of
the inner language — you rewire those manually. tree-sitter's pure-C dependency-free runtime
is why it's embeddable everywhere and Lezer is not.

## 5. Incremental parsing, error recovery, performance

**Incremental reparse:** edit the old tree with a `TSInputEdit` via `ts_tree_edit()`, then
`ts_parser_parse` passing the old tree -> "a new tree that internally shares structure with
the old tree." Caveat (shared with Lezer): an unterminated `/*` or open string invalidates
everything after it.

**Error recovery** is GLR-based, scored by *error cost*. Two node concepts: **`ERROR`**
(wraps unparseable text; has extent/children) and **`MISSING`** (a zero-width token the
parser *inserted*; a property of a terminal, **not** an `(ERROR)` node — so `(ERROR)`
queries don't catch missing tokens). Weaknesses: recovery quality is grammar-dependent and
poorly documented; bad input often collapses to one broad structureless ERROR node
(destroying highlighting there); Pulsar calls error recovery "largely a black box."

**Whole-document parsing — the central scaling constraint:** tree-sitter parses the
**entire buffer**, not the viewport. *Highlighting* can be viewport-limited (run highlight
queries over visible ranges only), but **parsing is not** — no first-class "parse only
what's visible." Editors repeatedly request it (Helix #3072).

| Input | Symptom |
|---|---|
| 50K-line C++ | ~2 s latency, "impossible to work with" (Helix #3072) |
| 1.6 MB JSON | 1.2 s parse / 0.7 s reparse; **two retained trees ~300 MB RAM** (TS #222) |
| 50K-line Lua | parse 3,284 ms + 128 ms uninterruptible balancing; 1.45M subtrees (TS #4019) |

**Keeping it off the UI thread:**
- **Timeout API changed:** `ts_parser_set_timeout_micros` deprecated as of v0.25, replaced
  by a **progress callback** via `parse_with_options`. After a timeout the parser *resumes*
  — call `reset()` before parsing a *different* doc.
- **Balancing footgun:** the timeout bounded only the parse phase, not final tree-balancing
  (`ts_subtree_balance`), which ran uninterruptibly (#4019, since fixed).
- **Zed** parses on background threads via a copy-on-write "sum tree"; reparse only
  edit-intersecting trees.
- **Pulsar** chops parsing into 3 ms blocks with yields; minified files force full re-highlight.

## 6. Bracket matching, auto-close, tag auto-close/rename

The more a feature fires *during typing* (invalid buffer), the more it's hand-rolled.

- **Bracket matching (jump to partner):** **Neovim = hand-rolled, deliberately NOT
  tree-sitter** (default `matchparen` uses syntax attributes + char scanning from
  `matchpairs`, bounded to visible window +-100 lines, 300 ms timeout / 60 ms insert).
  **Why:** must be instant, work in any buffer (no grammar), Vim-compatible. **Helix =
  tree-sitter-first with a plain-text fallback** — and the fragility shows: `mm` "is unable
  to give correct results when tree-sitter does not have relevant information" and breaks on
  large files. **Zed = `brackets.scm`** (tree-derived).
- **Auto-close brackets = hand-rolled character logic everywhere.** The decision "insert
  `)` now" happens before reparse, on an unbalanced buffer. Zed's config: a literal
  character-pair table, with tree-sitter appearing **only as `not_in = ["string","comment"]`
  guard.** *Character logic does the work; the tree only vetoes by context.*
- **Tag auto-close/rename (HTML/JSX) = tree-derived — the one during-typing feature that
  uses the tree, and exactly where ERROR-node fragility bites.** `nvim-ts-autotag` keys off
  the grammar's error-recovery node names (`erroneous_end_tag_name`, `jsx_opening_element`);
  in deeper error states it silently no-ops or closes the wrong tag.

## 7. Structural selection / text objects / siblings

Tree-sitter's sweet spot: read-only structural queries against a valid tree. No editor
hand-rolls them.

- **Expand/shrink:** walk up/down. Zed `alt-up`/`alt-down`; Helix `expand_selection` =
  `goto_parent()`, `shrink_selection` = `goto_first_child()`; nvim `incremental_selection`.
  Limitation — **granularity is the grammar's, not the user's** (Helix #3785: expansion
  goes leftward in method chains, immediately includes surrounding delimiters). nvim-tree-
  sitter dropped incremental_selection from `main`; Neovim is folding a built-in version
  into 0.12 **with LSP-based selection as fallback** (the tree isn't always available).
- **Text objects (`textobjects.scm`):** function/class/parameter, inner/around. Coverage is
  manual and per-language — a text object exists only if someone wrote the capture; absent
  ones silently do nothing (vs hand-written Vim `ip`/`i(` which always work). Still
  "experimental"; `master` frozen.
- **Go-to-sibling / next-function / swap-parameters:** nvim `move`/`swap`, Helix
  `]f`/`[f`/`select_next_sibling`. Require `.around`; swap can leave dangling separators;
  no-op in broken buffers.

## 8. Symbols / outline / sticky context (`tags.scm` and the tree)

`tags.scm` captures `@definition.*` / `@reference.*` + `@name` + `@doc`. Powers GitHub's
search-based navigation (19 langs, no LSP), the `tree-sitter tags` CLI (ctags replacement),
and AI repo-maps (aider PageRank symbol graph). **Maturity: uneven** — not every grammar
ships it (Kotlin has none), so ecosystems vendor/patch their own.

Outline/breadcrumbs — `tags.scm` is not the only source: **Zed** uses a separate
`outline.scm` ("symbol outline is syntactic ... local to one file"); **Helix** uses
`symbols.scm` (tree-sitter, "less precise" than LSP); **aerial.nvim** supports both backends,
defaults to *prefer tree-sitter, fall back to LSP*.

Sticky context: **nvim-treesitter-context** (tree-native, `context.scm`, throttled/memoized,
prefers `WinScrolled`); **Zed** from its outline; **VS Code is NOT tree-sitter** — sticky
scroll is provider-pluggable with fallback chain outline(LSP) -> folding -> indentation.

**Big tradeoff (tree-sitter vs LSP symbols):** tree-sitter is *syntactic and single-file* —
knows `foo` is an identifier in call position but not which definition it binds. ~80x faster
but lower-fidelity. GitHub's answer is two tiers (search-based tags + *precise* via
stack-graphs) — and GitHub **archived stack-graphs Sept 2025**, underscoring how expensive
semantic resolution on a syntactic foundation is. **Consensus is hybrid:** tree-sitter for
instant/structural/offline; LSP for semantic/cross-file, preferred when a server is attached.

## 9. Migration lessons (Atom/Pulsar, Emacs, Zed)

Why they moved: regex/TextMate grammars see "one line of text at a time ... in an
approximate way"; tree-sitter maintains "a syntax tree at all times."

**What concretely regressed:**
- **Atom's JS tree-sitter grammar lost highlighting the TextMate grammar had**
  (language-javascript#558): `const`/`module`/`this`/`=>`/`require` and the `=` assignment
  class stopped highlighting. **Users disabled tree-sitter en masse** — "the real cost of
  breaking established conventions."
- **Incomplete-line handling regressed vs TextMate** ("the legacy TextMate-style grammar is
  much better at interpreting incomplete lines than the modern Tree-sitter CSS grammar").
- **Grammars silently accept invalid syntax** without flagging the tree as bad.
- **Grammar quality varies wildly** ("The C grammar is good ... the Rust grammar is not").

**Theme/scope mapping was the most under-appreciated pain:** TextMate scopes are deeply
hierarchical and "load-bearing for far more than color" (snippets, scope-aware commands).
tree-sitter's stock captures are flat (`@string`), so naive remapping **collapses theme
granularity, drops delimiter styling, breaks user snippets**. Pulsar authored *richer*
queries rather than reuse upstream flat ones. Ecosystem-wide, capture names still aren't
standardized — **a theme is no longer portable the way a TextMate theme was.**

**Grammar distribution / versioning / WASM** (dominant in practitioner retrospectives):
- **Versioning is broken:** "basically every merged PR changed a grammar enough to deserve
  a semver major bump," so consumers pin **SHAs**. Emacs: "the lack of versioning ... breaks
  major modes from time to time."
- **Install friction** (compile on user machine, needs C compiler + Git).
- **WASM is a second-class binding** (must guess libc functions, manual `delete()`, no
  custom predicates).
- **Stability/security:** grammars **segfault** and can **hang** the editor.
- **Abandonment risk** (Pulsar forked a 30-month-stale SCSS parser).

**What tree-sitter does NOT solve / editors still hand-roll or defer:** semantics -> LSP;
indentation ("the indentation logic itself had to be invented"); error recovery (opaque);
symbol/outline extraction (re-engineered per editor); `.scm` queries aren't universally
reusable (Emacs translates to Elisp `treesit-font-lock-rules`); editor plumbing (Zed's COW
sum-tree; Emacs vs gap buffer).

**Honest verdicts:** Pulsar — "clearly better than what we had before, warts and all,"
integration cost "much, much less than ... TextMate into Atom." Batsov — "genuinely great ...
But it's not magical" (needed 200+ tests because "font-lock and indentation are easy to
break accidentally"). Sharpest skeptic — for *basic highlighting only*, tree-sitter is
*more* upfront effort than TextMate and produces trees too loose for compiler-grade use; ROI
is real only once you want the structural features.

## Bottom line for an editor/viewer implementer

1. Use tree-sitter for read-only structural queries against a valid tree — highlighting,
   folding, structural selection, text objects, sibling nav, single-file outline/sticky.
2. **Folding is the safe `.scm` bet**; budget for stale-fold updates, comment-endpoint
   handling, and a separate `#region` marker mechanism.
3. **Do not lean on `indents.scm`** — Helix reverted Python to its hand-written fallback,
   VS Code never adopted it. A production indenter needs hand-written electric chars,
   braceless lookahead, alignment, and graceful behavior on the invalid tree that exists on
   *every keystroke*.
4. **Auto-pairs and bracket-jump should be hand-rolled** (tree only as a string/comment
   guard); tag auto-close is the one during-typing feature worth deriving from the tree.
5. **Injections are separate top-level trees** — fragments not valid top-level degrade to
   ERROR; the integration layer is where perf dies. Lezer's overlay is cleaner on the web.
6. **Parsing is whole-document and memory-heavy** — background-thread it; use the progress
   callback (not the deprecated timeout); watch the balancing phase.
7. **Symbols are syntactic and single-file** — pair with LSP for cross-file nav.
8. **Don't expect query/theme portability** — pin grammar SHAs, not version tags.

## Sources
- tree-sitter docs: tree-sitter.github.io/tree-sitter/3-syntax-highlighting.html ;
  /4-code-navigation.html ; /using-parsers/3-advanced-parsing.html
- TS issues/discussions: #1251, #3625, #18107 (neovim), #222, #4019, #4001, #923, #1768 ;
  v0.25 release notes
- Zed: zed.dev/blog/syntax-aware-editing ; zed.dev/docs/extensions/languages ;
  zed.dev/docs/outline-panel ; discussion #23371
- Helix: commit 9ae70cc (disable Python indents) ; docs.helix-editor.com/guides/indent.html,
  /textobject.html ; PR #1562 ; issues #3072, #3584, #11109, #13795 ; discussion #3785 ;
  release 25.07 notes
- Neovim: neovim.io/doc/user/treesitter/, /pi_paren/ ; issues #28692
- nvim-treesitter: README/archive ; discussions #5259 ; issues #1438, #5643, #7062, #8391 ;
  nvim-treesitter-textobjects ; nvim-treesitter-context ; nvim-yati ; nvim-ts-autotag
- GitHub: github.com/github/code-navigation ; github.blog Atom announcement (2018-10-31) ;
  github.blog stack-graphs
- Pulsar "modern tree-sitter" parts 1-7 (blog.pulsar-edit.dev)
- Emacs: archive.casouri.cc/note/2025/emacs-tree-sitter-in-depth/
- Batsov: batsov.com/articles/2026/02/27/building-emacs-major-modes-with-treesitter-lessons-learned/
- Brunsfeld HN comment (news.ycombinator.com/item?id=18349488) ; dotat.at/@/2025-03-30-hilite.html
- VS Code: issues #208985, #177649
- Lezer: lezer.codemirror.net/docs/guide/ ; codemirror.net/examples/mixed-language/
- lambdaland.org/posts/2026-01-21_tree-sitter_vs_lsp/ ; aerial.nvim (github.com/stevearc/aerial.nvim)
