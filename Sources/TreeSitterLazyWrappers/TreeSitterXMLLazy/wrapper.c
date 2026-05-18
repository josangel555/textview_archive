// Re-export shim for the lazy-loaded TreeSitter XML grammar.
//
// The wrapper target depends on the upstream `TreeSitterXML` product
// (which compiles parser.c + scanner.c into a static archive). SwiftPM
// links that archive into this target's `.dynamic` library product
// (`libTreeSitterXMLLazy.dylib`), so the `tree_sitter_xml` symbol from
// upstream ends up inside our dylib with default visibility — exactly
// what `GrammarLoader.dlopen + dlsym` needs.
//
// Why a wrapper file at all: SwiftPM requires at least one source per
// target, and a `void`-returning reference defeats `-dead_strip` for
// the upstream symbol on platforms where the linker is aggressive
// about pruning library-archive members no other object references.
//
// Why also expose `tree_sitter_xml_lazy_keepalive`: lets the
// SwiftTreeSitter test harness verify the wrapper actually links the
// expected upstream grammar by symbol-greppability, without having to
// resolve through the upstream package directly.

#include <stdint.h>

typedef struct TSLanguage TSLanguage;
extern const TSLanguage *tree_sitter_xml(void);

const void *tree_sitter_xml_lazy_keepalive(void) {
    return (const void *)tree_sitter_xml;
}
