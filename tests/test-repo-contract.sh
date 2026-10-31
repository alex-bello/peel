#!/usr/bin/env bash
# Repo contract: package scripts, SDLC config, and docs that must not drift from them.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$PEEL_ROOT" || exit 1

# pkg_field EXPR: evaluate a JS expression against package.json as `p`.
pkg_field() { node -e "const p=require('./package.json'); const v=($1); console.log(v ?? '')"; }

name="$(pkg_field 'p.name')"
assert_eq "package name is peel" "peel" "$name"

for s in lint test validate sdlc:validate-config; do
  assert_true "package.json defines script '$s'" node -e "process.exit(require('./package.json').scripts['$s'] ? 0 : 1)"
done

validate="$(pkg_field 'p.scripts.validate')"
for part in "run lint" "run test" "sdlc:validate-config"; do
  case "$validate" in
    *"$part"*) pass "validate runs '$part'" ;;
    *) fail "validate runs '$part'" "validate is: $validate" ;;
  esac
done

assert_true ".sdlc.yml passes the vendored validator" node scripts/sdlc/validate-config.mjs -- .sdlc.yml

# Guards against copying the template of a sibling repo without renaming its worktree root.
worktree_root="$(sed -n 's/^  worktree_root: *//p' .sdlc.yml)"
assert_eq "worktree_root is ../<package name>-worktrees" "../${name}-worktrees" "$worktree_root"

# Every `pnpm run X` mentioned in the docs must be a real script.
for doc in AGENTS.md SDLC.md README.md; do
  [[ -f $doc ]] || continue
  while IFS= read -r cmd; do
    assert_true "$doc: 'pnpm run $cmd' exists" node -e "process.exit(require('./package.json').scripts['$cmd'] ? 0 : 1)"
  done < <(grep -oE 'pnpm run [A-Za-z0-9:_-]+' "$doc" | awk '{print $3}' | sort -u)
done

finish
