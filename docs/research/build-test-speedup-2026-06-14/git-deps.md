# Git dependencies (tree-sitter grammars) — clone size

## The problem

`.build/repositories/` = **798 MB** of git mirrors + `.build/checkouts/` = **210 MB** of
working trees, for the 18 SwiftPM dependencies — almost entirely the tree-sitter grammars.
Worst offenders (pack file = full history):

| Grammar mirror | pack | commits |
|---|---|---|
| tree-sitter-c-sharp | 191 MB | 1081 |
| tree-sitter-typescript | 158 MB | — |
| tree-sitter-cpp | 105 MB | — |
| tree-sitter-rust | 58 MB | — |
| tree-sitter-markdown | 58 MB | — |
| tree-sitter-javascript | 48 MB | — |
| (12 more) | … | … |

And via the SourceKit-LSP index build, **all of this is cloned a SECOND time** into
`.build/index-build/repositories/` (814 MB) — see `disk-build-dir.md`. So the grammars cost
~1.6 GB of git data on disk for content we consume as **one pinned `parser.c` + `scanner.c`
per grammar.**

## Why the clones are huge

The grammar repos vendor **generated parser tables** (multi-MB `parser.c` per language) AND
keep **full commit history** of those regenerated-every-release tables. tree-sitter-c-sharp's
`parser.c` is enormous and has been regenerated 1000+ times → a 191 MB pack.

## What does NOT work (verified)

- **No SwiftPM shallow/depth flag.** `swift package --help` exposes no `--depth` / `--shallow`
  for SCM dependencies. SwiftPM clones each git dependency as a **full mirror** into
  `repositories/`. The mirror for tree-sitter-c-sharp has all 1081 commits (`git rev-list
  --count --all` = 1081); `remote.origin.partialclonefilter` is unset (not a partial clone).
- So `git clone --filter=blob:none` / `--depth 1` (the web's headline advice for huge repos)
  **cannot be applied through SwiftPM** — SwiftPM owns the clone. The blobless-clone research is
  correct in general (88%+ clone-time reduction) but there's no hook to inject the filter.

## What CAN work (Rec T2 — needs approval, higher effort)

Three escalating options, all touching the dependency-provenance model (so **owner approval**):

1. **Local path / mirror override.** Pre-clone each grammar shallow/blobless once into a local
   cache and point SwiftPM at it via a path dependency or `.package(url: "file://…")`. Keeps the
   exact pinned revisions (preserving the `Package.swift` rationale about the alex-pinkus
   `tree-sitter-swift` revision pin and the `with-generated-files` branch trap) but cuts the
   on-disk git data. Medium effort; brittle across machines/VM rsync.

2. **Local SwiftPM registry mirror.** Stand up a registry (or use `--replace-scm-with-registry`)
   serving the pinned grammar sources as packages. SwiftPM fetches package *archives*, not git
   history → no `repositories/` mirrors at all. Cleanest long-term; most setup.

3. **Vendor the generated `parser.c`/`scanner.c` into the repo** and drop the git dependencies
   entirely, compiling the grammars as in-repo C targets (the project already does this for the
   `CTSPatch{Python,JavaScript,Lua}` scanner files!). This is the smallest *on-disk* footprint
   and removes the double-clone, but it's the biggest change to how grammars are sourced and
   loses the clean upstream-version-bump path. The `Package.swift` already documents heavy
   investment in the current pinning model — vendoring would supersede it.

**Recommendation:** don't do T2 reactively. The duplicate-clone half of the cost is killed for
free by F1 (disabling the LSP index build removes `index-build/repositories`, −814 MB). That
leaves a single 798 MB `repositories/`, which is annoying but not urgent. Pursue T2 only if the
grammar clone cost becomes a real pain point (e.g. VM rsync time, fresh-checkout latency). When
you do, **option 1 (local mirror)** preserves the most of the current provenance model.

## Quick partial win (Rec F7 — marginal)

`git gc`/repack on the mirrors won't shrink much (packs are already packed). Not worth it alone.

## Sources
- https://github.blog/open-source/git/get-up-to-speed-with-partial-clone-and-shallow-clone/
- https://github.blog/open-source/git/git-clone-a-data-driven-study-on-cloning-behaviors/
- `swift package --help` (no depth/shallow flag — verified locally)
- https://swiftpackageindex.com/faq (registry/SCM transformation)
