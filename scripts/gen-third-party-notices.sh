#!/usr/bin/env bash
# Regenerate THIRD_PARTY_NOTICES.md — the aggregated attribution file
# for every third-party component we ship.
#
# Two sources:
#   1. SwiftPM checkouts under .build/checkouts/<pkg>/ — we read each
#      package's LICENSE/COPYING/NOTICE file verbatim. Requires that the
#      packages are already resolved (`swift package resolve`), so the
#      checkouts exist. The script fails loudly if a checkout or its
#      license file is missing rather than silently dropping attribution.
#   2. Vendored JS bundles with no SwiftPM checkout (Mermaid, CodeMirror
#      6) — their license texts are embedded below as heredocs, since
#      we ship the minified output, not a git checkout. Bump the version
#      strings here when re-vendoring those bundles.
#
# Output is written to <repo>/THIRD_PARTY_NOTICES.md. scripts/build-app.sh
# (owned by G14) copies the generated file into Contents/Resources/ of
# the assembled bundle.
#
# Usage:
#   bash scripts/gen-third-party-notices.sh            # write the file
#   bash scripts/gen-third-party-notices.sh --check    # fail if stale
#
# Exit: 0 = wrote (or up-to-date under --check); 1 = error; 3 = stale
#       under --check.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
CHECKOUTS="$ROOT_DIR/.build/checkouts"
OUT="$ROOT_DIR/THIRD_PARTY_NOTICES.md"

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK_MODE=1
fi

if [[ ! -d "$CHECKOUTS" ]]; then
  echo "Error: $CHECKOUTS not found. Run 'swift package resolve' first." >&2
  exit 1
fi

# (checkout-dir-name  ->  human label) for every SwiftPM dependency we
# link or ship. The lazy-grammar dylibs ship in Contents/Frameworks/,
# so their grammars count even though ViewerCore doesn't statically
# link them.
SWIFTPM_PKGS=(
  "swift-cmark|cmark (swift-cmark, CommonMark C reference parser)"
  "swift-markdown|swift-markdown (Apple)"
  "SwiftTreeSitter|SwiftTreeSitter (ChimeHQ)"
  "tree-sitter|tree-sitter (runtime)"
  "tree-sitter-bash|tree-sitter-bash"
  "tree-sitter-c|tree-sitter-c"
  "tree-sitter-c-sharp|tree-sitter-c-sharp"
  "tree-sitter-cpp|tree-sitter-cpp"
  "tree-sitter-java|tree-sitter-java"
  "tree-sitter-javascript|tree-sitter-javascript"
  "tree-sitter-json|tree-sitter-json"
  "tree-sitter-lua|tree-sitter-lua"
  "tree-sitter-markdown|tree-sitter-markdown"
  "tree-sitter-python|tree-sitter-python"
  "tree-sitter-rust|tree-sitter-rust"
  "tree-sitter-swift|tree-sitter-swift (alex-pinkus)"
  "tree-sitter-typescript|tree-sitter-typescript"
  "tree-sitter-xml|tree-sitter-xml"
)

# Locate the license file inside a checkout. Upstream naming varies:
# LICENSE, LICENSE.txt, LICENSE.md, COPYING. First match wins.
find_license() {
  local dir="$1"
  local f
  for f in LICENSE LICENSE.txt LICENSE.md LICENSE.MD COPYING COPYING.txt; do
    if [[ -f "$dir/$f" ]]; then
      echo "$dir/$f"
      return 0
    fi
  done
  return 1
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
  echo "# Third-Party Notices"
  echo
  echo "TextView (\`com.markdownviewer.MarkdownViewer\`) bundles and links the"
  echo "third-party components listed below. Each is distributed under its own"
  echo "license; the full license text for every component is reproduced here."
  echo
  echo "> **Generated file — do not edit by hand.** Regenerate with"
  echo "> \`bash scripts/gen-third-party-notices.sh\` after a dependency or"
  echo "> vendored-bundle change. \`scripts/build-app.sh\` copies this file"
  echo "> into \`Contents/Resources/\` of the assembled \`.app\`."
  echo
  echo "## Contents"
  echo
  echo "- SwiftPM dependencies (swift-markdown, cmark, SwiftTreeSitter,"
  echo "  tree-sitter runtime, and the per-language grammars)."
  echo "- Vendored JavaScript bundles shipped under \`Contents/Resources/\`"
  echo "  (Mermaid, CodeMirror 6)."
  echo
  echo "---"
  echo
  echo "## SwiftPM dependencies"

  for entry in "${SWIFTPM_PKGS[@]}"; do
    dir_name="${entry%%|*}"
    label="${entry#*|}"
    pkg_dir="$CHECKOUTS/$dir_name"
    if [[ ! -d "$pkg_dir" ]]; then
      echo "Error: checkout missing: $pkg_dir (run 'swift package resolve')." >&2
      exit 1
    fi
    lic="$(find_license "$pkg_dir")" || {
      echo "Error: no LICENSE/COPYING file found in $pkg_dir." >&2
      exit 1
    }
    echo
    echo "### $label"
    echo
    echo '```'
    cat "$lic"
    # NOTICE files (e.g. swift-markdown) carry required extra attribution.
    if [[ -f "$pkg_dir/NOTICE.txt" ]]; then
      echo
      echo "----- NOTICE -----"
      cat "$pkg_dir/NOTICE.txt"
    elif [[ -f "$pkg_dir/NOTICE" ]]; then
      echo
      echo "----- NOTICE -----"
      cat "$pkg_dir/NOTICE"
    fi
    echo '```'
  done

  echo
  echo "---"
  echo
  echo "## Vendored JavaScript bundles"
  echo
  echo "These ship as pre-built minified files under \`Contents/Resources/\`"
  echo "(no SwiftPM checkout). Versions are pinned in"
  echo "\`scripts/codemirror-build/package.json\` (CodeMirror 6) and"
  echo "\`docs/MERMAID_IMPL.md\` (Mermaid). Update the version strings in this"
  echo "generator when re-vendoring."
  echo
  echo "### Mermaid 11.4.1"
  echo
  echo '```'
  cat <<'MERMAID_LICENSE'
MIT License

Copyright (c) 2014 - 2024 Knut Sveidqvist

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
MERMAID_LICENSE
  echo '```'
  echo
  echo "### CodeMirror 6"
  echo
  echo "Bundled from the \`@codemirror/*\` packages pinned in"
  echo "\`scripts/codemirror-build/package.json\`. All are MIT-licensed."
  echo
  echo '```'
  cat <<'CODEMIRROR_LICENSE'
MIT License

Copyright (C) 2018-2021 by Marijn Haverbeke <marijn@haverbeke.berlin> and others

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
CODEMIRROR_LICENSE
  echo '```'
} > "$TMP"

if (( CHECK_MODE == 1 )); then
  if [[ -f "$OUT" ]] && diff -q "$OUT" "$TMP" >/dev/null 2>&1; then
    echo "THIRD_PARTY_NOTICES.md is up to date."
    exit 0
  fi
  echo "THIRD_PARTY_NOTICES.md is STALE. Run scripts/gen-third-party-notices.sh." >&2
  exit 3
fi

mv "$TMP" "$OUT"
trap - EXIT
echo "Wrote $OUT"
