# Vendored: mermaid.min.js

- Package:    mermaid
- Version:    11.16.0
- Source:     https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js
- npm verify: npm pack mermaid@11.16.0 -> package/dist/mermaid.min.js
              (byte-identical to the CDN bundle: same SHA-256, verified 2026-07-29)
- License:    MIT (see ./LICENSE)
- Fetched:    2026-07-29
- SHA-256:    74d7c46dabca328c2294733910a8aa1ed0c37451776e8d5295da38a2b758fb9b
- File size:  ~3.57 MB (3,565,102 bytes; we ship the un-gzipped UMD)
- Why bumped: 11.4.1 carried 6 published advisories (2 XSS sanitizer-bypass,
  1 DoS) that sat unseen for ~11 months — the advisory-watch nightly never
  runs locally (no GH remote). 11.16.0 was latest at bump time.

## How to refresh
1. Re-download from the URL above (or `npm pack mermaid@<version>`).
2. Diff the new SHA against this file. Refuse to commit if you cannot
   explain why the contents changed.
3. Update VERSION, FETCHED, and SHA-256 above.
4. Run `swift test --filter MermaidVendorTests` — it re-checks the SHA on
   the vendored bytes and fails CI if the file was swapped without bumping
   this manifest.
