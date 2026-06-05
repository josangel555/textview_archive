#!/usr/bin/env bash
# Install an `mdv` CLI shim so files can be opened from the terminal
# without typing the full app path.
#
# Default install location: /usr/local/bin/mdv  (requires sudo)
# Override with --prefix:    bash scripts/install-mdv-cli.sh --prefix ~/.local/bin
#
# Usage after install:
#   mdv file.md
#   mdv ~/projects/foo/
#   mdv -                          # read stdin into a temp file and open
#   echo "# hi" | mdv -
#
# The shim is a thin Bash script that just delegates to
# `/usr/bin/open -a` for the installed .app — so it works without any
# new entitlements and respects the user's LaunchServices defaults.

set -euo pipefail

PREFIX="/usr/local/bin"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help)
      grep -E '^#' "$0" | sed -E 's/^# ?//' | head -25
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$PREFIX"
DEST="$PREFIX/mdv"
APP_NAME="MarkdownViewer"

cat > "$DEST" <<'SHIM'
#!/usr/bin/env bash
# `mdv` — open files or folders in MarkdownViewer.
# Installed by scripts/install-mdv-cli.sh
set -euo pipefail

APP_NAME="MarkdownViewer"

# Stdin → temp file → open. Useful for piping rendered docs.
if [[ "${1:-}" == "-" || ( -z "${1:-}" && ! -t 0 ) ]]; then
  TMP="$(mktemp -d)/stdin.md"
  cat > "$TMP"
  exec /usr/bin/open -a "$APP_NAME" "$TMP"
fi

if [[ $# -eq 0 ]]; then
  exec /usr/bin/open -a "$APP_NAME"
fi

# Convert relative paths to absolute (open -a -F resolves cwd) and
# pass them all through.
ABS_PATHS=()
for arg in "$@"; do
  if [[ -e "$arg" ]]; then
    ABS_PATHS+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
  else
    ABS_PATHS+=("$arg")
  fi
done

exec /usr/bin/open -a "$APP_NAME" "${ABS_PATHS[@]}"
SHIM

chmod +x "$DEST"

echo "==> Installed $DEST"
echo
echo "Try:"
echo "  mdv DESIGN.md"
echo "  mdv ~/projects"
echo "  echo '# Hello' | mdv -"
echo
echo "If 'mdv' isn't found, add $PREFIX to your PATH."
