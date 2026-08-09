#!/bin/bash
# commit-refs.sh — find, validate, and rewrite commit-id references embedded in
# FILES (docs, comments, scripts), so no stale SHA survives a history rewrite.
#
# WHY (owner ask 2026-08-08): the repo's own docs are full of commit ids
# (HANDOFF/BACKLOG/LESSONS/CHANGELOG/docs/**, code comments, the agent memory
# dir, the textview_dist README). The planned open-source publish keeps FULL history
# but scrubs credentials via git-filter-repo — which rewrites EVERY sha. Any
# file-embedded reference then points at a commit that no longer exists.
# git-filter-repo remaps shas inside commit MESSAGES automatically; file
# CONTENTS are ours to fix — that's the `remap` mode, driven by the
# commit-map file filter-repo emits.
#
# MODES
#   scan [--extra <dir>]...      Report every 7-40-hex token in tracked text
#                                files that RESOLVES to a commit in this repo
#                                (validation kills hex-noise false positives),
#                                plus any that LOOK like sha refs but resolve
#                                to nothing (stale/typo — the thing we hunt).
#                                --extra adds untracked dirs (memory, textview_dist).
#   remap <commit-map> [--apply] Given filter-repo's commit-map ("old new" per
#                                line), rewrite old→new (any abbreviation ≥7
#                                chars) across tracked text files. Dry-run by
#                                default; --apply writes.
#
# Scan output: TSV  status<TAB>file:line<TAB>sha   status ∈ OK|STALE
# ("STALE" = matches the sha SHAPE in a ref-like context but isn't a commit
# here — includes refs to OTHER repos, e.g. textview_dist shas, so eyeball those.)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# Tracked text files likely to carry refs. Vendored web bundles excluded.
PATHSPECS=(':*.md' ':*.sh' ':*.swift' ':*.yml' ':*.toml' ':(exclude)Sources/ViewerUI/Resources/*')

mode="${1:-scan}"; shift || true

# Candidate refs: hex runs of 7-12 chars (short/abbrev ids; full 40-hex also
# caught by a second pattern). Longer runs (sha256 checksums, UUID halves) are
# ignored by the length bound; validation filters the rest.
scan_candidates() {
  # System grep, not `git grep`: macOS `git grep -E` silently ignores \b
  # word boundaries (found live — tracked files matched NOTHING).
  git ls-files -z -- "${PATHSPECS[@]}" \
    | xargs -0 grep -nIoE '\b[0-9a-f]{7,12}\b|\b[0-9a-f]{40}\b' 2>/dev/null || true
  for d in "${EXTRA_DIRS[@]:-}"; do
    [ -d "$d" ] || continue
    grep -rnIoE '\b[0-9a-f]{7,12}\b|\b[0-9a-f]{40}\b' "$d" 2>/dev/null \
      | grep -v '/\.git/' || true
  done
}

case "$mode" in
  scan)
    EXTRA_DIRS=()
    while [ $# -gt 0 ]; do
      case "$1" in --extra) EXTRA_DIRS+=("$2"); shift 2 ;; *) echo "unknown arg $1" >&2; exit 2 ;; esac
    done
    ok=0; stale=0
    while IFS=: read -r file line sha; do
      [ -n "${sha:-}" ] || continue
      if git rev-parse --quiet --verify "${sha}^{commit}" >/dev/null 2>&1; then
        printf 'OK\t%s:%s\t%s\n' "$file" "$line" "$sha"; ok=$((ok+1))
      else
        # Only report non-resolving hex when the LINE reads ref-like — cuts
        # noise from lucky hex words while keeping true stale refs visible.
        ctx="$(sed -n "${line}p" "$file" 2>/dev/null || true)"
        if printf '%s' "$ctx" | grep -qiE 'commit|sha|@ |head|release|rev|merge|cherry'; then
          printf 'STALE\t%s:%s\t%s\n' "$file" "$line" "$sha"; stale=$((stale+1))
        fi
      fi
    done < <(scan_candidates)
    echo "== scan done: $ok resolving refs, $stale ref-like non-resolving (stale/foreign) ==" >&2
    ;;

  remap)
    map="${1:?usage: remap <commit-map> [--apply]}"; shift || true
    apply=0; [ "${1:-}" = "--apply" ] && apply=1
    [ -f "$map" ] || { echo "no such map: $map" >&2; exit 2; }
    # Collect every resolving ref occurrence, then rewrite via the map. An
    # abbreviated ref is remapped to the SAME LENGTH abbreviation of the new
    # sha, so doc formatting stays stable.
    changed=0
    while IFS=$'\t' read -r _ loc sha; do
      file="${loc%%:*}"
      full="$(git rev-parse --quiet --verify "${sha}^{commit}" || true)"
      [ -n "$full" ] || continue
      new="$(awk -v o="$full" '$1==o {print $2}' "$map")"
      [ -n "$new" ] || continue
      newabbrev="${new:0:${#sha}}"
      [ "$sha" = "$newabbrev" ] && continue
      if [ "$apply" = 1 ]; then
        perl -0pi -e "s/\b\Q${sha}\E\b/${newabbrev}/g" "$file"
      fi
      printf '%s\t%s\t%s -> %s\n' "$([ $apply = 1 ] && echo REWROTE || echo WOULD-REWRITE)" \
        "$file" "$sha" "$newabbrev"
      changed=$((changed+1))
    done < <("$0" scan 2>/dev/null | grep '^OK' | sort -u -t$'\t' -k2,3)
    echo "== remap done: $changed reference(s) $([ $apply = 1 ] && echo rewritten || echo 'would be rewritten (dry-run; pass --apply)') ==" >&2
    ;;

  *) echo "usage: $0 scan [--extra dir]... | remap <commit-map> [--apply]" >&2; exit 2 ;;
esac
