#!/bin/bash
# SwiftPM dependency advisory watch (TSK-628) — the cargo-audit analog for
# the Swift side of the tree. The exposure that motivates it: 14 tree-sitter
# grammar pins PARSE ATTACKER-CONTROLLED FILES; an unmonitored grammar CVE
# is a real hole.
#
# Source: the GitHub Advisory Database (ecosystem=swift) — the only advisory
# feed covering SwiftPM packages. Design: fetch the FULL swift advisory set
# (it is small — pages of dozens, capped below) in one paginated query, then
# match affected package names against our pins LOCALLY. One API call beats
# 18 per-package `affects` queries and avoids URL-encoding semantics we
# cannot verify offline.
#
# HONESTY RULE for a network check: with MDV_ADVISORY_STRICT=1 (the nightly
# workflow sets it) an API failure FAILS the run — an advisory watch that
# silently passes when offline is a false green. Without strict (ad-hoc
# local runs) network failures warn and exit 0.
#
# Modes:
#   swiftpm-advisory-watch.sh              # full check (network)
#   swiftpm-advisory-watch.sh --parse-only # print parsed pins, no network
#                                          # (the gate-runnable test seam)
set -u

RESOLVED="${MDV_PACKAGE_RESOLVED:-Package.resolved}"
STRICT="${MDV_ADVISORY_STRICT:-0}"
MAX_PAGES=10   # 100/page; >1000 swift advisories would warrant a redesign

if [[ ! -f "$RESOLVED" ]]; then
  echo "swiftpm-advisory-watch: $RESOLVED not found" >&2
  exit 2
fi

# --- parse pins (v2/v3 "pins" or legacy "object.pins") -------------------
parse_pins() {
  python3 - "$RESOLVED" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
pins = d.get("pins") or d.get("object", {}).get("pins") or []
for p in pins:
    ident = p.get("identity") or p.get("package") or "?"
    loc = (p.get("location") or p.get("repositoryURL") or "").rstrip("/")
    if loc.endswith(".git"):
        loc = loc[:-4]
    ver = (p.get("state") or {}).get("version") or ""
    rev = (p.get("state") or {}).get("revision") or ""
    print(f"{ident}\t{loc}\t{ver or rev}")
PYEOF
}

if [[ "${1:-}" == "--parse-only" ]]; then
  parse_pins
  exit 0
fi

PINS="$(parse_pins)"
if [[ -z "$PINS" ]]; then
  echo "swiftpm-advisory-watch: no pins parsed from $RESOLVED" >&2
  exit 2
fi

fetch_page() {
  local page="$1"
  local path="/advisories?ecosystem=swift&per_page=100&page=${page}"
  if command -v gh >/dev/null 2>&1; then
    gh api "$path" 2>/dev/null && return 0
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -sf -H "Authorization: Bearer $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github+json" \
         "https://api.github.com${path}" && return 0
  fi
  # Unauthenticated fallback: the advisory endpoint is PUBLIC (60 req/hr
  # unauth limit; we make at most MAX_PAGES=10 calls). This repo has no
  # GitHub remote, so the nightly workflow never runs — the LOCAL run is
  # the only live lane and must work without gh/credentials (TSK-628).
  curl -sf -H "Accept: application/vnd.github+json" \
       "https://api.github.com${path}" && return 0
  return 1
}

# Hermetic test seam (TSK-628): a fixture file of canned advisories skips
# the network entirely — the gate-runnable path that keeps the matcher's
# honesty regression-guarded (see AdvisoryWatchScriptTests).
if [[ -n "${MDV_ADVISORY_FIXTURE:-}" ]]; then
  if [[ ! -f "$MDV_ADVISORY_FIXTURE" ]]; then
    echo "swiftpm-advisory-watch: fixture $MDV_ADVISORY_FIXTURE not found" >&2
    exit 2
  fi
  ALL="$(cat "$MDV_ADVISORY_FIXTURE")"
  net_ok=1
else

ALL="[]"
net_ok=1
for page in $(seq 1 "$MAX_PAGES"); do
  body=$(fetch_page "$page") || { net_ok=0; break; }
  ALL=$(python3 -c "
import json, sys
acc = json.loads(sys.argv[1]); new = json.loads(sys.argv[2] or '[]')
print(json.dumps(acc + new))
" "$ALL" "$body")
  count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1] or '[]')))" "$body")
  [[ "$count" -lt 100 ]] && break
done

fi  # MDV_ADVISORY_FIXTURE

if [[ "$net_ok" == "0" ]]; then
  echo "==> advisory API unreachable" >&2
  if [[ "$STRICT" == "1" ]]; then
    echo "==> STRICT: failing — an advisory watch must not silently pass offline" >&2
    exit 1
  fi
  echo "==> non-strict: tolerated (ad-hoc run); the nightly lane runs strict" >&2
  exit 0
fi

# --- local match: advisory package names vs pin urls/identities ----------
# Pins ride an ENV VAR, advisories ride argv. (A prior version fed pins via
# `<<< "$PINS"` ALONGSIDE the heredoc — the herestring overrode the heredoc,
# so python executed the PIN LIST as its script, the matcher never ran, and
# the empty result read as PASSED. A matcher that cannot run must FAIL.)
result=$(MDV_PINS="$PINS" python3 - "$ALL" <<'PYEOF'
import json, os, sys
advisories = json.loads(sys.argv[1] or "[]")
pins = []
for line in os.environ.get("MDV_PINS", "").splitlines():
    parts = line.split("\t")
    if len(parts) == 3:
        pins.append(parts)

hits = []
for a in advisories:
    for v in a.get("vulnerabilities") or []:
        name = ((v.get("package") or {}).get("name") or "").rstrip("/").removesuffix(".git").lower()
        if not name:
            continue
        for ident, loc, ver in pins:
            # Swift advisories key by repo URL; tolerate scheme/suffix drift
            # by matching on the owner/repo tail.
            tail = "/".join(loc.lower().split("/")[-2:])
            if name.endswith(tail) or tail.endswith(name) or name == ident.lower():
                hits.append(f"{a.get('ghsa_id')} affects {ident} {ver} ({a.get('summary')})")
print(f"{len(advisories)} advisories scanned")
for h in sorted(set(hits)):
    print("HIT " + h)
PYEOF
) || {
  echo "==> matcher failed to run — failing (a watch that cannot match is not a pass)" >&2
  exit 1
}
echo "$result"
if grep -q '^HIT ' <<< "$result"; then
  echo "==> ADVISORIES MATCH PINNED PACKAGES — triage required" >&2
  exit 1
fi
echo "==> swiftpm advisory watch PASSED ($(echo "$PINS" | wc -l | tr -d ' ') pins)"
