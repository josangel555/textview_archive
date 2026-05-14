#!/usr/bin/env bash
# Resets all TCC (privacy) prompts for MarkdownViewer so the next launch
# starts clean. Use when:
#   - the privacy prompts ("Documents folder access") won't stick across
#     rebuilds (caused by ad-hoc signing → new CDHash → TCC sees a new app)
#   - you want to test the first-launch grant flow
#
# After this script: the next `open -a MarkdownViewer file-in-Documents.md`
# will prompt once for Documents/Desktop/Downloads/etc.; granting them
# will stick until the next rebuild's CDHash change.
set -euo pipefail

BUNDLE_ID="com.markdownviewer.MarkdownViewer"

echo "==> Resetting TCC permissions for $BUNDLE_ID"
# tccutil reset takes a service name + bundle ID. `All` clears every
# service granted to the bundle.
tccutil reset All "$BUNDLE_ID" 2>&1 | sed 's/^/  /' || true

echo "==> Killing any running MarkdownViewer instance"
killall MarkdownViewer 2>/dev/null || true

echo
echo "Next launch will prompt once per protected folder."
echo "Grant when prompted; the answer sticks until next rebuild."
echo
echo "For a permanent grant: open System Settings → Privacy & Security"
echo "  → Full Disk Access → add /Users/me/Documents/workspaces/claude/"
echo "  markdown_viewer/dist/MarkdownViewer.app"
echo
echo "Long term: ship with a Developer ID signature (Phase 9)."
