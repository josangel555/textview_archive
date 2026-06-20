# CodeMirror 6 Language Support: what's derived from the Lezer parse tree, and what isn't

Companion to `FINDINGS.md` (TSK-1039). Web research, 2026-06-20. Organized by capability.
For each: the mechanism, **whether it strictly requires the Lezer tree**, and the
alternative source (if any). Crosscutting theme: CodeMirror separates **tree-driven node
props** (need a parser) from **service facets** and **language-data facets** (do *not*
need a parser — just functions/config keyed by document position). Most "smarts" can be
driven by an alternative token/structure source, but the *default* implementations in the
language packages read the Lezer tree.

## 0. The two architectural seams that answer the core question

There are two indirection layers between a feature and its data source.

**Seam 1 — Service facets (tree-optional).** Several features are defined as a *facet of
functions* that take `(state, position)` and return a result, with a tree-reading default
registered as one of those functions. Marijn Haverbeke (CM author) is explicit:

> "You can wire in whatever logic you want through the `indentService` and `foldService`
> facets, which aren't dependent on syntax trees."
> — discuss.codemirror.net, "Indentation and folding without a language"

**Seam 2 — `languageData` facet (`EditorState.languageDataAt`).** A position-keyed
key/value lookup. Features resolve their *config* (comment tokens, close-bracket pairs,
word chars, indent-on-input regex, autocomplete sources, indent units) through it. It does
**not** itself require a tree — but in a *mixed-language* document the active language at a
position is determined by the tree (the nested mount), so `languageDataAt` *transitively*
uses the tree to pick which config applies. Mechanism: `defineLanguageFacet` creates the
facet; `languageDataProp`/the `Language.data` field register it; `EditorState.languageDataAt`
reads it.

```
Feature -> languageDataAt("key", pos) -> [config values]      Seam 2: config, tree-optional
Feature -> fooService facet (functions) -> [default reads tree] Seam 1: service, tree-optional
Feature -> syntaxTree(state).resolveInner(pos) -> [tree nodes]  hard tree dependency
```

## 1. What a `LanguageSupport` / `Language` provides beyond highlighting

`Language` holds: `parser` (the Lezer `Parser`), `data` (its `languageData` facet, via
`defineLanguageFacet`), `name`, and `extension` (which installs the language **plus the
background parse worker**). `LanguageSupport` bundles a `Language` with supporting
extensions (autocomplete sources, fold/indent props are usually attached to node types in
the grammar, plus extra extensions).

Derived from the parse tree: **code folding** (`foldNodeProp`), **auto-indentation**
(`indentNodeProp`), **bracket matching** (`NodeProp.openedBy/closedBy` +
`bracketMatchingHandle`), **structural selection** (`selectParentSyntax`), **syntax-tree
navigation** (cursors / `resolveStack`), **highlighting** (`styleTags`). Derived from
**language data** (config, not tree-shaped): **comment toggling** (`commentTokens`),
**auto-close brackets** (`closeBrackets`), **autocomplete source selection**
(`autocomplete`), **electric reindent** (`indentOnInput`), **word chars** (`wordChars`).

## 2. Code folding

Two parallel systems, with a clear priority order in the public `foldable()`:

> "First asks any fold services registered through `foldService`, and if none of them
> return a result, tries to query the fold node prop of syntax nodes that cover the end
> of the line." — fold.ts

- **`foldService`** — facet of functions `(state, lineStart, lineEnd) => {from, to} | null`.
  **Does NOT require the tree.** Can fold from indentation, blank-line heuristics, regex.
- **`foldNodeProp`** (default for Lezer languages) — a node prop mapping node type -> fold
  range. Consumed by internal `syntaxFolding()`, which **requires the tree**:
  `let tree = syntaxTree(state); if (tree.length < end) return null; let stack =
  tree.resolveStack(end, 1)` then walks nodes querying `foldNodeProp`. `foldInside` is the
  common helper ("folds everything but the first and last child" — e.g. braces/brackets).
  `codeFolding()` installs the state field (`foldState`, a decoration set) +
  `foldEffect`/`unfoldEffect`.

