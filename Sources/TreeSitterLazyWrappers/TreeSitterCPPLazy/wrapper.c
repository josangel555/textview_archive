// Re-export shim for the lazy-loaded TreeSitter C++ grammar.
// See TreeSitterXMLLazy/wrapper.c for the design rationale.
//
// Upstream exports `tree_sitter_cpp` (without a `++` suffix), so
// `GrammarLoader.Grammar.cpp.cSymbol` matches verbatim.

#include <stdint.h>

typedef struct TSLanguage TSLanguage;
extern const TSLanguage *tree_sitter_cpp(void);

const void *tree_sitter_cpp_lazy_keepalive(void) {
    return (const void *)tree_sitter_cpp;
}
