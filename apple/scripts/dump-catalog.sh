#!/usr/bin/env bash
# Print the bridge's command tables: dump-catalog.sh engine|ui|menus  (tab separated).
# engine: id label menu params; ui: id label menu; menus: title items. Needs cargo (host build of apple/bridge).
set -euo pipefail
BRIDGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bridge" && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
cd "$BRIDGE" && cargo run -q --example dump -- "${1:?engine|ui|menus}" 2> >(grep -v 'craft-fonts' >&2)
