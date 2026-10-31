#!/usr/bin/env bash
# tools/lint.sh must pass clean scripts and reject syntax errors and shellcheck findings.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$PEEL_ROOT/tools/lint.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts"

# A sandbox "repo" so the real scripts are never involved.
printf '#!/usr/bin/env bash\necho "hello"\n' >"$tmp/scripts/good.sh"
assert_true "clean script passes" env PEEL_ROOT="$tmp" bash "$LINT"

printf '#!/usr/bin/env bash\nif then\n' >"$tmp/scripts/good.sh"
assert_false "syntax error is rejected" env PEEL_ROOT="$tmp" bash "$LINT"

# shellcheck disable=SC2016  # the literal, unquoted $UNQUOTED is the defect under test
printf '#!/usr/bin/env bash\nrm -rf $UNQUOTED/*\n' >"$tmp/scripts/good.sh"
assert_false "shellcheck finding is rejected" env PEEL_ROOT="$tmp" bash "$LINT"

rm -f "$tmp/scripts/good.sh"
assert_false "no scripts at all is an error" env PEEL_ROOT="$tmp" bash "$LINT"

finish
