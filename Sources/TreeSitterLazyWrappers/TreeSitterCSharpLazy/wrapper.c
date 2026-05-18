// Re-export shim for the lazy-loaded TreeSitter C# grammar.
// See TreeSitterXMLLazy/wrapper.c for the design rationale.
//
// Upstream package name: `tree-sitter-c-sharp` (hyphenated); product
// name: `TreeSitterCSharp` (Swift convention); C symbol:
// `tree_sitter_c_sharp` (the grammar authors' chosen identifier —
// underscore, not hyphen). `GrammarLoader.Grammar.cSharp.cSymbol`
// returns that exact string.

#include <stdint.h>

typedef struct TSLanguage TSLanguage;
extern const TSLanguage *tree_sitter_c_sharp(void);

const void *tree_sitter_c_sharp_lazy_keepalive(void) {
    return (const void *)tree_sitter_c_sharp;
}
