// Re-export shim for the lazy-loaded TreeSitter TypeScript grammar.
// See TreeSitterXMLLazy/wrapper.c for the design rationale.
//
// Note: tree-sitter-typescript ships two grammars (typescript + tsx).
// We re-export only `tree_sitter_typescript` here; .tsx files are
// detected as `.typescript` upstream in `HighlightLanguage.detect`,
// matching today's behavior.

#include <stdint.h>

typedef struct TSLanguage TSLanguage;
extern const TSLanguage *tree_sitter_typescript(void);

const void *tree_sitter_typescript_lazy_keepalive(void) {
    return (const void *)tree_sitter_typescript;
}