**Verdict:** Folding is *not* fundamentally tied to the parser — `foldService` is the
escape hatch — but the *default* grammar-attached folding (`foldNodeProp`) reads the tree.
`StreamLanguage` (tokenizer, no real tree) folds poorly because there's no structural
nesting to fold on.

## 3. Auto-indentation

Same service/prop duality, same service-first fallback. `getIndentation`:

```
for (let service of context.state.facet(indentService)) {
  let result = service(context, pos)
  if (result !== undefined) return result          // tree-free path wins if present
}
let tree = syntaxTree(context.state)
return tree.length >= pos ? syntaxIndentation(context, tree, pos) : null   // tree path
```

- **`indentService`** — facet of `(IndentContext, pos) => number | null | undefined`. **No
  tree required**; `undefined` defers to the next service. Indents plain text by copying the
  previous line's whitespace.
- **`indentNodeProp`** (default) — attaches an indent strategy to node types; consumed by
  `syntaxIndentation`, which **requires the tree**. Strategy builders: `delimitedIndent`
  (bracketed blocks), `continuedIndent` (wrapped continuations, `except` regex),
  `flatIndent`. `TreeIndentContext` exposes `baseIndent` and `continue()`. `indentUnit`
  facet defines the whitespace unit.
- **`indentOnInput`** (electric chars) — on typing, reads the **`indentOnInput` regex from
  language data** at the cursor, tests the line prefix, and if it matches calls
  `getIndentation` to reindent. So it's *config from language data* (Seam 2) **plus**
  whatever `getIndentation` resolves (service or tree).
- **`insertNewlineAndIndent`** (the Enter command) builds an `IndentContext` with
  `simulateBreak`/`simulateDoubleBreak` and calls `getIndentation`.

**Verdict:** Indentation has a first-class tree-free path (`indentService`); the rich
grammar-driven path (`indentNodeProp`) needs the tree. The trigger character set
(`indentOnInput`) is pure language-data config.

## 4. Bracket matching (`bracketMatching`)

A **two-stage** strategy — tree first, character scan as fallback.
`matchBrackets(state, pos, dir)` calls `matchMarkedBrackets` then `matchPlainBrackets`.

- **Tree path (`matchMarkedBrackets`):** `let tree = syntaxTree(state), node =
  tree.resolveInner(pos, dir)`, then reads `NodeProp.openedBy` / `NodeProp.closedBy` (the
  matching node names, encoded in the grammar) to find the partner node, and
  `bracketMatchingHandle` to highlight just the "handle" sub-range (e.g. only the `<...>`
  of an HTML tag, not the whole element). **Requires the tree** and grammar-declared
  `openedBy`/`closedBy` props.
- **Fallback (`matchPlainBrackets`):** scans characters within `maxScanDistance`, tracking
  nesting depth — but even here it consults the tree to require the matched bracket be the
  same token type: `tree.resolveInner(basePos + pos, 1).type != tokenType`. So it's
  character scanning **disambiguated by** the tree where available.

`MatchResult` = `{ start: {from,to}, end?: {from,to}, matched: boolean }`. Commands
`cursorMatchingBracket` / `selectMatchingBracket` call `matchBrackets` in up to four
directions around the cursor.

**Verdict:** Bracket *matching* uses the tree by default (via `openedBy`/`closedBy`), but
degrades to character scanning. **Not** strictly tree-dependent.

## 5. Auto-close brackets (`closeBrackets`) — lives in `@codemirror/autocomplete`

Config comes from **language data**, and quote-handling uses the **tree**:

> `function config(state, pos) { return state.languageDataAt<CloseBracketConfig>("closeBrackets", pos)[0] || defaults }`
> — closebrackets.ts

- `CloseBracketConfig`: `brackets` (default `["(","[","{","'",'"']`), `before` (chars after
  which auto-close fires, default `)]}:;>`), `stringPrefixes` (e.g. Python `r`/`f`).
- **Tree usage for quotes:** `probablyInString()`, `nodeStart()`, `canStartStringAt()` walk
  the tree to avoid closing a quote when already inside a string and to detect string
  prefixes. `insertBracket` dispatches to `handleOpen`/`handleClose`/`handleSame`.

