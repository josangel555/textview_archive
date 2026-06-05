// Re-export shim for the lazy-loaded TreeSitter TypeScript grammar.
// See TreeSitterXMLLazy/wrapper.c for the design rationale.
//
// Note: tree-sitter-typescript ships two grammars (typescript + tsx).
// Both upstream parser archives (typescript/parser.c + tsx/parser.c)
// link into this one dylib, so both `tree_sitter_typescript` and
// `tree_sitter_tsx` are available to `GrammarLoader` via dlsym. We keep
// an explicit keepalive reference to EACH so neither symbol is pruned by
// `-dead_strip`: `tree_sitter_tsx` has no other referrer in this target,
// so without the reference below its export from the dylib would be
// incidental rather than guaranteed. The plain TS grammar cannot parse
// JSX, so `.tsx` files must resolve to `tree_sitter_tsx` for correct
// highlighting — see the matching `GrammarLoader.Grammar.tsx` case.

#include <stdint.h>

typedef struct TSLanguage TSLanguage;
extern const TSLanguage *tree_sitter_typescript(void);
extern const TSLanguage *tree_sitter_tsx(void);

const void *tree_sitter_typescript_lazy_keepalive(void) {
    return (const void *)tree_sitter_typescript;
}

const void *tree_sitter_tsx_lazy_keepalive(void) {
    return (const void *)tree_sitter_tsx;
}
