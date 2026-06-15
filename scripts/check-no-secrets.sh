#!/usr/bin/env bash
# check-no-secrets.sh — committed-secret scan for the PRE-PUBLIC-RELEASE checklist (TSK-859).
#
# The repo signs locally only today (cert "MarkdownViewer Local Dev"; no Developer
# ID until shipping public, per CLAUDE.md). Before that public ship, verify no API
# key / token / private key was ever committed to a tracked file.
#
# DELIBERATELY STANDALONE / on-demand — NOT wired into scripts/test-headless-gate.sh
# (the velocity-critical merge gate). A heuristic secret regex can false-positive on
# a realistic test fixture; coupling that to every merge would be worse than the risk
# it guards while the repo is clean. Run it as a release-checklist step instead:
#
#   bash scripts/check-no-secrets.sh        # exit 0 = clean, 2 = candidate(s) found
#
# Conservative by design: high-confidence provider patterns + a generic
# secret-assignment pattern with test/fixture/placeholder noise excluded. The only
# credential-like string in the repo is the intentional LOCAL-DEV UTM VM password
# (`<vm-sudo-password>` / vm-tester@…, CLAUDE.md) — a throwaway local VM, not a real secret; it is
# too short to match the {24,} generic rule and matches no provider pattern.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

found=0
report() { printf 'POTENTIAL SECRET [%s]:\n' "$1"; printf '%s\n' "$2" | sed 's/^/  /'; found=1; }

m=$(git grep -nE 'AKIA[0-9A-Z]{16}' -- ':(exclude)*.lock' 2>/dev/null) && [ -n "$m" ] && report "aws-access-key" "$m"
m=$(git grep -nE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}' 2>/dev/null) && [ -n "$m" ] && report "github-token" "$m"
m=$(git grep -nE 'BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY' -- ':(exclude)*test*' ':(exclude)*fixture*' 2>/dev/null) && [ -n "$m" ] && report "private-key" "$m"
m=$(git grep -nE 'xox[baprs]-[A-Za-z0-9-]{10,}|sk_live_[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{30,}' 2>/dev/null) && [ -n "$m" ] && report "slack/stripe/google-key" "$m"
m=$(git grep -nEi '(api[_-]?key|secret|access[_-]?token|client[_-]?secret|password)["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9/+_-]{24,}' \
      -- '*.swift' '*.rs' '*.json' '*.sh' '*.plist' '*.yml' '*.yaml' 2>/dev/null \
      | grep -ivE 'test|mock|fixture|example|placeholder|xxxx|your-|<|payload|sha256|checksum|hash|uuid|redact') \
  && [ -n "$m" ] && report "generic-secret-assignment" "$m"

if [ "$found" -ne 0 ]; then
  printf '\n==> check-no-secrets: FOUND candidate secret(s) above — review before a public release.\n'
  exit 2
fi
printf '==> check-no-secrets: clean (no committed secrets in tracked files).\n'
exit 0