**Verdict:** Pairs/config are pure language data (no tree). The *intelligent* quote
behavior (don't double-close inside a string) reads the tree but degrades gracefully.

## 6. HTML tag closing & tag matching (`@codemirror/lang-html`)

**Heavily tree-dependent.**

- **`autoCloseTags`** is an `inputHandler` for `>` and `/`. It calls
  `syntaxTree(state).resolveInner(head, -1)` and branches on node names (`EndTag`,
  `IncompleteCloseTag`, `CloseTag`, `OpenTag`). The tag name to insert comes from
  `elementName(doc, node, head)` reading the tree. Without the tree it cannot know the
  enclosing tag name.
- **Tag matching** via `bracketMatchingHandle.add({ "OpenTag CloseTag": node =>
  node.getChild("TagName") })` — reuses the bracket-matching tree machinery.
- **Nesting** (CSS/JS in `<style>`/`<script>`): `configureNesting(...)` + `parseMixed`.

**Verdict:** Tag auto-close/matching is one of the most tree-coupled features; no
character-scan fallback equivalent.

## 7. `languageData` (`EditorState.languageDataAt`) — the config seam

Mechanism: `defineLanguageFacet(baseData?)` creates a facet; values are objects of
arbitrary keys; `EditorState.languageDataAt<T>(name, pos, side?)` returns matching values.
In mixed documents the *active language at pos* is resolved through the tree's nested
mounts, so the right config wins automatically.

Features that resolve config through it:

| `languageData` key | Consumer | What it controls | Tree needed for the *config*? |
|---|---|---|---|
| `"commentTokens"` | `@codemirror/commands` comment cmds | `{line, block:{open,close}}` | No (only to pick language in mixed docs) |
| `"autocomplete"` | `@codemirror/autocomplete` | the completion source(s) | No (same caveat) |
| `"closeBrackets"` | `closeBrackets` | `CloseBracketConfig` | No |
| `"indentOnInput"` | `indentOnInput` | electric-reindent regex | No |
| `"wordChars"` | word-motion / `completeAnyWord` | extra word characters | No |

**Verdict:** `languageDataAt` is fundamentally a position->config map and does **not**
require a parser. The only tree linkage is *which* language is active at a position in a
nested document. A non-Lezer language (`StreamLanguage`) still defines a `languageData`
facet, so all of these keep working.

## 8. Comment toggling

`toggleComment`/`lineComment`/`blockComment`/`toggleBlockComment` read **`commentTokens`
from language data** — `{line: "//"}` or `{block: {open, close}}`. **No tree required.** In
a mixed document the tree only decides *which* comment tokens apply at the cursor.

## 9. Structural selection & syntax-tree navigation

**Tree-required.** `selectParentSyntax`:

```
let tree = syntaxTree(state), stack = tree.resolveStack(range.from, 1)
... walk cur = cur.next to find the smallest node properly containing the selection
return EditorSelection.range(node.to, node.from)
```

It resolves a **stack** at the cursor and walks outward to the next enclosing node. General
syntax navigation uses tree cursors / `resolveInner` / `resolveStack`. **No alternative
source** short of supplying your own tree-shaped structure. Outline/symbol info isn't a
built-in CM extension, but where editors build it they iterate the same Lezer tree.

## 10. Autocomplete: does it use the tree?

- **Source *selection*** is via language data, not the tree: `let sources = conf.override
  || state.languageDataAt("autocomplete", cur(state)).map(asSource)`. **No tree to pick
  the source.**
- **Whether an individual source *uses* the tree depends on the source:**
  - `completeFromList` / `completeAnyWord` / `CompletionContext.matchBefore` — **regex on
    text, no tree** (`matchBefore` scans within ~250 chars).
  - `ifIn` / `ifNotIn` — **use the tree**: walk `syntaxTree(...).resolveInner(...).parent`
    checking node names (e.g. only complete inside/outside a `String`/`Comment`).
  - `CompletionContext.tokenBefore` — reads the tree to find the preceding token.

**Verdict:** the autocomplete *engine* is tree-independent (source selection = language
data, matching = regex). Syntax-*aware* completion opts into the tree.

## 11. Lezer parsing characteristics (incremental, error recovery, scheduling)

**Incremental reparse.** Lezer keeps a cache of **tree fragments** (annotated with
intervening doc changes via `TreeFragment.applyChanges`) and reuses nodes covering
unchanged regions. `+`/`*` repeat operators are stored as **balanced sub-trees**, so
re-matching unchanged spans is cheap — but "even a tiny document change, if it changes the
meaning of the stuff that comes after it, can require a big part of the document to be
re-parsed."

**Error recovery (GLR).** Lezer is an incremental **GLR** parser that "can produce a tree
for any input." On error it runs recovery strategies in parallel (skip the current token,
or skip ahead to a matching token), wrapping ignored/skip regions in **error nodes**. GLR
splits are *opt-in* (annotated ambiguity points) so they don't proliferate.

