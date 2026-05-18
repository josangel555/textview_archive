#!/bin/sh
# Tier B sidebar plugin — returns hardcoded rows. The host pipes a
# JSON envelope on stdin (we ignore it here) and expects a JSON
# response with a "rows" array on stdout.
#
# Envelope shape (v1):
#   { "version": 1, "kind": "listRows",
#     "invocationID": "<uuid>", "args": {} }
#
# Response shape (v1):
#   { "rows": [ { "id": "...", "label": "...", "detail": "..." | null }, ... ] }
#
# Env: only $HOME is passed; $PATH is *not*. Hence the absolute paths
# below (and we don't shell out to anything outside /bin or /usr/bin).
# cwd is the plugin folder.

# Drain stdin so the host's writer doesn't see EPIPE.
/bin/cat >/dev/null

/bin/cat <<'JSON'
{
  "rows": [
    { "id": "1", "label": "Hello, plugin",       "detail": "v1" },
    { "id": "2", "label": "From a subprocess",   "detail": "Tier B" },
    { "id": "3", "label": "Built with /bin/sh",  "detail": null  }
  ]
}
JSON
