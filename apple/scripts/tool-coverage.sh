#!/usr/bin/env bash
# Every desktop panel.* and tool.* UI command (tools: state.rs Tool::ALL, panels: dock.rs PanelKind::ALL) must have an
# entry in apple/docs/tool-map.toml (`ios = "..."` or `excluded = "reason"`), and every entry must name
# an existing id. Prints a markdown "Tools and panels" section. Exit 1 on a gap.
# Needs cargo (host build of apple/bridge), bash, grep.
set -euo pipefail
APPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP="${TOOL_COVERAGE_MAP:-$APPLE/docs/tool-map.toml}"
[[ -f "$MAP" ]] || { echo "error: $MAP not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{ "$APPLE/scripts/dump-catalog.sh" tools; "$APPLE/scripts/dump-catalog.sh" panels; } | cut -f1 | grep -E '^(panel|tool)\.' | sort -u > "$TMP/desktop.txt"

# mapped id<TAB>ios|excluded<TAB>text
awk '
  /^\[[A-Za-z0-9_.]+\]/ { id=$0; gsub(/[\[\]]/,"",id); next }
  /^(ios|swift|excluded)[ ]*=/ { k=$1; v=$0; sub(/^[^=]*=[ ]*"/,"",v); sub(/"[ ]*$/,"",v); print id "\t" k "\t" v }
' "$MAP" | sort > "$TMP/map.tsv"
cut -f1 "$TMP/map.tsv" | sort -u > "$TMP/mapped.txt"

status=0
comm -23 "$TMP/desktop.txt" "$TMP/mapped.txt" > "$TMP/unmapped.txt"
comm -13 "$TMP/desktop.txt" "$TMP/mapped.txt" > "$TMP/stale.txt"
if [[ -s "$TMP/unmapped.txt" ]]; then echo "error: desktop ids missing from tool-map.toml:" >&2; sed 's/^/  /' "$TMP/unmapped.txt" >&2; status=1; fi
if [[ -s "$TMP/stale.txt" ]]; then echo "error: tool-map.toml names ids that are not desktop panel/tool commands:" >&2; sed 's/^/  /' "$TMP/stale.txt" >&2; status=1; fi

echo "## Tools and panels"
echo
echo "| Desktop id | iOS |"
echo "|---|---|"
while IFS=$'\t' read -r id kind text; do
  if [[ "$kind" == excluded ]]; then echo "| \`$id\` | excluded: $text |"; else echo "| \`$id\` | $text |"; fi
done < "$TMP/map.tsv"
echo
todo=$(grep -c $'\tTODO$' "$TMP/map.tsv" || true)
[[ "$todo" != 0 ]] && echo "note: $todo entries are still swift = \"TODO\"" >&2
[[ "${1:-}" == --strict && "$todo" != 0 ]] && status=1
echo "$(wc -l < "$TMP/desktop.txt" | tr -d ' ') desktop panel/tool ids, $(grep -c $'\texcluded\t' "$TMP/map.tsv" || true) excluded."
exit $status