**Scheduling — viewport-first, time-sliced.** From language.ts:

- `Language.extension` installs a `parseWorker` **ViewPlugin**. `LanguageState` wraps a
  `ParseContext` (fragments, current tree, parse length, viewport bounds, skipped regions).
- **Work budget constants** (approx.): `Apply = 20` ms (immediate work on a change),
  `MinSlice = 25` ms, `Slice = 100` ms, `ChunkBudget = 3000` ms per `ChunkTime = 30000` ms
  window, `MaxParseAhead = 1e5` (don't eagerly parse beyond viewport + margin).
- **Viewport-driven:** parses to `vpTo + (viewportFirst ? 0 : MaxParseAhead)`. Regions
  beyond the viewport are *skipped* (placeholder nodes) and reparsed on scroll.
- **Scheduling primitive:** `requestIdleCallback` when available, else `setTimeout`
  (~500 ms `MaxPause`). Parsing yields on `isInputPending()`.

**Query/force API:** `syntaxTree(state)`, `ensureSyntaxTree(state, upto, timeout?)`,
`syntaxTreeAvailable(state, upto?)`, `forceParsing(view, upto?, timeout?)`,
`syntaxParserRunning(view)`.

**Implication for an alternative core:** any replacement parser must supply the same
incremental-fragment + time-sliced + error-tolerant + viewport-skipping contract (Lezer's
`Parser`/`PartialParse` `startParse`/`advance`/`stoppedAt`) to plug into the scheduler —
this is the hardest part to replicate, independent of the tree-shaped features.

## 12. Language injection / nested & mixed-language parsing

Mechanism: **`parseMixed`** from `@lezer/common`, applied as the outer parser's `wrap`.
After the outer parse it scans for nodes that host another language and **mounts** an inner
tree. Two mount kinds:

- **Regular mount** — replaces the node with the inner tree's root (strictly-nested langs).
- **Overlay** — replaces only *parts* of a node with inner content (array of ranges, or a
  predicate per descendant). For non-hierarchical nesting (templating <-> output).

**HTML -> CSS/JS:** `lang-html` uses `parseMixed(node => node.name == "ScriptText" ?
{parser: jsParser} : ...)`; `configureNesting` selects the parser by tag/attribute.

**Markdown -> fenced code:** `@lezer/markdown`'s `parseCode` builds a `parseMixed` `wrap`.
For a `FencedCode` node it returns `{parser, overlay: node => node.type.id == Type.CodeText,
...}` — an **overlay over `CodeText` only**, so the fences are excluded. The info-string is
read from the `CodeInfo` child and passed to `codeParser(info)`. At the CodeMirror layer,
`lang-markdown`'s `codeLanguages` (array or function) resolves it via
`LanguageDescription.matchLanguageName`, returning a loaded parser or
`ParseContext.getSkippingParser(found.load())` (lazy async load, region skipped until
loaded).

**Why this matters for `languageDataAt`:** because the inner language is **mounted into the
tree**, `EditorState.languageDataAt(name, pos)` returns the *inner* language's config inside
the fenced block / `<script>` — so comment tokens, autocomplete, indentation, and
close-brackets automatically switch. **This is the one place the tree is load-bearing for
language-data features.**

**Verdict:** Mixed-language is intrinsically tree-based (mounts live in the tree). It's the
mechanism that makes the *config* features behave correctly in polyglot docs.

## 13. Non-Lezer alternative: `StreamLanguage`

CodeMirror ships `StreamLanguage` (the CM5-style line tokenizer adapter) as the official
non-Lezer path. It produces a **flat token stream, not a structured tree** — "mostly just
tokenizers ... quickly break down when you need more than tokenizing, for example to
distinguish type names from variable names." Keeps highlighting + language-data config;
loses/degrades structural selection, rich `indentNodeProp`/`foldNodeProp`, tag matching,
syntax-aware completion.

## Summary table: tied to the Lezer tree?

| Capability | Default mechanism | Strictly needs tree? | Tree-free alternative |
|---|---|---|---|
| Syntax highlighting | `styleTags` on nodes | Default yes | Stream tokenizer (`StreamLanguage`) |
| Code folding | `foldNodeProp` | **No** | `foldService` facet (text/indent) |
| Auto-indentation | `indentNodeProp` | **No** | `indentService` facet |
| Indent-on-input (electric) | language data + `getIndentation` | No (config) | language-data regex + `indentService` |
| Bracket matching | `openedBy`/`closedBy` + handle | No (degrades) | `matchPlainBrackets` char scan |
| Auto-close brackets | `closeBrackets` language data | No for pairs; quotes use tree | language data only |
| HTML tag auto-close/match | `syntaxTree.resolveInner` + names | **Yes** | none built-in |
| Comment toggling | `commentTokens` language data | **No** | language data only |
| Structural selection | `resolveStack` walk | **Yes** | none (needs tree) |
| Syntax navigation / cursors | `@lezer/common` `Tree` | **Yes** | supply your own tree |
| Autocomplete *source selection* | `languageDataAt("autocomplete")` | **No** | language data only |
| Autocomplete `ifIn`/`ifNotIn` | `syntaxTree.resolveInner` | **Yes** (opt-in) | text-only sources don't need it |
| Mixed/nested languages | `parseMixed` mounts | **Yes** | none (mounts are tree-native) |
| `languageDataAt` resolution | position->config facet | No alone; tree picks lang in mixed | single-language: no tree |
| Incremental/error-tolerant/time-sliced parse | Lezer `Parser` + CM scheduler | **Yes** (this IS the parser contract) | any parser implementing `startParse`/`advance` |

**Bottom line:** the *config-shaped* features (comments, close-bracket pairs, autocomplete
source selection, word chars, indent-on-input triggers) ride on `languageData` and need no
parser. The *line-local* structural features (folding, indentation) have official tree-free
service facets. The genuinely tree-bound features: structural selection, syntax navigation,
syntax-aware completion, HTML tag auto-close/match, bracket disambiguation, and — most
importantly — **mixed-language mounting** plus the **incremental/error-recovering/time-sliced
parse contract** itself.

## Sources
- CM reference: codemirror.net/docs/ref/#language ; codemirror.net/docs/ref/ ;
  codemirror.net/examples/lang-package/ ; codemirror.net/examples/mixed-language/
- Source: github.com/codemirror/language (language.ts, fold.ts, indent.ts, matchbrackets.ts,
  stream-parser.ts) ; github.com/codemirror/autocomplete (closebrackets.ts, completion.ts,
  state.ts) ; github.com/codemirror/commands (commands.ts) ;
  github.com/codemirror/lang-html (html.ts) ; github.com/codemirror/lang-markdown
  (markdown.ts) ; github.com/lezer-parser/markdown (nest.ts)
- Lezer: lezer.codemirror.net/docs/guide/ ; lezer.codemirror.net/docs/ref/
- DeepWiki: deepwiki.com/codemirror/language ; deepwiki.com/lezer-parser/markdown
- discuss.codemirror.net: "indentation and folding without a language" ; "how CM6 schedules
  parsing" ; "way to customize error recovery just a bit"
- github.com/codemirror/dev#1483 (stream-indent limits when nested)

Note: a few exact constants in §11 (e.g. `MaxPause` ~500 ms) are paraphrased from extracted
source readings rather than copied verbatim — treat the *behavior* as confident and the
*literal numbers* as best-effort from current `main` of `language.ts`.
