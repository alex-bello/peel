#!/usr/bin/env bash
# Conventions every shell script in the repo follows. Picks up scripts as they land.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$PEEL_ROOT" || exit 1

checked=0
for f in setup.sh scripts/*.sh tools/*.sh tests/*.sh; do
  [[ -e $f ]] || continue
  checked=$((checked + 1))
  assert_eq "$f: bash shebang" "#!/usr/bin/env bash" "$(head -n 1 "$f")"
  assert_false "$f: no CRLF line endings" grep -q $'\r' "$f"
done

# Entry points are executed directly, so they must be executable. Sourced libs are exempt.
for f in setup.sh tools/lint.sh tests/run.sh scripts/discover.sh scripts/test-print.sh; do
  [[ -e $f ]] || continue
  assert_true "$f: executable" test -x "$f"
done

if [[ $checked -gt 0 ]]; then
  pass "checked $checked script(s)"
else
  fail "found no shell scripts to check"
fi

finish
