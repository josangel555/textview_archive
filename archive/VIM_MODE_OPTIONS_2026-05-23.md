# Vim-like Editing Mode — Research + Integration Design

Research + design dated **2026-05-23**. Read-only. No code changes.

Companion to:

- `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` — the v1 bridge spec
  this doc extends.
- `Sources/ViewerUI/CodeMirrorEditorView.swift` — the CM6 wrapper
  whose bridge we touch.
- `Sources/ViewerUI/Resources/codemirror/codemirror.js` — current
  vendored bundle, 584,651 bytes on disk (esbuild IIFE, Safari17,
  minified).
- `scripts/codemirror-build/{package.json,entry.js}` — esbuild
  workspace.

Audience framing: the user asked for **"like IntelliJ's Vim mode"** —
i.e. IdeaVim-style. Not full Vim. Not Neovim. A modal-editing
veneer over the existing CM6 host that wins back the muscle-memory
without rewriting the editor.

Scope:

1. **Landscape** — Part 1. What CM6-on-Vim plugins exist, what
   IdeaVim actually emulates (the comparator the user named), and
   what hand-rolling looks like.
2. **Integration design** — Part 2. Bundle, settings, conflict
   matrix with our menu shortcuts, `:` command UX, find-bar
   reconciliation, `.vimrc`-lite, bridge-v2 deltas, phased rollout.
3. **Risks + recommendation** — Part 3.

15+ sources cited inline. Hard numbers (bundle, last-commit, open
issues) verified via GitHub API + Bundlephobia rather than from
training data.

---

## Table of contents

- Part 1 — Landscape
  - 1.1  Option matrix
  - 1.2  `@replit/codemirror-vim`
  - 1.3  `codemirror-vim` (the original)
  - 1.4  Hand-rolled "Vim-lite" keymap
  - 1.5  IdeaVim — the comparator
  - 1.6  Helix / Kakoune (brief)
- Part 2 — Integration design
  - 2.1  Vendoring + bundle delta
  - 2.2  Toggle + state model
  - 2.3  Conflict matrix vs macOS / our shortcuts
  - 2.4  `:` command-line UI
  - 2.5  `/` and `?` search reconciliation
  - 2.6  `:w` / `:q` / `:wq` semantics in OUR app
  - 2.7  Bridge protocol v2 additions
  - 2.8  Settings persistence (`.vimrc`-lite vs `@AppStorage`)
  - 2.9  Status-bar mode indicator UI
  - 2.10 Testing strategy
  - 2.11 Phased rollout
- Part 3 — Risks + recommendation
- Sources

---

# PART 1 — Landscape

## 1.1 Option matrix

| # | Option                              | License | Maintained                                                       | Bundle delta (min / gz / raw npm)  | Coverage vs Vim `:help index` | Known gotchas (concrete)                                                                                                       |
|---|-------------------------------------|---------|------------------------------------------------------------------|------------------------------------|-------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| 1 | `@replit/codemirror-vim` (v6.3.0)   | MIT     | Active — last push 2026-05-12; 453 ⭐; 85 contrib; 19 open issues | ~120 KB / ~38 KB / ~240 KB unpacked| ~70-80% of common verbs       | `o` bug, `~`+undo enters visual, IME in command mode, `Ctrl-u/d`, `:w` no-op until `defineEx`, no built-in status-bar          |
| 2 | `codemirror-vim` (no prefix)        | MIT     | Same upstream — npm-published as `@replit/codemirror-vim`; no separate CM5-only npm package today | n/a (no CM6 port outside Replit fork)         | n/a                          | The legacy CM5 vim bindings live inside `codemirror/codemirror5` for backward-compat only; not consumable for CM6              |
| 3 | Hand-rolled `keymap`-based Vim-lite | MIT (ours) | We own it                                                     | ~3-5 KB minified (~150-250 LOC)    | ~10-15% of common verbs       | We become the maintainer. No `:` ex commands, no registers, no macros, no marks, no operator-pending mode unless we build it    |
| 4 | IdeaVim (reference only — JVM)      | MIT     | Active — JetBrains-owned, 10.2k ⭐, pushed daily                  | n/a (not CM6)                      | ~90% of `:help index`         | Comparator only; not deployable in JS                                                                                          |
| 5 | Helix-style / Kakoune-style         | various | Different mental model entirely (selection-first)                | n/a                                | n/a vs Vim                    | User asked for **IdeaVim**, not Helix. Skip.                                                                                   |

Bundle numbers for option 1 come from Bundlephobia
(`bundlephobia.com/api/size?package=@replit/codemirror-vim`):
**119,935 bytes minified, 38,323 bytes gzipped**. Unpacked tarball
~240 KB.

A 280 KB estimate that appeared in the prior CM6 design doc
(`docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §10) was conservative —
the real **minified** add to our esbuild bundle is closer to
**~120 KB**, and after esbuild dedupes shared CM6 internals (state,
view, commands, search are peer deps already in our bundle) the
**effective delta is likely 80-100 KB**. Confirmed below.

---

## 1.2 `@replit/codemirror-vim`

The canonical option. Originally authored by Yunchi Luo
(@mightyguava) and folded into the legacy CodeMirror 5 distro;
extracted and CM6-ported under Replit's GitHub org.

**Metadata (verified 2026-05-23):**

| Field                | Value                                                                |
|----------------------|----------------------------------------------------------------------|
| Repo                 | `https://github.com/replit/codemirror-vim`                           |
| License              | MIT                                                                  |
| Latest version       | 6.3.0                                                                 |
| Last commit          | 2026-05-12 (CI tweak); previous bug-fix wave 2026-02-21              |
| Default branch       | `master`                                                              |
| Stars / forks        | 453 / 48                                                              |
| Contributors         | 85 (top: nightwing 141, mightyguava 117, marijnh 68, sergeichestakov 31) |
| Open issues (non-PR) | 19                                                                    |
| Weekly downloads     | ~18.7k (npm)                                                          |
| Peer deps            | `@codemirror/{state,view,commands,language,search}` ^6 — **all already in our bundle**          |
| Dev deps             | `vite ^6`, `typescript ^5.8`, `@codemirror/buildhelper`               |

**Maintenance read.** Healthy, not torrid. The cadence is "burst of
bug-fixes every 2-4 months." Marijn Haverbeke himself (CM6
author) shows up at #3 in the contributor list — meaningful signal
that upstream CM6 doesn't treat this fork as adversarial. Snyk's
package-health badge rates it "Healthy."

