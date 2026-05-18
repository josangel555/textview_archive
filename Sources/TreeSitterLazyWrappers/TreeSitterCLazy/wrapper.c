// Re-export shim for the lazy-loaded TreeSitter C grammar.
// See TreeSitterXMLLazy/wrapper.c for the design rationale.

#include <stdint.h>

typedef struct TSLanguage TSLanguage;
extern const TSLanguage *tree_sitter_c(void);

const void *tree_sitter_c_lazy_keepalive(void) {
    return (const void *)tree_sitter_c;
}
