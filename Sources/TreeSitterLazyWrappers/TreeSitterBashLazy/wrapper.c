// Re-export shim for the lazy-loaded TreeSitter Bash grammar.
// See TreeSitterXMLLazy/wrapper.c for the design rationale.

#include <stdint.h>

typedef struct TSLanguage TSLanguage;
extern const TSLanguage *tree_sitter_bash(void);

const void *tree_sitter_bash_lazy_keepalive(void) {
    return (const void *)tree_sitter_bash;
}
