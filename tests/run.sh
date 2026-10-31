#!/usr/bin/env bash
# Run every tests/test-*.sh in its own process and report a combined result.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
count=0

for t in "$HERE"/test-*.sh; do
  [[ -e $t ]] || continue
  count=$((count + 1))
  printf '\n# %s\n' "${t##*/}"
  bash "$t" || failed+=("${t##*/}")
done

if [[ $count -eq 0 ]]; then
  echo "FAIL no tests found in $HERE" >&2
  exit 1
fi

printf '\n'
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAIL ${#failed[@]} of $count test file(s) failed: ${failed[*]}" >&2
  exit 1
fi
echo "tests ok: $count file(s)"
