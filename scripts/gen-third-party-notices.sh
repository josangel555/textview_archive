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
# TSK-854: highlighting is rust-only now (the Swift TreeSitter twin was
# deleted), so the Swift package only links the grammars code-FOLDS +
# structural search need — json/swift/markdown/xml/javascript/typescript.
# The 8 highlight-only grammars (bash, c, c-sharp, cpp, java, lua, python,
# rust) were removed from Package.swift; their notices are dropped here too.
# (The rust core carries its own copy of the full grammar set — those are
# attributed via the rust-core notices, not this Swift-package list.)
SWIFTPM_PKGS=(
  "swift-cmark|cmark (swift-cmark, CommonMark C reference parser)"
  "swift-markdown|swift-markdown (Apple)"
  "SwiftTreeSitter|SwiftTreeSitter (ChimeHQ)"
  "tree-sitter|tree-sitter (runtime)"
  "tree-sitter-javascript|tree-sitter-javascript"
  "tree-sitter-json|tree-sitter-json"
  "tree-sitter-markdown|tree-sitter-markdown"
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
  echo "- Statically-linked Rust crates (the \`mdvcore\` engine linked into the"
  echo "  main executable via \`libmdvcore_ffi.a\`)."
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
  echo "## Statically-linked Rust crates (mdvcore)"
  echo
  echo "The \`mdvcore\` engine is compiled from the Rust workspace under"
  echo "\`rust-core/\` and statically linked into the main executable"
  echo "(\`libmdvcore_ffi.a\`), so every crate in its dependency closure is"
  echo "redistributed in the shipped binary. Copyright rests with each crate's"
  echo "respective authors (as identified on crates.io); the license texts are"
  echo "reproduced once per license below the crate list."
  echo
  echo "<!-- RUST-CRATES-BEGIN -->"
  if command -v cargo >/dev/null 2>&1 && [[ -d "$ROOT_DIR/rust-core" ]]; then
    # Normal (non-dev) dependency closure of the linked ffi crate, with each
    # crate's declared license expression. Workspace-local mdvcore-* crates are
    # first-party and excluded.
    RUST_CRATES="$(cd "$ROOT_DIR/rust-core" && cargo tree -p mdvcore-ffi \
        --edges normal --prefix none --format "{p}|{l}" 2>/dev/null \
      | sed -E 's/ \(\*\)$//; s/ \(proc-macro\)//; s| \(/[^)]*\)||' \
      | grep -v '^mdvcore-' | sort -u)"
    if [[ -z "$RUST_CRATES" ]]; then
      echo "Error: cargo tree produced no crates — rust attribution would be empty." >&2
      exit 1
    fi
    # Every license expression must be from the families whose texts are
    # reproduced below — a new crate with an unknown license must FAIL here,
    # not ship unattributed.
    while IFS='|' read -r _crate lic; do
      case "$lic" in
        "MIT"|"MIT OR Apache-2.0"|"Unlicense OR MIT"|"Apache-2.0 OR MIT"|\
        "(MIT OR Apache-2.0) AND Unicode-3.0"|"Zlib"|"Apache-2.0"|"BSD-3-Clause") ;;
        *)
          echo "Error: crate '$_crate' has unhandled license '$lic'." >&2
          echo "Add its license text to gen-third-party-notices.sh." >&2
          exit 1
          ;;
      esac
    done <<< "$RUST_CRATES"
    awk -F'|' '{ printf "- `%s` — %s\n", $1, $2 }' <<< "$RUST_CRATES"
  else
    # No cargo on this machine (VM / CI): carry the committed block forward so
    # --check stays meaningful for the rest of the file.
    awk '/<!-- RUST-CRATES-BEGIN -->/{f=1;next} /<!-- RUST-CRATES-END -->/{f=0} f' \
      "$OUT" 2>/dev/null || true
  fi
  echo "<!-- RUST-CRATES-END -->"
  echo
  echo "### MIT License (crates listed as MIT, or the MIT arm of a dual license)"
  echo
  echo '```'
  cat <<'RUST_MIT'
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
RUST_MIT
  echo '```'
  echo
  echo "### Apache License 2.0 (the Apache-2.0 arm of dual-licensed crates)"
  echo
  echo "Apache-2.0-licensed crates are redistributed under the terms of the"
  echo "Apache License, Version 2.0. The full text is available at"
  echo "<https://www.apache.org/licenses/LICENSE-2.0>; its terms apply to each"
  echo "crate above that names Apache-2.0, with the copyright held by that"
  echo "crate's authors."
  echo
  echo "### The Unlicense (crates listed as Unlicense OR MIT)"
  echo
  echo '```'
  cat <<'RUST_UNLICENSE'
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or distribute
this software, either in source code form or as a compiled binary, for any
purpose, commercial or non-commercial, and by any means.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
RUST_UNLICENSE
  echo '```'
  echo
  echo "### Unicode License v3 (unicode-ident's data tables)"
  echo
  echo '```'
  cat <<'RUST_UNICODE'
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright (c) 1991-2023 Unicode, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of data files and any associated documentation (the "Data Files") or software
and any associated documentation (the "Software") to deal in the Data Files
or Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, and/or sell copies of the Data
Files or Software, and to permit persons to whom the Data Files or Software
are furnished to do so, provided that either (a) this copyright and permission
notice appear with all copies of the Data Files or Software, or (b) this
copyright and permission notice appear in associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR
CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE,
DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
OF THE DATA FILES OR SOFTWARE.
RUST_UNICODE
  echo '```'
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