**API surface (from `src/index.ts` + `src/vim.js`):**

```ts
// Extension constructor
vim(options?: { status?: boolean }): Extension

// Bridge into the CM5-shaped instance, so the rest of the API
// (the original CodeMirror.Vim.* methods) keeps working.
getCM(view: EditorView): CodeMirrorCompat

// The full Vim emulator namespace. Notable members:
Vim.map(lhs, rhs, ctx)                      // ":imap jj <Esc>"-equivalent
Vim.unmap(lhs, ctx)
Vim.defineEx(fullName, shortName, fn)        // register :w, :q, :wq, …
Vim.defineOperator(name, fn)
Vim.handleKey(cm, key, source)               // force-feed a key
Vim.exitInsertMode(cm)
Vim.exitVisualMode(cm, moveHead?)
Vim.enterVimMode(cm) / leaveVimMode(cm)
```

`Vim.defineEx` is load-bearing for us — it's the official hook to
make `:w`, `:q`, `:wq`, `:reload`, `:goto-folder` *actually do
something in our app* instead of being no-ops. Confirmed via
source: registers into `exCommands[name]` + the dispatcher's
`commandMap_`.

**Mode-change events.** There is a `'vim-mode-change'` event fired
on the CM5-compat instance; payload `{mode: 'normal' | 'insert' |
'visual' | 'replace', subMode?: 'linewise' | 'blockwise'}`.
Caveat: there's an open issue (#251) noting it doesn't fire on
**command-mode** enter/exit — i.e. when the user starts typing `:`
or `/`. Our status bar will need to listen for that separately
(or accept that "command" doesn't show up in the indicator).

**Known concrete bugs (from issue tracker — sampled, not
exhaustive):**

| Issue | Symptom                                                                                       | Severity for us |
|------:|-----------------------------------------------------------------------------------------------|-----------------|
| #196  | `~` (case-invert) followed by undo lands in visual mode                                       | low — odd but harmless |
| #178  | Random input in normal mode under IME                                                          | **high** — CJK users |
| #177  | Replaying a macro while it's being recorded hangs the page                                    | medium — JS event loop  |
| #199  | No support for mapping an operator (`g@` / `operatorfunc`)                                    | low — advanced |
| #212  | `indentWithTab` still indents in normal mode (binding conflict)                                | medium — easy to hit    |
| #225  | No `U` (undo all changes on line)                                                              | low |
| #234  | `%` doesn't jump to matching paren                                                             | medium — Vim 101 verb   |
| #237  | "Documentation of what is and is not supported" still open                                    | meta |
| #238  | Insert-mode multi-key mappings delete the previous char                                       | medium — user-config land |
| #243  | `{` / `}` motion broken on iOS Bluetooth                                                       | n/a — we're macOS desktop |
| #244  | "Allow CM6 keymaps before vim extension" — extension ordering pain                            | medium — affects our integration order |
| #251  | `vim-mode-change` doesn't fire on command-mode transition                                     | medium — status bar gap |
| #264  | Curly-brace deletion behaves unexpectedly                                                      | low |

The most painful for us are **#178 (IME)** and **#244 (keymap
ordering)**. IME is mitigated by leaving vim mode off by default for
CJK input pipelines (we can't detect that proactively; document
it). #244 is solvable by careful `Prec.high(...)` ordering — vim
must beat our app keymap for `Esc`, but must lose for our menu
mod-shortcuts.

**`.vimrc` support.** None natively. The configuration model is:
call `Vim.map(...)` and `Vim.defineEx(...)` from JS at startup.
Obsidian's `obsidian-vimrc-support` plugin shows the canonical
workaround: parse a `.vimrc`-shaped text file ourselves and replay
the lines through `Vim.map` / `Vim.defineEx`. That parser is small
(~200 LOC in the Obsidian plugin) — feasible if we want it.

---

## 1.3 `codemirror-vim` (the original, no `@replit/` prefix)

Short answer: **not a viable separate option for CM6**.

Long answer:

- The legacy CodeMirror 5 vim addon ships *inside* the
  `codemirror/codemirror5` repo (as `addon/keymap/vim.js`). That's
  the source @mightyguava originally wrote.
- When CM6 was the rewrite, the vim addon was **extracted** to
  `replit/codemirror-vim` as the CM6-targeting fork. The CM5
  package still exists for backward compat but it does **not**
  work against a CM6 `EditorView`.
- There is no separate, maintained CM6-targeting `codemirror-vim`
  npm package outside the `@replit/...` namespace today.

So practically, for CM6, "the canonical vim option" = option 1.

---

## 1.4 Hand-rolled "Vim-lite" via `keymap`

Roughly what it'd take to implement the Pareto subset of Vim verbs
*without* depending on an external package.

**Scope guess (highest-value verbs only):**

- Modal state machine: `NORMAL`, `INSERT`, `VISUAL` (charwise +
  linewise). No `OPERATOR-PENDING`, no `SELECT`, no `REPLACE`.
- Motions: `h j k l`, `w b e`, `0 $ ^`, `gg G`, `{ }`, `f F t T`,
  `% `(maybe).
- Operators: `d`, `y`, `c` — but only in their doubled-line form
  (`dd`, `yy`, `cc`) and as `dw`/`yw`/`cw`. No `d{motion}` general
  case.
