#!/usr/bin/env bash
# Lint every shell script in the repo: `bash -n` (syntax), then shellcheck.
# Fails loudly if shellcheck is missing; it is a developer tool, not an npm dependency.
set -euo pipefail

ROOT="${PEEL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "FAIL shellcheck not found. Install it: brew install shellcheck (macOS) or sudo apt-get install shellcheck (Debian/Raspberry Pi OS)." >&2
  exit 1
fi

files=()
for f in setup.sh scripts/*.sh tools/*.sh tests/*.sh; do
  [[ -e $f ]] && files+=("$f")
done

if [[ ${#files[@]} -eq 0 ]]; then
  echo "FAIL no shell scripts found under $ROOT" >&2
  exit 1
fi

for f in "${files[@]}"; do
  bash -n "$f"
done
shellcheck -x "${files[@]}"
echo "lint ok: ${#files[@]} shell script(s) (bash -n + shellcheck $(shellcheck --version | awk '/^version:/ {print $2}'))"
