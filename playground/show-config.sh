#!/usr/bin/env bash
#
# Shows how Kong is configured in the playground:
#   1. the declarative source of truth (kong.yml), and
#   2. what Kong actually loaded, via the (read-only) Admin API.
#
# Usage: ./show-config.sh   (after `docker compose up -d`)
set -euo pipefail

ADMIN="${ADMIN:-http://localhost:8001}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pretty-print JSON with jq when available; otherwise print as-is.
pretty() { if command -v jq >/dev/null 2>&1; then jq .; else cat; fi; }

echo "============================================================"
echo " Declarative config (playground/kong.yml)"
echo "============================================================"
cat "$HERE/kong.yml"
echo

echo "============================================================"
echo " Loaded by Kong (Admin API @ $ADMIN — read-only in DB-less)"
echo "============================================================"
for endpoint in services routes plugins consumers; do
  echo
  echo "--- GET /$endpoint ---"
  # .data[] strips Kong's envelope/metadata when jq is present.
  if command -v jq >/dev/null 2>&1; then
    curl -s "$ADMIN/$endpoint" | jq '.data'
  else
    curl -s "$ADMIN/$endpoint"
    echo
  fi
done
