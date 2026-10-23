#!/usr/bin/env bash
# Merge the original FilmCraft code (remote `upstream`) into the fork's `main`.
#
# Usage: apple/scripts/sync-upstream.sh [--no-verify] [-h|--help]
#   --no-verify  skip the post-merge checks (bridge gate, xcframework, coverage scripts)
#
# The fork only adds paths (apple/, FORK.md, .github/workflows/apple-*.yml), so the merge is conflict-free.
# The script refuses to run if the fork changed any upstream file, or if the working tree is dirty.
set -euo pipefail

VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --no-verify) VERIFY=0 ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/storytold/filmcraft}"
FORK_PATHS='^(apple/|FORK\.md$|\.github/workflows/apple-)'

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean; commit or stash first" >&2
  exit 1
fi
[[ "$(git branch --show-current)" == main ]] || { echo "error: run on main" >&2; exit 1; }

echo "==> Fetching upstream"
git fetch upstream

# Upstream files the fork changed since the last merge base: there must be none.
BASE="$(git merge-base HEAD upstream/main)"
TOUCHED="$(git diff --name-only "$BASE" HEAD | grep -Ev "$FORK_PATHS" || true)"
if [[ -n "$TOUCHED" ]]; then
  echo "error: the fork changed upstream files (move the change upstream or into apple/):" >&2
  echo "$TOUCHED" >&2
  exit 1
fi

if git merge-base --is-ancestor upstream/main HEAD; then
  echo "==> Already up to date with upstream/main"
  exit 0
fi

echo "==> Merging upstream/main"
git merge --no-ff --no-edit -m "Merge upstream/main into main [skip ci]" upstream/main

if [[ "$VERIFY" == 1 ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  echo "==> Bridge gate"
  (cd apple/bridge && cargo test && cargo clippy --all-targets -- -D warnings)
  echo "==> xcframework (simulator, debug)"
  apple/scripts/build-xcframework.sh --sim-only --debug
  echo "==> Coverage scripts"
  apple/scripts/check-command-ids.sh
  apple/scripts/tool-coverage.sh
  apple/scripts/feature-coverage.sh --check || echo "note: regenerate with apple/scripts/feature-coverage.sh and commit"
fi
echo "==> Done. Review, then: git push origin main"
