#!/usr/bin/env bash
# Feature coverage of the iOS app against the engine catalog and the desktop UI command table.
#
# Usage: apple/scripts/feature-coverage.sh [--check]
#   (no option)  regenerate apple/docs/FEATURE_COVERAGE.md
#   --check      do not write: exit 1 when the committed file is stale
# Needs cargo (host build of apple/bridge) and python3.
set -euo pipefail
APPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=report
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$APPLE/scripts/dump-catalog.sh" engine > "$TMP/engine.tsv"
{ "$APPLE/scripts/dump-catalog.sh" ui; "$APPLE/scripts/dump-catalog.sh" tools; "$APPLE/scripts/dump-catalog.sh" panels; } | awk -F"\t" '!seen[$1]++' > "$TMP/ui.tsv"
python3 -I "$APPLE/scripts/feature-coverage.py" "$MODE" "$TMP/engine.tsv" "$TMP/ui.tsv"