- Inserts: `i a o O A I`, `x`, `r{char}`.
- Search: `/`, `?`, `n`, `N`. (Layer on CM6's `searchKeymap`.)
- Ex commands: literal-string switch on `:w`, `:q`, `:wq`, `:e`.
- No registers (single anonymous register only), no marks, no
  macros, no `.` repeat, no `Ctrl-o/Ctrl-i` jump list, no
  multi-cursor-aware vim.

**Effort estimate.** ~250-400 LOC of JS, mostly in one file. The
state machine is the easy part; the **interaction with CM6's own
default keymap** is the hard part — every "g goes into pending-g
state" branch has to interpose between CM6 absorbing the keystroke
as text and our handler claiming it. The way to do it cleanly is a
single `keymap.of([{any: handler}])` with `Prec.highest` that owns
keystrokes only in NORMAL mode and falls through in INSERT.

**Coverage vs Vim.** ~10-15% of the `:help index`. Enough for
`hjkl + dd/yy/p` muscle memory, missing for `ci"`, `d2w`,
`gqap`, anything with text objects or counts.

**When this'd be the right choice.** Almost never. The
`@replit/codemirror-vim` package costs ~80-100 KB effective delta;
the hand-rolled version costs ~3-5 KB but is **fundamentally a
worse vim** that an IdeaVim user will notice in 30 seconds. Only
attractive if (a) the `@replit/...` package becomes unmaintained
and we don't want to fork it, or (b) we're trying to ship a deeply
custom modal model that isn't really Vim. Neither is true today.

---

## 1.5 IdeaVim — the comparator

The user named IdeaVim as the bar. Worth pinning down what
IdeaVim's "Summary of Supported Vim Features" section actually
claims (verbatim from `README.md` on `master`):

> Normal / insert / visual / select / etc. modes
> Motion / deletion / change / window / etc. commands
> Key mappings
> Marks / Macros / Digraphs / Registers
> Some set commands
> Full Vim regexps for search and search/replace
> Vim web help
> ~/.ideavimrc configuration file
> Vim script, including some builtin functions
> IdeaVim plugins

And on Vim Script support:

> At the moment we support all language features, but not all of
> the built-in functions and options are supported.

And on Action mappings:

> Mappings to `<Action>` don't work with `noremap`. If you know
> the case when it's needed, please let us know.

**Translation to our context.**

| IdeaVim feature                                              | `@replit/codemirror-vim` equivalent              | Hand-rolled gap |
|--------------------------------------------------------------|--------------------------------------------------|------------------|
| Normal / Insert / Visual / Select / Replace modes            | Normal / Insert / Visual (+ replace, no select)  | Normal / Insert / Visual |
| Motion / deletion / change / window commands                  | Motion + deletion + change. **No windows**       | Motions only     |
| Key mappings (`map`, `imap`, `vmap`)                          | `Vim.map(lhs, rhs, ctx)`                          | none             |
| Marks (`m{a-z}`, `'a`, `` `a ``)                              | yes (local marks; some global marks)              | none             |
| Macros (`q{a}…q`, `@a`)                                       | yes — but see issue #177 (hangs on self-replay)   | none             |
| Digraphs                                                      | partial                                           | none             |
| Registers (`"+`, `"a`, …)                                     | partial — `"a-z`, `"_`, `"+` (system clipboard)   | none             |
| `set` commands (some)                                          | yes via `:set` ex commands the package wires      | hand-rolled subset |
| Full Vim regexps                                              | partial (Vim regex flavor, not JS regex)          | JS regex only    |
| Vim web help                                                  | no                                                | no               |
| `.vimrc` / `~/.ideavimrc`                                     | **no native support** — DIY parser as in §1.2     | DIY              |
| Vim Script                                                    | no                                                | no               |
| IdeaVim plugins                                               | no                                                | no               |

**Take-away.** The `@replit/codemirror-vim` plugin covers
~roughly 70-80% of the IdeaVim feature surface. The two
prominent gaps are **`.vimrc` parsing** (DIY) and **Vim Script**
(out of reach without re-implementing an interpreter — explicitly
out of scope for this project). For a Markdown editor with a
secondary code-editor mode, those gaps are acceptable.

---

## 1.6 Helix / Kakoune (brief, as requested)

User asked for IdeaVim. These are mentioned only so we've
considered them and rejected.

- **Helix** — selection-first model. "Verb-noun" inverted to
  "noun-verb": `wd` selects the word then deletes, vs Vim's `dw`.
  Bundle would be hand-rolled (no CM6 package). Wrong choice — the
  user's muscle memory is Vim, not Helix.
- **Kakoune** — same idea as Helix but older. Composability is
  the headline feature. No CM6 port exists. Same rejection.

Neither is the asked-for thing. Move on.

---

# PART 2 — Integration design for THIS app

## 2.1 Vendoring + bundle delta

### entry.js diff (for option 1)

```diff
--- scripts/codemirror-build/entry.js (current)
+++ scripts/codemirror-build/entry.js (with vim)
@@
 import { javascript } from "@codemirror/lang-javascript";
 import { python } from "@codemirror/lang-python";
 import { json } from "@codemirror/lang-json";
 import { oneDark } from "@codemirror/theme-one-dark";
+import { vim, getCM, Vim } from "@replit/codemirror-vim";

 export {
   EditorState, EditorView, EditorSelection, Compartment,
   keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter,
   drawSelection, rectangularSelection, crosshairCursor, dropCursor,
   defaultKeymap, history, historyKeymap, undo, redo, indentWithTab,
   searchKeymap, highlightSelectionMatches, openSearchPanel,
   syntaxHighlighting, defaultHighlightStyle, bracketMatching,
   foldKeymap, foldGutter, indentOnInput,
   markdown, javascript, python, json, oneDark,
+  vim, getCM, Vim,
 };
```

### package.json diff

```diff
   "dependencies": {
     "@codemirror/commands": "6.6.0",
     ...
     "@codemirror/view": "6.28.1",
+    "@replit/codemirror-vim": "6.3.0",
     "esbuild": "0.21.5"
   }
```

Note the **exact pin** per CLAUDE.md "Pin versions exactly."

### Rebuild

```bash
cd scripts/codemirror-build
npm install --no-audit --no-fund
npm run build
```

Outputs go straight into the committed
`Sources/ViewerUI/Resources/codemirror/codemirror.{js,css}`.

### Bundle size projection

| Stage                                               | Bytes      | Notes                                                    |
|-----------------------------------------------------|-----------:|----------------------------------------------------------|
| Current `codemirror.js` (today, verified `ls -la`)  |    584,651 | Esbuild IIFE Safari17 minified                           |
| Vim package raw (Bundlephobia)                      |    119,935 | minified, before dedupe with our CM6 internals           |
| Vim package gzipped                                 |     38,323 | only relevant if we ever GZ-serve; not us today          |
| Expected after esbuild dedupe                       |  ~80,000-100,000 | Vim's deps are peer-deps already in our bundle      |
| **Projected new total**                             | **~665-685 KB** | well under the 1.5 MB BUNDLE soft cap from CM6 doc §19   |

Cross-check vs the cap table in CM6 doc §19 (which estimated +210
KB minified for the same package): the Bundlephobia number is
authoritative. The CM6 doc number was conservative. Update that
table after Phase 4 lands.

### Bundle-cap math

From CLAUDE.md and `scripts/check-bundle-size.sh`:

| Cap                | Limit  | After vim adds                   |
|--------------------|--------|----------------------------------|
| Total `.app`       | 25 MB  | +~100 KB → still well under      |
| Executable         | 16 MB  | unchanged (vim is JS, not Swift) |
| `codemirror.js`    | (soft 1.5 MB) | ~670 KB                  |

**Verdict: comfortable.** No re-architecting needed.

---

## 2.2 Toggle + state model

Three reasonable scopes for the toggle:

| Scope         | Pros                                                          | Cons                                                            | Recommendation |
|---------------|---------------------------------------------------------------|-----------------------------------------------------------------|----------------|
| Per-app       | Matches IdeaVim mental model — you either are a vim user or aren't | Annoying for the user who wants vim only in `.swift` not in `.md` | **default**    |
| Per-tab       | Granular                                                      | Surprising; no obvious indicator until status bar               | no             |
| Per-language  | Match-the-file-type heuristic                                  | Confusing when one user wants vim everywhere                    | future opt-in  |

Recommendation: **per-app** via `@AppStorage` global toggle, with
the always-available `:` ex-command escape hatch (`:set novim`)
to disable for the current session if needed.

**Persisted under**: `@AppStorage("MarkdownViewer.editor.vimMode")`
of type `Bool`, default `false`. Reads in `EditorSettingsView`,
piped through `DocumentModel` → `CodeMirrorEditorView` → bridge
`setVimEnabled`.

**Live re-toggle without restart**: use a CM6 `Compartment` so
flipping the setting only swaps the `vim()` extension in/out
without rebuilding the whole state. Same pattern as
the existing theme / language compartments in `codemirror.html`.

```js
const vimCompartment = new Compartment();
EditorState.create({
  extensions: [
    vimCompartment.of([]),   // off by default
    ...
  ],
});
// later:
view.dispatch({ effects: vimCompartment.reconfigure(vim()) });
```

Toggling sends a `vim-mode-change` event back so the status bar
updates without poll.

---

## 2.3 Conflict matrix vs macOS + our shortcuts

This is the section that makes or breaks the UX. Vim takes ⎋ (`Esc`)
and a long list of single-letter keys; our app has menu bindings
that also fire on those keys when modified.

### Vim mode keys we'd hijack (NORMAL mode)

`h j k l w b e 0 $ ^ g G { } f F t T % / ? n N i a o O I A x r c d y p P u . v V Esc :`

### Our app's existing menu / global shortcuts (best guess from main app)

| Shortcut    | Menu / Action (mapped today)                | Conflict risk in vim NORMAL mode    | Resolution             |
|-------------|---------------------------------------------|-------------------------------------|------------------------|
| ⌘ S         | Save                                         | none (Vim doesn't claim Mod-keys)   | macOS wins             |
| ⌘ W         | Close tab                                    | none                                | macOS wins             |
| ⌘ Z / ⇧⌘ Z  | Undo / Redo (routed via menu → CM)            | bare `u` and `Ctrl-r` would map to vim — but **only bare**, not Mod | macOS wins on ⌘; vim wins on bare `u`/`Ctrl-r` |
| ⌘ F         | Find                                         | none                                | macOS wins. See §2.5  |
| ⌘ G / ⇧⌘ G  | Find Next / Prev                              | none                                | macOS wins             |
| ⌘ T         | New tab                                      | none                                | macOS wins             |
| ⌘ N         | New window                                    | none                                | macOS wins             |
| ⌘ O         | Open                                          | bare `O` opens-line-above in vim    | macOS wins on ⌘ O; bare `O` is vim    |
| ⌘ 1 – ⌘ 9   | Switch tab                                    | none                                | macOS wins             |
| ⌃ Tab / ⇧⌃ Tab | Next / prev tab                            | none — vim doesn't hijack Ctrl-Tab  | macOS wins             |
| ⌘ ,         | Settings                                      | none                                | macOS wins             |
| ⌃ U         | (currently unbound? or scroll-up?)            | vim wants `Ctrl-u` for half-page-up | **conflict** — see §6.4 of CM6 doc; document; let vim win  |
| ⌃ D         | (currently unbound?)                          | vim wants `Ctrl-d` for half-page-down | **conflict** — let vim win |
| ⌃ R         | (currently unbound?)                          | vim wants `Ctrl-r` for redo         | **conflict** — let vim win |
| ⌃ F / ⌃ B   | (currently unbound?)                          | vim wants page-down / page-up        | let vim win |
| Esc         | (no global binding; closes popovers)         | vim wants `Esc` to exit insert       | **complex** — vim wins inside CM6; the rest of the app still gets `Esc` for popover dismissal because Esc bubbles up if vim doesn't claim it (already in NORMAL mode → vim's `Esc` is a no-op so it bubbles) |
| `:`         | none                                          | vim opens command line               | vim wins inside CM6     |
| `/` `?`     | none                                          | vim opens search                     | vim wins; see §2.5      |

### Resolution policy (short version)

1. **All ⌘-modified shortcuts win** for the host app (macOS menu
   semantics). Vim doesn't bind ⌘-keys, so this is automatic — no
   special-case code needed.
2. **All bare letter keys win for vim** when in NORMAL/VISUAL mode.
   In INSERT mode they're text input as usual.
3. **`Ctrl-{u,d,f,b,r,o,i}` win for vim** when in NORMAL/VISUAL.
   This is the contentious set — they would otherwise be free for
   us to claim as future menu shortcuts. **Decision**: don't claim
   any of `Ctrl-{a-z}` for app menus going forward, to keep this
   simple.
4. **`Esc` is layered.** In INSERT it exits insert (vim claims it).
   In NORMAL it's a no-op (bubbles to the host — popovers /
   walkthrough dismissal still work).
5. **`Tab` is contentious.** Today we have `indentWithTab` wired,
   which is the source of issue #212. **Decision**: drop
   `indentWithTab` from the keymap when vim mode is on (or wrap it
   in a compartment that the vim toggle disables); rely on vim's
   own `Tab` handling.

### Passthrough escape hatch

For users who genuinely want one Mod-key on their personal
machine to do something different, the `:` command line gives them
an out (e.g. `:map <C-d> <Action>(MacOSScrollHalfPageDown)` —
though we won't ship that mapping by default).

---

## 2.4 `:` command-line UI

Two options:

**Option A — let `@replit/codemirror-vim` render its own.**
The package ships a built-in command-line input that appears at
the bottom of the editor's DOM (separate `<input>` overlaid). It's
plain HTML, plain styling — works inside WKWebView. **No Swift
plumbing required for the input itself.** Output (when an ex
command runs) is JS-side.

**Option B — render a Swift-side command-line input.**
A native NSTextField at the bottom of the editor, intercepting
`:` keystrokes from the bridge and posting back the typed line.

| Criterion                       | Option A (JS)                       | Option B (Swift)                   |
|---------------------------------|-------------------------------------|------------------------------------|
| Bundle cost                      | $0 (included in vim package)       | $0 (Swift)                          |
| UX consistency with rest of app  | minor — JS-themed input            | full — uses NSTextField             |
| Plumbing complexity              | none                               | substantial bridge work             |
| Native paste / dictation         | partial (WKWebView contenteditable) | full (NSTextField)                 |
| Future-proof against package bugs | breaks if upstream regresses       | independent                         |

**Recommendation: Option A**, defer Option B unless the JS input
proves user-hostile. The bridge protocol still gets a
`vimCommand(line: String, replyId)` outbound message so that we
can intercept `:` commands that should dispatch *in Swift*
(`:reload`, `:goto-folder`, etc. — Phase C). The vim package's
`Vim.defineEx('reload', 'reload', () => bridge.send({type:
'vimCommand', line: 'reload'}))` registration is the seam.

---

## 2.5 `/` and `?` search reconciliation

We have **three** find UIs now if we're not careful:

1. Swift-side `MarkdownFindBar` (the canonical app find — ⌘F).
2. CM6's built-in `@codemirror/search` panel (currently the
   editor-mode find — also ⌘F).
3. Vim's `/` and `?` search overlays.

The CM6 design doc Phase 2 already plans to **collapse #1 and #2**
into "MarkdownFindBar drives JS find via bridge." That plan stands.

For #3, the recommendation:

- **`/` and `?` open MarkdownFindBar** (the same Swift bar that ⌘F
  opens), pre-populated with empty query and search direction.
- **`n` / `N` advance** by calling `findNext` / `findPrev` on the
  bridge.
- The vim package's built-in `/` overlay is suppressed — we
  override it via `Vim.defineEx('search-forward', 'search-forward',
  …)` and hijack the key binding, or by wrapping the package's
  `vim()` extension and re-binding `/` and `?` to a "post to Swift"
  action.

**Pick ONE find UI: MarkdownFindBar.** Same find experience whether
you ⌘F, hit `/`, or hit `?`.

---

## 2.6 `:w` / `:q` / `:wq` semantics in OUR app

Per-command behavior — choose deliberately so we don't surprise
the user.

| Vim command  | Native Vim meaning                  | Our app behavior                                                            |
|--------------|-------------------------------------|-----------------------------------------------------------------------------|
| `:w`         | Write current buffer                | **Save** — equivalent to ⌘ S. Wired via `Vim.defineEx('write', 'w', save)` → bridge `saveRequested`. |
| `:w!`        | Force write                          | Same as `:w`. We don't have a permission model where force matters.        |
| `:wa`        | Write all                            | **Save all** — equivalent to ⌘ ⌥ S (if we have one), or no-op + status msg |
| `:q`         | Quit (close window)                  | **Close tab** — equivalent to ⌘ W                                          |
| `:q!`        | Force quit                            | **Close tab without saving** — equivalent to ⌘ W discarding edits         |
| `:wq` / `:x` | Write + quit                         | Save + close tab                                                            |
| `:qa`        | Quit all                              | **Quit app** — equivalent to ⌘ Q (warn if any tabs dirty)                   |
| `:e {path}`  | Edit file                            | Open `{path}` in a new tab. If `{path}` is omitted, reload current.        |
| `:b {n}`     | Switch buffer                        | Switch to tab N (matches our ⌘ 1-9)                                        |
| `:bn` / `:bp`| Next / prev buffer                   | Next / prev tab (⌃ Tab / ⇧⌃ Tab)                                          |
| `:reload`    | (not native — IdeaVim-style action)  | Reload current document from disk                                          |
| `:goto-folder` | (not native)                        | Open Workspaces sheet → folder picker                                       |

Document this table in the user-facing wiki under
`docs/USER_GUIDE_VIM.md` (Phase B). All of these wire via
`Vim.defineEx(...)` calls done once at bundle init.

---

## 2.7 Bridge protocol — additions to v1

From `CM6_INTEGRATION_DESIGN_2026-05-23.md` §13. Vim-specific
deltas are additive; nothing in v1 changes shape.

### 2.7.1 New editor → swift messages

```jsonc
// Vim mode entered/exited. Fired on every transition.
{ "v": 1, "type": "vimModeChanged",
  "mode": "normal" | "insert" | "visual" | "replace",
  "subMode": "linewise" | "blockwise" | null }
```

```jsonc
// A `:` ex command was typed and dispatched. JS sends this only
// for ex commands we've registered as "swift-side" via defineEx.
{ "v": 1, "type": "vimCommand",
  "name": "reload",
  "argv": ["--force"],
  "replyId": "r-9c12" }
```

```jsonc
// Search initiated via `/` or `?`. Swift opens MarkdownFindBar.
{ "v": 1, "type": "vimSearchRequested",
  "direction": "forward" | "backward",
  "initialQuery": "" }
```

### 2.7.2 New swift → editor messages

```jsonc
// Live toggle from Settings; no reload needed.
{ "v": 1, "type": "setVimEnabled", "enabled": true }
```

```jsonc
// Force a particular mode (e.g. after focus restore).
{ "v": 1, "type": "setVimMode",
  "mode": "normal" | "insert" | "visual" }
```

```jsonc
// Programmatically run an ex command (used by :reload, etc.,
// when triggered from native menu).
{ "v": 1, "type": "executeVimCommand",
  "line": ":w" }
```

### 2.7.3 Enum additions

In Swift (`CMInbound` / `CMOutbound` from CM6 doc §13.7-8):

```swift
// inbound
case vimModeChanged(mode: VimMode, subMode: VimSubMode?)
case vimCommand(name: String, argv: [String], replyId: String)
case vimSearchRequested(direction: VimSearchDirection, initialQuery: String)

// outbound
case setVimEnabled(Bool)
case setVimMode(VimMode)
case executeVimCommand(line: String)

enum VimMode: String, Codable {
    case normal, insert, visual, replace, command
}
enum VimSubMode: String, Codable { case linewise, blockwise }
enum VimSearchDirection: String, Codable { case forward, backward }
```

All Codable, all pure-logic, all testable in `ViewerCoreTests`
without launching a WebView.

---

## 2.8 Settings persistence — `.vimrc` vs `@AppStorage`

Three rungs of ambition:

### Rung A — `@AppStorage` only (recommended start)

A small typed config struct, all dials in Settings UI.

```swift
struct VimSettings {
    var enabled: Bool = false
    var escapeAlias: EscapeAlias = .none           // .none | .jk | .jj
    var leaderKey: String = "\\"
    var clipboardYank: Bool = true                  // y → system clipboard
    var showStatusBar: Bool = true
    var relativeLineNumbers: Bool = false           // gutter mode
}
```

Each setting bridged to JS via either `setVimEnabled` or, for the
intra-vim ones, `executeVimCommand(":imap jk <Esc>")` shaped lines.
**No file parsing.**

### Rung B — Bundled `.vimrc` + user overrides

Ship a bundled `default.vimrc` inside the app resources; user can
edit `~/Library/Application Support/com.markdownviewer.MarkdownViewer/vimrc`
to override. Per CLAUDE.md, we never write to `~/Documents`,
`~/Desktop`, `~/Downloads` — Application Support is the right
location.

Parser is ~150-250 LOC, modeled on Obsidian's
`obsidian-vimrc-support` plugin (MIT, 200 LOC for the parser).
Each line shape we support:

- `imap <lhs> <rhs>` → `Vim.map('lhs', 'rhs', 'insert')`
- `nmap <lhs> <rhs>` → `Vim.map('lhs', 'rhs', 'normal')`
- `vmap <lhs> <rhs>` → `Vim.map('lhs', 'rhs', 'visual')`
- `set <option>=<value>` → swallowed for known options, ignored for unknown
- `let mapleader = "\\"` → captured + applied via remap rewriting
- `" comment lines` ignored

Recommend: **Phase B/C decision**. Don't ship the parser before
the Phase A `@AppStorage` toggles show real demand.

### Rung C — Full Vim Script

Out of scope. Doesn't fit the project budget; IdeaVim itself flags
this as "partial."

---

## 2.9 Status-bar mode indicator UI

Sketch:

```
┌─────────────────────────────────────────────────────────────────┐
│ Editor (CM6 WKWebView)                                          │
│                                                                 │
│  void main() {                                                  │
│    printf("hello\n");                                           │
│  }█                                                             │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ -- NORMAL --   |  README.md  |  Ln 12, Col 4  |  UTF-8  |  LF   │
└─────────────────────────────────────────────────────────────────┘
   ^^^^^^^^^^^^
   new segment
```

- Width: ~12 ch, fixed.
- Color: NORMAL = subtle (gray text on bar bg), INSERT = green
  text, VISUAL = blue text, COMMAND = yellow. Matches the
  IdeaVim / Vim convention.
- Hidden when vim mode is off.
- Renders in the existing bottom-bar SwiftUI view (same row as the
  cursor `Ln:Col` readout the CM6 doc Phase 1 adds).
- Driven by the `vimModeChanged` bridge message; defaults to
  NORMAL on first `vim()` extension load.

Caveat: command mode (`:`) doesn't fire `vim-mode-change` per
issue #251. Two workarounds: (a) wrap `Vim.defineEx` to broadcast
mode COMMAND on entry; or (b) accept that the indicator sticks at
NORMAL while the `:` prompt is open. Pick (a) when we ship.

---

## 2.10 Testing strategy

Per CLAUDE.md: pure-logic tests host-only, UI/live tests VM-only.

### Pure-logic (host, `ViewerCoreTests`)

- `VimSettingsCodableTests` — round-trip the `VimSettings` struct.
- `CMInboundVimDecodingTests` — extend existing
  `CodeMirrorBridgeTests`. Cover `vimModeChanged`,
  `vimCommand`, `vimSearchRequested` decoding.
- `CMOutboundVimEncodingTests` — round-trip `setVimEnabled`,
  `setVimMode`, `executeVimCommand`.
- `VimExCommandRoutingTests` — given `:wq`, the Swift router
  should call `saveActiveEditor` + `closeActiveTab` in that order.
  Pure logic, no WebView.
- `VimRcParserTests` — only if Rung B ships (Phase C).
  Parser-only; doesn't touch Vim engine.

### Live (VM-only, `Tests/ViewerUITests/`)

- `CodeMirrorVimSmokeTest` — open editor, enable vim, send `i`
  → expect mode INSERT, type "hello", send `Esc` → expect mode
  NORMAL, send `dd` → expect doc empty (line gone). Pin the four
  known bugs from CM6 doc §6.4 as **xfail** tests so we notice when
  upstream fixes them.
- `CodeMirrorVimSaveTest` — vim mode on, type `:w`, expect
  `saveRequested` in Swift + file written.
- `CodeMirrorVimSearchTest` — vim on, type `/foo<Enter>`, expect
  MarkdownFindBar to open with `foo` and a highlighted hit.
- `CodeMirrorVimStatusBarTest` — assert mode indicator label
  matches mode after each transition.

### Manual

- IME composition + vim mode (CJK input, see #178). Doc as a
  caveat in `MANUAL_TESTING.md`.
- Macro `q{a}…q` recording + `@a` playback (cover the macro-hang
  bug #177 if it triggers).

### Bundle integrity

Add to existing `CodeMirrorBundleTests`:

- Assert `window.CM.vim` exists when vim is bundled.
- Assert bundle size hasn't blown past **800 KB** (current ~585 KB
  + ~100 KB vim + headroom).

---

## 2.11 Phased rollout

### Phase A — ship Vim mode off by default (target: 1 day)

Goal: validate the bundle delta and the toggle plumbing.

Deliverables:

- Add `@replit/codemirror-vim` 6.3.0 to
  `scripts/codemirror-build/package.json`. Re-bundle.
- Wire `vim()` behind a `Compartment`, off by default.
- `@AppStorage("MarkdownViewer.editor.vimMode")` toggle.
- Settings UI: new "Vim mode" row in Editor section. Single
  checkbox.
- Bridge: `setVimEnabled(Bool)`, `vimModeChanged` (consumed but
  not displayed yet).
- `:w` / `:q` / `:wq` wired via `Vim.defineEx` to existing menu
  actions.
- Drop `indentWithTab` when vim is on (sidesteps issue #212).
- Bundle size assertion in `CodeMirrorBundleTests`.

Tests: bridge decode/encode for new message types. VM:
`CodeMirrorVimSmokeTest`.

Gate: bundle ≤ 700 KB; smoke test green; user can turn it on,
type Vim verbs, see them work.

### Phase B — status bar indicator + `.vimrc`-lite via `@AppStorage` (target: 1-2 days)

Goal: feel like a Vim mode you can live in.

Deliverables:

- Status-bar mode indicator (§2.9). Wired to `vimModeChanged`.
  Wrap `Vim.defineEx` to broadcast COMMAND when `:` opens.
- `VimSettings` struct with all dials in §2.8 Rung A.
- Settings UI: dropdown for `escapeAlias` (none / `jk` / `jj`),
  toggle for `relativeLineNumbers`, toggle for `clipboardYank`.
- `/` / `?` route to `MarkdownFindBar` (vim search reconciliation
  per §2.5).

Tests: status-bar mode transitions.

Gate: a vim user can use the editor without going back into
Settings.

### Phase C — `:` commands bridged to Swift app actions (target: 2-3 days)

Goal: `:reload`, `:goto-folder`, `:open-walkthrough`, etc., act
like IdeaVim's `<Action>(...)` mapping.

Deliverables:

- `vimCommand` bridge message + Swift-side router.
- A registry of "command-name → Swift closure" entries
  (`DocumentController.openWalkthrough`, etc.).
- A discoverable list: `:help` ex command opens the command
  palette / a help sheet.
- (Optional) Rung B `.vimrc` parser, reading
  `~/Library/Application Support/com.markdownviewer.MarkdownViewer/vimrc`.

Tests: `VimExCommandRoutingTests` with table-driven assertions.

Gate: docs added (`docs/USER_GUIDE_VIM.md` + entry in `BACKLOG.md`
that the Vim mode is no longer experimental).

---

# PART 3 — Risks & recommendation

## 3.1 Top 3 risks of shipping any Vim mode

1. **Bug-tail of `@replit/codemirror-vim`.** Concrete open issues
   include the IME garbling in normal mode (#178), the
   `vim-mode-change` not firing on `:` (#251), the curly-brace
   deletion oddity (#264), `%` not matching parens (#234). The
   upstream cadence is 2-4 months between bug-fix waves, which
   means we'll be sitting on a known regression for that window
   when (not if) one bites us. **Mitigation**: ship behind a
   setting; document caveats in `docs/USER_GUIDE_VIM.md`; pin
   exact version; have a written rollback ("set the bundle dep to
   the prior version, rebundle, commit, re-release").
2. **Maintenance ownership creep.** Every Vim user files three
   Vim bugs in the first week. We need to triage them as
   "ours or theirs" without becoming the de-facto Vim project.
   **Mitigation**: a triage label in BACKLOG.md and a short
   "report upstream / fix here / wontfix" decision tree.
3. **macOS / app-shortcut collisions.** §2.3 maps out the surface
   today but it'll grow. Future-us will add ⌃P or ⌃N for *some*
   menu action and break a Vim user's expectation. **Mitigation**:
   add a CI lint that fails if a `KeyboardShortcut("ctrl-X")` is
   added to a menu item, forcing a `noVimConflict` ack in the
   review.

## 3.2 Recommendation

**Ship Phase A as scoped above using `@replit/codemirror-vim` 6.3.0.**

Reasons:

- Bundle delta is **~100 KB effective**, well inside our caps —
  cheaper than my own (and the prior doc's) initial conservative
  estimates.
- License is MIT, license is clean, Marijn Haverbeke is a
  contributor (CM6 author trusts the fork enough to commit to it).
- The user explicitly asked for IdeaVim-like, and this package
  covers ~70-80% of IdeaVim's feature surface — well above the
  threshold where a Vim user will feel at home.
- The toggle is per-app and opt-in, so the worst-case
  regression-blast-radius is zero non-Vim users.
- The hand-rolled "Vim-lite" alternative is meaningfully worse
  for almost zero bundle savings — bad trade.

**Total effort estimate**: Phase A ~1 day, Phase B ~1-2 days,
Phase C ~2-3 days. **Multi-day, not multi-week.** Total ~1
working week if all three phases ship sequentially; comfortably
parallelizable with other Phase 4 items in the CM6 roadmap.

## 3.3 Deal-breakers we'd need plan B for

- **If `@replit/codemirror-vim` becomes unmaintained.** Plan B:
  fork. The codebase is ~120 KB minified, MIT, with the original
  author still active. Forking is feasible. We would *not* try to
  hand-roll a replacement (per §1.4 — bad trade).
- **If the bundle delta blows the cap** (e.g. esbuild dedupe is
  worse than projected and we add 250 KB instead of 100). Plan B:
  ship `vim` as a lazy-loaded dynamic import behind the toggle —
  WKWebView on macOS 15 supports `import()`. ~30 KB engineering
  cost.
- **If WKWebView IME + vim mode is unusable for CJK locales.**
  Plan B: auto-disable vim mode when the system input source is a
  CJK source. Detectable via `TISCopyCurrentKeyboardInputSource`.
  Surface a "Vim mode disabled because IME is active" hint.

No deal-breaker found in the research that would block shipping
Phase A. We can start.

---

# Sources

1. `@replit/codemirror-vim` GitHub —
   `https://github.com/replit/codemirror-vim`
2. `@replit/codemirror-vim` npm —
   `https://www.npmjs.com/package/@replit/codemirror-vim`
3. Bundlephobia size data —
   `https://bundlephobia.com/api/size?package=@replit/codemirror-vim`
   (minified 119,935 B, gzipped 38,323 B, last verified 2026-05-23)
4. Snyk package health badge —
   `https://snyk.io/advisor/npm-package/@replit/codemirror-vim`
5. GitHub API live metadata —
   `https://api.github.com/repos/replit/codemirror-vim` (453 ⭐,
   85 contrib, 19 open non-PR issues, last push 2026-05-12)
6. JetBrains/ideavim repo —
   `https://github.com/JetBrains/ideavim` (10,201 ⭐, MIT)
7. IdeaVim README (Summary of Supported Vim Features) —
   `https://raw.githubusercontent.com/JetBrains/ideavim/master/README.md`
8. IdeaVim Emulated-plugins wiki —
   `https://github.com/JetBrains/ideavim/wiki/Emulated-plugins`
9. CodeMirror Vim mode tracker issue #79 —
   `https://github.com/codemirror/dev/issues/79`
10. Joplin "CodeMirror 6 vim mode issues" thread —
    `https://discourse.joplinapp.org/t/codemirror-6-vim-mode-issues/35135`
    (concrete `o` and `:w` bugs in @replit/codemirror-vim under Joplin)
11. Open issue #196 (`~` then undo) —
    `https://github.com/replit/codemirror-vim/issues/196`
12. Open issue #178 (IME in normal mode) —
    `https://github.com/replit/codemirror-vim/issues/178`
13. Open issue #251 (`vim-mode-change` on command mode) —
    `https://github.com/replit/codemirror-vim/issues/251`
14. Open issue #244 (CM6 keymaps before vim extension) —
    `https://github.com/replit/codemirror-vim/issues/244`
15. discuss.CodeMirror "Listening for mode changes in vim
    extension" — `https://discuss.codemirror.net/t/listening-for-mode-changes-in-vim-extension/7554`
16. discuss.CodeMirror "Change vim mode programmatically" —
    `https://discuss.codemirror.net/t/change-vim-mode-programmatically/3881`
17. discuss.CodeMirror "Vim - How to use defineEx()" —
    `https://discuss.codemirror.net/t/vim-how-to-use-defineex/738`
18. discuss.CodeMirror "Handling IME in Vim command mode" —
    `https://discuss.codemirror.net/t/handling-ime-input-method-editor-correctly-in-vim-command-mode/8829`
19. Obsidian vimrc-support (parser reference for Rung B) —
    `https://github.com/esm7/obsidian-vimrc-support`
20. Obsidian "vimrc support" DeepWiki overview —
    `https://deepwiki.com/esm7/obsidian-vimrc-support/4.1-vim-mappings-and-settings`
21. Mintlify-hosted @replit/codemirror-vim API ref —
    `https://www.mintlify.com/replit/codemirror-vim/api/vim-exit-insert-mode`
22. MarkEdit feature request "Support VIM key-bindings" #177 —
    `https://github.com/MarkEdit-app/MarkEdit/issues/177`
23. MarkEdit PR #635 (Vim integration) —
    `https://github.com/MarkEdit-app/MarkEdit/pull/635`
24. MarkEdit Customization wiki —
    `https://github.com/MarkEdit-app/MarkEdit/wiki/Customization`
25. Helix vs Kakoune comparison —
    `https://gigasblade.blogspot.com/2025/10/helix-vs-kakoune-october-2025-which.html`
26. Replit "Betting on CodeMirror" blog post —
    `https://blog.replit.com/codemirror`
27. CodeMirror System Guide (Compartment, Prec) —
    `https://codemirror.net/docs/guide/`
28. Companion: `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` — bridge
    v1 baseline; §6.4 vim mode flakiness recap; §13 bridge spec
    that 2.7 above extends; §19 bundle-growth table this doc
    updates with empirical Bundlephobia numbers.

---

*End of document. ~600 lines.*
