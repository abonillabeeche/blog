#!/usr/bin/env bash
# Fails if any post mentions a term that must not be published (confidential
# products, customer names, internal hostnames). The terms are not in the repo:
# locally they come from .blocklist, in CI from the BLOCKLIST secret.
# One case-insensitive term per line; lines starting with # are ignored.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${BLOCKLIST:-}" ]]; then
  terms=$(printf '%s\n' "$BLOCKLIST")
elif [[ -f .blocklist ]]; then
  terms=$(cat .blocklist)
else
  echo "check-blocklist: no .blocklist file and no BLOCKLIST env; refusing to pass" >&2
  exit 1
fi

status=0
while IFS= read -r term; do
  [[ -z "$term" || "$term" == \#* ]] && continue
  if grep -rniF --include='*.md' -- "$term" content/ >/tmp/blocklist-hits 2>/dev/null; then
    echo "BLOCKED term found (term not printed; see file:line):" >&2
    cut -d: -f1,2 /tmp/blocklist-hits >&2
    status=1
  fi
done <<<"$terms"
rm -f /tmp/blocklist-hits
exit $status
