# Vendored: mermaid.min.js

- Package:    mermaid
- Version:    11.4.1
- Source:     https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js
- npm verify: npm pack mermaid@11.4.1 -> package/dist/mermaid.min.js
- License:    MIT (see ./LICENSE)
- Fetched:    2026-05-17
- SHA-256:    a43bc1afd446f9c4cc66ac5dd45d02e8d65e26fc5344ec0ef787f88d6ddb6f9e
- File size:  ~2.45 MB (2,571,900 bytes; ~600 KB gzipped; we ship the un-gzipped UMD)

## How to refresh
1. Re-download from the URL above (or `npm pack mermaid@<version>`).
2. Diff the new SHA against this file. Refuse to commit if you cannot
   explain why the contents changed.
3. Update VERSION, FETCHED, and SHA-256 above.
4. Run `swift test --filter MermaidVendorTests` — it re-checks the SHA on
   the vendored bytes and fails CI if the file was swapped without bumping
   this manifest.
